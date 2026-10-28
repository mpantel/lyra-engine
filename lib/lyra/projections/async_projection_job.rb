# frozen_string_literal: true

module Lyra
  module Projections
    # ActiveJob for asynchronous projection processing.
    #
    # When projection_mode is :async, events are projected to model tables
    # in background jobs rather than synchronously during the request.
    #
    # Benefits:
    # - Faster response times (don't wait for projection)
    # - Better fault isolation (projection failures don't fail requests)
    # - Retry capability for transient failures
    #
    # Trade-offs:
    # - Eventual consistency (reads may not see latest writes immediately)
    # - Requires background job infrastructure (Sidekiq, etc.)
    #
    # Usage:
    #   AsyncProjectionJob.perform_later(event_id, 'Registration', :create)
    #
    class AsyncProjectionJob < ActiveJob::Base
      queue_as :lyra_projections

      # Enqueue only once the writing transaction commits. The job is enqueued
      # from the model's callbacks, inside the transaction that stores its
      # event; a worker that picks it up earlier cannot see the event, finds
      # nothing, completes, and the projection is lost with no retry. If the
      # transaction rolls back, the event is gone and the job is never enqueued.
      self.enqueue_after_transaction_commit = true

      # Retry with exponential backoff for transient failures
      retry_on StandardError, wait: :polynomially_longer, attempts: 5

      # Don't retry on permanent failures
      discard_on ActiveRecord::RecordNotFound

      # Bring the event's record up to date with its stream, rather than
      # applying this one event.
      #
      # Jobs run concurrently on a worker pool, so a record's jobs can finish in
      # any order. Applying only "this event" let an earlier update land after a
      # later one and roll the row back (the Olist replay through Solidus left
      # orders at "confirm" whose events ended at "complete"), and a late create
      # could even resurrect a destroyed record. Applying the stream in order
      # under a lock held per stream converges instead: whichever job runs last
      # writes the latest state, because the stream only grows and every newer
      # event has a job of its own.
      #
      # Only the events after the stream's checkpoint (AsyncCheckpoint, the
      # last event a job applied) are applied, so a record's jobs cost what its
      # history is long, not its square: replaying the whole stream every time
      # made each job of a record with n events apply all n. That is exact
      # because a record's events commit in the order they were appended:
      # ES-Async writers take the lock on the aggregate before appending
      # (config.lock_aggregate_before_append), so no event can commit, unseen,
      # below a checkpoint already passed. With that lock off, or without a
      # usable checkpoint, the job replays the whole stream as before.
      # +operation+ is kept for job compatibility.
      def perform(event_id, model_class_name, operation = nil)
        event = load_event(event_id)
        return unless event

        model_class = model_class_name.constantize
        model_id = event.data[:model_id] || event.data["model_id"]
        stream = Lyra.stream_name(model_class, model_id)

        model_class.transaction do
          lock_stream!(model_class, stream)
          project_stream(model_class, model_id, stream)
        end
      end

      private

      def project_stream(model_class, model_id, stream)
        model_class.with_connection do |connection|
          events = events_to_apply(connection, stream)
          Rebuild.project_events(model_class, events)
          AsyncCheckpoint.write(connection, stream, events.last.event_id) if events.any? && incremental?(connection)
        end
      end

      # The events after the checkpoint when it can be trusted; the whole
      # stream otherwise (the checkpoint's event is gone, or none was written).
      def events_to_apply(connection, stream)
        reader = Lyra.config.event_store.read.stream(stream)
        position = incremental?(connection) && AsyncCheckpoint.read(connection, stream)
        return reader.to_a unless position

        reader.from(position).to_a
      rescue RubyEventStore::EventNotFound
        Lyra.config.event_store.read.stream(stream).to_a
      end

      # Checkpoints are exact only while writers take the lock on the
      # aggregate, and need a database where it is taken (PostgreSQL) or
      # writers are serialised anyway (SQLite).
      def incremental?(connection)
        Lyra.config.lock_aggregate_before_append && connection.adapter_name.match?(/postgres|sqlite/i)
      end

      # Serialise projection of one stream across workers (Lyra::AdvisoryLock).
      def lock_stream!(model_class, stream)
        model_class.with_connection { |c| Lyra::AdvisoryLock.xact_lock(c, stream, purpose: "ES-Async projection") }
      end

      # read.event returns nil for a missing event (read.event! raises): the
      # warning sat in a rescue of EventNotFound and was never logged.
      def load_event(event_id)
        event = Lyra.config.event_store.read.event(event_id)
        Rails.logger.warn("Lyra::AsyncProjectionJob: Event #{event_id} not found") unless event
        event
      end
    end
  end
end
