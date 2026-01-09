module Lyra
  # Maps CRUD operations to domain events
  class EventMapper
    class << self
      # Map a CRUD operation to an event
      def map_operation(model_class, operation, data)
        mapper_class = find_mapper(model_class) || DefaultMapper

        mapper_class.new(model_class, operation, data).to_event
      end

      # Register a custom mapper for a model
      def register_mapper(model_class, mapper_class)
        mappers[model_class.name] = mapper_class
      end

      private

      def mappers
        @mappers ||= {}
      end

      def find_mapper(model_class)
        mappers[model_class.name]
      end
    end

    attr_reader :model_class, :operation, :data

    def initialize(model_class, operation, data)
      @model_class = model_class
      @operation = operation
      @data = data
    end

    def to_event
      event_class = resolve_event_class
      event_class.new(data: event_data, metadata: event_metadata)
    end

    def event_data
      {
        model_class: model_class.name,
        model_id: data[:id],
        operation: operation,
        attributes: data[:attributes] || {},
        changes: data[:changes] || {},
        timestamp: Time.current
      }
    end

    def event_metadata
      {
        user_id: data[:user_id],
        request_id: data[:request_id],
        correlation_id: Lyra::Correlation.current_id,
        causation_id: Lyra::Causation.current_id,
        source: 'lyra_interceptor'
      }
    end

    def resolve_event_class
      config = Lyra.config.model_config(model_class)
      event_name = config.event_name_for(operation)
      # Sanitize namespaced event names for constant lookup
      sanitized_name = event_name.to_s.gsub("::", "")

      # First check if it exists in Lyra::Events namespace
      if Lyra::Events.const_defined?(sanitized_name, false)
        return Lyra::Events.const_get(sanitized_name, false)
      end

      # Try to constantize (for user-defined event classes)
      begin
        event_name.constantize
      rescue NameError
        create_dynamic_event_class(event_name)
      end
    end

    def create_dynamic_event_class(event_name)
      # Sanitize namespaced event names (e.g., "Spree::OrderCreated" -> "SpreeOrderCreated")
      sanitized_name = event_name.to_s.gsub("::", "")

      return Lyra::Events.const_get(sanitized_name, false) if Lyra::Events.const_defined?(sanitized_name, false)

      Lyra::Events.const_set(sanitized_name, Class.new(Lyra::Event))
    end
  end

  class DefaultMapper < EventMapper
    # Uses the base EventMapper behavior
  end

  # Example of a custom mapper
  class AuditMapper < EventMapper
    def event_data
      super.merge(
        audit_info: {
          ip_address: data[:ip_address],
          user_agent: data[:user_agent]
        }
      )
    end
  end
end
