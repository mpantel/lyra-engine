module Lyra
  # Base aggregate class for event sourcing
  class Aggregate
    attr_reader :id, :version, :changes

    def initialize(id = nil)
      @id = id
      @version = 0
      @changes = []
      @state = {}
    end

    # Load aggregate from event stream
    def self.load(id, event_store = nil)
      event_store ||= Lyra.config.event_store
      aggregate = new(id)

      stream_name = aggregate.stream_name
      events = event_store.read.stream(stream_name).to_a

      events.each { |event| aggregate.apply(event, persisted: true) }
      aggregate
    rescue RubyEventStore::EventNotFound
      new(id)
    end

    # Apply an event to the aggregate
    def apply(event, persisted: false)
      method_name = "apply_#{event.class.name.demodulize.underscore}"

      if respond_to?(method_name, true)
        send(method_name, event)
        @version += 1 if persisted
        @changes << event unless persisted
      end
    end

    # Store pending changes to event store
    def store(event_store = nil)
      return if @changes.empty?

      event_store ||= Lyra.config.event_store

      @changes.each do |event|
        event_store.publish(event, stream_name: stream_name)
      end

      @changes.clear
    end

    def stream_name
      "#{self.class.name.demodulize}$#{id}"
    end

    protected

    attr_reader :state

    def set_state(key, value)
      @state[key] = value
    end

    def get_state(key)
      @state[key]
    end
  end

  # Generic aggregate for monitored models
  class GenericAggregate < Aggregate
    def initialize(id = nil, model_class = nil)
      super(id)
      @model_class = model_class
    end

    def stream_name
      "#{@model_class.name}$#{id}"
    end

    # Override apply to handle dynamic event class names (e.g., RegistrationCreated -> apply_created)
    def apply(event, persisted: false)
      event_name = event.class.name.demodulize.underscore

      # Extract operation from event name (e.g., "registration_created" -> "created")
      operation = extract_operation(event_name)
      method_name = "apply_#{operation}"

      if respond_to?(method_name, true)
        send(method_name, event)
        @version += 1 if persisted
        @changes << event unless persisted
      end
    end

    private

    def extract_operation(event_name)
      # Match common operation suffixes
      case event_name
      when /_created$/, /_imported$/
        "created"
      when /_updated$/
        "updated"
      when /_destroyed$/, /_deleted$/
        "destroyed"
      else
        event_name
      end
    end

    def apply_created(event)
      @id = event.data[:model_id] rescue event.model_id
      attrs = event.data[:attributes] rescue event.attributes
      attrs&.each { |k, v| set_state(k, v) }
    end

    def apply_updated(event)
      changes = event.data[:changes] rescue event.changes
      changes&.each do |key, value|
        # Handle both [old, new] arrays and direct values
        new_val = value.is_a?(Array) ? value.last : value
        set_state(key, new_val)
      end
    end

    def apply_destroyed(event)
      set_state(:deleted, true)
      timestamp = event.data[:timestamp] rescue event.timestamp rescue Time.current
      set_state(:deleted_at, timestamp)
    end
  end
end
