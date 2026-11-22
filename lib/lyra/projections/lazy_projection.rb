# frozen_string_literal: true

module Lyra
  module Projections
    # ES-Lazy: event sourcing that projects on read.
    #
    # Enabled with projection_mode :lazy in event-sourcing mode. Writes store
    # events only, as in ES-NoProj. Before any database read, the tables are
    # brought up to date from the event log, and the read then runs as real
    # SQL: joins, merged relations, SQL fragments and aggregates all work. The
    # log stays the only source of truth; the tables are a cache that can be
    # thrown away and rebuilt (Rebuild).
    #
    # Correctness rests on three rules:
    # - Events are applied one by one in the log's global order, so a parent
    #   row always exists before its child's (foreign keys), and each record
    #   ends in the state its last event says.
    # - A checkpoint records the last event applied. Catch-up runs under a
    #   PostgreSQL advisory lock, so concurrent readers never apply an event
    #   twice, and in the reader's transaction, so a rolled-back write leaves
    #   neither rows nor a checkpoint past it.
    # - Event ids are assigned before commit, so a slow transaction can make
    #   event 10 visible after event 11. The checkpoint therefore also records
    #   the ids missing below it. When a missing event appears later, its
    #   record is replayed in full (Rebuild.replay_record), which converges
    #   however late it arrives. A gap still empty after GAP_TTL seconds is
    #   taken to be a rolled-back transaction and forgotten; this is the mode's
    #   one bound: a single transaction open for longer than GAP_TTL would have
    #   its events skipped. A fresh checkpoint also watches the FRESH_WINDOW ids
    #   below the first visible event, where in-flight writes would be.
    # - Open gaps are re-checked at most every GAP_RECHECK seconds, so they do
    #   not slow every read. A write that commits late in another connection
    #   becomes visible within about GAP_RECHECK; a process's own writes, above
    #   the checkpoint, are visible immediately.
    #
    # Cost: every read first checks whether the log has moved on, in one
    # query that reads the checkpoint and the newest event id together.
    # Catch-up happens only when it has. A reader that finds another reader
    # catching up does not queue to repeat its work: it waits for that
    # catch-up to end and reads the checkpoint again (wait_for_catch_up). A
    # catch-up that applies nothing writes no checkpoint. The checkpoint
    # table is created on first use, so enabling the mode needs no migration.
    class LazyProjection
      TABLE = "lyra_projection_checkpoints"
      NAME = "lazy"
      LOCK = "lyra_lazy_projection"
      GAP_TTL = 300
      GAP_RECHECK = 1.0
      FRESH_WINDOW = 100
      BATCH = 1_000
      # How often a reader waits for another reader's catch-up before it
      # queues for the lock itself, as every reader did before. Two waits
      # suffice when every catch-up commits: the second holder took the lock
      # after this reader's check, so it saw every event this reader must
      # see. The third allows for one that rolled back, or for a try that
      # failed only because another waiter held the lock shared for a moment.
      WAITS = 3

      class << self
        def active?
          Lyra.event_sourcing_mode? && Lyra.config.projection_mode == :lazy
        end

        # Run the block with no catch-up before its reads (a write that
        # caught up when it began: BypassEvents.atomically).
        def without_catch_up
          return yield unless active?

          previous = Thread.current[:lyra_lazy_catching_up]
          Thread.current[:lyra_lazy_catching_up] = true
          begin
            yield
          ensure
            Thread.current[:lyra_lazy_catching_up] = previous
          end
        end

        # Called before a read on +model_class+ (see Interceptors::LazyReads).
        def before_read(model_class)
          return unless active?
          return if Thread.current[:lyra_lazy_catching_up]
          return if internal?(model_class)

          catch_up!
        end

        # Apply every event not yet in the tables. Returns the number applied.
        # Only while ES-Lazy is the current configuration, unless +force+: the
        # mode check catches the tables up before leaving ES-Lazy, and the
        # process running it may already be configured for the target mode.
        def catch_up!(force: false)
          return 0 unless force || active?
          return 0 if Thread.current[:lyra_lazy_catching_up]

          began = Thread.current[:lyra_lazy_catching_up] = true
          ActiveRecord::Base.with_connection do |connection|
            ensure_table!(connection)
            target = catch_up_target(connection)
            next 0 unless target

            ActiveRecord::Base.transaction { catch_up_to(connection, target) }
          end
        ensure
          # Only the call that set it (a call refused above left it to its
          # owner: a catch-up under way, or LazyProjection.without_catch_up).
          Thread.current[:lyra_lazy_catching_up] = nil if began
        end

        # The current checkpoint: [position, { gap_id => first_seen_epoch }].
        def checkpoint(connection = nil)
          return ActiveRecord::Base.with_connection { |c| checkpoint(c) } unless connection

          ensure_table!(connection)
          row = connection.select_one("SELECT position, gaps FROM #{TABLE} WHERE name = #{connection.quote(NAME)}")
          return [0, {}] unless row

          parse_checkpoint(row["position"], row["gaps"])
        end

        # Bring the rows of +ids+ (records of +model_class+) up to date with
        # their streams, where a stream has an event the tables have not had
        # yet (past the checkpoint, or among its gaps): that record is
        # replayed onto its row (Rebuild.replay_record), as a catch-up would.
        # For a write that skips callbacks, once it holds the records'
        # aggregate locks (Lyra::BypassEvents): an update committed after the
        # catch-up the write began with is then in the row it writes, not
        # lost under it. One query when every row is up to date. Returns how
        # many records were replayed.
        def refresh_records(model_class, ids)
          return 0 unless active? && ids.any?

          ActiveRecord::Base.with_connection do |connection|
            position, gaps = checkpoint(connection)
            prefix = Lyra.stream_prefix(model_class)
            streams = ids.map { |id| connection.quote("#{prefix}#{id}") }.join(", ")
            pending = ["e.id > #{Integer(position)}"]
            pending << "e.id IN (#{gaps.keys.map { Integer(_1) }.join(',')})" if gaps.any?
            behind = connection.uncached do
              connection.select_values(
                "SELECT DISTINCT s.stream FROM event_store_events_in_streams s " \
                "JOIN event_store_events e ON e.event_id = s.event_id " \
                "WHERE s.stream IN (#{streams}) AND (#{pending.join(' OR ')})",
                "Lyra ES-Lazy rows behind"
              )
            end
            behind.each { |stream| Rebuild.replay_record(model_class, stream.delete_prefix(prefix)) }
            behind.size
          end
        end

        # Forget the checkpoint, e.g. after the tables were truncated or rebuilt.
        def reset!(connection = nil)
          return ActiveRecord::Base.with_connection { |c| reset!(c) } unless connection

          connection.execute("DELETE FROM #{TABLE}") if connection.table_exists?(TABLE)
          @gaps_checked_at = nil
        end

        private

        def internal?(model_class)
          table = model_class.respond_to?(:table_name) ? model_class.table_name.to_s : ""
          table.start_with?("event_store_") || table == TABLE
        end

        def parse_checkpoint(position, gaps)
          [position.to_i, JSON.parse(gaps || "{}").transform_keys(&:to_i)]
        end

        # Fast path, no lock: nil when nothing is new and open gaps (if any)
        # were re-checked less than GAP_RECHECK seconds ago. Otherwise the
        # newest event id this read must see applied: the catch-up target.
        #
        # One statement reads the checkpoint and the newest event id, so both
        # come from one snapshot. It decides as the two queries it replaces
        # did, so the fast path skips exactly what it skipped before.
        def catch_up_target(connection)
          row = connection.select_rows(<<~SQL.squish).first
            SELECT c.position, c.gaps, (SELECT MAX(id) FROM event_store_events)
            FROM (SELECT 1) AS one LEFT JOIN #{TABLE} c ON c.name = #{connection.quote(NAME)}
          SQL
          position, gaps = parse_checkpoint(row[0], row[1])
          newest = row[2].to_i
          # A checkpoint past the newest event cannot be right: the event
          # store was emptied or restored without this table. Taken at its
          # word, every new event would look applied and nothing would be
          # projected again; start over instead (applying is idempotent).
          if position > newest
            warn_stale_checkpoint(position, newest)
            reset!(connection)
            return newest.zero? ? nil : newest
          end
          return newest if newest > position

          gaps_rechecked?(gaps) ? nil : newest
        end

        def gaps_rechecked?(gaps)
          gaps.empty? || (Process.clock_gettime(Process::CLOCK_MONOTONIC) - (@gaps_checked_at || 0)) < GAP_RECHECK
        end

        # Bring the tables up to +target+, in the reader's transaction.
        #
        # The reader that gets the lock catches up, as before. A reader that
        # finds the lock taken does not queue behind it to repeat the same
        # work: it waits for that catch-up to end (AdvisoryLock.wait_for),
        # then reads the checkpoint again and is done if nothing it must see
        # is left (caught_up_to?). Otherwise it tries again, and after WAITS
        # waits it queues for the lock and catches up itself, as before.
        #
        # The rules hold: only the lock's holder applies events or writes the
        # checkpoint, in its own transaction, in the log's order, from the
        # checkpoint it reads under the lock (rules 1 and 2); a reader that
        # waited applies and writes nothing, so its transaction has nothing
        # to roll back. Waiting skips work only when the work is done, by a
        # catch-up that committed (the waiter reads the committed checkpoint
        # after the holder's transaction ended), and it is judged with the
        # gap list (rule 3), more strictly than the fast path judges it.
        def catch_up_to(connection, target)
          WAITS.times do
            return apply_pending(connection) if try_lock!(connection)

            wait_for_catch_up(connection)
            return 0 if caught_up_to?(connection, target)
          end
          lock!(connection)
          apply_pending(connection)
        end

        # After waiting: has a committed catch-up applied every event this
        # reader must see? Those are the events visible to it, up to the
        # newest it saw before waiting (+target+; events committed later are
        # not owed to this read). The checkpoint must have reached +target+,
        # and no event the checkpoint lists as missing may be visible to this
        # reader: such an event committed (or was written by this reader's
        # own open transaction) after the catch-up passed its id, and only a
        # catch-up under the lock replays it. So this reader sees what it
        # would have seen had it queued for the lock and caught up itself;
        # unlike the fast path, it does not wait GAP_RECHECK for a late event.
        def caught_up_to?(connection, target)
          position, gaps = checkpoint(connection)
          return false if position < target
          return true if gaps.empty?

          connection.select_value(
            "SELECT 1 FROM event_store_events WHERE id IN (#{gaps.keys.map { Integer(_1) }.join(',')}) LIMIT 1"
          ).nil?
        end

        def apply_pending(connection)
          position, gaps = checkpoint(connection)
          started_at = [position, gaps.dup]
          applied = 0

          loop do
            rows = connection.select_rows(
              "SELECT id, event_id FROM event_store_events WHERE id > #{Integer(position)} ORDER BY id LIMIT #{BATCH}"
            )
            break if rows.empty?

            events = load_events(rows.map(&:last))
            # A fresh checkpoint starts at the first visible event: ids below it
            # are history (deleted, or from before the mode was enabled), not
            # in-flight writes.
            expected = position.zero? ? [rows.first.first.to_i - FRESH_WINDOW, 1].max : position + 1
            rows.each do |id, event_id|
              id = id.to_i
              (expected...id).each { |missing| gaps[missing] ||= Time.now.to_i }
              expected = id + 1
              event = events[event_id]
              applied += 1 if event && apply_event(event)
            end
            position = rows.last.first.to_i
          end

          applied += fill_gaps(connection, gaps)
          # A catch-up that found nothing new (another reader got there
          # first) leaves the checkpoint row alone: rewriting the same values
          # cost a row write and a commit that must reach the disk, all under
          # the lock every other catching-up reader waits on.
          save_checkpoint(connection, position, gaps) unless [position, gaps] == started_at
          applied
        end

        # Events that were in flight when their id was passed: replay each
        # one's whole record, so it converges however late it arrived.
        def fill_gaps(connection, gaps)
          @gaps_checked_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          return 0 if gaps.empty?

          rows = connection.select_rows(
            "SELECT id, event_id FROM event_store_events WHERE id IN (#{gaps.keys.map { Integer(_1) }.join(',')})"
          )
          events = load_events(rows.map(&:last))
          rows.each do |id, event_id|
            gaps.delete(id.to_i)
            event = events[event_id] or next
            model_class, model_id = target_of(event)
            Rebuild.replay_record(model_class, model_id) if model_class
          end
          @gaps_checked_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          expired = Time.now.to_i - GAP_TTL
          gaps.delete_if { |_, seen| seen < expired }
          rows.size
        end

        def apply_event(event)
          model_class, = target_of(event)
          operation = operation_of(event)
          return false unless model_class && operation

          ModelProjection.project(model_class, operation, Struct.new(:events, :attributes, :success?, keyword_init: true).new(
            events: [event], success?: true,
            attributes: if %i[created imported].include?(operation)
                          Lyra::Event.created_attributes(event.data)
                        else
                          event.data[:attributes] || event.data["attributes"] || {}
                        end
          ), INTERNAL)
          true
        end

        def target_of(event)
          name = event.data[:model_class] || event.data["model_class"]
          id = event.data[:model_id] || event.data["model_id"]
          model_class = Lyra.config.monitored_model_named(name)
          [model_class, id]
        end

        def operation_of(event)
          case Lyra::Event.operation_of(event)
          when :created, :imported then :create
          when :updated then :update
          when :destroyed then :destroy
          end
        end

        def load_events(event_ids)
          return {} if event_ids.empty?

          Lyra.config.event_store.read.events(event_ids).to_a.to_h { |e| [e.event_id, e] }
        end

        def warn_stale_checkpoint(position, newest)
          message = "Lyra: ES-Lazy checkpoint #{position} is past the newest event (#{newest}); " \
                    "the event store was emptied or restored without #{TABLE}. Catching up from the start."
          defined?(Rails) && Rails.logger ? Rails.logger.warn(message) : Kernel.warn(message)
        end

        def lock!(connection)
          Lyra::AdvisoryLock.xact_lock(connection, LOCK, purpose: "ES-Lazy catch-up")
        end

        # True when this transaction now holds the catch-up lock (or the
        # adapter has none, as lock! then takes none); false when another
        # reader holds it.
        def try_lock!(connection)
          Lyra::AdvisoryLock.try_xact_lock(connection, LOCK, purpose: "ES-Lazy catch-up")
        end

        # Wait until the reader that holds the catch-up lock has committed or
        # rolled back. Several waiters go on together.
        def wait_for_catch_up(connection)
          Lyra::AdvisoryLock.wait_for(connection, LOCK)
        end

        def save_checkpoint(connection, position, gaps)
          name = connection.quote(NAME)
          json = connection.quote(JSON.generate(gaps))
          updated = connection.exec_update(
            "UPDATE #{TABLE} SET position = #{Integer(position)}, gaps = #{json}, updated_at = CURRENT_TIMESTAMP WHERE name = #{name}"
          )
          return if updated.to_i.positive?

          connection.execute(
            "INSERT INTO #{TABLE} (name, position, gaps, updated_at) VALUES (#{name}, #{Integer(position)}, #{json}, CURRENT_TIMESTAMP)"
          )
        end

        def ensure_table!(connection)
          return if @table_ready

          Lyra.create_own_table(connection, TABLE) do |conn|
            conn.create_table(TABLE, id: false) do |t|
              t.string :name, null: false
              t.bigint :position, null: false, default: 0
              t.text :gaps
              t.datetime :updated_at
            end
            conn.add_index(TABLE, :name, unique: true)
          end
          @table_ready = true
        end
      end
    end
  end
end
