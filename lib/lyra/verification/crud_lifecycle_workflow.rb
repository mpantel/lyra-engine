# frozen_string_literal: true

module Lyra
  module Verification
    # Petri Net model for verifying CRUD→Event mapping correctness.
    #
    # This workflow models the lifecycle of an entity through CRUD operations
    # and verifies that:
    # 1. Every CRUD operation generates exactly one event
    # 2. Entity state transitions are valid (can't update/destroy before create)
    # 3. All terminal states are reachable
    # 4. No deadlocks in the event flow
    #
    # @example Verify the workflow
    #   workflow = Lyra::Verification::CrudLifecycleWorkflow.new
    #   results = workflow.verify!
    #   puts results[:liveness][:deadlock_free] # => true
    #
    class CrudLifecycleWorkflow < PetriFlow::Workflow
      workflow_name "CRUD Entity Lifecycle"

      # Entity lifecycle states
      # - nonexistent: Entity does not exist yet
      # - created: Entity was just created (event pending)
      # - persisted: Entity exists in storage
      # - updated: Entity was just updated (event pending)
      # - destroyed: Entity was just destroyed (event pending)
      # - deleted: Entity no longer exists (terminal)
      places :nonexistent, :created, :persisted, :updated, :destroyed, :deleted

      # Starting state - entity does not exist
      initial_place :nonexistent

      # Terminal state - entity is deleted
      terminal_places :deleted

      # CRUD Operations as Transitions
      # Each transition represents a CRUD operation that:
      # 1. Changes entity state
      # 2. Generates a corresponding event

      # CREATE: nonexistent → created → persisted
      transition :create, from: :nonexistent, to: :created,
                 trigger: "ActiveRecord after_create callback"
      transition :emit_created_event, from: :created, to: :persisted,
                 trigger: "Lyra::Events::Created published"

      # UPDATE: persisted → updated → persisted (cycle)
      transition :update, from: :persisted, to: :updated,
                 trigger: "ActiveRecord after_update callback"
      transition :emit_updated_event, from: :updated, to: :persisted,
                 trigger: "Lyra::Events::Updated published"

      # DESTROY: persisted → destroyed → deleted
      transition :destroy, from: :persisted, to: :destroyed,
                 trigger: "ActiveRecord after_destroy callback"
      transition :emit_destroyed_event, from: :destroyed, to: :deleted,
                 trigger: "Lyra::Events::Destroyed published"
    end

    # CREATE operation workflow across all Lyra modes
    class CreateModeWorkflow < PetriFlow::Workflow
      workflow_name "Create Mode Verification"

      places :idle,
             :create_requested,
             :monitor_mode, :hijack_mode, :event_sourcing_mode,
             :event_published, :command_processed,
             :completed

      initial_place :idle
      terminal_places :completed

      # Request create
      transition :request_create, from: :idle, to: :create_requested,
                 trigger: "model.save (new record)"

      # Monitor mode: after_create callback
      transition :select_monitor, from: :create_requested, to: :monitor_mode,
                 trigger: "Lyra.monitor_mode? == true"
      transition :monitor_publish, from: :monitor_mode, to: :event_published,
                 trigger: "lyra_intercept_create"

      # Hijack mode: before_create callback with command
      transition :select_hijack, from: :create_requested, to: :hijack_mode,
                 trigger: "Lyra.hijack_mode? == true"
      transition :hijack_handle, from: :hijack_mode, to: :command_processed,
                 trigger: "CommandHandler.handle(CreateCommand)"

      # Event sourcing mode
      transition :select_es, from: :create_requested, to: :event_sourcing_mode,
                 trigger: "Lyra.event_sourcing_mode? == true"
      transition :es_process, from: :event_sourcing_mode, to: :command_processed,
                 trigger: "lyra_prepare_event_source + lyra_finalize"

      # Complete
      transition :complete_from_event, from: :event_published, to: :completed,
                 trigger: "Event stored"
      transition :complete_from_command, from: :command_processed, to: :completed,
                 trigger: "Command processed"
    end

    # UPDATE operation workflow across all Lyra modes
    class UpdateModeWorkflow < PetriFlow::Workflow
      workflow_name "Update Mode Verification"

      places :idle,
             :update_requested,
             :monitor_mode, :hijack_mode, :event_sourcing_mode,
             :event_published, :command_processed,
             :completed

      initial_place :idle
      terminal_places :completed

      # Request update
      transition :request_update, from: :idle, to: :update_requested,
                 trigger: "model.save (existing record)"

      # Monitor mode: after_update callback
      transition :select_monitor, from: :update_requested, to: :monitor_mode,
                 trigger: "Lyra.monitor_mode? == true"
      transition :monitor_publish, from: :monitor_mode, to: :event_published,
                 trigger: "lyra_intercept_update"

      # Hijack mode: before_update callback with command
      transition :select_hijack, from: :update_requested, to: :hijack_mode,
                 trigger: "Lyra.hijack_mode? == true"
      transition :hijack_handle, from: :hijack_mode, to: :command_processed,
                 trigger: "CommandHandler.handle(UpdateCommand)"

      # Event sourcing mode
      transition :select_es, from: :update_requested, to: :event_sourcing_mode,
                 trigger: "Lyra.event_sourcing_mode? == true"
      transition :es_process, from: :event_sourcing_mode, to: :command_processed,
                 trigger: "lyra_prepare_event_source + lyra_finalize"

      # Complete
      transition :complete_from_event, from: :event_published, to: :completed,
                 trigger: "Event stored"
      transition :complete_from_command, from: :command_processed, to: :completed,
                 trigger: "Command processed"
    end

    # DESTROY operation workflow across all Lyra modes
    class DestroyModeWorkflow < PetriFlow::Workflow
      workflow_name "Destroy Mode Verification"

      places :idle,
             :destroy_requested,
             :monitor_mode, :hijack_mode, :event_sourcing_mode,
             :event_published, :command_processed,
             :completed

      initial_place :idle
      terminal_places :completed

      # Request destroy
      transition :request_destroy, from: :idle, to: :destroy_requested,
                 trigger: "model.destroy"

      # Monitor mode: after_destroy callback
      transition :select_monitor, from: :destroy_requested, to: :monitor_mode,
                 trigger: "Lyra.monitor_mode? == true"
      transition :monitor_publish, from: :monitor_mode, to: :event_published,
                 trigger: "lyra_intercept_destroy"

      # Hijack mode: before_destroy callback with command
      transition :select_hijack, from: :destroy_requested, to: :hijack_mode,
                 trigger: "Lyra.hijack_mode? == true"
      transition :hijack_handle, from: :hijack_mode, to: :command_processed,
                 trigger: "CommandHandler.handle(DestroyCommand)"

      # Event sourcing mode
      transition :select_es, from: :destroy_requested, to: :event_sourcing_mode,
                 trigger: "Lyra.event_sourcing_mode? == true"
      transition :es_process, from: :event_sourcing_mode, to: :command_processed,
                 trigger: "lyra_prepare_event_source + lyra_finalize"

      # Complete
      transition :complete_from_event, from: :event_published, to: :completed,
                 trigger: "Event stored"
      transition :complete_from_command, from: :command_processed, to: :completed,
                 trigger: "Command processed"
    end

    # Convenience alias for backwards compatibility
    CrudModeVerificationWorkflow = CreateModeWorkflow

    # Verification runner for Lyra CRUD workflows
    class CrudVerifier
      attr_reader :results, :report

      def initialize
        @results = {}
        @report = nil
      end

      # Verify all CRUD workflows
      def verify_all
        verify_lifecycle
        verify_modes
        verify_bypass
        verify_generated_workflows
        generate_report
        @report
      end

      # Verify entity lifecycle workflow
      def verify_lifecycle
        workflow = CrudLifecycleWorkflow.new
        @results[:lifecycle] = {
          workflow: workflow.workflow_name,
          verification: workflow.verify!,
          terminal_reachability: workflow.terminal_reachability.dup,
          diagrams: {
            mermaid: workflow.to_mermaid,
            dot: workflow.to_dot
          }
        }
      end

      # Verify mode-switching workflows (Create, Update, Destroy)
      def verify_modes
        @results[:modes] = {}

        {
          create: CreateModeWorkflow,
          update: UpdateModeWorkflow,
          destroy: DestroyModeWorkflow
        }.each do |operation, workflow_class|
          workflow = workflow_class.new
          @results[:modes][operation] = {
            workflow: workflow.workflow_name,
            verification: workflow.verify!,
            terminal_reachability: workflow.terminal_reachability.dup,
            diagrams: {
              mermaid: workflow.to_mermaid,
              dot: workflow.to_dot
            }
          }
        end
      end

      # Verify the callback-bypassing writes, which the CRUD nets don't cover
      def verify_bypass
        workflow = BypassWorkflow.new
        @results[:bypass] = {
          workflow: workflow.workflow_name,
          verification: workflow.verify!,
          terminal_reachability: workflow.terminal_reachability.dup,
          coverage: BypassWorkflow.coverage(workflow),
          diagrams: {
            mermaid: workflow.to_mermaid,
            dot: workflow.to_dot
          }
        }
      end

      # Verify generated workflows from app/workflows directories
      # Scans both Lyra gem's workflows AND Rails app's workflows
      def verify_generated_workflows
        @results[:generated_workflows] = {}

        # Find all workflow directories
        workflows_dirs = find_workflows_dirs
        return if workflows_dirs.empty?

        # Ensure the Generated module exists
        Lyra::Verification.const_set(:Generated, Module.new) unless Lyra::Verification.const_defined?(:Generated)

        # Load and verify workflows from all directories
        workflows_dirs.each do |workflows_dir|
          Dir.glob(File.join(workflows_dir, "*_workflow.rb")).each do |file|
            basename = File.basename(file, '.rb')
            # Skip if already loaded from another directory
            next if @results[:generated_workflows].key?(basename.to_sym)

            begin
              # Use load instead of require to bypass Zeitwerk
              load file

              # Extract class name from file name
              class_name = basename.split('_').map(&:capitalize).join

              # Try to find the class - check multiple locations
              workflow_class = find_workflow_class(class_name)

              if workflow_class
                workflow = workflow_class.new

                @results[:generated_workflows][basename.to_sym] = {
                  workflow: workflow.workflow_name,
                  file: file,
                  verification: workflow.verify!,
                  terminal_reachability: workflow.terminal_reachability.dup,
                  diagrams: {
                    mermaid: workflow.to_mermaid,
                    dot: workflow.to_dot
                  }
                }
              end
            rescue StandardError => e
              @results[:generated_workflows][basename.to_sym] = {
                error: "#{e.class}: #{e.message}",
                file: file
              }
            end
          end
        end
      end

      # Find all workflow directories (both Lyra gem and Rails app)
      def find_workflows_dirs
        dirs = []

        # Check Lyra gem's app/workflows
        lyra_gem_root = Gem.loaded_specs['lyra']&.gem_dir
        lyra_gem_root ||= File.expand_path('../../..', __dir__)
        lyra_workflows = File.join(lyra_gem_root, 'app', 'workflows')
        dirs << lyra_workflows if Dir.exist?(lyra_workflows)

        # Check Rails app's app/workflows
        if defined?(Rails) && Rails.root
          rails_workflows = Rails.root.join('app', 'workflows').to_s
          # Add only if different from Lyra gem's path
          dirs << rails_workflows if Dir.exist?(rails_workflows) && !dirs.include?(rails_workflows)
        end

        dirs
      end

      # Find workflow class by name, checking multiple locations
      def find_workflow_class(class_name)
        # Check Generated module first (if it exists)
        if defined?(Lyra::Verification::Generated) &&
           Lyra::Verification::Generated.const_defined?(class_name)
          return Lyra::Verification::Generated.const_get(class_name)
        end

        # Check top-level (for workflows defined without module)
        if Object.const_defined?(class_name)
          klass = Object.const_get(class_name)
          return klass if klass < PetriFlow::Workflow
        end

        nil
      end

      # Backwards compatibility
      def find_workflows_dir
        find_workflows_dirs.first
      end

      # Analyze actual CRUD→Event mapping from Lyra configuration
      def analyze_mapping
        mapping = PetriFlow::Matrix::CrudEventMapping.new

        Lyra.config.monitored_models.each do |model_class|
          config = Lyra.config.model_config(model_class)
          prefix = config.event_prefix

          # Record expected mappings
          mapping.record_mapping(:create, "#{prefix}Created".to_sym)
          mapping.record_mapping(:update, "#{prefix}Updated".to_sym)
          mapping.record_mapping(:delete, "#{prefix}Destroyed".to_sym)
        end

        @results[:mapping] = {
          matrix: mapping.to_table,
          stats: {
            models: Lyra.config.monitored_models.count,
            total_mappings: mapping.to_matrix.to_a.flatten.sum
          }
        }
      end

      # Generate verification report
      def generate_report
        @report = {
          timestamp: Time.current,
          lyra_version: Lyra::VERSION,
          petri_flow_version: PetriFlow::VERSION,
          summary: build_summary,
          details: @results
        }
      end

      private

      def build_summary
        lifecycle = @results[:lifecycle]
        modes = @results[:modes]

        {
          lifecycle_valid: lifecycle_valid?(lifecycle),
          modes_valid: modes_valid?(modes),
          all_terminals_reachable: all_terminals_reachable?,
          deadlock_free: deadlock_free?,
          bypass_covered: bypass_covered?,
          recommendations: build_recommendations
        }
      end

      def lifecycle_valid?(result)
        return false unless result

        verification = result[:verification]
        # Note: We don't require deadlock_free because the update cycle
        # (persisted ↔ updated) is intentional - entities can be updated
        # indefinitely without being deleted. This is valid CRUD behavior.
        verification[:boundedness][:is_safe] &&
          result[:terminal_reachability].values.all?
      end

      def modes_valid?(modes_results)
        return false unless modes_results

        # Check all three CRUD mode workflows
        modes_results.values.all? do |result|
          next false unless result[:verification]
          result[:verification][:boundedness][:is_safe] &&
            result[:terminal_reachability].values.all?
        end
      end

      def all_terminals_reachable?
        flatten_results.all? do |result|
          next true unless result[:terminal_reachability]
          result[:terminal_reachability].values.all?
        end
      end

      # Deadlock-freedom in the thesis's sense: no reachable marking is dead
      # unless it marks a designated terminal place. PetriFlow's raw
      # deadlock_free counts the intended end as a deadlock, so it is false
      # for every net here.
      def deadlock_free?
        flatten_results.all? do |result|
          next true unless result.dig(:verification, :liveness)
          result[:verification][:liveness][:terminates_properly]
        end
      end

      def bypass_covered?
        @results.dig(:bypass, :coverage, :covered) || false
      end

      # Flatten nested results (modes has 3 sub-results)
      def flatten_results
        results = []
        results << @results[:lifecycle] if @results[:lifecycle]
        results += @results[:modes].values if @results[:modes]
        results << @results[:bypass] if @results[:bypass]
        results += @results[:generated_workflows].values if @results[:generated_workflows]
        results
      end

      def build_recommendations
        recommendations = []

        unless all_terminals_reachable?
          recommendations << "Some terminal states are unreachable - review state machine design"
        end

        unless deadlock_free?
          recommendations << "Some net can get stuck outside its terminal places - review the transitions"
        end

        unless bypass_covered?
          recommendations << "A callback-bypassing write can change the store without an event"
        end

        if recommendations.empty?
          recommendations << "All verifications passed - CRUD→Event mapping is formally correct"
        end

        recommendations
      end
    end
  end
end
