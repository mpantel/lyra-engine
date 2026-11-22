# frozen_string_literal: true

module Lyra
  # Work that should commit on its own, outside the caller's open transaction:
  # Genesis imports and reference-link catch-ups. This process records each as
  # done, so it must not vanish with the caller's rollback, and its advisory
  # lock should be held only while the work runs, not until the caller commits.
  #
  # Outside a transaction the block simply runs. Inside one, a thread checks
  # out a second connection and runs it there. Two cases give no second
  # connection, and waiting for one would never end or would fail the caller:
  #
  # - the pool's connection is pinned (Rails' transactional tests, system
  #   tests): every checkout returns the caller's own connection, which the
  #   caller holds locked while it waits -- a deadlock, not a timeout;
  # - no connection comes free within the pool's checkout timeout (every
  #   connection is held by a thread of the application).
  #
  # Then the block runs inline, in the caller's transaction. The block is
  # passed +inline+, true in that case, and #after_commit lets the caller
  # record the work as done only once that transaction commits: after a
  # rollback the work is simply done again on the next use.
  module OwnConnection
    class << self
      # Runs the block, on a connection of its own when +model_class+'s
      # connection has a transaction open. Yields +inline+; returns the block's
      # value.
      #
      # +wait_for_connection+ false: with no connection free in the pool
      # (none idle, and the pool at its size), run inline at once rather
      # than wait up to the checkout timeout, holding the caller's
      # transaction and its locks (ReferenceLinks.catch_up, which does not
      # wait inline either).
      def run(model_class = ActiveRecord::Base, wait_for_connection: true, &block)
        where = model_class.with_connection do |connection|
          next :here unless connection.transaction_open?

          connection.pinned ? :inline : :own
        end
        return yield(false) if where == :here
        return yield(true) if where == :inline

        pool = model_class.connection_pool
        unless wait_for_connection
          stat = pool.stat
          return yield(true) unless stat[:idle].to_i.positive? || stat[:connections].to_i < stat[:size].to_i
        end
        begin
          # prevent_permanent_checkout: whatever the block leases is returned
          # with the connection, not left to the thread when it ends.
          # The block's error is raised here, by value; the thread does not
          # also report it (a refused Genesis import, say).
          Thread.new do
            Thread.current.report_on_exception = false
            pool.with_connection(prevent_permanent_checkout: true) { block.call(false) }
          end.value
        rescue ActiveRecord::ConnectionTimeoutError
          yield(true)
        end
      end

      # Runs the block when +model_class+'s current transaction commits, or at
      # once when there is none: how a caller records inline work as done.
      def after_commit(model_class = ActiveRecord::Base, &block)
        model_class.current_transaction.after_commit(&block)
      end
    end
  end
end
