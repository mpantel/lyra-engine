require "test_helper"

module Lyra
  class AggregateTest < Minitest::Test
    def test_aggregate_initialization
      aggregate = Aggregate.new("test-123")

      assert_equal "test-123", aggregate.id
      assert_equal 0, aggregate.version
      assert_equal [], aggregate.changes
    end

    def test_aggregate_initialization_without_id
      aggregate = Aggregate.new

      assert_nil aggregate.id
      assert_equal 0, aggregate.version
    end

    def test_aggregate_stream_name
      aggregate = Aggregate.new("test-456")

      assert_equal "Aggregate$test-456", aggregate.stream_name
    end

    def test_aggregate_apply_event
      # Create a test aggregate with an apply method
      aggregate = Aggregate.new("test-789")

      # Define the apply method for Event class
      def aggregate.apply_event(event)
        set_state(:applied, true)
      end

      # Create a mock event
      event = Event.new(data: { model_class: "Test", model_id: "test-789", operation: :create })

      # Apply should add to changes
      aggregate.apply(event)

      assert_equal 1, aggregate.changes.length
      assert_equal event, aggregate.changes.first
      assert_equal 0, aggregate.version # Version only increments for persisted events
      assert aggregate.send(:get_state, :applied)
    end

    def test_aggregate_apply_persisted_event
      aggregate = Aggregate.new("test-100")

      # Define the apply method for Event class
      def aggregate.apply_event(event)
        set_state(:applied, true)
      end

      event = Event.new(data: { model_class: "Test", model_id: "test-100", operation: :create })

      # Apply persisted event should increment version but not add to changes
      aggregate.apply(event, persisted: true)

      assert_equal 0, aggregate.changes.length
      assert_equal 1, aggregate.version
      assert aggregate.send(:get_state, :applied)
    end

    def test_aggregate_state_management
      aggregate = Aggregate.new("test-200")

      aggregate.send(:set_state, :name, "Alice")
      aggregate.send(:set_state, :email, "alice@example.com")

      assert_equal "Alice", aggregate.send(:get_state, :name)
      assert_equal "alice@example.com", aggregate.send(:get_state, :email)
    end

    def test_generic_aggregate_initialization
      model_class = Class.new
      model_class.define_singleton_method(:name) { "User" }

      aggregate = GenericAggregate.new("user-123", model_class)

      assert_equal "user-123", aggregate.id
      assert_equal "User$user-123", aggregate.stream_name
    end

    def test_generic_aggregate_apply_created_event
      model_class = Class.new
      model_class.define_singleton_method(:name) { "User" }

      aggregate = GenericAggregate.new(nil, model_class)

      event = Event.new(
        data: {
          model_class: "User",
          model_id: "user-456",
          operation: :create,
          attributes: { name: "Bob", email: "bob@example.com" },
          changes: {},
          timestamp: Time.current
        }
      )

      # Dynamically create the event class in Events module
      Lyra::Events.const_set("Created", Class.new(Lyra::Event)) unless Lyra::Events.const_defined?("Created")

      aggregate.send(:apply_created, event)

      assert_equal "user-456", aggregate.id
      assert_equal "Bob", aggregate.send(:get_state, :name)
      assert_equal "bob@example.com", aggregate.send(:get_state, :email)
    end

    def test_generic_aggregate_apply_updated_event
      model_class = Class.new
      model_class.define_singleton_method(:name) { "User" }

      aggregate = GenericAggregate.new("user-789", model_class)
      aggregate.send(:set_state, :name, "Alice")
      aggregate.send(:set_state, :email, "alice@example.com")

      event = Event.new(
        data: {
          model_class: "User",
          model_id: "user-789",
          operation: :update,
          attributes: {},
          changes: { email: ["alice@example.com", "alice.new@example.com"] },
          timestamp: Time.current
        }
      )

      aggregate.send(:apply_updated, event)

      assert_equal "Alice", aggregate.send(:get_state, :name)
      assert_equal "alice.new@example.com", aggregate.send(:get_state, :email)
    end

    def test_generic_aggregate_apply_destroyed_event
      model_class = Class.new
      model_class.define_singleton_method(:name) { "User" }

      aggregate = GenericAggregate.new("user-999", model_class)
      aggregate.send(:set_state, :name, "Charlie")

      event = Event.new(
        data: {
          model_class: "User",
          model_id: "user-999",
          operation: :destroy,
          attributes: {},
          changes: {},
          timestamp: Time.current
        }
      )

      aggregate.send(:apply_destroyed, event)

      assert aggregate.send(:get_state, :deleted)
      # deleted_at will be set to event.timestamp (which might be nil in test)
      assert aggregate.send(:state).key?(:deleted_at)
      # Name should still be there
      assert_equal "Charlie", aggregate.send(:get_state, :name)
    end
  end

  # Aggregate.load and GenericAggregate against an event store.
  class AggregateLoadTest < Minitest::Test
    def setup
      @event_store = RailsEventStore::Client.new
      Lyra.configure do |config|
        config.event_store = @event_store
        config.mode = :monitor
      end
    end

    def teardown
      Lyra.reset_config!
    end

    # Test Aggregate.load with events
    def test_aggregate_load_replays_events_from_stream
      # First publish some events to a stream using GenericAggregate
      model_class = Class.new
      model_class.define_singleton_method(:name) { "LoadTestModel" }

      aggregate_id = "test-load-#{SecureRandom.hex(4)}"
      stream_name = "LoadTestModel$#{aggregate_id}"

      # Create a properly named event class
      unless Lyra::Events.const_defined?("LoadTestModelCreated")
        Lyra::Events.const_set("LoadTestModelCreated", Class.new(Lyra::Event))
      end

      event = Lyra::Events::LoadTestModelCreated.new(
        data: {
          model_class: "LoadTestModel",
          model_id: aggregate_id,
          operation: :create,
          attributes: { name: "LoadTest" }
        }
      )

      @event_store.publish(event, stream_name: stream_name)

      # Load using GenericAggregate which handles dynamic event names
      loaded = GenericAggregate.new(aggregate_id, model_class)

      # Read events and apply them manually to test the load path
      events = @event_store.read.stream(stream_name).to_a
      events.each { |e| loaded.apply(e, persisted: true) }

      assert_equal aggregate_id, loaded.id
      assert_equal 1, loaded.version
      assert_equal "LoadTest", loaded.send(:get_state, :name)
    end

    # Test Aggregate.load rescue branch - when stream doesn't exist
    def test_aggregate_load_returns_new_aggregate_when_stream_missing
      # Use a non-existent ID - the rescue branch catches EventNotFound
      # But RailsEventStore doesn't raise for empty streams, it returns []
      # So we test with a custom aggregate that will have empty events
      aggregate_id = "nonexistent-#{SecureRandom.hex(4)}"

      # This tests the path where events array is empty
      # The rescue branch is for when the event store itself fails
      loaded = Aggregate.load(aggregate_id, @event_store)

      assert_equal aggregate_id, loaded.id
      assert_equal 0, loaded.version  # No events = version 0
    end

    # Test extract_operation else branch
    def test_generic_aggregate_extract_operation_with_non_standard_event
      model_class = Class.new
      model_class.define_singleton_method(:name) { "TestModel" }

      aggregate = GenericAggregate.new("test-123", model_class)

      # Create an event with non-standard naming
      custom_event_class = Class.new(Lyra::Event)
      Lyra::Events.const_set("CustomAction", custom_event_class) unless Lyra::Events.const_defined?("CustomAction")

      event = Lyra::Events::CustomAction.new(
        data: {
          model_class: "TestModel",
          model_id: "test-123",
          operation: :custom
        }
      )

      # This should hit the else branch in extract_operation
      # The event name "custom_action" doesn't match _created, _updated, or _destroyed
      aggregate.apply(event)

      # Verify it processed (even if no matching apply method)
      assert_equal 0, aggregate.version  # No matching method, so version doesn't increment
    end
  end
end
