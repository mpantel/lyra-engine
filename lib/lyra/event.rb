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
    # Dynamically created events will be placed here: the interceptor,
    # CommandHandler, BypassEvents and Genesis create Lyra::Events::<Name>
    # when they first write one, and Lyra::Schema::EventClassRegistrar creates
    # them at boot for the models monitored by then.
    #
    # A process that only reads may never get there: in a lazily loaded
    # process (development, console, rake) no model has declared
    # monitor_with_lyra at boot, so nothing is registered, and RubyEventStore's
    # DomainEvent mapper (Object.const_get(record.event_type), falling back to
    # a plain RubyEventStore::Event on NameError) returned events without
    # Lyra's readers (operation, attributes, changes, ...).
    #
    # const_missing closes that gap, for Lyra's own event names only: a name
    # one of the monitored models (or the stored schema) writes, after
    # loading the model the name's stem names if it has not been loaded yet
    # (PostCreated -> Post, SpreeOrderCreated -> Spree::Order). Any other
    # name raises NameError as before.
    CRUD_SUFFIX = /(Created|Updated|Destroyed|Imported)\z/

    class << self
      def const_missing(name)
        return super unless lyra_event_name?(name.to_s)

        # Loading the model may have defined it meanwhile.
        return const_get(name, false) if const_defined?(name, false)

        const_set(name, Class.new(Lyra::Event))
      end

      # Whether +name+ (sanitized, no "::") is an event name Lyra writes.
      def lyra_event_name?(name)
        return true if known_event_names.include?(name)

        stem = name.sub(CRUD_SUFFIX, "")
        return false if stem == name || stem.empty?

        model_candidates(stem).map { |candidate| loads_model?(candidate) }.any? &&
          known_event_names.include?(name)
      end

      private

      # The sanitized event names the monitored models and the stored schema
      # use.
      def known_event_names
        names = Lyra.config.monitored_models.flat_map do |model|
          config = model.respond_to?(:lyra_config) && model.lyra_config
          config ||= Lyra.config.model_config(model)
          ops = %i[created updated destroyed imported].map { |op| config.event_name_for(op) }
          ops + (defined?(Lyra::DomainEvents) ? Lyra::DomainEvents.generated_names(model) : [])
        rescue StandardError
          []
        end
        (names + schema_event_names).map { |n| n.to_s.gsub("::", "") }
      end

      def loads_model?(candidate)
        !candidate.safe_constantize.nil?
      rescue StandardError, LoadError
        false
      end

      def schema_event_names
        return [] unless defined?(Lyra::Schema::Store) && Lyra::Schema::Store.exists?

        models = (Lyra::Schema::Store.load_current || {})[:models] || {}
        models.each_value.flat_map { |m| (m[:events] || m["events"] || {}).keys.map(&:to_s) }
      rescue StandardError
        []
      end

      # Model names the stem may stand for: "SpreeOrder" -> SpreeOrder,
      # Spree::Order. Names of up to five words are split every way.
      def model_candidates(stem)
        words = stem.scan(/[A-Z][a-z0-9]*|[a-z0-9]+/)
        return [stem] if words.size < 2 || words.size > 5 || words.join != stem

        (0...(1 << (words.size - 1))).map do |mask|
          words.each_with_index.map do |word, i|
            i.zero? || mask[i - 1].zero? ? word : "::#{word}"
          end.join
        end
      end
    end
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
