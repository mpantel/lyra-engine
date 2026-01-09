# frozen_string_literal: true

module Lyra
  module Consistency
    # Read-Your-Writes consistency helper for event_sourcing mode.
    #
    # When using async projections, there's a window where a record might
    # exist in the event store but not yet in the database. This helper
    # ensures that within a block, any writes are immediately projected
    # before reads happen.
    #
    # Usage:
    #   Lyra::Consistency::ReadYourWrites.with_guaranteed_read do
    #     @registration = Registration.create!(params)
    #     redirect_to @registration  # Guaranteed to find it
    #   end
    #
    module ReadYourWrites
      class << self
        # Execute block with read-your-writes guarantee
        #
        # Tracks any writes within the block and ensures they are
        # projected before the block returns.
        def with_guaranteed_read
          return yield unless Lyra.event_sourcing_mode?

          # Store pending writes in thread-local storage
          Thread.current[:lyra_pending_writes] = []

          begin
            result = yield
            ensure_projected
            result
          ensure
            Thread.current[:lyra_pending_writes] = nil
          end
        end

        # Record a write that needs projection (called by interceptor)
        def record_write(model_class, operation, result)
          pending = Thread.current[:lyra_pending_writes]
          return unless pending

          pending << { model_class: model_class, operation: operation, result: result }
        end

        # Check if we're in a guaranteed read block
        def in_guaranteed_block?
          !Thread.current[:lyra_pending_writes].nil?
        end

        private

        # Ensure all pending writes are projected
        def ensure_projected
          pending = Thread.current[:lyra_pending_writes] || []

          pending.each do |write|
            Lyra::Projections::ModelProjection.project(
              write[:model_class],
              write[:operation],
              write[:result]
            )
          rescue => e
            Rails.logger.error("Lyra: Failed to ensure projection - #{e.message}")
            raise if Lyra.config.strict_projections
          end
        end
      end
    end

    # Controller concern for automatic read-your-writes handling
    module ControllerConcern
      extend ActiveSupport::Concern

      included do
        around_action :with_lyra_consistency, if: :lyra_consistency_enabled?
      end

      private

      def with_lyra_consistency
        ReadYourWrites.with_guaranteed_read { yield }
      end

      def lyra_consistency_enabled?
        Lyra.event_sourcing_mode? && Lyra.config.projection_mode == :async
      end
    end
  end
end
