require_relative "boot"

require "rails"
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "action_controller/railtie"
require "action_view/railtie"
require "rails/test_unit/railtie"

# Require the gems listed in Gemfile (Lyra among them).
Bundler.require(*Rails.groups)

module BlogApp
  class Application < Rails::Application
    config.load_defaults 8.1
    config.autoload_lib(ignore: %w[assets tasks])

    # Models only: no views, assets or sessions.
    config.api_only = true
    config.time_zone = "UTC"
  end
end
