# Code coverage setup - must be at the very top
require "simplecov"
SimpleCov.start do
  add_filter "/test/"
  add_filter "/vendor/"
  add_filter "/gems/"

  add_group "Core", "lib/lyra"
  add_group "Privacy", "lib/lyra/privacy"
  add_group "Visualization", "lib/lyra/visualization"
  add_group "Controllers", "app/controllers"
  add_group "Interceptors", "lib/lyra/interceptors"
  add_group "Projections", "lib/lyra/projections"
  add_group "Schema", "lib/lyra/schema"

  track_files "{lib,app}/**/*.rb"

  enable_coverage :branch
  minimum_coverage line: 50, branch: 40
end

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
$LOAD_PATH.unshift File.expand_path("../app/controllers", __dir__)

require "minitest/autorun"
require "minitest/reporters"
require "mocha/minitest"

Minitest::Reporters.use! [
  Minitest::Reporters::SpecReporter.new,
  Minitest::Reporters::JUnitReporter.new
]

# Minimal Rails-like environment for testing
require "active_support/all"

# Load dummy Rails application for controller tests
begin
  ENV["RAILS_ENV"] = "test"
  require File.expand_path("../test/dummy/config/environment", __dir__)

  # Load the database schema
  load File.expand_path("../test/dummy/db/schema.rb", __dir__)

  # Ensure the engine is loaded
  require "lyra/engine"

  # Configure ActionController for testing
  ActionController::Base.view_paths = [File.expand_path("../app/views", __dir__)]

  # Load Lyra controllers
  require File.expand_path("../app/controllers/lyra/application_controller", __dir__)
  require File.expand_path("../app/controllers/lyra/dashboard_controller", __dir__)
  require File.expand_path("../app/controllers/lyra/flow_controller", __dir__)
  require File.expand_path("../app/controllers/lyra/privacy_controller", __dir__)

rescue LoadError => e
  # Dummy app not available - controller tests will be skipped
  puts "Warning: Could not load dummy Rails app: #{e.message}"
  puts "#{e.backtrace.first(5).join("\n")}"
  puts "Controller tests will be skipped. Run unit tests only with: rake test:unit"
rescue StandardError => e
  puts "Warning: Error setting up dummy Rails app: #{e.message}"
  puts "#{e.backtrace.first(5).join("\n")}"
  puts "Controller tests may fail. Run unit tests only with: rake test:unit"
end

# Configure Lyra after Rails is loaded
if defined?(Rails) && defined?(Lyra)
  Lyra.configure do |config|
    config.mode = :monitor
    config.event_store = RailsEventStore::Client.new(
      repository: RubyEventStore::ActiveRecord::EventRepository.new(
        serializer: RubyEventStore::Serializers::YAML
      )
    )
    # monitored_models defaults to [] in Configuration
  end
end

# Set up routes for controller tests
if defined?(ActionController::TestCase) && defined?(Lyra::Engine)
  class ActionController::TestCase
    setup do
      @routes = Lyra::Engine.routes
    end
  end
end

# Define TestModel for controller tests
if defined?(ActiveRecord::Base)
  class TestModel < ActiveRecord::Base
    self.table_name = "users"  # Use existing users table from schema
  end

  # Define User model for interceptor tests (includes CrudInterceptor)
  class User < ActiveRecord::Base
    self.table_name = "users"
    include Lyra::Interceptors::CrudInterceptor
    monitor_with_lyra
  end
end

# Every test starts from the same Lyra configuration: the one established
# above, captured once here. Lyra.config is process-global, and tests change it
# freely (modes, event stores, monitored models, reset_config!). Before this,
# whatever one test left behind reached the next: a stub model registered by
# one test broke the dashboard tests in some orders, and a reset in one test's
# teardown removed the baseline (the event store, the monitored User model) for
# every test after it. Each test now gets a fresh copy of the baseline before
# its setup runs, and the copy is replaced again after its teardown.
module LyraConfigIsolation
  class << self
    attr_accessor :baseline

    # A copy whose collections are its own, so registering a model in one test
    # cannot reach the baseline or another test.
    def fresh_config
      return Lyra::Configuration.new unless baseline

      baseline.dup.tap do |config|
        config.instance_variable_set(:@monitored_models, baseline.monitored_models.dup)
        config.instance_variable_set(:@model_configs, baseline.instance_variable_get(:@model_configs).dup)
      end
    end

    def install_fresh_config
      Lyra.instance_variable_set(:@config, fresh_config) if baseline
      # Genesis remembers which models it imported; that memory is per test too.
      Lyra::Genesis.reset! if defined?(Lyra::Genesis)
    end
  end

  def before_setup
    LyraConfigIsolation.install_fresh_config
    super
  end

  def after_teardown
    super
  ensure
    LyraConfigIsolation.install_fresh_config
  end
end

if defined?(Lyra)
  LyraConfigIsolation.baseline = Lyra.config
  Minitest::Test.prepend(LyraConfigIsolation)
end
