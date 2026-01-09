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
    rescue => e
      CommandResult.failure(error: e.message)
    end

    private

    def handle_create
      model_class = command.model_class

      # Generate ID for new aggregate
      # In event_sourcing mode, we MUST pre-generate IDs since we abort the DB save
      # In hijack mode, only UUID keys need pre-generation (integers come from DB)
      id = if Lyra.event_sourcing_mode?
        # Always pre-generate in event_sourcing mode
        IdGenerator.next_id(model_class)
      elsif model_class.columns_hash[model_class.primary_key]&.type == :uuid
        SecureRandom.uuid
      else
        # For integer primary keys in hijack mode, use a temporary placeholder
        # The actual ID will be assigned by the database after save
        "pending-#{SecureRandom.hex(8)}"
      end

      # Create aggregate
      aggregate_class = find_aggregate_class
      aggregate = aggregate_class.new(id, command.model_class)

      # Create event with pre-generated ID
      # Use symbolize_keys for consistent key types in event data
      event_attrs = command.attributes.symbolize_keys.merge(id: id)
      event = create_event(:created, id, event_attrs)

      # Apply event to aggregate
      aggregate.apply(event)

      # Store events
      # In event_sourcing mode, defer storage until after throw(:abort) completes
      # (storing inside the callback would be rolled back with the transaction)
      unless Lyra.event_sourcing_mode?
        aggregate.store(Lyra.config.event_store)
      end

      # Return result with ID
      # In event_sourcing mode, always include ID (it's pre-generated)
      # In hijack mode, only include for UUID (integers come from DB)
      attributes = command.attributes.dup
      # Remove string "id" key to prevent conflict with symbol :id
      # (AR attributes have string keys, but we add symbol keys)
      attributes.delete("id")
      if Lyra.event_sourcing_mode? || model_class.columns_hash[model_class.primary_key]&.type == :uuid
        attributes[:id] = id
      end
      CommandResult.success(attributes: attributes, events: [event])
    end

    def handle_update
      # Load aggregate (or create new one for records without event history)
      aggregate_class = find_aggregate_class
      aggregate = aggregate_class.load(command.id, Lyra.config.event_store) rescue aggregate_class.new(command.id, command.model_class)

      # Create event
      event = create_event(:updated, command.id, { changes: command.changes })

      # Apply event to aggregate
      aggregate.apply(event)

      # Store events (defer in event_sourcing mode)
      unless Lyra.event_sourcing_mode?
        aggregate.store(Lyra.config.event_store)
      end

      CommandResult.success(events: [event])
    end

    def handle_destroy
      # Load aggregate (or create new one for records without event history)
      aggregate_class = find_aggregate_class
      aggregate = aggregate_class.load(command.id, Lyra.config.event_store) rescue aggregate_class.new(command.id, command.model_class)

      # Create event
      event = create_event(:destroyed, command.id, {})

      # Apply event to aggregate
      aggregate.apply(event)

      # Store events (defer in event_sourcing mode)
      unless Lyra.event_sourcing_mode?
        aggregate.store(Lyra.config.event_store)
      end

      CommandResult.success(events: [event])
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

      event_metadata = {
        source: 'lyra_command_handler',
        correlation_id: Lyra::Correlation.current_id,
        causation_id: Lyra::Causation.current_id
      }

      config = Lyra.config.model_config(command.model_class)
      event_name = config.event_name_for(operation)

      # Find or create the event class in Lyra::Events namespace
      event_class = if Lyra::Events.const_defined?(event_name, false)
        Lyra::Events.const_get(event_name, false)
      else
        Lyra::Events.const_set(event_name, Class.new(Lyra::Event))
      end

      event_class.new(data: event_data, metadata: event_metadata)
    end

    def find_aggregate_class
      config = Lyra.config.model_config(command.model_class)
      config.aggregate_class || Lyra::GenericAggregate
    end
  end
end
