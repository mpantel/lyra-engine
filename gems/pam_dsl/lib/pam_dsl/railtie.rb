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
    # Must restrictions and objections (Arts. 18, 21) go to a durable store?
    # nil (the default): yes outside development and test, so the in-memory
    # store refuses to record there. true or false sets it for every environment.
    config.pam_dsl.require_durable_rights_store = nil

    # Make configuration available
    initializer "pam_dsl.configuration" do |app|
      PamDsl.rails_config = app.config.pam_dsl
      required = app.config.pam_dsl.require_durable_rights_store
      PamDsl.require_durable_rights_store =
        required.nil? ? !(Rails.env.development? || Rails.env.test?) : required
    end
  end
end
