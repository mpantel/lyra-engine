# frozen_string_literal: true

require "set"

module Lyra
  module Rights
    # What a connection has recorded in its open transaction, per store.
    #
    # A store's snapshot or cache is shared by the threads of the process, and
    # each thread reads through its own connection. Rights or consent recorded
    # in an open transaction are seen by that transaction only: so the keys a
    # connection wrote are read afresh through it until its transaction ends,
    # the shared snapshot is never filled from such a connection, and when the
    # transaction commits or rolls back the keys are dropped from the shared
    # snapshot (the next read takes them from the database).
    module Pending
      private

      def init_pending
        @pending = {}.compare_by_identity
        @pending_mutex = Mutex.new
      end

      def current_connection
        ActiveRecord::Base.connection_pool.active_connection
      end

      # The keys this thread's connection wrote in its open transaction, or nil.
      def pending_here
        connection = current_connection
        return nil unless connection

        keys = @pending_mutex.synchronize { @pending[connection] }
        return nil unless keys
        return keys if connection.transaction_open?

        # Its transaction ended without telling us (a dropped callback).
        settle(connection)
        nil
      end

      # After a write of +keys+: remember them for this connection's open
      # transaction, and settle when it ends. Outside a transaction the write
      # is committed already: settle at once.
      def mark_pending(keys)
        connection = current_connection
        unless connection&.transaction_open?
          settled(keys)
          return
        end

        @pending_mutex.synchronize { (@pending[connection] ||= Set.new).merge(keys) }
        watch(connection)
      end

      def watch(connection)
        transaction = ActiveRecord::Base.current_transaction
        return unless transaction.open?

        transaction.after_commit { settle(connection) }
        transaction.after_rollback do
          # A savepoint rolled back: the transaction around it goes on, and its
          # keys stay read afresh until it ends.
          connection.transaction_open? ? watch(connection) : settle(connection)
        end
      end

      def settle(connection)
        keys = @pending_mutex.synchronize { @pending.delete(connection) }
        settled(keys.to_a) if keys
      end
    end
  end
end
