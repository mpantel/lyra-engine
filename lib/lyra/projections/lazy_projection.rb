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
    # Cost: every read first checks whether the log has moved on (two small
    # queries). Catch-up happens only when it has. The checkpoint table is
    # created on first use, so enabling the mode needs no migration.
    class LazyProjection
      TABLE = "lyra_projection_checkpoints"
      NAME = "lazy"
      LOCK = "lyra_lazy_projection"
      GAP_TTL = 300
      GAP_RECHECK = 1.0
      FRESH_WINDOW = 100
      BATCH = 1_000

      class << self
        def active?
          Lyra.event_sourcing_mode? && Lyra.config.projection_mode == :lazy
        end

        # Called before a read on +model_class+ (see Interceptors::LazyReads).
        def before_read(model_class)
          return unless active?
          return if Thread.current[:lyra_lazy_catching_up]
          return if internal?(model_class)

          catch_up!
        end

        # Apply every event not yet in the tables. Returns the number applied.
        def catch_up!
          return 0 unless active?
          return 0 if Thread.current[:lyra_lazy_catching_up]

          Thread.current[:lyra_lazy_catching_up] = true
          connection = ActiveRecord::Base.connection
          ensure_table!(connection)
          return 0 if up_to_date?(connection)

          applied = 0
          ActiveRecord::Base.transaction do
            lock!(connection)
            applied = apply_pending(connection)
          end
          applied
        ensure
          Thread.current[:lyra_lazy_catching_up] = nil
        end

        # The current checkpoint: [position, { gap_id => first_seen_epoch }].
        def checkpoint(connection = ActiveRecord::Base.connection)
          ensure_table!(connection)
          row = connection.select_one("SELECT position, gaps FROM #{TABLE} WHERE name = #{connection.quote(NAME)}")
          return [0, {}] unless row

          [row["position"].to_i, JSON.parse(row["gaps"] || "{}").transform_keys(&:to_i)]
        end

        # Forget the checkpoint, e.g. after the tables were truncated or rebuilt.
        def reset!(connection = ActiveRecord::Base.connection)
          connection.execute("DELETE FROM #{TABLE}") if connection.table_exists?(TABLE)
          @gaps_checked_at = nil
        end

        private

        def internal?(model_class)
          table = model_class.respond_to?(:table_name) ? model_class.table_name.to_s : ""
          table.start_with?("event_store_") || table == TABLE
        end

        # Fast path, no lock: nothing new, and open gaps (if any) were
        # re-checked less than GAP_RECHECK seconds ago.
        def up_to_date?(connection)
          position, gaps = checkpoint(connection)
          return false if max_event_id(connection) > position

          gaps.empty? || (Process.clock_gettime(Process::CLOCK_MONOTONIC) - (@gaps_checked_at || 0)) < GAP_RECHECK
        end

        def apply_pending(connection)
          position, gaps = checkpoint(connection)
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
          save_checkpoint(connection, position, gaps)
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
            events: [event], attributes: event.data[:attributes] || event.data["attributes"] || {}, success?: true
          ))
          true
        end

        def target_of(event)
          name = event.data[:model_class] || event.data["model_class"]
          id = event.data[:model_id] || event.data["model_id"]
          model_class = name && Lyra.config.monitored_models.find { |m| m.name == name }
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

        def max_event_id(connection)
          connection.select_value("SELECT MAX(id) FROM event_store_events").to_i
        end

        def lock!(connection)
          return unless connection.adapter_name.match?(/postgres/i)

          connection.execute("SELECT pg_advisory_xact_lock(hashtext(#{connection.quote(LOCK)}))")
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

          unless connection.table_exists?(TABLE)
            connection.create_table(TABLE, id: false) do |t|
              t.string :name, null: false
              t.bigint :position, null: false, default: 0
              t.text :gaps
              t.datetime :updated_at
            end
            connection.add_index(TABLE, :name, unique: true)
          end
          @table_ready = true
        end
      end
    end
  end
end
