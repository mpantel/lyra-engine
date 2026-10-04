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
