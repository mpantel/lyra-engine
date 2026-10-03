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

      # Load rake tasks
      rake_tasks do
        load "tasks/lyra_schema.rake"
        load "tasks/lyra_projections.rake"
      end
    end
  end
end
