# frozen_string_literal: true

module Lyra
  module Projections
    # ES-Lazy: event sourcing that projects on read.
    #
    # Enabled with projection_mode :lazy in event-sourcing mode. Writes store
    # events only, as in ES-NoProj. Before a read through Active Record's
    # hooked paths (Interceptors::LazyReads), the tables are brought up to
    # date from the event log, and the read then runs as real SQL: joins,
    # merged relations, SQL fragments and aggregates all work. The log stays
    # the only source of truth; the tables are a cache that can be thrown away
    # and rebuilt (Rebuild).
    #
    # It rests on four rules:
    # - Events are applied one by one in the log's global order: a gap's
    #   event once visible, before the events above the checkpoint that came
    #   after it, so a parent's row is there before its child's.
    # - A checkpoint records the last event applied. Catch-up runs under a
    #   PostgreSQL advisory lock, so concurrent readers never apply an event
    #   twice, and in the reader's transaction, so a rolled-back write leaves
    #   neither rows nor a checkpoint past it.
    # - Event ids are assigned before commit, so a slow transaction can make
    #   event 10 visible after event 11. The checkpoint therefore also records
    #   the ids missing below it. When a missing event appears later, it is
    #   applied, and after it the later events of its record that were
    #   applied before it, if any, so that it undoes none of them.
    # - The check before a read catches up when an event above the checkpoint,
    #   or the event of a listed gap, is visible to it, this thread's own
    #   writes included; it is never answered from the query cache (a
    #   request's or a job's). Gaps whose events are not visible cost a query
    #   per read, not the lock: those are re-checked under the lock, and the
    #   old ones forgotten, at most every GAP_RECHECK seconds in a process.
    #
    # That check is all the fourth rule promises. It does not make the mode
    # safe for concurrent read-modify-write, and these limits remain:
    # - The catch-up comes before the read's SQL: a locking read (lock,
    #   with_lock) that waited for a row lock does not see what that lock's
    #   holder committed, as the holder wrote events only. Two increments
    #   under a row lock can give 1.
    # - A gap still empty after GAP_TTL seconds is taken to be a rolled-back
    #   transaction and forgotten: the events of a transaction open for longer
    #   than that can be skipped for good.
    # - A fresh checkpoint watches only the FRESH_WINDOW ids below the first
    #   visible event: a write in flight further below is skipped.
    # - Leaving ES-Lazy does not wait for writes in flight: one that commits
    #   after the last catch-up is not in the tables.
    # - A catch-up that cannot be applied fails its read, and every read
    #   after it: events that no order of the log makes valid under the
    #   table's constraints, or one that needs an event skipped for good.
    # - The catch-up lock is held to the end of the application's transaction,
    #   so transactions can deadlock on it: one that holds a row and then
    #   reads waits for the lock, while the lock's holder waits for the row.
    #   PostgreSQL detects it and aborts one (ActiveRecord::Deadlocked). The
    #   fourth rule makes a read catch up wherever a gap's event is visible
    #   to it, where until 1.0.0 the fast path returned stale rows: such a
    #   read can now wait for the lock, and deadlock, instead. That is
    #   deliberate, a detected deadlock rather than a silent stale read.
    #   Reads with only invisible gaps take the lock no more often than
    #   before. In REPEATABLE READ and SERIALIZABLE, visible means in the
    #   transaction's snapshot, and a catch-up can fail with
    #   ActiveRecord::SerializationFailure.
    # - A query repeated in a query-cache scope can be answered from that
    #   cache, as in Active Record. Reads with no hook (raw SQL, eager_load's
    #   records, ids, count_by_sql, a relation's cache_version) and reads
    #   within without_catch_up do not catch up.
    #
    # Cost: every read first checks whether the log has moved on, in one
    # query that reads the checkpoint and the newest event id together, and
    # in a second one while gaps are open. A catch-up happens when the log has
    # moved on, or a gap is to be filled or re-checked. A reader that finds
    # another reader catching up does not queue to repeat its work: it waits
    # for that catch-up to end and reads the checkpoint again
    # (wait_for_catch_up). A catch-up that applies nothing writes no
    # checkpoint. The checkpoint table is created on first use, so enabling
    # the mode needs no migration.
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

      # Design c (1.0.1): a catch-up run for a reader inside a transaction runs
      # in a transaction of its own (Lyra::OwnConnection) and commits at once,
      # so its lock is not held to the reader's commit (the deadlock of 1.0.0).
      # It waits at most SKIP_LOCKED_WAIT for a row another transaction holds,
      # then leaves that record's events on the gap list for a later catch-up;
      # the lock's holder replays the record itself (bring_locked_up_to_date).
      SKIP_LOCKED_WAIT = "100ms"

      # How many times a locking load runs again for records that started to
      # match after its keys were read (lock_selection).
      SELECTION_RECHECKS = 2

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
            # Never from the query cache: it would answer for a log that has
            # moved on since, and for a lock that this call has yet to take.
            connection.uncached do
              target = catch_up_target(connection)
              next 0 unless target
              # Outside a transaction, and in a REPEATABLE READ or SERIALIZABLE
              # one (whose snapshot, taken at its first statement, would not
              # show rows another connection's catch-up commits later), the
              # catch-up runs here, as in 1.0.0.
              if !connection.transaction_open? || snapshot_isolation?(connection)
                next ActiveRecord::Base.transaction { catch_up_to(connection, target) }
              end
              # Inside a transaction (design c): only its own events left, which
              # the reader applies itself, or a catch-up of the others' first.
              writes = own_writes(connection)
              mine = writes && writes[:events].any?
              next apply_own_writes(connection) if mine && !others_pending?(connection)

              catch_up_on_own_connection(connection, target)
            end
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
        # replayed onto its row in full (Rebuild.replay_record; a catch-up
        # applies the event itself, in the log's order).
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

        # Record that this transaction appended an event of a record (called by
        # Lyra.append_events in ES-Lazy): the catch-up on a connection of its own
        # cannot see it before the commit, so the reader's own reads replay it
        # (apply_own_writes). Forgotten when the transaction ends.
        # The records and events this thread's open transaction on +connection+
        # appended, or nil. Tied to the outermost transaction's object, so a
        # later transaction, after a commit or a rollback, starts empty.
        def own_writes(connection)
          writes = Thread.current[:lyra_lazy_own_writes]
          return nil unless writes && connection.transaction_open?

          writes[:transaction].equal?(outermost(connection)) ? writes : nil
        end

        # Whether +connection+'s transaction reads from one snapshot: an
        # isolation level the application set for it (transaction(isolation:),
        # or the pool's). A database whose default level is REPEATABLE READ is
        # not seen here.
        def snapshot_isolation?(connection)
          %i[repeatable_read serializable].include?(connection.current_transaction.isolation)
        end

        # The outermost open transaction of +connection+ (Active Record's own
        # object, one per BEGIN).
        def outermost(connection)
          connection.transaction_manager.instance_variable_get(:@stack).first
        end

        def own_write!(model_class, id, event_id)
          return unless active?

          model_class.with_connection do |connection|
            next unless connection.transaction_open?

            writes = own_writes(connection) ||
                     (Thread.current[:lyra_lazy_own_writes] = { transaction: outermost(connection), records: {}, events: [] })
            writes[:records][[model_class, id]] = true
            writes[:events] << event_id
          end
        end

        # Whether an event other than the reader's own is visible to it and not
        # yet in the tables: past the checkpoint, or listed as a gap.
        def others_pending?(connection)
          own = own_writes(connection)&.fetch(:events) || []
          position, gaps = checkpoint(connection)
          pending = ["e.id > #{Integer(position)}"]
          pending << "e.id IN (#{gaps.keys.map { Integer(_1) }.join(',')})" if gaps.any?
          mine = own.empty? ? "" : " AND e.event_id NOT IN (#{own.map { connection.quote(_1) }.join(',')})"
          !connection.select_value("SELECT 1 FROM event_store_events e WHERE (#{pending.join(' OR ')})#{mine} LIMIT 1",
                                   "Lyra ES-Lazy others pending").nil?
        end

        # The reader's own events, uncommitted, onto their rows, in its
        # transaction: the records it wrote, whose aggregate locks it holds, so
        # no other writer of them commits meanwhile (the lock order is the
        # aggregate, then the row). Each record once per run of its writes.
        # Returns how many were replayed.
        def apply_own_writes(connection)
          writes = own_writes(connection)
          return 0 unless writes

          pending = writes[:records].select { |_, dirty| dirty }.keys
          pending.each do |model_class, id|
            Rebuild.replay_record(model_class, id)
            writes[:records][[model_class, id]] = false
          end
          pending.size
        end

        # Catch up for a reader inside a transaction (design c): the catch-up in
        # a transaction of its own, committed at once, skipping rows another
        # transaction holds; then the reader's own events, which that
        # transaction cannot see. Where no second connection can be had (a
        # pinned connection in transactional tests, a full pool), the catch-up
        # runs in the reader's transaction, as in 1.0.0.
        def catch_up_on_own_connection(connection, target)
          applied = Lyra::OwnConnection.run(ActiveRecord::Base, wait_for_connection: false) do |inline|
            if inline
              ActiveRecord::Base.transaction { catch_up_to(connection, target) }
            else
              Thread.current[:lyra_lazy_catching_up] = true
              ActiveRecord::Base.with_connection do |own|
                own.uncached do
                  own_target = catch_up_target(own)
                  own_target ? own.transaction { catch_up_to(own, own_target, skip_locked: true) } : 0
                end
              end
            end
          end
          applied.to_i + apply_own_writes(connection)
        end

        # Whether a locking read (lock!, with_lock, lock.find) takes its records'
        # aggregate locks before it reads them (from 1.0.1): in ES-Lazy, before
        # its row locks; in ES-NoProj, which keeps no rows to lock, before it
        # reads their streams; in ES-Async, before the streams' locks, under
        # which the rows are brought up to date, and then the row locks: the
        # order a write that skips callbacks takes them in
        # (Lyra::Verification::AsyncLockOrderNet).
        def orders_locking_reads?
          Lyra.event_sourcing_mode? && %i[lazy disabled async].include?(Lyra.config.projection_mode)
        end

        # The aggregate locks of +ids+ (records of +model_class+), in a fixed
        # order, inside the caller's transaction: what every ES-Lazy writer of
        # them takes first, taken before a locking read's row locks.
        def take_aggregate_locks(model_class, ids)
          return unless model_class.respond_to?(:lyra_monitored) && model_class.lyra_monitored
          return if ids.empty?

          model_class.with_connection do |connection|
            next unless connection.transaction_open?

            streams = ids.map { Lyra.stream_name(model_class, _1) }.uniq.sort
            streams.each do |stream|
              Lyra::AdvisoryLock.xact_lock(connection, "lyra_aggregate/#{stream}", purpose: "aggregate write")
            end
            next unless Lyra.config.projection_mode == :async

            # ES-Async: the streams' locks, which a projection job and a write
            # that skips callbacks take, then the events no job has applied yet
            # onto the rows, so the locking read that follows reads the rows as
            # their streams have them and no job writes them until it ends.
            Lyra::AdvisoryLock.xact_lock_all(connection, streams, purpose: "ES-Async projection")
            Lyra::Projections::AsyncProjectionJob.project_pending(model_class, ids)
          end
        end

        # A locking load whose keys are not known before it runs
        # (Model.lock.where(...)): +keys+ (the selection's primary keys, read
        # without the lock) first, their aggregate locks (take_aggregate_locks,
        # in ES-Async with the rows brought up to date), then the locking
        # query (the block). A record the query returns whose key was not read
        # first (it started to match in between) has its row locked before
        # its aggregate lock: its lock is taken then and the query runs again,
        # up to SELECTION_RECHECKS times. Returns the query's result.
        # A locking read of Lyra's own (a bulk write's snapshot, whose locks it
        # has already taken in its order): the block runs without the
        # application's locking-read handling (lock_selection).
        def own_locking_read
          previous = Thread.current[:lyra_locking_selection]
          Thread.current[:lyra_locking_selection] = true
          yield
        ensure
          Thread.current[:lyra_locking_selection] = previous
        end

        def lock_selection(model_class, pk, keys)
          previous = Thread.current[:lyra_locking_selection]
          Thread.current[:lyra_locking_selection] = true
          locked = keys.call.uniq
          take_aggregate_locks(model_class, locked)
          result = yield
          SELECTION_RECHECKS.times do
            index = result.respond_to?(:columns) ? result.columns.index(pk) : nil
            break unless index

            missing = result.rows.map { _1[index] }.uniq - locked
            break if missing.empty?

            take_aggregate_locks(model_class, missing)
            locked |= missing
            result = yield
          end
          result
        ensure
          Thread.current[:lyra_locking_selection] = previous
        end

        # Whether +sql+ (a query or its Arel) locks the rows it reads (FOR
        # UPDATE, FOR NO KEY UPDATE, FOR SHARE): with_lock, lock!, lock.
        def locked_read?(sql)
          return false unless active? && !Thread.current[:lyra_lazy_catching_up]

          if sql.respond_to?(:ast) && sql.ast.respond_to?(:lock)
            !sql.ast.lock.nil?
          else
            sql.to_s.match?(/\bFOR\s+(NO\s+KEY\s+)?(UPDATE|SHARE)\b/i)
          end
        end

        # After a locking read of +model_class+ (+result+, on +connection+):
        # take the records' stream heads, so that no writer of them commits
        # while the lock is held, and replay onto its row each record whose
        # stream has events the row has not had (refresh_records). Returns how
        # many were replayed: the caller reads again if any were. Inside a
        # transaction only (outside one the locks end with the statement).
        def bring_locked_up_to_date(model_class, connection, result)
          return 0 unless connection.respond_to?(:transaction_open?) && connection.transaction_open?
          return 0 unless model_class.respond_to?(:lyra_monitored) && model_class.lyra_monitored

          key = Lyra.key_column(model_class).to_s
          return 0 unless result.respond_to?(:columns) && result.columns.include?(key)

          ids = result.rows.map { _1[result.columns.index(key)] }.compact.uniq
          return 0 if ids.empty?

          streams = ids.map { Lyra.stream_name(model_class, _1) }.uniq.sort
          # The records' aggregate locks, then their heads: the order every
          # writer of ES-Lazy takes them in (the aggregate lock before the
          # append, the head at it), so a reader that finds a writer between the
          # two waits for it rather than closing a cycle with it.
          streams.each { Lyra::AdvisoryLock.xact_lock(connection, "lyra_aggregate/#{_1}", purpose: "aggregate write") }
          Lyra::StreamHeads.lock_streams!(streams, connection: connection)
          refresh_records(model_class, ids)
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

        # Fast path, no lock: nil when nothing is new, no open gap's event is
        # visible, and the gaps were re-checked less than GAP_RECHECK seconds
        # ago. Otherwise the newest event id this read must see applied: the
        # catch-up target.
        #
        # One statement reads the checkpoint and the newest event id, so both
        # come from one snapshot: every event visible in it is above the
        # position, applied, or listed among the gaps (or past the limits in
        # the class comment). A recent re-check says nothing about the listed
        # ones: one can have committed since, this thread's own write too.
        def catch_up_target(connection)
          row = connection.select_rows(<<~SQL.squish).first
            SELECT c.position, c.gaps, (SELECT MAX(id) FROM event_store_events), c.event_id,
                   (SELECT e.event_id FROM event_store_events e WHERE e.id = c.position)
            FROM (SELECT 1) AS one LEFT JOIN #{TABLE} c ON c.name = #{connection.quote(NAME)}
          SQL
          position, gaps = parse_checkpoint(row[0], row[1])
          newest = row[2].to_i
          # A checkpoint whose event is no longer at its position (from 1.0.1;
          # one an earlier version wrote names none, and is taken as before):
          # the event store was emptied or restored without this table, and
          # its new events may already reach the position, which compared
          # alone would take them as applied. Start over instead.
          if row[3] && position.positive? && row[3] != row[4]
            warn_stale_checkpoint(position, newest, gone: true)
            reset!(connection)
            return newest.zero? ? nil : newest
          end
          # A checkpoint past the newest event cannot be right: the event
          # store was emptied or restored without this table. Taken at its
          # word, every new event would look applied and nothing would be
          # projected again; start over instead (applying is idempotent).
          if position > newest
            warn_stale_checkpoint(position, newest)
            reset!(connection)
            return newest.zero? ? nil : newest
          end
          return newest if newest > position || !gaps_rechecked?(gaps)

          gap_to_fill?(connection, gaps) ? newest : nil
        end

        # Whether an event of one of +gaps+ is visible and still listed as
        # missing. One statement for both: a gap that another catch-up filled
        # after +gaps+ was read is in the tables, and is no reason to take the
        # lock. The gaps are JSON text with the ids as quoted keys, hence LIKE.
        def gap_to_fill?(connection, gaps)
          return false if gaps.empty?

          !connection.select_value(<<~SQL.squish, "Lyra ES-Lazy gaps").nil?
            SELECT 1 FROM event_store_events e
            JOIN #{TABLE} c ON c.name = #{connection.quote(NAME)} AND c.gaps LIKE '%"' || e.id || '"%'
            WHERE e.id IN (#{gaps.keys.map { Integer(_1) }.join(',')}) LIMIT 1
          SQL
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
        # gap list (rules 3 and 4), as the fast path judges it.
        def catch_up_to(connection, target, skip_locked: false)
          WAITS.times do
            return apply_pending(connection, skip_locked: skip_locked) if try_lock!(connection)

            wait_for_catch_up(connection)
            return 0 if caught_up_to?(connection, target)
          end
          lock!(connection)
          apply_pending(connection, skip_locked: skip_locked)
        end

        # After waiting: has a committed catch-up applied every event this
        # reader must see? Those are the events visible to it, up to the
        # newest it saw before waiting (+target+; events committed later are
        # not owed to this read). The checkpoint must have reached +target+,
        # and no event the checkpoint lists as missing may be visible to this
        # reader: such an event committed (or was written by this reader's
        # own open transaction) after the catch-up passed its id, and only a
        # catch-up under the lock replays it. So this reader sees what it
        # would have seen had it queued for the lock and caught up itself.
        def caught_up_to?(connection, target)
          position, gaps = checkpoint(connection)
          position >= target && !gap_to_fill?(connection, gaps)
        end

        def apply_pending(connection, skip_locked: false)
          position, gaps = checkpoint(connection)
          started_at = [position, gaps.dup]
          applied = 0
          # Design c: a row another transaction holds is waited for at most
          # SKIP_LOCKED_WAIT; its record's events then stay gaps (skipped).
          skipped = skip_locked ? Set.new : nil
          connection.execute("SET LOCAL lock_timeout = '#{SKIP_LOCKED_WAIT}'") if skip_locked

          loop do
            rows = connection.select_rows(
              "SELECT id, event_id FROM event_store_events WHERE id > #{Integer(position)} ORDER BY id LIMIT #{BATCH}"
            )
            # The gaps after the batch is read and before it is applied: their
            # ids are below the batch's, and an event that one in the batch
            # needs (a child's parent) committed before it, so is visible by
            # now. Once more when no batch is left.
            applied += fill_gaps(connection, position, gaps, skipped)
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
              next unless event

              if skipped
                applied += 1 if apply_or_skip(connection, event, id, gaps, skipped) { apply_event(event) }
              else
                applied += 1 if apply_event(event)
              end
            end
            position = rows.last.first.to_i
          end

          expired = Time.now.to_i - GAP_TTL
          gaps.delete_if { |_, seen| seen < expired }
          # A catch-up that found nothing new (another reader got there
          # first) leaves the checkpoint row alone: rewriting the same values
          # cost a row write and a commit that must reach the disk, all under
          # the lock every other catching-up reader waits on.
          save_checkpoint(connection, position, gaps) unless [position, gaps] == started_at
          applied
        end

        # Events that were in flight when their id was passed, in the log's
        # order.
        def fill_gaps(connection, position, gaps, skipped = nil)
          @gaps_checked_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          return 0 if gaps.empty?

          rows = connection.select_rows(
            "SELECT id, event_id FROM event_store_events WHERE id IN (#{gaps.keys.map { Integer(_1) }.join(',')}) ORDER BY id"
          )
          events = load_events(rows.map(&:last))
          rows.each do |id, event_id|
            gaps.delete(id.to_i)
            event = events[event_id] or next
            if skipped
              apply_or_skip(connection, event, id.to_i, gaps, skipped) { apply_late_event(connection, event, position, gaps) }
            else
              apply_late_event(connection, event, position, gaps)
            end
          end
          @gaps_checked_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          rows.size
        end

        # A gap's event, then those after it in its record's stream that the
        # tables already have (at or below +position+ and no gap), so that it
        # undoes none of them. Not the record's whole stream: its earlier
        # states can name rows destroyed since, and its events not applied
        # yet rows not yet inserted, and either fails under a foreign key.
        def apply_late_event(connection, event, position, gaps)
          model_class, model_id = target_of(event)
          return unless model_class

          stream = Lyra.config.event_store.read.stream(Lyra.stream_name(model_class, model_id)).to_a
          later = stream.drop_while { _1.event_id != event.event_id }.drop(1)
          if later.any?
            applied = connection.select_rows(
              "SELECT id, event_id FROM event_store_events WHERE id <= #{Integer(position)} " \
              "AND event_id IN (#{later.map { connection.quote(_1.event_id) }.join(',')})"
            ).to_h { |id, event_id| [event_id, !gaps.key?(id.to_i)] }
            later.select! { applied[_1.event_id] }
          end
          Rebuild.project_events(model_class, [event, *later], INTERNAL)
        end

        # Apply one event (the block) in a savepoint. Where its row is held by
        # another transaction past SKIP_LOCKED_WAIT, or the wait closed a cycle
        # PostgreSQL broke, the event, and every later one of its record in this
        # catch-up, stays a gap, for a later catch-up or for the holder, who
        # replays its record itself. Returns whether it was applied.
        def apply_or_skip(connection, event, id, gaps, skipped)
          model_class, model_id = target_of(event)
          stream = model_class ? Lyra.stream_name(model_class, model_id) : nil
          if stream && skipped.include?(stream)
            gaps[id] = Time.now.to_i
            return false
          end

          connection.transaction(requires_new: true) { yield }
          true
        rescue ActiveRecord::LockWaitTimeout, ActiveRecord::Deadlocked
          gaps[id] = Time.now.to_i
          skipped << stream if stream
          false
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

        def warn_stale_checkpoint(position, newest, gone: false)
          where = gone ? "names an event no longer at that position" : "is past the newest event (#{newest})"
          message = "Lyra: ES-Lazy checkpoint #{position} #{where}; " \
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
            "UPDATE #{TABLE} SET position = #{Integer(position)}, gaps = #{json}, updated_at = CURRENT_TIMESTAMP, " \
            "event_id = (#{event_at(position)}) WHERE name = #{name}"
          )
          return if updated.to_i.positive?

          connection.execute(
            "INSERT INTO #{TABLE} (name, position, gaps, updated_at, event_id) " \
            "VALUES (#{name}, #{Integer(position)}, #{json}, CURRENT_TIMESTAMP, (#{event_at(position)}))"
          )
        end

        def event_at(position) = "SELECT event_id FROM event_store_events WHERE id = #{Integer(position)}"

        def ensure_table!(connection)
          return if @table_ready

          Lyra.create_own_table(connection, TABLE) do |conn|
            conn.create_table(TABLE, id: false) do |t|
              t.string :name, null: false
              t.bigint :position, null: false, default: 0
              t.text :gaps
              t.datetime :updated_at
              t.string :event_id
            end
            conn.add_index(TABLE, :name, unique: true)
          end
          # The event at the position (1.0.1): a checkpoint is trusted only while
          # that event is there (catch_up_target). Added outside the caller's
          # transaction to a table an earlier version created.
          Lyra.add_own_columns(connection, TABLE, event_id: [:string])
          @table_ready = true
        end
      end
    end
  end
end
