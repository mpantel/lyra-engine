require_relative "boot"

require "rails/all"

# Require the gems listed in Gemfile
Bundler.require(*Rails.groups)

# Require Lyra
require "lyra"

module BlogApp
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 7.1

    # Configure RailsEventStore
    config.to_prepare do
      Rails.configuration.event_store = RailsEventStore::Client.new(
        repository: RailsEventStoreActiveRecord::EventRepository.new(serializer: YAML)
      )
    end

    # Configure eager loading for production
    config.eager_load_paths << Rails.root.join("lib")

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w(assets tasks examples))
  end
end
