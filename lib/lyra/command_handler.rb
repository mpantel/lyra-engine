module Lyra
  # Command handler for processing commands in hijack mode
  class CommandHandler
    class << self
      def handle(command)
        handler = new(command)
        handler.call
      end
    end

    attr_reader :command

    def initialize(command)
      @command = command
    end

    def call
      case command
      when Commands::CreateCommand
        handle_create
      when Commands::UpdateCommand
        handle_update
      when Commands::DestroyCommand
        handle_destroy
      else
        CommandResult.failure(error: "Unknown command type")
      end
    rescue EventStoreUnavailableError
      # Fail-closed: a write whose event cannot be stored fails with the
      # error, as in event sourcing, rather than as a refused save.
      raise
    rescue => e
      CommandResult.failure(error: e.message)
    end

    private

    def handle_create
      model_class = command.model_class

      # Generate ID for new aggregate. Both modes store the Created event before
      # any INSERT, so the record's real ID must be known now: the event's
      # model_id and its stream ("Model$<id>") are fixed at this point.
      #
      # Hijack mode used to give integer keys a "pending-<hex>" placeholder and
      # let the database assign the ID afterwards. The Created event then lived
      # in a stream nothing else ever read: every later event went to the real
      # "Model$<id>" stream, so a record's history began with an update, and
      # rebuilding it from events (dual view, projections) found no attributes.
      # Hijack now reserves the ID the same way event-sourcing mode does (a
      # sequence nextval on PostgreSQL) and the row is inserted with it.
      #
      # An ID the application set explicitly is kept (it used to be replaced
      # with a generated one). In hijack mode the database may be assigning
      # IDs to other inserts at the same time, so an ID is reserved only where
      # that cannot collide (IdGenerator.reserves_safely?: a UUID, or the
      # table's PostgreSQL sequence). Elsewhere hijack falls back to the
      # "pending-<hex>" placeholder, with a one-time warning, rather than risk
      # a duplicate key.
      explicit_id = (command.attributes["id"] || command.attributes[:id]).presence
      id = explicit_id ||
           (IdGenerator.next_id(model_class) if Lyra.event_sourcing_mode? || IdGenerator.reserves_safely?(model_class))
      unless id
        warn_pending_stream(model_class)
        id = "pending-#{SecureRandom.hex(8)}"
      end

      # Create aggregate
      aggregate_class = find_aggregate_class
      aggregate = aggregate_class.new(id, *aggregate_args(aggregate_class))

      # Create event with pre-generated ID
      # Use symbolize_keys for consistent key types in event data
      event_attrs = command.attributes.symbolize_keys.merge(id: id)
      events = create_events(:created, id, event_attrs)
      event = events.first

      # Apply event to aggregate
      aggregate.apply(event)

      # Store events
      # In event_sourcing mode, defer storage until after throw(:abort) completes
      # (storing inside the callback would be rolled back with the transaction)
      unless Lyra.event_sourcing_mode?
        aggregate.store(Lyra.config.event_store)
        store_additional_events(events.drop(1), aggregate.stream_name)
      end

      # Return result with the ID, so the caller inserts the row under the same
      # ID the event already carries.
      attributes = command.attributes.dup
      # Remove string "id" key to prevent conflict with symbol :id
      # (AR attributes have string keys, but we add symbol keys)
      attributes.delete("id")
      attributes[:id] = id unless id.to_s.start_with?("pending-")
      CommandResult.success(attributes: attributes, events: events)
    end

    def handle_update
      aggregate = load_aggregate

      # Create event
      events = create_events(:updated, command.id, { changes: command.changes })
      event = events.first

      # Apply event to aggregate
      aggregate.apply(event)

      # Store events (defer in event_sourcing mode)
      unless Lyra.event_sourcing_mode?
        aggregate.store(Lyra.config.event_store)
        store_additional_events(events.drop(1), aggregate.stream_name)
      end

      CommandResult.success(events: events)
    end

    def handle_destroy
      aggregate = load_aggregate

      # Create event
      events = create_events(:destroyed, command.id, {})
      event = events.first

      # Apply event to aggregate
      aggregate.apply(event)

      # Store events (defer in event_sourcing mode)
      unless Lyra.event_sourcing_mode?
        aggregate.store(Lyra.config.event_store)
        store_additional_events(events.drop(1), aggregate.stream_name)
      end

      CommandResult.success(events: events)
    end

    # The events for one write: its own event first (a domain event if one of
    # the model's rules matches, else the CRUD event), then any additional
    # domain events (Lyra::DomainEvents).
    def create_events(operation, id, data)
      own = create_event(operation, id, data)
      Lyra::DomainEvents.build(
        command.model_class, operation, data: own.data, metadata: own.metadata.to_h,
        default_class: own.class, record: command.record, changes: changes_for(operation, data)
      )
    end

    def changes_for(operation, data)
      case operation
      when :created then command.record&.changes || {}
      when :updated then data[:changes] || {}
      else {}
      end
    end

    # In Hijack mode the aggregate stores the write's own event; additional
    # domain events go to the same stream, in the same transaction.
    def store_additional_events(events, stream_name)
      Lyra.append_events(events, stream_name: stream_name) if events.any?
    end

    def create_event(operation, id, data)
      event_data = {
        model_class: command.model_class.name,
        model_id: id,
        operation: operation,
        attributes: data[:attributes] || data,
        changes: data[:changes] || {},
        timestamp: Time.current
      }

      event_metadata = attribution_metadata(operation).merge(source: 'lyra_command_handler')

      config = Lyra.config.model_config(command.model_class)
      event_name = config.event_name_for(operation)

      # Find or create the event class in Lyra::Events namespace. A namespaced
      # model (Spree::Price) gives a namespaced default name (Spree::PriceCreated),
      # which is not a valid constant: strip the separators, as every other
      # event path does. Without this, hijack and event-sourcing creates of a
      # namespaced model failed, and the failure surfaced only as an unsaved
      # parent record.
      sanitized_name = event_name.to_s.gsub("::", "")
      event_class = if Lyra::Events.const_defined?(sanitized_name, false)
        Lyra::Events.const_get(sanitized_name, false)
      else
        Lyra::Events.const_set(sanitized_name, Class.new(Lyra::Event))
      end

      event_class.new(data: event_data, metadata: Lyra::Privacy.stamp(command.model_class, event_data, event_metadata))
    end

    # The same attribution metadata a Monitor event carries
    # (CrudInterceptor#lyra_event_metadata: user_id, request_id, the causal
    # chain, the user action, config.metadata_proc), built from the record
    # the command came from. Hijack and event-sourcing events used to carry
    # only the causal chain, so they lost who made the write. A command
    # without a record (direct CommandHandler use) gets the context that
    # needs no record: the causal chain and the user action in scope.
    def attribution_metadata(operation)
      record = command.respond_to?(:record) ? command.record : nil
      return record.lyra_event_metadata(operation) if record.respond_to?(:lyra_event_metadata)

      context = Lyra::UserActionContext.current
      {
        correlation_id: Lyra::Correlation.current_id,
        causation_id: Lyra::Causation.current_id,
        action_id: context&.action_id,
        user_action: context && { type: context.action_type, controller: context.controller, action: context.action_name }
      }
    end

    # The aggregate for an update or destroy.
    #
    # Only a model's own aggregate_class is loaded with its stream's history,
    # since only domain checks there can use it. The default GenericAggregate
    # decides nothing from history, so it starts empty: reading the stream
    # would add SQL to every Hijack and event-sourcing update and destroy for
    # nothing. A record without event history loads as a new aggregate
    # (version 0).
    #
    # Loading used to call load without the model class GenericAggregate
    # needs for its stream name, and rescue the NoMethodError that followed. A
    # programming error now fails the command (visibly, as an error on the
    # record); an error reading the store is logged and the write proceeds
    # from an empty aggregate. An unavailable store fails closed.
    def load_aggregate
      aggregate_class = find_aggregate_class
      args = aggregate_args(aggregate_class)
      return aggregate_class.new(command.id, *args) unless custom_aggregate?

      begin
        aggregate_class.load(command.id, Lyra.config.event_store, *args)
      rescue EventStoreUnavailableError, NoMethodError, NameError, ArgumentError, TypeError
        raise
      rescue => e
        Rails.logger.error(
          "Lyra: could not load #{aggregate_class.name} history for " \
          "#{command.model_class.name}$#{command.id} (#{e.class}: #{e.message}); continuing from an empty aggregate"
        )
        aggregate_class.new(command.id, *args)
      end
    end

    # GenericAggregate (and any aggregate whose initializer takes it) needs
    # the model class for its stream name; an Aggregate subclass with the
    # base initializer takes the id alone.
    def aggregate_args(aggregate_class)
      params = aggregate_class.instance_method(:initialize).parameters
      positional = params.count { |type, _| type == :req || type == :opt }
      positional >= 2 || params.any? { |type, _| type == :rest } ? [command.model_class] : []
    end

    def find_aggregate_class
      config = Lyra.config.model_config(command.model_class)
      klass = config.aggregate_class || Lyra::GenericAggregate
      klass.is_a?(String) ? klass.constantize : klass
    end

    def custom_aggregate?
      !Lyra.config.model_config(command.model_class).aggregate_class.nil?
    end

    # Once per model: say why its created events are not in its own stream.
    def warn_pending_stream(model_class)
      @@pending_warned ||= Set.new
      return unless @@pending_warned.add?(model_class.name)

      adapter = model_class.connection.adapter_name rescue "unknown adapter"
      Rails.logger.warn(
        "Lyra: hijack mode can't reserve a safe id for #{model_class.name} " \
        "(#{adapter}, integer key without a PostgreSQL sequence); " \
        "its created events go to a pending-<hex> stream, not #{model_class.name}$<id>"
      )
    end
  end
end
