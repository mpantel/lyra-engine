# frozen_string_literal: true

module Lyra
  module Associations
    # Event-aware association module for handling eventual consistency.
    #
    # In event_sourcing mode, associated records may not exist in the database
    # yet if projections are async. This module provides event-aware versions
    # of Rails associations that fall back to event reconstruction when needed.
    #
    # Usage in models:
    #   class Registration < ApplicationRecord
    #     include Lyra::Associations::EventAware
    #
    #     event_aware_belongs_to :program
    #     event_aware_has_many :payment_transactions
    #   end
    #
    module EventAware
      extend ActiveSupport::Concern

      class_methods do
        # Event-aware belongs_to association
        #
        # Tries database first, falls back to event reconstruction if not found.
        #
        # @param name [Symbol] Association name
        # @param options [Hash] Standard belongs_to options plus:
        #   - class_name: Override the class name
        #   - foreign_key: Override the foreign key
        def event_aware_belongs_to(name, **options)
          foreign_key = options[:foreign_key] || "#{name}_id"
          class_name = (options[:class_name] || name.to_s.camelize).to_s

          define_method(name) do
            fk_value = send(foreign_key)
            return nil if fk_value.nil?

            # Try database first (fast path)
            associated = class_name.constantize.find_by(id: fk_value)
            return associated if associated

            # Fall back to event store reconstruction (slow path)
            return nil unless Lyra.event_sourcing_mode?

            EventReconstructor.reconstruct(class_name.constantize, fk_value)
          end

          define_method("#{name}=") do |value|
            send("#{foreign_key}=", value&.id)
          end
        end

        # Event-aware has_many association
        #
        # Queries database and optionally includes pending records from events.
        #
        # @param name [Symbol] Association name (plural)
        # @param options [Hash] Options including:
        #   - class_name: Override the class name
        #   - foreign_key: Override the foreign key
        def event_aware_has_many(name, **options)
          foreign_key = options[:foreign_key] || "#{model_name.singular}_id"
          class_name = (options[:class_name] || name.to_s.singularize.camelize).to_s

          define_method(name) do
            model_id = id
            return [] unless model_id

            # Query database
            db_records = class_name.constantize.where(foreign_key => model_id)

            # In event_sourcing mode with async projections, include pending records
            if Lyra.event_sourcing_mode? && Lyra.config.projection_mode == :async
              pending = PendingRecords.for(class_name.constantize, foreign_key, model_id)
              (db_records.to_a + pending).uniq(&:id)
            else
              db_records
            end
          end
        end
      end
    end

    # Reconstructs a record from its event stream
    class EventReconstructor
      class << self
        # Reconstruct a record's current state from events
        #
        # @param model_class [Class] The model class
        # @param id [Integer, String] The record ID
        # @return [VirtualRecord, nil] A virtual record or nil if not found/deleted
        def reconstruct(model_class, id)
          stream_name = "#{model_class.name}$#{id}"

          begin
            events = Lyra.config.event_store.read.stream(stream_name).to_a
          rescue StandardError
            return nil
          end

          return nil if events.empty?

          # Replay events to build current state
          state = replay_events(events)

          return nil if state[:deleted]

          VirtualRecord.new(model_class, id, state)
        end

        private

        def replay_events(events)
          state = { deleted: false }

          events.each do |event|
            data = event.data.is_a?(Hash) ? event.data : {}

            case Lyra::Event.operation_of(event)
            when :created, :imported
              state.merge!(data[:attributes] || data["attributes"] || {})
            when :updated
              changes = data[:changes] || data["changes"] || {}
              changes.each do |field, change|
                new_value = change.is_a?(Array) ? change.last : change
                state[field.to_sym] = new_value
              end
            when :destroyed
              state[:deleted] = true
            end
          end

          state
        end
      end
    end

    # Finds records that exist in events but not yet in the database
    class PendingRecords
      class << self
        # Find pending records for a has_many association
        #
        # @param model_class [Class] The associated model class
        # @param foreign_key [String] The foreign key field
        # @param parent_id [Integer, String] The parent record ID
        # @return [Array<VirtualRecord>] Array of virtual records
        def for(model_class, foreign_key, parent_id)
          # This is a simplified implementation
          # A production version would need to track pending events more efficiently
          []
        end
      end
    end

    # Virtual record representing a record from events (not in DB)
    #
    # Provides a read-only interface that looks like an ActiveRecord model
    # but is backed by event data instead of a database row.
    class VirtualRecord
      attr_reader :id

      def initialize(model_class, id, state)
        @model_class = model_class
        @id = id
        @state = state.transform_keys(&:to_sym)
      end

      def persisted?
        false
      end

      def new_record?
        true
      end

      # Indicates this is a virtual record from events
      def pending_projection?
        true
      end

      def readonly?
        true
      end

      # Access attributes
      def [](key)
        @state[key.to_sym]
      end

      def attributes
        @state.except(:deleted)
      end

      def to_param
        id&.to_s
      end

      def method_missing(method, *args)
        method_name = method.to_s

        # Getter
        if @state.key?(method)
          @state[method]
        # Boolean query
        elsif method_name.end_with?("?")
          field = method_name.chomp("?").to_sym
          !!@state[field]
        # Setter (rejected - read only)
        elsif method_name.end_with?("=")
          raise ReadOnlyRecord, "Cannot modify a virtual record"
        else
          nil
        end
      end

      def respond_to_missing?(method, include_private = false)
        @state.key?(method) || method.to_s.end_with?("?") || super
      end

      class ReadOnlyRecord < StandardError; end
    end
  end
end
