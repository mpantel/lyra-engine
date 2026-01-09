# frozen_string_literal: true

require "rails/railtie"

module PetriFlow
  # Rails integration for PetriFlow.
  # Automatically loads rake tasks and discovers workflows in app/workflows/.
  #
  # @example Configure in config/application.rb or an initializer
  #   Rails.application.configure do
  #     config.petri_flow.workflows_path = "app/workflows"
  #     config.petri_flow.auto_discover = true
  #   end
  #
  class Railtie < Rails::Railtie
    railtie_name :petri_flow

    # Load rake tasks
    rake_tasks do
      load File.expand_path("tasks/petri_flow.rake", __dir__)
    end

    # Configuration defaults
    config.petri_flow = ActiveSupport::OrderedOptions.new
    config.petri_flow.workflows_path = "app/workflows"
    config.petri_flow.auto_discover = true

    # Store configuration reference
    initializer "petri_flow.configuration" do |app|
      PetriFlow.rails_config = app.config.petri_flow
    end

    # Auto-discover workflows after initialization
    config.after_initialize do |app|
      if app.config.petri_flow.auto_discover
        workflows_dir = app.root.join(app.config.petri_flow.workflows_path)
        Registry.discover_in(workflows_dir.to_s)
      end
    end
  end
end
