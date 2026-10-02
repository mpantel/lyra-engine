module Lyra
  # Base event class for all Lyra events
  class Event < RubyEventStore::Event
    def self.inherited(subclass)
      super
      # Auto-register event types
      Lyra::EventRegistry.register(subclass)
    end

    # Accessor methods that handle both symbol and string keys
    # (JSON serializer converts symbols to strings)
    def model_class
      data[:model_class] || data["model_class"]
    end

    def model_id
      data[:model_id] || data["model_id"]
    end

    def operation
      op = data[:operation] || data["operation"]
      op.is_a?(String) ? op.to_sym : op
    end

    def attributes
      data[:attributes] || data["attributes"] || {}
    end

    def changes
      data[:changes] || data["changes"] || {}
    end

    def timestamp
      data[:timestamp] || data["timestamp"] || metadata[:timestamp]
    end

    def user_id
      # user_id is stored in data[:metadata] (nested), not top-level metadata
      nested = data[:metadata] || data["metadata"] || {}
      nested[:user_id] || nested["user_id"] || metadata[:user_id]
    end

    def request_id
      # request_id is stored in data[:metadata] (nested), not top-level metadata
      nested = data[:metadata] || data["metadata"] || {}
      nested[:request_id] || nested["request_id"] || metadata[:request_id]
    end
  end

  module Events
    # Dynamically created events will be placed here
  end

  class EventRegistry
    @events = []

    class << self
      def register(event_class)
        @events << event_class unless @events.include?(event_class)
      end

      def all
        @events
      end

      def find_by_name(name)
        @events.find { |e| e.name == name }
      end
    end
  end
end
