# frozen_string_literal: true

module Lyra
  module Consistency
    # Read-Your-Writes consistency helper for event_sourcing mode.
    #
    # When using async projections, there's a window where a record might
    # exist in the event store but not yet in the database. This helper
    # projects the writes made inside a block itself: by default when the
    # block ends, so reads after the block see them (reads inside it do not);
    # with each_write: true as each write is made, so reads later in the same
    # block see them too.
    #
    # Usage:
    #   Lyra::Consistency::ReadYourWrites.with_guaranteed_read do
    #     @registration = Registration.create!(params)
    #   end
    #   redirect_to @registration  # Guaranteed to find it
    #
    #   # Code that reads back what it has just written, in the same unit
    #   # of work (Solidus completes an order by reading its new payment):
    #   Lyra::Consistency::ReadYourWrites.with_guaranteed_read(each_write: true) do
    #     order.payments.create!(amount: total)
    #     order.complete!  # finds the payment
    #   end
    #
    module ReadYourWrites
      class << self
        # Execute block with read-your-writes guarantee
        #
        # Tracks any writes within the block and ensures they are
        # projected before the block returns. With each_write: true, each
        # write is projected as it is made, in its own transaction, as ES-Sync
        # projects it; the projection job is still enqueued and, finding the
        # row already up to date, applies nothing new.
        #
        # Nesting: an inner block keeps its own list of writes and projects
        # them when it ends (so reads after the inner block, still inside the
        # outer one, see them), then restores the outer block's list, so the
        # outer block's writes made before and after the inner block are
        # projected when the outer block ends. If the inner block raises, its
        # unprojected writes are handed to the outer block, which projects
        # them if it completes. Every write is projected by the time the
        # outermost block returns. (The inner block used to reset the list to
        # [] and then to nil, losing the outer block's writes.)
        def with_guaranteed_read(each_write: false)
          return yield unless Lyra.event_sourcing_mode?

          # Store pending writes in thread-local storage
          outer = Thread.current[:lyra_pending_writes]
          outer_each_write = Thread.current[:lyra_ryw_each_write]
          Thread.current[:lyra_pending_writes] = []
          Thread.current[:lyra_ryw_each_write] = each_write

          begin
            result = yield
            ensure_projected
            Thread.current[:lyra_pending_writes] = []
            result
          ensure
            pending = Thread.current[:lyra_pending_writes] || []
            outer&.concat(pending)
            Thread.current[:lyra_pending_writes] = outer
            Thread.current[:lyra_ryw_each_write] = outer_each_write
          end
        end

        # Record a write that needs projection (called by interceptor). In a
        # block opened with each_write: true it is projected at once.
        def record_write(model_class, operation, result)
          pending = Thread.current[:lyra_pending_writes]
          return unless pending

          write = { model_class: model_class, operation: operation, result: result }
          return project(write) if Thread.current[:lyra_ryw_each_write]

          pending << write
        end

        # Check if we're in a guaranteed read block
        def in_guaranteed_block?
          !Thread.current[:lyra_pending_writes].nil?
        end

        private

        # Ensure all pending writes are projected
        def ensure_projected
          (Thread.current[:lyra_pending_writes] || []).each { |write| project(write) }
        end

        def project(write)
          Lyra::Projections::ModelProjection.project(write[:model_class], write[:operation], write[:result])
        rescue => e
          Rails.logger.error("Lyra: Failed to ensure projection - #{e.message}")
          raise if Lyra.config.strict_projections
        end
      end
    end

    # Controller concern for automatic read-your-writes handling: under
    # ES-Async each action runs inside ReadYourWrites.with_guaranteed_read.
    #
    # By default the action's writes are projected when it ends, so the next
    # request (a redirect after a create) finds them. An application that
    # reads back within one action what it has just written opts in to
    # projecting each write as it is made, for a controller and its
    # subclasses, from an initializer, without changing its own code:
    #
    #   Spree::BaseController.include Lyra::Consistency::ControllerConcern
    #   Spree::BaseController.lyra_read_your_writes each_write: true
    #
    # Those actions then behave as under ES-Sync, the cost of reading one's
    # own writes; the projection job still runs and finds nothing new.
    module ControllerConcern
      extend ActiveSupport::Concern

      included do
        class_attribute :lyra_read_your_writes_each_write, instance_writer: false, default: false
        around_action :with_lyra_consistency, if: :lyra_consistency_enabled?
      end

      class_methods do
        # Project each write of an action as it is made (each_write: true)
        # or when the action ends (false, the default).
        def lyra_read_your_writes(each_write:)
          self.lyra_read_your_writes_each_write = each_write
        end
      end

      private

      def with_lyra_consistency(&)
        ReadYourWrites.with_guaranteed_read(each_write: self.class.lyra_read_your_writes_each_write, &)
      end

      def lyra_consistency_enabled?
        Lyra.event_sourcing_mode? && Lyra.config.projection_mode == :async
      end
    end
  end
end
