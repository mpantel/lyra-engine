# frozen_string_literal: true

module Lyra
  # A PostgreSQL transaction-level advisory lock, released at commit. Genesis,
  # ES-Lazy's catch-up and ES-Async's per-stream projection take one so that
  # several processes running them at once never do the same work twice.
  #
  # SQLite needs none: it serialises writers. Other adapters have no such lock
  # here, so the call does nothing there and warns once per purpose, since
  # those paths are then safe in a single process only.
  #
  # The order of a record's locks. A write that takes both a record's
  # aggregate lock (this advisory lock on "lyra_aggregate/<stream>") and its
  # row's lock takes the aggregate lock first: ES-Async's and ES-Lazy's
  # writes through callbacks take the aggregate lock only (their rows are the
  # projection's), Hijack and ES-Sync take the row's lock only (the row lock
  # is their aggregate lock: CrudInterceptor#lyra_lock_aggregate!), and a
  # write that skips callbacks (update_columns, touch, delete, and in ES-Async
  # update_all and delete_all: Lyra::BypassEvents) and an erasure
  # (Lyra::Erasure#lock_record) take the aggregate lock, then write or lock
  # the row. A write that took them the other way round deadlocked against
  # one of these. Several records' aggregate locks are taken together by
  # xact_lock_all.
  #
  # Lyra orders the locks of one write, not those of an application's
  # transaction: one that writes several records one after another takes
  # their locks in the order it writes them, and can deadlock against
  # another transaction, or a bulk write, that holds one of them and waits
  # for another, as plain Active Record's row locks do. PostgreSQL detects
  # it and aborts one of them (ActiveRecord::Deadlocked). Write records in
  # one order (by primary key, say) and retry the transaction on
  # ActiveRecord::Deadlocked; see docs/TROUBLESHOOTING.md.
  module AdvisoryLock
    @warned = {}

    class << self
      # Returns true when a lock was taken, false otherwise.
      def xact_lock(connection, key, purpose:)
        adapter = connection.adapter_name
        if adapter.match?(/postgres/i)
          connection.execute("SELECT pg_advisory_xact_lock(hashtext(#{connection.quote(key)}))")
          return true
        end

        warn_once(adapter, purpose) unless adapter.match?(/sqlite/i)
        false
      end

      # The locks of every one of +keys+, as xact_lock takes each. Each is
      # tried without waiting, in one statement, in a savepoint; when every
      # one is free, that is all (one statement besides the savepoint's).
      #
      # When some are held by other sessions, what the call does next depends
      # on whether this transaction holds advisory locks of its own already
      # (wait_bound, one query, at the first contention only):
      #
      # - It holds none (a bulk write beginning its transaction's locking):
      #   it waits for the held ones, in the order of their hashes, keeping
      #   the ones it took, for at most MAX_WAIT_MS in all; a holder that
      #   ends meanwhile lets it through, in its place in that lock's queue.
      #   When the time is up, the savepoint is rolled back, which gives back
      #   every lock taken in it, and the next try first waits, holding none,
      #   for the first lock that was held, for at most half of
      #   deadlock_timeout, then tries them all again. Before, it gave every
      #   lock back whenever one was held and waited for that one without a
      #   limit: sessions that come and go with a few of its records kept it
      #   out (a bulk write of 8 records against three transactions that each
      #   held one and then bulk-wrote two others went through once in 15
      #   seconds in ES-NoProj), and, waiting in their locks' queues, it was
      #   the one PostgreSQL aborted for their deadlocks (5 or 6 times in
      #   those 15 seconds). No wait of the call's lasts as long as
      #   deadlock_timeout, so PostgreSQL never reports it deadlocked: its own
      #   check runs only after deadlock_timeout, and a session that waits for
      #   a lock the call took began waiting after the call took it, so its
      #   check finds the call gone. Two bulk writes, or a bulk write and a
      #   transaction that holds one of its records and asks for another,
      #   therefore never deadlock: the bulk write gives way.
      # - It holds some (a transaction that wrote a record, or a bulk write's
      #   later round): whenever one is held, it gives back the ones it took
      #   in that try and waits for that one holding none of them, without a
      #   limit, as before 1.0.0. It holds its earlier locks anyway, and
      #   keeping the new ones as well while it waited made such transactions
      #   deadlock against each other.
      #
      # Nothing changes for the caller: a wait that ran out of time is not
      # reported, and the call returns only once it holds every lock (the
      # lock limit check comes before it, and nothing is appended before it
      # returns). A lock_timeout of the caller's own that is shorter than a
      # bounded wait's share stays in force, and its timeout raises
      # ActiveRecord::LockWaitTimeout, as before. Under contention the bulk
      # write's turns cost the transactions it shares records with some
      # throughput: they wait while it holds its records, up to MAX_WAIT_MS
      # at a time. After TRIES tries, or outside a transaction (no savepoint
      # to give locks back with), the locks are taken waiting, in the order
      # of their hashes. Returns true when the locks were taken, false
      # otherwise.
      def xact_lock_all(connection, keys, purpose:)
        keys = keys.uniq
        return false if keys.empty?
        return xact_lock(connection, keys.first, purpose: purpose) if keys.size == 1

        adapter = connection.adapter_name
        unless adapter.match?(/postgres/i)
          warn_once(adapter, purpose) unless adapter.match?(/sqlite/i)
          return false
        end

        hashes = "SELECT DISTINCT hashtext(k) AS h FROM unnest(ARRAY[#{keys.map { connection.quote(_1) }.join(', ')}]::text[]) " \
                 "AS k ORDER BY h"
        if connection.transaction_open?
          contended = nil
          # The bounds of its waits (wait_bound) when the caller held no
          # advisory lock of its own at the first contention; false when it
          # did; nil before the first.
          bounded = nil
          TRIES.times do
            held = nil
            connection.transaction(requires_new: true) do
              # The lock another session held last time, waited for while
              # this call holds none of the others (it gets its place in
              # that lock's queue; at most half of deadlock_timeout where
              # the waits are bounded), then the others tried.
              if contended
                if bounded
                  held = contended unless wait_briefly(connection, [contended], bounded, bounded.first)
                else
                  connection.execute("SELECT pg_advisory_xact_lock(#{contended})")
                end
              end
              raise ActiveRecord::Rollback if held

              # Volatile functions are called on the subquery's rows, in
              # their order, every one of them.
              rows = connection.select_rows("SELECT h, pg_try_advisory_xact_lock(h) FROM (#{hashes}) AS keys")
              missing = rows.reject { |_, taken| taken }.map { |hash, _| Integer(hash) }
              next if missing.empty?

              bounded = wait_bound(connection, rows.size - missing.size) if bounded.nil?
              next if bounded && wait_briefly(connection, missing, bounded, MAX_WAIT_MS)

              held = missing.first
              raise ActiveRecord::Rollback
            end
            return true unless held

            contended = held
          end
        end
        connection.execute("SELECT count(pg_advisory_xact_lock(h)) FROM (#{hashes}) AS keys")
        true
      end

      # How many times xact_lock_all tries all the locks before it waits for
      # them in order.
      TRIES = 200

      # The longest a bulk write waits, in milliseconds, holding the locks it
      # took, for the ones it did not (xact_lock_all), in all; never more
      # than half of deadlock_timeout either.
      MAX_WAIT_MS = 100

      # Take the lock only if no other session holds it. Returns true when
      # the caller may go on as the lock's holder: it took the lock, or there
      # is no such lock on this adapter (as xact_lock, which then takes none).
      # Returns false when another session holds it.
      def try_xact_lock(connection, key, purpose:)
        adapter = connection.adapter_name
        if adapter.match?(/postgres/i)
          return connection.select_value("SELECT pg_try_advisory_xact_lock(hashtext(#{connection.quote(key)}))") == true
        end

        warn_once(adapter, purpose) unless adapter.match?(/sqlite/i)
        true
      end

      # Wait until no other session holds the lock, without keeping it: take
      # it shared in a savepoint and roll the savepoint back, which gives the
      # lock back. Shared requests do not exclude each other, so every
      # session waiting on the same holder goes on when that holder's
      # transaction ends. The lock belongs to the savepoint, not to the
      # session, so it cannot outlive the caller's transaction whatever
      # interrupts this call; a session-level lock left behind by an error or
      # a Thread#raise between taking and giving it back would block every
      # later holder for good. Keeping it until the caller's transaction ends
      # would block every holder for as long as that transaction, and two
      # waiters that each kept it shared and then asked for it exclusively
      # would deadlock. The savepoint, the wait and the rollback go to the
      # server as one string, one round trip; if the wait fails, the rest is
      # not run, and the error rolls back the caller's transaction or
      # savepoint, which also releases the lock. Returns false where there is
      # no such lock.
      def wait_for(connection, key)
        return false unless connection.adapter_name.match?(/postgres/i)

        connection.transaction do
          connection.execute(
            "SAVEPOINT lyra_wait_for; " \
            "SELECT pg_advisory_xact_lock_shared(hashtext(#{connection.quote(key)})); " \
            "ROLLBACK TO SAVEPOINT lyra_wait_for; RELEASE SAVEPOINT lyra_wait_for"
          )
        end
        true
      end

      # Forget which purposes have warned (tests).
      def reset_warnings!
        @warned = {}
      end

      private

      # xact_lock_all, at its first contention, having just taken +taken+
      # of its locks: whether its waits are bounded. Only for a caller that
      # holds no other advisory lock in this session (a bulk write that
      # begins its transaction's locking): [half of deadlock_timeout in ms,
      # the session's lock_timeout in ms (0: none), the lock_timeout setting
      # to restore]. False for one that already holds some (a transaction
      # that wrote a record and now writes others): it waits holding none of
      # the new ones, as before 1.0.0. One query.
      def wait_bound(connection, taken)
        held, half_deadlock, lock, setting = connection.select_rows(
          "SELECT (SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND granted AND pid = pg_backend_pid()), " \
          "(EXTRACT(epoch FROM current_setting('deadlock_timeout')::interval) * 500)::bigint, " \
          "(EXTRACT(epoch FROM current_setting('lock_timeout')::interval) * 1000)::bigint, " \
          "current_setting('lock_timeout')"
        ).first
        return false unless Integer(held) == taken

        [Integer(half_deadlock), Integer(lock), setting]
      end

      # xact_lock_all, for a caller whose waits are bounded (wait_bound):
      # wait for the locks of +hashes+, in their order, in the caller's
      # savepoint, for at most +total+ milliseconds in all, never more than
      # half of deadlock_timeout. The limit is lock_timeout, set for that
      # statement only (SET LOCAL, then set back; the three go to the server
      # as one string), to the total divided among the locks. lock_timeout,
      # not statement_timeout: its timer runs only while a lock is waited
      # for, and PostgreSQL reports one that fires as the lock is granted as
      # a lock timeout, in this statement or the next of the string, never in
      # a later statement of the caller's (a statement_timeout that fired as
      # the statement ended cancelled the next one "due to user request").
      # True when every one was taken; false when the time ran out, and the
      # caller rolls its savepoint back, which also undoes the SET LOCAL.
      #
      # A lock_timeout of the caller's own (the session's or the
      # transaction's) that is shorter than that share is left as it is, and
      # its timeout is the caller's error (ActiveRecord::LockWaitTimeout), as
      # for a wait without a bound: it is not taken for this call's own limit
      # and tried again.
      def wait_briefly(connection, hashes, (half_deadlock, lock, setting), total)
        each = [[total, half_deadlock].min / hashes.size, 1].max
        wait = "SELECT count(pg_advisory_xact_lock(h)) FROM (SELECT unnest(ARRAY[#{hashes.sort.join(', ')}]::int[]) AS h " \
               "ORDER BY h) AS keys"
        if lock.positive? && lock < each
          connection.execute(wait)
          return true
        end

        begin
          connection.execute(
            "SET LOCAL lock_timeout = #{Integer(each)}; #{wait}; SET LOCAL lock_timeout = #{connection.quote(setting)}"
          )
        rescue ActiveRecord::LockWaitTimeout
          return false
        end
        true
      end

      def warn_once(adapter, purpose)
        return if @warned[purpose]

        @warned[purpose] = true
        logger = defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
        message = "Lyra: #{purpose} runs without a lock on #{adapter} (only PostgreSQL has the " \
                  "advisory lock Lyra uses); it is safe in a single process only"
        logger ? logger.warn(message) : Kernel.warn(message)
      end
    end
  end
end
