require "test_helper"

module Lyra
  class EventTest < Minitest::Test
    def test_event_creation_with_data
      event = Event.new(
        data: {
          model_class: "User",
          model_id: 123,
          operation: :create,
          attributes: { name: "John Doe", email: "john@example.com" },
          changes: {},
          timestamp: Time.current
        }
      )

      assert_equal "User", event.model_class
      assert_equal 123, event.model_id
      assert_equal :create, event.operation
      assert_equal "John Doe", event.attributes[:name]
      assert_equal "john@example.com", event.attributes[:email]
    end

    def test_event_with_metadata
      event = Event.new(
        data: {
          model_class: "Order",
          model_id: 456,
          operation: :create,
          attributes: { total: 100.0 },
          changes: {},
          timestamp: Time.current
        },
        metadata: { user_id: "user-123", request_id: "req-abc" }
      )

      assert_equal "user-123", event.user_id
      assert_equal "req-abc", event.request_id
    end

    def test_event_with_changes
      event = Event.new(
        data: {
          model_class: "Product",
          model_id: 789,
          operation: :update,
          attributes: { price: 29.99 },
          changes: { price: [19.99, 29.99] },
          timestamp: Time.current
        }
      )

      assert_equal :update, event.operation
      assert_equal [19.99, 29.99], event.changes[:price]
    end

    def test_event_timestamp
      now = Time.current
      event = Event.new(
        data: {
          model_class: "Post",
          model_id: 1,
          operation: :create,
          attributes: {},
          changes: {},
          timestamp: now
        }
      )

      # RailsEventStore::Event provides its own timestamp
      assert event.metadata[:timestamp] || event.data[:timestamp]
      # Test that our timestamp in data is accessible
      assert_equal now.to_i, event.data[:timestamp].to_i
    end

    def test_event_id_generation
      event = Event.new(
        data: {
          model_class: "Comment",
          model_id: 42,
          operation: :create,
          attributes: {},
          changes: {},
          timestamp: Time.current
        }
      )

      assert event.event_id
      refute_nil event.event_id
    end

    def test_event_metadata_access
      event = Event.new(
        data: {
          model_class: "Invoice",
          model_id: 100,
          operation: :create,
          attributes: {},
          changes: {},
          timestamp: Time.current
        },
        metadata: {
          user_id: "admin-1",
          request_id: "req-xyz",
          ip_address: "192.168.1.1"
        }
      )

      assert_equal "admin-1", event.metadata[:user_id]
      assert_equal "req-xyz", event.metadata[:request_id]
      assert_equal "192.168.1.1", event.metadata[:ip_address]
    end
  end
end
