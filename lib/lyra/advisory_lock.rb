# frozen_string_literal: true

module Lyra
  # A PostgreSQL transaction-level advisory lock, released at commit. Genesis,
  # ES-Lazy's catch-up and ES-Async's per-stream projection take one so that
  # several processes running them at once never do the same work twice.
  #
  # SQLite needs none: it serialises writers. Other adapters have no such lock
  # here, so the call does nothing there and warns once per purpose, since
  # those paths are then safe in a single process only.
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
