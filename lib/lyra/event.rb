module Lyra
  # Base event class for all Lyra events
  class Event < RubyEventStore::Event
    # What a stored event does to its record when replayed: :created,
    # :imported, :updated, :destroyed, or nil (not replayed).
    #
    # Read from the event's data (every event Lyra writes records its
    # operation there), not from its name: a write mapped to a domain event
    # (PaymentCompleted, see DomainEvents) replays as the operation it was.
    # Replay used to look at the name's suffix (...Created, ...Updated,
    # ...Destroyed), so a renamed event was silently skipped. Only events too
    # old to carry an operation fall back to the name.
    #
    # An additional domain event emitted alongside a write's own event
    # (data replay: false) returns nil: the write is replayed once, from its
    # own event.
    def self.operation_of(event)
      data = event.data.is_a?(Hash) ? event.data : {}
      return nil if data[:replay] == false || data["replay"] == false

      case (data[:operation] || data["operation"]).to_s
      when "created", "create" then :created
      when "imported" then :imported
      when "updated", "update" then :updated
      when "destroyed", "destroy", "deleted" then :destroyed
      when "" then operation_from_name(event)
      end
    end

    def self.operation_from_name(event)
      case event.event_type.to_s
      when /Created\z/ then :created
      when /Imported\z/ then :imported
      when /Updated\z/ then :updated
      when /Destroyed\z/ then :destroyed
      end
    end

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
