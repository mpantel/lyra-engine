# frozen_string_literal: true

module Lyra
  module Verification
    # Generates Petri net workflows for Lyra's modes and the lifecycle of its
    # monitored models. The mode nets are written by hand below, one step per
    # method Lyra calls, in the order test/verification/trace_conformance_test.rb
    # observes on real writes; the lifecycle net uses the monitored models'
    # configuration (event prefixes).
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

        # Lyra's callbacks are installed by Lyra::Interceptors::CrudInterceptor,
        # which this analysis does not introspect: the lists stay empty and the
        # generated workflow names the generic after_* hooks.
        @analysis[:callback_hooks] = { before: [], after: [] }
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
          description: "The row is written as usual; the event follows in the same transaction",
          places: [:idle, :row_written, :event_built, :completed],
          initial_place: :idle,
          terminal_places: [:completed],
          transitions: [
            { name: :write_row, from: :idle, to: :row_written,
              trigger: "ActiveRecord writes the row" },
            { name: :build_event, from: :row_written, to: :event_built,
              trigger: "after_* callback: CrudInterceptor#publish_event builds it (Lyra::DomainEvents.build)" },
            { name: :append_event, from: :event_built, to: :completed,
              trigger: "Lyra.append_events, in a savepoint of the same transaction" }
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
          description: "The event is built and stored before the row, which is written from it",
          places: [:idle, :command_built, :event_built, :event_applied, :event_stored, :completed],
          initial_place: :idle,
          terminal_places: [:completed],
          transitions: [
            { name: :intercept_write, from: :idle, to: :command_built,
              trigger: "WriteHooks, after the model's before_* callbacks: a Lyra::Command (a create first reserves its id)" },
            { name: :build_event, from: :command_built, to: :event_built,
              trigger: "Lyra::CommandHandler.handle: create_events" },
            { name: :apply_event, from: :event_built, to: :event_applied,
              trigger: "aggregate.apply(event): the event joins the aggregate's pending events" },
            { name: :store_event, from: :event_applied, to: :event_stored,
              trigger: "aggregate.store: Lyra.append_events" },
            { name: :write_row, from: :event_stored, to: :completed,
              trigger: "ActiveRecord writes the row with the event's attributes" }
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
          description: "The event is stored, then projected into the table in the same transaction",
          places: [:idle, :command_built, :event_built, :event_applied, :event_stored, :completed],
          initial_place: :idle,
          terminal_places: [:completed],
          transitions: [
            { name: :intercept_write, from: :idle, to: :command_built,
              trigger: "WriteHooks: a Lyra::Command (a create first reserves its id); the row write is withheld" },
            { name: :build_event, from: :command_built, to: :event_built,
              trigger: "Lyra::CommandHandler.handle: create_events" },
            { name: :apply_event, from: :event_built, to: :event_applied,
              trigger: "aggregate.apply(event)" },
            { name: :store_event, from: :event_applied, to: :event_stored,
              trigger: "after_* callback lyra_finalize_event_source: Lyra.append_events" },
            { name: :project_row, from: :event_stored, to: :completed,
              trigger: "synchronous projection writes the row from the event" }
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
      # BOTH response_returned AND job_enqueued simultaneously.
      def generate_es_async_workflow
        {
          name: "Event Sourcing Async Mode Workflow",
          description: "The event is stored; a job projects it into the table after commit",
          places: [:idle, :command_built, :event_built, :event_applied, :event_stored,
                   :response_returned, :job_enqueued, :projection_complete],
          initial_place: :idle,
          # The caller's write ends at response_returned; the row follows when the
          # job runs. Both are terminal.
          terminal_places: [:response_returned, :projection_complete],
          transitions: [
            { name: :intercept_write, from: :idle, to: :command_built,
              trigger: "WriteHooks: a Lyra::Command (a create first reserves its id); the row write is withheld" },
            { name: :build_event, from: :command_built, to: :event_built,
              trigger: "Lyra::CommandHandler.handle: create_events" },
            { name: :apply_event, from: :event_built, to: :event_applied,
              trigger: "aggregate.apply(event)" },
            { name: :store_event, from: :event_applied, to: :event_stored,
              trigger: "after_* callback lyra_finalize_event_source: Lyra.append_events" },
            # FORK: the write returns while the projection job is pending
            { name: :async_fork, from: :event_stored, to: [:response_returned, :job_enqueued],
              trigger: "AsyncProjectionJob.perform_later, after commit" },
            { name: :project_row, from: :job_enqueued, to: :projection_complete,
              trigger: "AsyncProjectionJob writes the row from the event, under a per-stream lock" }
          ],
          generated_at: Time.current,
          source: "Lyra::Verification::WorkflowGenerator"
        }
      end
    end
  end
end
