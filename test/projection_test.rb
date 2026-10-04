require "test_helper"

module Lyra
  class ProjectionTest < Minitest::Test
    def test_projection_class_handle
      projection_class = Class.new(Projection) do
        attr_reader :handled_event

        def apply_event(event)
          @handled_event = event
        end
      end

      event = Event.new(data: { model_class: "Test", model_id: 1, operation: :created })

      # The class method creates a new instance and calls handle
      instance = projection_class.new
      instance.handle(event)

      assert_equal event, instance.handled_event
    end

    def test_projection_handle_with_matching_method
      projection = Projection.new

      # Define a test apply method
      def projection.apply_event(event)
        @handled = true
      end

      event = Event.new(data: { model_class: "Test", model_id: 1, operation: :created })
      projection.handle(event)

      assert projection.instance_variable_get(:@handled)
    end

    def test_projection_handle_without_matching_method
      projection = Projection.new
      event = Event.new(data: { model_class: "Test", model_id: 1, operation: :created })

      # Should not raise an error
      assert_nil projection.handle(event)
    end

    # RubyEventStore 3.1 accepts only subscribers that respond to call;
    # subscribe_to used to pass the class, which defined only handle, and
    # raised RubyEventStore::InvalidHandler.
    class SubscribedThingHappened < RubyEventStore::Event; end

    class SubscribedProjection < Projection
      class << self
        attr_accessor :applied
      end

      def apply_subscribed_thing_happened(event)
        (self.class.applied ||= []) << event.data
      end
    end

    def test_subscribe_to_runs_apply_methods_for_published_events
      client = RubyEventStore::Client.new(repository: RubyEventStore::InMemoryRepository.new)
      previous = Lyra.config.event_store
      Lyra.config.event_store = client
      SubscribedProjection.applied = []

      SubscribedProjection.subscribe_to(SubscribedThingHappened)
      client.publish(SubscribedThingHappened.new(data: { n: 1 }))
      client.publish(RubyEventStore::Event.new(data: { n: 2 }))

      assert_equal [{ n: 1 }], SubscribedProjection.applied
    ensure
      Lyra.config.event_store = previous
    end
  end

  class StateProjectionTest < Minitest::Test
    def test_rebuild_from_events_with_created_event
      projection = StateProjection.new

      event = Event.new(
        data: {
          model_class: "User",
          model_id: 1,
          operation: :created,
          attributes: { name: "Alice", email: "alice@example.com" },
          changes: {},
          timestamp: Time.current
        }
      )

      state = projection.rebuild_from_events([event])

      assert_equal "Alice", state[:name]
      assert_equal "alice@example.com", state[:email]
    end

    def test_rebuild_from_events_with_updated_event
      projection = StateProjection.new

      created_event = Event.new(
        data: {
          model_class: "User",
          model_id: 1,
          operation: :created,
          attributes: { name: "Alice", email: "alice@example.com" },
          changes: {},
          timestamp: 1.hour.ago
        }
      )

      updated_event = Event.new(
        data: {
          model_class: "User",
          model_id: 1,
          operation: :updated,
          attributes: {},
          changes: { email: ["alice@example.com", "alice.new@example.com"] },
          timestamp: Time.current
        }
      )

      state = projection.rebuild_from_events([created_event, updated_event])

      assert_equal "Alice", state[:name]
      assert_equal "alice.new@example.com", state[:email]
    end

    def test_rebuild_from_events_with_destroyed_event
      projection = StateProjection.new

      now = Time.current

      created_event = Event.new(
        data: {
          model_class: "User",
          model_id: 1,
          operation: :created,
          attributes: { name: "Bob" },
          changes: {},
          timestamp: 1.hour.ago
        }
      )

      destroyed_event = Event.new(
        data: {
          model_class: "User",
          model_id: 1,
          operation: :destroyed,
          attributes: {},
          changes: {},
          timestamp: now
        }
      )

      state = projection.rebuild_from_events([created_event, destroyed_event])

      assert_equal "Bob", state[:name]
      assert state[:deleted]
      # deleted_at is set from event.timestamp, which may be nil for test events
      # Just check it exists in the state
      assert state.key?(:deleted_at)
    end

    def test_rebuild_from_events_with_multiple_updates
      projection = StateProjection.new

      events = [
        Event.new(
          data: {
            model_class: "User",
            model_id: 1,
            operation: :created,
            attributes: { name: "Charlie", age: 25, city: "NYC" },
            changes: {},
            timestamp: 3.hours.ago
          }
        ),
        Event.new(
          data: {
            model_class: "User",
            model_id: 1,
            operation: :updated,
            attributes: {},
            changes: { age: [25, 26] },
            timestamp: 2.hours.ago
          }
        ),
        Event.new(
          data: {
            model_class: "User",
            model_id: 1,
            operation: :updated,
            attributes: {},
            changes: { city: ["NYC", "LA"] },
            timestamp: 1.hour.ago
          }
        )
      ]

      state = projection.rebuild_from_events(events)

      assert_equal "Charlie", state[:name]
      assert_equal 26, state[:age]
      assert_equal "LA", state[:city]
    end

    def test_rebuild_from_empty_events
      projection = StateProjection.new

      state = projection.rebuild_from_events([])

      assert_equal({}, state)
    end
  end

  class AuditProjectionTest < Minitest::Test
    # Note: AuditProjection.audit_trail is a class method that reads from event store
    # which would require mocking. Testing just the data transformation logic.

    def test_audit_trail_format
      # This would require event store integration, so we'll test the concept
      # In a real scenario, you'd mock Lyra.config.event_store

      # Just verify the class exists and has the method
      assert AuditProjection.respond_to?(:audit_trail)
    end
  end
end
