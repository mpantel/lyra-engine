# frozen_string_literal: true

require "rails/railtie"

module PamDsl
  class Railtie < Rails::Railtie
    railtie_name :pam_dsl

    # Load rake tasks
    rake_tasks do
      load File.expand_path("tasks/privacy.rake", __dir__)
    end

    # Configuration for Rails apps
    config.pam_dsl = ActiveSupport::OrderedOptions.new
    config.pam_dsl.default_policy = nil
    config.pam_dsl.organization = "Organization Name"
    config.pam_dsl.dpo_contact = "dpo@example.com"

    # Make configuration available
    initializer "pam_dsl.configuration" do |app|
      PamDsl.rails_config = app.config.pam_dsl
    end
  end
end
