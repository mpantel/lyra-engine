module Lyra
  # Only define Engine when Rails is available
  if defined?(Rails)
    class Engine < ::Rails::Engine
      isolate_namespace Lyra

      config.generators do |g|
        g.test_framework :rspec
      end

      initializer "lyra.configure_rails_initialization" do
        # Initialize Event Store
        Lyra.event_store ||= RailsEventStore::Client.new
      end

      # PetriFlow is optional, but app/workflows/*.rb subclass
      # PetriFlow::Workflow: without the gem, eager loading them (production
      # boot, and the lyra:mode:*, lyra:repair, lyra:schema:* tasks, which
      # eager-load the application) raised NameError. Without PetriFlow the
      # directory is neither autoloaded nor eager-loaded; the workflows are
      # used only by Lyra::Verification, which is loaded only with the gem,
      # and the dashboard checks Lyra.petri_flow_available? before
      # verifying. Runs before the Finisher's :setup_main_autoloader.
      initializer "lyra.optional_workflows", before: :set_autoload_paths do
        Lyra::Engine.ignore_workflows! unless Lyra::Engine.workflows_loadable?
      end

      def self.workflows_loadable?
        Lyra.petri_flow_available? && !!defined?(::PetriFlow::Workflow)
      end

      def self.workflows_path
        root.join("app", "workflows").to_s
      end

      def self.ignore_workflows!
        Rails.autoloaders.main.ignore(workflows_path)
      end

      initializer "lyra.inject_interceptors", after: :load_config_initializers do
        ActiveSupport.on_load(:active_record) do
          require "lyra/interceptors/crud_interceptor"
          include Lyra::Interceptors::CrudInterceptor
        end
      end

      # Install association interceptor for disabled projections mode
      # Must run after active_record is loaded
      initializer "lyra.install_association_interceptor", after: "lyra.inject_interceptors" do
        ActiveSupport.on_load(:active_record) do
          require "lyra/interceptors/association_interceptor"
          Lyra::Interceptors::AssociationInterceptor.install!
        end
      end

      # Read hooks for ES-Lazy (projection_mode :lazy); inert in other modes.
      initializer "lyra.install_lazy_reads", after: "lyra.inject_interceptors" do
        ActiveSupport.on_load(:active_record) do
          require "lyra/interceptors/lazy_reads"
          Lyra::Interceptors::LazyReads.install!
        end
      end

      # Install strict data access relation extension for update_all/delete_all
      # This intercepts bulk operations on relations (Model.where(...).update_all)
      initializer "lyra.install_strict_data_access", after: "lyra.inject_interceptors" do
        ActiveSupport.on_load(:active_record) do
          ActiveRecord::Relation.prepend(Lyra::StrictDataAccessRelation)
        end
      end

      # config.models = [...]: instrument the declared models once the
      # application's code has loaded, and again after each code reload.
      initializer "lyra.apply_declared_models", after: :load_config_initializers do |app|
        app.config.to_prepare { Lyra.config.apply_declared_models! }
      end

      # Lyra::ModeSync: adopt a mode switched in another process, before each
      # request and each background job.
      initializer "lyra.mode_sync" do |app|
        app.config.middleware.use Lyra::ModeSync::Middleware
        ActiveSupport.on_load(:active_job) do
          before_perform { Lyra::ModeSync.maybe_sync! }
        end
      end

      # config.verify_mapping!: verify at boot, once the models are
      # instrumented; a failure stops the boot.
      initializer "lyra.verify_mapping", after: "lyra.apply_declared_models" do
        config.after_initialize do
          Lyra.booted!
          Lyra.verify_mapping! if Lyra.config.verify_mapping_at_boot?
          # Mode Transition Safety at boot, for the processes that serve the
          # application. Rake tasks (migrations, rake lyra:mode:check itself)
          # boot too, and must not be refused by the switch they prepare.
          Lyra::ModeTransition.boot_check! unless defined?(Rake.application) && Rake.application.top_level_tasks.any?
        end
      end

      # Register event classes at startup for RailsEventStore deserialization
      # This ensures Object.const_get() works when reading events from the store
      initializer "lyra.register_event_classes", after: :load_config_initializers do
        config.after_initialize do
          next unless Lyra.config.monitored_models.any?

          Lyra::Schema::EventClassRegistrar.register_all
        end
      end

      # Schema validation on startup (after event classes are registered)
      initializer "lyra.verify_schema", after: "lyra.register_event_classes" do
        config.after_initialize do
          next unless Lyra.config.monitored_models.any?
          next unless Lyra.config.strict_schema

          validator = Lyra::Schema::Validator.new
          validator.enforce! if validator.schema_exists?
        end
      end

      # Rails loads every lib/tasks/*.rake under an engine's root into the
      # host application. In the monorepo that root also holds its own
      # maintenance tasks (gems:, public:, stats:, ...), and the Lyra task
      # files loaded here explicitly as well, so each Lyra task ran twice
      # (lyra:mode:check checked everything twice). Host applications get
      # Lyra's own tasks, once.
      paths["lib/tasks"].glob = "lyra_*.rake"
    end
  end
end
