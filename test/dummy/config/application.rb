require_relative 'boot'

require 'rails'
require 'active_model/railtie'
require 'active_record/railtie'
require 'active_job/railtie' # Lyra's async projections run on ActiveJob
require 'action_controller/railtie'
require 'action_view/railtie'

Bundler.require(*Rails.groups)
require "lyra"

module Dummy
  class Application < Rails::Application
    config.load_defaults Rails::VERSION::STRING.to_f

    # For compatibility with applications that use this config
    config.action_controller.include_all_helpers = false

    # Disable warnings
    config.active_support.deprecation = :log
    config.eager_load = false
  end
end
