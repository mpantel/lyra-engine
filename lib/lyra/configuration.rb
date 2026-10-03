module Lyra
  class Configuration
    # Valid modes for Lyra operation
    MODES = [:disabled, :monitor, :hijack, :event_sourcing].freeze

    attr_accessor :mode, :event_store, :event_backend, :hijack_enabled, :retention_policy
    attr_accessor :projection_mode, :strict_projections, :projection_error_handler, :async_projections_inline
    attr_accessor :strict_schema, :schema_path
    attr_accessor :strict_data_access  # Raise on callback-bypassing operations
    attr_accessor :metadata_proc  # Custom metadata proc for events
    attr_reader :monitored_models

    def initialize
      @mode = :monitor
      @event_backend = :rails_event_store
      @hijack_enabled = false
      @monitored_models = []
      @model_configs = {}
      @retention_policy = nil
      # Event sourcing specific options
      @projection_mode = :sync  # :sync, :async, :disabled (ES-NoProj) or :lazy (ES-Lazy: project on read)
      @strict_projections = false  # Raise on projection errors if true
      @projection_error_handler = nil  # Custom error handler proc
      @async_projections_inline = false  # Run async projections synchronously (useful for testing)
      # Schema validation options
      @strict_schema = false  # Fail on startup if schema changes detected
      @schema_path = nil  # Custom path for schema files (defaults to db/lyra_schemas/)
      # Strict data access - raise on operations that bypass callbacks
      @strict_data_access = false
      # User tracking - custom metadata proc called for every event
      # Signature: ->(record, operation) { { user_id: ..., ... } }
      @metadata_proc = nil
    end

    # Register a model for monitoring/hijacking
    def monitor_model(model_class, options = {})
      # Check by name to handle Rails development reloading (class objects change on reload)
      model_name = begin
        model_class.name
      rescue StandardError
        model_class.object_id.to_s
      end

      unless @monitored_models.any? { |m| (m.name rescue m.object_id.to_s) == model_name }
        @monitored_models << model_class
      else
        # Update the reference to the new class object (after reload)
        @monitored_models.map! { |m| (m.name rescue m.object_id.to_s) == model_name ? model_class : m }
      end
      @model_configs[model_class] = ModelConfiguration.new(model_class, options)
    end

    def model_config(model_class)
      @model_configs[model_class] || ModelConfiguration.new(model_class)
    end

    def monitor_mode?
      @mode == :monitor
    end

    def hijack_mode?
      @mode == :hijack || @hijack_enabled
    end

    def event_sourcing_mode?
      @mode == :event_sourcing
    end

    def disabled_mode?
      @mode == :disabled
    end

    # Enable hijack mode (can override CRUD operations)
    def enable_hijack!
      @hijack_enabled = true
      @mode = :hijack
    end

    # Enable monitor mode (only log events, don't override)
    def enable_monitor!
      @hijack_enabled = false
      @mode = :monitor
    end

    # Enable event sourcing mode (events as source of truth, no direct DB writes)
    def enable_event_sourcing!
      @mode = :event_sourcing
      @hijack_enabled = false
    end

    # Disable Lyra completely
    def disable!
      @mode = :disabled
      @hijack_enabled = false
    end
  end

  class ModelConfiguration
    attr_accessor :event_prefix, :aggregate_class, :command_handler, :privacy_policy
    attr_reader :model_class

    def initialize(model_class, options = {})
      @model_class = model_class
      @event_prefix = options[:event_prefix] || model_class.name
      @aggregate_class = options[:aggregate_class]
      @command_handler = options[:command_handler]
      @custom_event_mapping = options[:event_mapping] || {}
      @privacy_policy = options[:privacy_policy]
    end

    def event_name_for(operation)
      @custom_event_mapping[operation] || "#{event_prefix}#{operation.to_s.camelize}"
    end
  end

  def self.config
    @config ||= Configuration.new
  end

  # Reset configuration (useful for testing)
  def self.reset_config!
    @config = Configuration.new
  end
end
