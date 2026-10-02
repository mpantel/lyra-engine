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

      # Bring the event's record up to date with its whole stream, rather than
      # applying this one event.
      #
      # Jobs run concurrently on a worker pool, so a record's jobs can finish in
      # any order. Applying only "this event" let an earlier update land after a
      # later one and roll the row back (the Olist replay through Solidus left
      # orders at "confirm" whose events ended at "complete"), and a late create
      # could even resurrect a destroyed record. Replaying the stream in order
      # under a lock held per stream converges instead: whichever job runs last
      # writes the latest state, because the stream only grows and every newer
      # event has a job of its own. +operation+ is kept for job compatibility.
      def perform(event_id, model_class_name, operation = nil)
        event = load_event(event_id)
        return unless event

        model_class = model_class_name.constantize
        model_id = event.data[:model_id] || event.data["model_id"]

        model_class.transaction do
          lock_stream!(model_class, "#{model_class.name}$#{model_id}")
          Rebuild.replay_record(model_class, model_id)
        end
      end

      private

      # Serialise projection of one stream across workers. A PostgreSQL
      # transaction-level advisory lock is released at commit. Other adapters
      # get no lock; SQLite serialises writers anyway.
      def lock_stream!(model_class, stream)
        connection = model_class.connection
        return unless connection.adapter_name.match?(/postgres/i)

        connection.execute("SELECT pg_advisory_xact_lock(hashtext(#{connection.quote(stream)}))")
      end

      def load_event(event_id)
        Lyra.config.event_store.read.event(event_id)
      rescue RubyEventStore::EventNotFound
        Rails.logger.warn("Lyra::AsyncProjectionJob: Event #{event_id} not found")
        nil
      end
    end
  end
end
