require "test_helper"

module Lyra
  # Test classes defined at module level
  class TestUser
    def self.name
      "User"
    end
  end

  class TestPost
    def self.name
      "Post"
    end
  end

  class TestComment
    def self.name
      "Comment"
    end
  end

  class TestOrder
    def self.name
      "Order"
    end
  end

  class TestInventory
    def self.name
      "Inventory"
    end
  end

  # Simulates a Rails Engine namespaced model (e.g., MyEngine::Order)
  class NamespacedOrder
    def self.name
      "MyEngine::Order"
    end
  end

  class EventMapperTest < Minitest::Test
    def setup
      Lyra.config.monitor_model(TestUser)
      Lyra.config.monitor_model(TestPost)
      Lyra.config.monitor_model(TestComment)
    end

    def test_map_create_operation
      data = {
        id: 123,
        attributes: { name: "Alice", email: "alice@example.com" },
        changes: {},
        user_id: "user-1",
        request_id: "req-abc"
      }

      event = EventMapper.map_operation(TestUser, :create, data)

      assert_equal "User", event.model_class
      assert_equal 123, event.model_id
      assert_equal :create, event.operation
      assert_equal "Alice", event.attributes[:name]
      assert_equal "alice@example.com", event.attributes[:email]
    end

    def test_map_update_operation
      data = {
        id: 456,
        attributes: { title: "New Title" },
        changes: { title: ["Old Title", "New Title"] },
        user_id: "user-2",
        request_id: "req-def"
      }

      event = EventMapper.map_operation(TestPost, :update, data)

      assert_equal "Post", event.model_class
      assert_equal 456, event.model_id
      assert_equal :update, event.operation
      assert_equal ["Old Title", "New Title"], event.changes[:title]
    end

    def test_map_destroy_operation
      data = {
        id: 789,
        attributes: {},
        changes: {},
        user_id: "user-3",
        request_id: "req-ghi"
      }

      event = EventMapper.map_operation(TestComment, :destroy, data)

      assert_equal "Comment", event.model_class
      assert_equal 789, event.model_id
      assert_equal :destroy, event.operation
    end

    def test_event_with_metadata
      data = {
        id: 1,
        attributes: { name: "Product A" },
        changes: {},
        user_id: "admin-1",
        request_id: "req-xyz"
      }

      event = EventMapper.map_operation(TestUser, :create, data)

      assert_equal "admin-1", event.metadata[:user_id]
      assert_equal "req-xyz", event.metadata[:request_id]
      assert_equal "lyra_interceptor", event.metadata[:source]
    end

    def test_event_includes_correlation_id_when_set
      data = {
        id: 1,
        attributes: { name: "Alice" },
        changes: {}
      }

      event = nil
      Lyra::Correlation.with_id("corr-test-123") do
        event = EventMapper.map_operation(TestUser, :create, data)
      end

      assert_equal "corr-test-123", event.metadata[:correlation_id]
    end

    def test_event_includes_causation_id_when_set
      data = {
        id: 1,
        attributes: { name: "Alice" },
        changes: {}
      }

      event = nil
      Lyra::Causation.with_id("cause-event-456") do
        event = EventMapper.map_operation(TestUser, :create, data)
      end

      assert_equal "cause-event-456", event.metadata[:causation_id]
    end

    def test_event_includes_both_correlation_and_causation_ids
      data = {
        id: 1,
        attributes: { name: "Alice" },
        changes: {}
      }

      event = nil
      Lyra::Correlation.with_id("corr-multi-789") do
        Lyra::Causation.with_id("cause-event-abc") do
          event = EventMapper.map_operation(TestUser, :create, data)
        end
      end

      assert_equal "corr-multi-789", event.metadata[:correlation_id]
      assert_equal "cause-event-abc", event.metadata[:causation_id]
    end

    def test_event_has_nil_correlation_and_causation_when_not_set
      # Ensure clean thread state
      Thread.current[:lyra_correlation_id] = nil
      Thread.current[:lyra_causation_id] = nil

      data = {
        id: 1,
        attributes: { name: "Alice" },
        changes: {}
      }

      event = EventMapper.map_operation(TestUser, :create, data)

      assert_nil event.metadata[:correlation_id]
      assert_nil event.metadata[:causation_id]
    end

    def test_custom_event_prefix
      Lyra.config.monitor_model(TestOrder, event_prefix: "OrderEvent")

      data = { id: 100, attributes: {}, changes: {} }
      event = EventMapper.map_operation(TestOrder, :create, data)

      assert_equal "Order", event.model_class
      assert_equal 100, event.model_id
    end

    def test_dynamic_event_class_creation
      Lyra.config.monitor_model(TestInventory)

      data = { id: 500, attributes: { quantity: 10 }, changes: {} }
      event = EventMapper.map_operation(TestInventory, :create, data)

      assert event.is_a?(Lyra::Event)
      assert_equal "Inventory", event.model_class
      assert_equal 10, event.attributes[:quantity]
    end

    # Tests for namespaced model support (fixed bug for Rails Engine models)
    # Note: Operation names use past tense (:created, :updated, :destroyed) to match
    # the event naming convention (e.g., MyEngineOrderCreated)
    def test_namespaced_model_creates_sanitized_event_class
      Lyra.config.monitor_model(NamespacedOrder, event_prefix: "MyEngine::Order")

      data = { id: 100, attributes: { number: "R123456", total: 99.99 }, changes: {} }
      event = EventMapper.map_operation(NamespacedOrder, :created, data)

      # Event should be created successfully without raising NameError
      assert event.is_a?(Lyra::Event)
      assert_equal "MyEngine::Order", event.model_class
      assert_equal "R123456", event.attributes[:number]

      # Event class should be created with sanitized name (no ::)
      assert Lyra::Events.const_defined?("MyEngineOrderCreated", false),
             "Should create MyEngineOrderCreated (sanitized from MyEngine::OrderCreated)"
    end

    def test_namespaced_model_update_operation
      Lyra.config.monitor_model(NamespacedOrder, event_prefix: "MyEngine::Order")

      data = {
        id: 200,
        attributes: { total: 150.00 },
        changes: { total: [100.00, 150.00] }
      }
      event = EventMapper.map_operation(NamespacedOrder, :updated, data)

      assert event.is_a?(Lyra::Event)
      assert_equal :updated, event.operation
      assert Lyra::Events.const_defined?("MyEngineOrderUpdated", false),
             "Should create MyEngineOrderUpdated for update operation"
    end

    def test_namespaced_model_destroy_operation
      Lyra.config.monitor_model(NamespacedOrder, event_prefix: "MyEngine::Order")

      data = { id: 300, attributes: {}, changes: {} }
      event = EventMapper.map_operation(NamespacedOrder, :destroyed, data)

      assert event.is_a?(Lyra::Event)
      assert_equal :destroyed, event.operation
      assert Lyra::Events.const_defined?("MyEngineOrderDestroyed", false),
             "Should create MyEngineOrderDestroyed for destroy operation"
    end
  end
end
