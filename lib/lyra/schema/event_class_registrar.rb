# frozen_string_literal: true

module Lyra
  module Schema
    # Registers event classes at Rails startup to ensure RailsEventStore
    # can properly deserialize events. Without this, dynamically created
    # event classes would not exist after app restart, causing
    # Object.const_get() to fail during event deserialization.
    class EventClassRegistrar
      class << self
        # Register all event classes from configuration and stored schema
        def register_all
          register_from_configuration
          register_from_schema
        end

        # Get list of all registered event class names
        def registered_events
          Lyra::Events.constants(false).map(&:to_s)
        end

        private

        # Register events for currently monitored models
        def register_from_configuration
          Lyra.config.monitored_models.each do |model_class|
            config = Lyra.config.model_config(model_class)

            [:created, :updated, :destroyed].each do |operation|
              event_name = config.event_name_for(operation)
              ensure_event_class_exists(event_name)
            end
          end
        end

        # Register events from stored schema (handles legacy/removed models)
        def register_from_schema
          return unless Store.exists?

          schema = Store.load_current
          return unless schema && schema[:models]

          schema[:models].each_value do |model_schema|
            events = model_schema[:events] || model_schema["events"] || {}
            events.each_key do |event_name|
              ensure_event_class_exists(event_name.to_s)
            end
          end
        end

        def ensure_event_class_exists(event_name)
          # Sanitize namespaced event names (e.g., "Spree::OrderCreated" -> "SpreeOrderCreated")
          # Ruby const_set doesn't accept "::" in constant names
          sanitized_name = event_name.to_s.gsub("::", "")

          return if Lyra::Events.const_defined?(sanitized_name, false)

          Lyra::Events.const_set(sanitized_name, Class.new(Lyra::Event))
        end
      end
    end
  end
end
