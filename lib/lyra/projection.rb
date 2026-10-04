module Lyra
  # Base class for projections (read models)
  class Projection
    class << self
      def handle(event)
        new.handle(event)
      end

      # RubyEventStore dispatches to a subscriber through #call (its
      # SyncScheduler accepts any object that responds to call), so the
      # projection class itself is the handler: each event goes to a fresh
      # instance's #handle. Without it, subscribe_to raised
      # RubyEventStore::InvalidHandler.
      def call(event)
        handle(event)
      end

      # Subscribe the projection to the given event classes (or event type
      # names) on Lyra's event store. Returns RES's unsubscribe procs.
      def subscribe_to(*event_types)
        event_types.flatten.map do |event_type|
          Lyra.config.event_store.subscribe(self, to: [event_type])
        end
      end
    end

    # Dispatch to apply_<event name>, e.g. apply_post_created for
    # Lyra::Events::PostCreated. The name comes from the event's type, so an
    # event read back as a plain RubyEventStore::Event (its class not loaded)
    # still reaches its handler.
    def handle(event)
      type = event.respond_to?(:event_type) ? event.event_type : event.class.name
      method_name = "apply_#{type.to_s.demodulize.underscore}"
      send(method_name, event) if respond_to?(method_name, true)
    end
  end

  # State projection that rebuilds current state from events
  class StateProjection < Projection
    def self.rebuild_state(model_class, model_id)
      stream_name = "#{model_class.name}$#{model_id}"
      events = Lyra.config.event_store.read.stream(stream_name).to_a

      new.rebuild_from_events(events)
    end

    def rebuild_from_events(events)
      state = {}

      events.each do |event|
        case event_operation(event)
        when :created, :imported
          state = event_attributes(event)
        when :updated
          state.merge!(event_changes(event).transform_values { |v| v.last })
        when :destroyed
          state[:deleted] = true
          state[:deleted_at] = event_timestamp(event)
        end
      end

      state
    end

    private

    def event_operation(event)
      return Lyra::Event.operation_of(event) if event.respond_to?(:data) && event.respond_to?(:event_type)
      return event.operation if event.respond_to?(:operation)

      op = event.data[:operation] || event.data["operation"]
      op.is_a?(String) ? op.to_sym : op
    end

    def event_attributes(event)
      return event.attributes if event.respond_to?(:attributes) && !event.attributes.is_a?(Hash)
      event.data[:attributes] || event.data["attributes"] || {}
    end

    def event_changes(event)
      return event.changes if event.respond_to?(:changes) && event.method(:changes).owner != ActiveRecord::AttributeMethods::Dirty rescue event.changes
      event.data[:changes] || event.data["changes"] || {}
    end

    def event_timestamp(event)
      return event.timestamp if event.respond_to?(:timestamp) && event.timestamp
      event.data[:timestamp] || event.data["timestamp"] || event.metadata[:timestamp]
    end
  end

  # Audit trail projection
  class AuditProjection < Projection
    def self.audit_trail(model_class, model_id)
      stream_name = "#{model_class.name}$#{model_id}"
      events = Lyra.config.event_store.read.stream(stream_name).to_a

      events.map do |event|
        # Access data with both symbol and string keys (JSON serializer uses strings)
        data = event.data
        # The writer's user_id is in the event's metadata (publish_event and
        # the CommandHandler pass it there). Events stored before that kept
        # it nested in data[:metadata]: the fallback reads those.
        nested_metadata = data[:metadata] || data["metadata"] || {}
        metadata = event.metadata.to_h

        {
          operation: data[:operation] || data["operation"],
          timestamp: data[:timestamp] || data["timestamp"] || metadata[:timestamp],
          user_id: metadata[:user_id] || metadata["user_id"] ||
                   nested_metadata[:user_id] || nested_metadata["user_id"],
          changes: data[:changes] || data["changes"] || {},
          attributes: data[:attributes] || data["attributes"] || {}
        }
      end
    end
  end
end
