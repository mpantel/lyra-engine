# Test helper for Blog App Lyra integration tests
require 'minitest/autorun'
require 'minitest/reporters'
require 'active_record'
require 'rails_event_store'
require 'rails_event_store_active_record'

# Load Lyra core components (avoiding engine/controllers)
$LOAD_PATH.unshift File.expand_path("../../../lib", __dir__)

# Define Lyra module structure
module Lyra
  class Error < StandardError; end
end

require 'lyra/version'
require 'lyra/configuration'
require 'lyra/correlation'
require 'lyra/event'
require 'lyra/event_store_adapter'
require 'lyra/event_mapper'
require 'lyra/interceptors/crud_interceptor'

# Add configuration helpers to Lyra module
module Lyra
  def self.configure
    yield config if block_given?
  end

  def self.monitor_mode?
    config.monitor_mode?
  end

  def self.hijack_mode?
    config.hijack_mode?
  end
end

# Use pretty output
Minitest::Reporters.use! [Minitest::Reporters::SpecReporter.new]

# Stub Rails module for standalone testing
module Rails
  def self.logger
    @logger ||= Logger.new(nil)  # Null logger for tests
  end

  def self.env
    ActiveSupport::StringInquirer.new("test")
  end
end

# Setup in-memory database for tests
ActiveRecord::Base.establish_connection(
  adapter: 'sqlite3',
  database: ':memory:'
)

# Define ApplicationRecord for models
class ApplicationRecord < ActiveRecord::Base
  self.abstract_class = true
end

# Include Lyra interceptor module into ActiveRecord
ActiveRecord::Base.include Lyra::Interceptors::CrudInterceptor

# Load schema
ActiveRecord::Schema.define do
  create_table :event_store_events, force: true do |t|
    t.string :event_id, null: false, limit: 36
    t.string :event_type, null: false
    t.binary :metadata
    t.binary :data, null: false
    t.datetime :created_at, null: false
  end
  add_index :event_store_events, :event_id, unique: true

  create_table :event_store_events_in_streams, force: true do |t|
    t.string :stream, null: false
    t.integer :position
    t.string :event_id, null: false, limit: 36
    t.datetime :created_at, null: false
  end
  add_index :event_store_events_in_streams, [:stream, :position], unique: true
  add_index :event_store_events_in_streams, [:stream, :event_id], unique: true

  create_table :users, force: true do |t|
    t.string :email, null: false
    t.string :name, null: false
    t.text :bio
    t.integer :age
    t.datetime :deleted_at
    t.timestamps
  end
  add_index :users, :email, unique: true

  create_table :posts, force: true do |t|
    t.references :user, null: false, foreign_key: true
    t.string :title, null: false
    t.text :body, null: false
    t.string :status, default: 'draft'
    t.integer :view_count, default: 0
    t.datetime :published_at
    t.timestamps
  end
  add_index :posts, :status

  create_table :comments, force: true do |t|
    t.references :user, null: false, foreign_key: true
    t.references :post, null: false, foreign_key: true
    t.text :body, null: false
    t.timestamps
  end
  add_index :comments, :created_at
end

# Setup Event Store with proper serializer
EVENT_STORE = RailsEventStore::Client.new(
  repository: RailsEventStoreActiveRecord::EventRepository.new(
    serializer: RubyEventStore::Serializers::YAML
  )
)

# Configure Lyra
Lyra.configure do |config|
  config.event_store = EVENT_STORE
  config.mode = :monitor
end

# Load models
require_relative '../app/models/user'
require_relative '../app/models/post'
require_relative '../app/models/comment'

# Base test class with helpful assertions
class Minitest::Test
  def setup
    # Clean database before each test
    User.delete_all
    Post.delete_all
    Comment.delete_all

    # Clear event store
    ActiveRecord::Base.connection.execute("DELETE FROM event_store_events")
    ActiveRecord::Base.connection.execute("DELETE FROM event_store_events_in_streams")
  end

  # Helper to get all events for a model
  def events_for(model_class, model_id)
    stream_name = "#{model_class.name}$#{model_id}"
    Lyra.config.event_store.read.stream(stream_name).to_a
  end

  # Helper to get event count
  def event_count
    Lyra.config.event_store.read.count
  end

  # Helper to assert event was published
  def assert_event_published(event_type, count: 1)
    events = Lyra.config.event_store.read.of_type(event_type).to_a
    assert_equal count, events.size, "Expected #{count} #{event_type} event(s), got #{events.size}"
  end

  # Helper to get last published event
  def last_event
    Lyra.config.event_store.read.limit(1).to_a.first
  end
end
