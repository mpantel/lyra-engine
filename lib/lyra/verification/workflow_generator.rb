# frozen_string_literal: true

module Lyra
  module Verification
    # Generates Petri net workflows by introspecting Lyra's actual implementation.
    # Uses metaprogramming to analyze callbacks, modes, and model configurations.
    class WorkflowGenerator
      attr_reader :analysis, :options

      AVAILABLE_MODES = [:monitor, :hijack, :es_sync, :es_async].freeze

      # The file a mode's workflow is written to, without ".rb": es_sync ->
      # "es_sync_mode_workflow". The same name whether one mode or all are
      # generated, so MODE=es_sync overwrites the file a full run wrote.
      def self.workflow_file_basename(mode)
        "#{mode}_mode_workflow"
      end

      # The class that file defines, the constant Zeitwerk expects from the
      # file's path: es_sync_mode_workflow.rb -> EsSyncModeWorkflow.
      def self.workflow_class_name(mode)
        workflow_file_basename(mode).split("_").map(&:capitalize).join
      end

      def initialize(options = {})
        @options = options
        @analysis = {
          modes: [],
          callbacks: {},
          models: [],
          event_types: []
        }
      end

      # Analyze Lyra implementation and generate workflow
      # @param mode [Symbol, nil] Specific mode to generate workflow for, or nil for all
      def generate!(mode: nil)
        analyze_modes
        analyze_callbacks
        analyze_monitored_models
        analyze_event_types

        result = {
          lifecycle_workflow: generate_lifecycle_workflow,
          analysis: @analysis
        }

        if mode
          # Generate workflow for specific mode
          validate_mode!(mode)
          result[:mode_workflow] = generate_workflow_for_mode(mode)
        else
          # Generate workflows for all modes
          result[:mode_workflows] = generate_all_mode_workflows
        end

        result
      end

      private

      def validate_mode!(mode)
        unless AVAILABLE_MODES.include?(mode.to_sym)
          raise ArgumentError, "Invalid mode: #{mode}. Available modes: #{AVAILABLE_MODES.join(', ')}"
        end
      end

      # Analyze available Lyra modes from configuration
      def analyze_modes
        @analysis[:modes] = []

        # Check which modes are defined in Lyra
        if Lyra.respond_to?(:config)
          config = Lyra.config

          # Introspect the mode from config
          if config.respond_to?(:mode)
            current_mode = config.mode
            @analysis[:current_mode] = current_mode
          end
        end

        # Define all possible modes based on Lyra's design
        @analysis[:modes] = [:monitor, :hijack, :es_sync, :es_async, :disabled]

        # Check which mode methods exist
        @analysis[:mode_methods] = {
          monitor: Lyra.respond_to?(:monitor_mode?),
          hijack: Lyra.respond_to?(:hijack_mode?),
          event_sourcing: Lyra.respond_to?(:event_sourcing_mode?)
        }
      end

      # Analyze ActiveRecord callbacks used by Lyra
      def analyze_callbacks
        @analysis[:callbacks] = {
          create: [],
          update: [],
          destroy: []
        }

        # Introspect the Lyra::Monitorable module for callback definitions
        if defined?(Lyra::Monitorable)
          monitorable = Lyra::Monitorable

          # Check instance methods for callback patterns
          if monitorable.respond_to?(:instance_methods)
            methods = monitorable.instance_methods(false)

            methods.each do |method_name|
              name = method_name.to_s
              if name.include?('create')
                @analysis[:callbacks][:create] << method_name
              elsif name.include?('update')
                @analysis[:callbacks][:update] << method_name
              elsif name.include?('destroy')
                @analysis[:callbacks][:destroy] << method_name
              end
            end
          end

          # Check for callback registrations in ClassMethods
          if monitorable.const_defined?(:ClassMethods)
            class_methods = monitorable::ClassMethods.instance_methods(false)
            @analysis[:class_methods] = class_methods
          end
        end

        # Analyze the actual callback hooks from ActiveSupport
        @analysis[:callback_hooks] = extract_callback_hooks
      end

      # Extract callback hook information from Lyra source
      def extract_callback_hooks
        hooks = { before: [], after: [] }

        # Find Lyra gem root from the loaded gem spec
        lyra_root = Gem.loaded_specs['lyra']&.gem_dir
        lyra_root ||= File.expand_path('../../../..', __FILE__)

        # Look for callback definitions in Monitorable
        monitorable_file = File.join(lyra_root, 'lib', 'lyra', 'monitorable.rb')

        if File.exist?(monitorable_file)
          content = File.read(monitorable_file)

          # Find after_* callbacks
          content.scan(/after_(create|update|destroy|commit|save)\s+:(\w+)/) do |type, method|
            hooks[:after] << { type: type, method: method }
          end

          # Find before_* callbacks
          content.scan(/before_(create|update|destroy|save)\s+:(\w+)/) do |type, method|
            hooks[:before] << { type: type, method: method }
          end
        end

        hooks
      end

      # Analyze monitored models
      def analyze_monitored_models
        @analysis[:models] = []

        if Lyra.respond_to?(:config) && Lyra.config.respond_to?(:monitored_models)
          Lyra.config.monitored_models.each do |model_class|
            model_info = {
              name: model_class.name,
              table_name: model_class.respond_to?(:table_name) ? model_class.table_name : nil,
              callbacks: extract_model_callbacks(model_class)
            }

            # Get Lyra-specific configuration
            if Lyra.config.respond_to?(:model_config)
              config = Lyra.config.model_config(model_class)
              model_info[:event_prefix] = config.event_prefix if config.respond_to?(:event_prefix)
              model_info[:excluded_attributes] = config.excluded_attributes if config.respond_to?(:excluded_attributes)
            end

            @analysis[:models] << model_info
          end
        end
      end

      # Extract callbacks registered on a specific model
      def extract_model_callbacks(model_class)
        callbacks = {}

        [:create, :update, :destroy, :save, :commit].each do |type|
          [:before, :after, :around].each do |timing|
            callback_name = "#{timing}_#{type}"
            if model_class.respond_to?("_#{callback_name}_callbacks")
              chain = model_class.send("_#{callback_name}_callbacks")
              callbacks["#{timing}_#{type}"] = chain.map { |cb| cb.filter.to_s } if chain.any?
            end
          end
        end

        callbacks
      end

      # Analyze event types published by Lyra
      def analyze_event_types
        @analysis[:event_types] = []

        # Check for event class definitions
        if defined?(Lyra::Events)
          Lyra::Events.constants.each do |const|
            event_class = Lyra::Events.const_get(const)
            if event_class.is_a?(Class)
              @analysis[:event_types] << {
                name: const.to_s,
                class: event_class.name,
                attributes: event_class.respond_to?(:attribute_names) ? event_class.attribute_names : []
              }
            end
          end
        end

        # Infer from CRUD operations
        @analysis[:crud_events] = [:Created, :Updated, :Destroyed]
      end

      # Generate lifecycle workflow from analysis
      def generate_lifecycle_workflow
        return nil unless defined?(PetriFlow)

        places = [:nonexistent, :created, :persisted, :updated, :destroyed, :deleted]
        transitions = []

        # Generate transitions based on analyzed callbacks
        hooks = @analysis[:callback_hooks]

        # CREATE flow
        transitions << {
          name: :create,
          from: :nonexistent,
          to: :created,
          trigger: hooks[:after].find { |h| h[:type] == 'create' }&.dig(:method) || 'after_create'
        }
        transitions << {
          name: :emit_created_event,
          from: :created,
          to: :persisted,
          trigger: 'publish Created event'
        }

        # UPDATE flow (cycle)
        transitions << {
          name: :update,
          from: :persisted,
          to: :updated,
          trigger: hooks[:after].find { |h| h[:type] == 'update' }&.dig(:method) || 'after_update'
        }
        transitions << {
          name: :emit_updated_event,
          from: :updated,
          to: :persisted,
          trigger: 'publish Updated event'
        }

        # DESTROY flow
        transitions << {
          name: :destroy,
          from: :persisted,
          to: :destroyed,
          trigger: hooks[:after].find { |h| h[:type] == 'destroy' }&.dig(:method) || 'after_destroy'
        }
        transitions << {
          name: :emit_destroyed_event,
          from: :destroyed,
          to: :deleted,
          trigger: 'publish Destroyed event'
        }

        {
          name: "CRUD Entity Lifecycle (Generated)",
          places: places,
          initial_place: :nonexistent,
          terminal_places: [:deleted],
          transitions: transitions,
          generated_at: Time.current,
          source: "Lyra::Verification::WorkflowGenerator"
        }
      end

      # Generate mode workflow from analysis
      def generate_mode_workflow
        return nil unless defined?(PetriFlow)

        modes = @analysis[:modes].reject { |m| m == :disabled }

        places = [:idle, :operation_requested]
        transitions = []

        # Add places for each mode
        modes.each do |mode|
          places << "#{mode}_processing".to_sym
        end
        places += [:event_published, :completed]

        # Initial transition
        transitions << {
          name: :request_operation,
          from: :idle,
          to: :operation_requested,
          trigger: 'CRUD operation initiated'
        }

        # Mode-specific transitions
        modes.each do |mode|
          processing_place = "#{mode}_processing".to_sym

          transitions << {
            name: "select_#{mode}_mode".to_sym,
            from: :operation_requested,
            to: processing_place,
            trigger: "Lyra.config.mode == :#{mode}"
          }

          transitions << {
            name: "#{mode}_complete".to_sym,
            from: processing_place,
            to: :event_published,
            trigger: "#{mode} mode processing complete"
          }
        end

        # Final transition
        transitions << {
          name: :finalize,
          from: :event_published,
          to: :completed,
          trigger: 'Event stored'
        }

        {
          name: "Lyra Mode Selection (Generated)",
          places: places,
          initial_place: :idle,
          terminal_places: [:completed],
          transitions: transitions,
          generated_at: Time.current,
          source: "Lyra::Verification::WorkflowGenerator"
        }
      end

      # Generate workflows for all available modes
      def generate_all_mode_workflows
        return {} unless defined?(PetriFlow)

        AVAILABLE_MODES.each_with_object({}) do |mode, workflows|
          workflows[mode] = generate_workflow_for_mode(mode)
        end
      end

      # Generate workflow for a specific mode
      def generate_workflow_for_mode(mode)
        return nil unless defined?(PetriFlow)

        case mode.to_sym
        when :monitor
          generate_monitor_workflow
        when :hijack
          generate_hijack_workflow
        when :es_sync
          generate_es_sync_workflow
        when :es_async
          generate_es_async_workflow
        end
      end

      # Monitor Mode: Passive observation of CRUD operations
      # CRUD executes normally, events published after the fact
      def generate_monitor_workflow
        {
          name: "Monitor Mode Workflow",
          description: "Passively observes CRUD operations without modification",
          places: [
            :idle,
            :crud_executing,
            :crud_completed,
            :event_building,
            :event_publishing,
            :completed
          ],
          initial_place: :idle,
          terminal_places: [:completed],
          transitions: [
            { name: :receive_crud, from: :idle, to: :crud_executing,
              trigger: "ActiveRecord callback triggered" },
            { name: :crud_success, from: :crud_executing, to: :crud_completed,
              trigger: "CRUD operation completes successfully" },
            { name: :build_event, from: :crud_completed, to: :event_building,
              trigger: "Extract changes from model" },
            { name: :publish_event, from: :event_building, to: :event_publishing,
              trigger: "Lyra::Event.publish" },
            { name: :store_event, from: :event_publishing, to: :completed,
              trigger: "RailsEventStore.publish" }
          ],
          generated_at: Time.current,
          source: "Lyra::Verification::WorkflowGenerator"
        }
      end

      # Hijack Mode: Intercepts CRUD, converts to command/event flow
      # Original CRUD is prevented, replaced with event-sourced operation
      def generate_hijack_workflow
        {
          name: "Hijack Mode Workflow",
          description: "Intercepts CRUD operations and converts to event sourcing",
          places: [
            :idle,
            :crud_intercepted,
            :command_created,
            :command_validating,
            :command_valid,
            :event_created,
            :event_stored,
            :projecting,
            :completed
          ],
          initial_place: :idle,
          terminal_places: [:completed],
          transitions: [
            { name: :intercept_crud, from: :idle, to: :crud_intercepted,
              trigger: "before_* callback intercepts operation" },
            { name: :create_command, from: :crud_intercepted, to: :command_created,
              trigger: "Convert CRUD to Lyra::Command" },
            { name: :validate_command, from: :command_created, to: :command_validating,
              trigger: "CommandHandler.validate" },
            { name: :command_passes, from: :command_validating, to: :command_valid,
              trigger: "Validation passes" },
            { name: :emit_event, from: :command_valid, to: :event_created,
              trigger: "CommandHandler.execute creates event" },
            { name: :store_event, from: :event_created, to: :event_stored,
              trigger: "RailsEventStore.publish" },
            { name: :project_state, from: :event_stored, to: :projecting,
              trigger: "Projection.apply(event)" },
            { name: :projection_complete, from: :projecting, to: :completed,
              trigger: "Model state updated from event" }
          ],
          generated_at: Time.current,
          source: "Lyra::Verification::WorkflowGenerator"
        }
      end

      # ES Sync Mode: Full event sourcing with synchronous projection
      # Blocks until projection is complete
      def generate_es_sync_workflow
        {
          name: "Event Sourcing Sync Mode Workflow",
          description: "Full event sourcing with synchronous (blocking) projection",
          places: [
            :idle,
            :command_received,
            :aggregate_loading,
            :aggregate_loaded,
            :command_applying,
            :events_generated,
            :events_storing,
            :events_stored,
            :projecting_sync,
            :projection_complete,
            :completed
          ],
          initial_place: :idle,
          terminal_places: [:completed],
          transitions: [
            { name: :receive_command, from: :idle, to: :command_received,
              trigger: "CommandHandler receives command" },
            { name: :load_aggregate, from: :command_received, to: :aggregate_loading,
              trigger: "Load aggregate from event stream" },
            { name: :aggregate_ready, from: :aggregate_loading, to: :aggregate_loaded,
              trigger: "Aggregate hydrated from events" },
            { name: :apply_command, from: :aggregate_loaded, to: :command_applying,
              trigger: "Aggregate.apply(command)" },
            { name: :generate_events, from: :command_applying, to: :events_generated,
              trigger: "Domain events created" },
            { name: :store_events, from: :events_generated, to: :events_storing,
              trigger: "EventStore.append_to_stream" },
            { name: :events_persisted, from: :events_storing, to: :events_stored,
              trigger: "Events committed to store" },
            { name: :project_sync, from: :events_stored, to: :projecting_sync,
              trigger: "ModelProjection.apply (synchronous)" },
            { name: :sync_complete, from: :projecting_sync, to: :projection_complete,
              trigger: "Read model updated" },
            { name: :finalize, from: :projection_complete, to: :completed,
              trigger: "Response returned to caller" }
          ],
          generated_at: Time.current,
          source: "Lyra::Verification::WorkflowGenerator"
        }
      end

      # ES Async Mode: Full event sourcing with asynchronous projection
      # Returns immediately, projection happens in background
      #
      # Uses Petri net FORK pattern to model true parallelism:
      # After events are stored, a single fork transition places tokens in
      # BOTH response_returned AND job_processing simultaneously.
      def generate_es_async_workflow
        {
          name: "Event Sourcing Async Mode Workflow",
          description: "Full event sourcing with asynchronous (non-blocking) projection",
          places: [
            :idle,
            :command_received,
            :aggregate_loading,
            :aggregate_loaded,
            :command_applying,
            :events_generated,
            :events_storing,
            :events_stored,
            :response_returned,      # Terminal: caller gets response immediately
            :job_processing,         # Background job starts
            :projecting_async,
            :projection_complete     # Terminal: projection eventually completes
          ],
          initial_place: :idle,
          terminal_places: [:response_returned, :projection_complete],
          transitions: [
            { name: :receive_command, from: :idle, to: :command_received,
              trigger: "CommandHandler receives command" },
            { name: :load_aggregate, from: :command_received, to: :aggregate_loading,
              trigger: "Load aggregate from event stream" },
            { name: :aggregate_ready, from: :aggregate_loading, to: :aggregate_loaded,
              trigger: "Aggregate hydrated from events" },
            { name: :apply_command, from: :aggregate_loaded, to: :command_applying,
              trigger: "Aggregate.apply(command)" },
            { name: :generate_events, from: :command_applying, to: :events_generated,
              trigger: "Domain events created" },
            { name: :store_events, from: :events_generated, to: :events_storing,
              trigger: "EventStore.append_to_stream" },
            { name: :events_persisted, from: :events_storing, to: :events_stored,
              trigger: "Events committed to store" },
            # FORK: Parallel split - produces tokens in TWO places simultaneously
            # Models async behavior: response returns AND background job starts
            { name: :async_fork, from: :events_stored, to: [:response_returned, :job_processing],
              trigger: "Enqueue job & return response (parallel)" },
            # Background projection flow (runs independently after fork)
            { name: :project_async, from: :job_processing, to: :projecting_async,
              trigger: "ModelProjection.apply (async)" },
            { name: :async_complete, from: :projecting_async, to: :projection_complete,
              trigger: "Read model eventually consistent" }
          ],
          generated_at: Time.current,
          source: "Lyra::Verification::WorkflowGenerator"
        }
      end
    end
  end
end
