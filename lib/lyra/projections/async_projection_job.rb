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

      # A create that met, in a unique index, the row of a record whose
      # stream gave the value up, and whose row is held by another
      # transaction, so it could not be brought up to date (ModelProjection
      # .refuse_skipped_create!, which brings it up to date when it is
      # free, so a holder whose own job was lost does not block): tried
      # again, at most every five minutes, for about a day (BEHIND_ATTEMPTS;
      # five attempts gave up after about seven minutes, and the record never
      # reached the table). Then it is reported (logged, and passed to
      # config.projection_error_handler) and given up: the row was held for
      # a day; a rebuild of the model projects the record. (Declared after
      # the general retry: Active Job takes the last handler that matches.)
      BEHIND_ATTEMPTS = 300
      retry_on Lyra::Projections::ProjectionBehind, attempts: BEHIND_ATTEMPTS,
                                                    wait: ->(executions) { [(executions**4) + 2, 300].min } do |_job, error|
        message = "#{error.message}; given up after #{BEHIND_ATTEMPTS} attempts: rebuild the model's projection " \
                  "(bin/rails lyra:projections:rebuild) once the row is free"
        Rails.logger.error(message) if defined?(Rails) && Rails.logger
        Lyra.config.projection_error_handler&.call(error, nil, :create)
      end

      # Two live records of the log hold one value (DuplicateInLog): no
      # attempt can project both. Logged once (ModelProjection), not retried.
      discard_on Lyra::Projections::DuplicateInLog

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
      #
      # The job does not wait for its row while it holds the stream's lock
      # (PostgreSQL): once it has the lock it takes the row's, skipping it if
      # another transaction holds it (row_taken?, the one statement this
      # costs), and then lets the lock go (its transaction, which wrote
      # nothing, commits), waits for the row with no lock of its own, and
      # starts again, up to ROW_WAITS times; after that it waits holding
      # the lock, as it always did. A transaction that held the row (an
      # update_columns, touch, delete, update_all, lock! or with_lock) and
      # then brought it up to date for an insert_all or upsert_all
      # (project_pending, which takes the stream's lock) deadlocked against
      # a job that had taken the lock and waited for the row. A job that
      # holds the row takes no other lock, so the writer then waits for it.
      def perform(event_id, model_class_name, operation = nil)
        event = load_event(event_id)
        return unless event

        model_class = model_class_name.constantize
        model_id = event.data[:model_id] || event.data["model_id"]
        stream = Lyra.stream_name(model_class, model_id)

        ROW_WAITS.times do
          projected = model_class.transaction do
            lock_stream!(model_class, stream)
            next false if row_taken?(model_class, model_id)

            self.class.project_stream(model_class, stream)
            true
          end
          return if projected

          wait_for_row(model_class, model_id)
        end
        model_class.transaction do
          lock_stream!(model_class, stream)
          self.class.project_stream(model_class, stream)
        end
      end

      # How many times a job lets its stream's lock go for a row another
      # transaction holds (perform).
      ROW_WAITS = 3

      class << self
        # Bring the rows of +ids+ (records of +model_class+) up to date with
        # their streams now, as their projection jobs would, for a write that
        # skips callbacks and would otherwise meet a row its job has not
        # written yet (Lyra::BypassEvents.projects_pending?). The caller holds
        # the records' aggregate locks, in its transaction, so no event can
        # be appended to those streams until it ends. The streams with events
        # past their checkpoint (AsyncCheckpoint.behind, one query) are locked
        # as a job locks them, in one statement, after the aggregate locks and
        # before any row (Lyra::AdvisoryLock's order): a job in flight
        # finishes first. Then, as perform does, the events after each
        # checkpoint are applied and the checkpoint is moved to the last of
        # them, in the caller's transaction.
        #
        # The pending jobs cannot apply those events again, nor undo the
        # caller's write: a job applies only what is past the checkpoint,
        # under the same lock, and that is the caller's own event at most,
        # already in the row (a create of an existing row inserts nothing, an
        # update sets the same values). Rolled back with the caller, the rows
        # and the checkpoint go back together, and the jobs apply the events
        # as before. Where checkpoints are not kept (incremental? false) every
        # stream given is replayed, and so is it by its jobs; the row ends as
        # its stream does either way. Returns how many records were brought
        # up to date.
        def project_pending(model_class, ids)
          return 0 if ids.empty?

          model_class.with_connection do |connection|
            streams = ids.map { Lyra.stream_name(model_class, _1) }.uniq
            behind = incremental?(connection) ? AsyncCheckpoint.behind(connection, streams) : streams
            next 0 if behind.empty?

            Lyra::AdvisoryLock.xact_lock_all(connection, behind, purpose: "ES-Async projection")
            behind.count { |stream| project_stream(model_class, stream).positive? }
          end
        end

        # Move the checkpoints of the records in +moves+ ([id, event id]) to
        # those events, in one statement: a write that skips callbacks wrote
        # their rows and those events, the last of their streams, in its
        # transaction, from rows that were up to date
        # (StrictDataAccessRelation#advance_checkpoints). Where checkpoints
        # are kept (incremental?).
        def advance(model_class, moves)
          return if moves.empty?

          model_class.with_connection do |connection|
            next unless incremental?(connection)

            AsyncCheckpoint.write_all(connection, moves.map { |id, event_id| [Lyra.stream_name(model_class, id), event_id] })
          end
        end

        # Apply +stream+'s events after its checkpoint to its row and move the
        # checkpoint to the last of them. The caller holds the stream's lock.
        # Returns how many events there were.
        def project_stream(model_class, stream)
          model_class.with_connection do |connection|
            events = events_to_apply(connection, stream)
            Rebuild.project_events(model_class, events, INTERNAL)
            AsyncCheckpoint.write(connection, stream, events.last.event_id) if events.any? && incremental?(connection)
            events.size
          end
        end

        private

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
      end

      private

      # Serialise projection of one stream across workers (Lyra::AdvisoryLock).
      def lock_stream!(model_class, stream)
        model_class.with_connection { |c| Lyra::AdvisoryLock.xact_lock(c, stream, purpose: "ES-Async projection") }
      end

      # Take the record's row (FOR UPDATE), unless another transaction holds
      # it: true then. One statement; a row not there (a create to project)
      # is not taken. PostgreSQL only (SKIP LOCKED); elsewhere false.
      def row_taken?(model_class, model_id)
        model_class.with_connection do |c|
          next false unless c.adapter_name.match?(/postgres/i)

          from = "FROM #{c.quote_table_name(model_class.table_name)} " \
                 "WHERE #{c.quote_column_name(Lyra.key_column(model_class))} = #{c.quote(model_id)}"
          present, held = c.uncached do
            c.select_rows("SELECT (SELECT 1 #{from}), (SELECT 1 #{from} FOR UPDATE SKIP LOCKED)", "Lyra ES-Async row").first
          end
          !present.nil? && held.nil?
        end
      end

      # Wait, holding no lock of the job's, until the transaction that holds
      # the record's row ends.
      def wait_for_row(model_class, model_id)
        model_class.transaction do
          model_class.with_connection do |c|
            c.uncached do
              c.select_value("SELECT 1 FROM #{c.quote_table_name(model_class.table_name)} " \
                             "WHERE #{c.quote_column_name(Lyra.key_column(model_class))} = #{c.quote(model_id)} FOR UPDATE",
                             "Lyra ES-Async row wait")
            end
          end
        end
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
