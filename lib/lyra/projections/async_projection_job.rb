# frozen_string_literal: true

module Lyra
  module Projections
    # ActiveJob for asynchronous projection processing.
    #
    # When projection_mode is :async, events are projected to model tables
    # in background jobs rather than synchronously during the request.
    #
    # Benefits:
    # - Faster response times (don't wait for projection)
    # - Better fault isolation (projection failures don't fail requests)
    # - Retry capability for transient failures
    #
    # Trade-offs:
    # - Eventual consistency (reads may not see latest writes immediately)
    # - Requires background job infrastructure (Sidekiq, etc.)
    #
    # Usage:
    #   AsyncProjectionJob.perform_later(event_id, 'Registration', :create)
    #
    class AsyncProjectionJob < ActiveJob::Base
      queue_as :lyra_projections

      # Retry with exponential backoff for transient failures
      retry_on StandardError, wait: :polynomially_longer, attempts: 5

      # Don't retry on permanent failures
      discard_on ActiveRecord::RecordNotFound

      def perform(event_id, model_class_name, operation)
        event = load_event(event_id)
        return unless event

        model_class = model_class_name.constantize

        # Build a CommandResult-like structure from the event
        result = build_result_from_event(event, operation)

        # Project to model table
        ModelProjection.project(model_class, operation.to_sym, result)
      end

      private

      def load_event(event_id)
        Lyra.config.event_store.read.event(event_id)
      rescue RubyEventStore::EventNotFound
        Rails.logger.warn("Lyra::AsyncProjectionJob: Event #{event_id} not found")
        nil
      end

      def build_result_from_event(event, operation)
        # Create a simple struct that looks like CommandResult
        Struct.new(:events, :attributes, :success?, keyword_init: true).new(
          events: [event],
          attributes: event.data[:attributes] || event.data["attributes"] || {},
          success?: true
        )
      end
    end
  end
end
