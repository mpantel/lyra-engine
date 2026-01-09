# frozen_string_literal: true

require "test_helper"
require "tmpdir"

module Lyra
  module Schema
    class EventClassRegistrarTest < Minitest::Test
      def setup
        Lyra.reset_config!
        @temp_path = Dir.mktmpdir("lyra_schemas_test")
        Store.schema_path = @temp_path

        # Clean up any previously registered event classes
        cleanup_event_classes

        # Create a mock model class
        @mock_model = Class.new do
          def self.name
            "TestUser"
          end

          def self.table_name
            "test_users"
          end

          def self.primary_key
            "id"
          end

          def self.column_names
            %w[id email]
          end

          def self.columns
            [
              OpenStruct.new(name: "id", type: :integer, null: false, limit: nil, default: nil),
              OpenStruct.new(name: "email", type: :string, null: false, limit: 255, default: nil)
            ]
          end
        end
      end

      def teardown
        FileUtils.rm_rf(@temp_path)
        Store.reset_path!
        Lyra.reset_config!
        cleanup_event_classes
      end

      def test_registers_events_from_monitored_models
        Lyra.config.monitor_model(@mock_model, event_prefix: "TestUser")

        EventClassRegistrar.register_all

        assert Lyra::Events.const_defined?("TestUserCreated", false)
        assert Lyra::Events.const_defined?("TestUserUpdated", false)
        assert Lyra::Events.const_defined?("TestUserDestroyed", false)
      end

      def test_registered_events_are_subclasses_of_lyra_event
        Lyra.config.monitor_model(@mock_model, event_prefix: "TestUser")

        EventClassRegistrar.register_all

        assert Lyra::Events::TestUserCreated < Lyra::Event
        assert Lyra::Events::TestUserUpdated < Lyra::Event
        assert Lyra::Events::TestUserDestroyed < Lyra::Event
      end

      def test_registers_events_from_stored_schema
        # Create a schema with events for a model not currently monitored
        schema = {
          version: 1,
          models: {
            "LegacyModel" => {
              events: {
                "LegacyModelCreated" => { operation: "created" },
                "LegacyModelUpdated" => { operation: "updated" },
                "LegacyModelDestroyed" => { operation: "destroyed" }
              }
            }
          }
        }
        Store.save(schema)

        EventClassRegistrar.register_all

        assert Lyra::Events.const_defined?("LegacyModelCreated", false)
        assert Lyra::Events.const_defined?("LegacyModelUpdated", false)
        assert Lyra::Events.const_defined?("LegacyModelDestroyed", false)
      end

      def test_does_not_overwrite_existing_event_classes
        # Pre-define an event class with custom behavior
        custom_class = Class.new(Lyra::Event) do
          def custom_method
            "custom"
          end
        end
        Lyra::Events.const_set("TestUserCreated", custom_class)

        Lyra.config.monitor_model(@mock_model, event_prefix: "TestUser")

        EventClassRegistrar.register_all

        # Verify the original class wasn't overwritten
        assert Lyra::Events::TestUserCreated.instance_methods.include?(:custom_method)
      end

      def test_handles_missing_schema_gracefully
        # No schema exists, no monitored models
        # Should not raise any errors
        initial_count = EventClassRegistrar.registered_events.size

        EventClassRegistrar.register_all

        # No new events should be registered
        assert_equal initial_count, EventClassRegistrar.registered_events.size
      end

      def test_registered_events_returns_list_of_event_names
        Lyra.config.monitor_model(@mock_model, event_prefix: "TestUser")

        EventClassRegistrar.register_all

        events = EventClassRegistrar.registered_events
        assert_includes events, "TestUserCreated"
        assert_includes events, "TestUserUpdated"
        assert_includes events, "TestUserDestroyed"
      end

      def test_combines_events_from_config_and_schema
        # Monitor one model via config
        Lyra.config.monitor_model(@mock_model, event_prefix: "TestUser")

        # Store schema with another model
        schema = {
          version: 1,
          models: {
            "OtherModel" => {
              events: {
                "OtherModelCreated" => { operation: "created" }
              }
            }
          }
        }
        Store.save(schema)

        EventClassRegistrar.register_all

        # Both should be registered
        assert Lyra::Events.const_defined?("TestUserCreated", false)
        assert Lyra::Events.const_defined?("OtherModelCreated", false)
      end

      # Tests for namespaced model support (fixed bug for Rails Engine models)
      def test_registers_namespaced_model_events_with_sanitized_names
        # Create a namespaced model class (simulating Rails Engine pattern)
        namespaced_model = Class.new do
          def self.name
            "MyEngine::Order"
          end

          def self.table_name
            "my_engine_orders"
          end

          def self.primary_key
            "id"
          end

          def self.column_names
            %w[id number total]
          end

          def self.columns
            [
              OpenStruct.new(name: "id", type: :integer, null: false, limit: nil, default: nil),
              OpenStruct.new(name: "number", type: :string, null: false, limit: nil, default: nil),
              OpenStruct.new(name: "total", type: :decimal, null: false, limit: nil, default: nil)
            ]
          end
        end

        Lyra.config.monitor_model(namespaced_model, event_prefix: "MyEngine::Order")

        EventClassRegistrar.register_all

        # Event class names should have :: removed (MyEngine::OrderCreated -> MyEngineOrderCreated)
        assert Lyra::Events.const_defined?("MyEngineOrderCreated", false),
               "Should create MyEngineOrderCreated (sanitized from MyEngine::OrderCreated)"
        assert Lyra::Events.const_defined?("MyEngineOrderUpdated", false),
               "Should create MyEngineOrderUpdated (sanitized from MyEngine::OrderUpdated)"
        assert Lyra::Events.const_defined?("MyEngineOrderDestroyed", false),
               "Should create MyEngineOrderDestroyed (sanitized from MyEngine::OrderDestroyed)"

        # Verify they don't try to create invalid constants with ::
        refute Lyra::Events.const_defined?("MyEngine::OrderCreated", false),
               "Should not create constant with :: in name (invalid Ruby)"
      end

      def test_namespaced_events_from_stored_schema
        # Create a schema with namespaced model events
        schema = {
          version: 1,
          models: {
            "MyEngine::Payment" => {
              events: {
                "MyEngine::PaymentCreated" => { operation: "created" },
                "MyEngine::PaymentUpdated" => { operation: "updated" }
              }
            }
          }
        }
        Store.save(schema)

        EventClassRegistrar.register_all

        # Should sanitize :: from event names
        assert Lyra::Events.const_defined?("MyEnginePaymentCreated", false),
               "Should sanitize MyEngine::PaymentCreated to MyEnginePaymentCreated"
        assert Lyra::Events.const_defined?("MyEnginePaymentUpdated", false),
               "Should sanitize MyEngine::PaymentUpdated to MyEnginePaymentUpdated"
      end

      def test_deeply_namespaced_model_events
        # Test with deeply nested namespace (e.g., MyEngine::Admin::Widget)
        schema = {
          version: 1,
          models: {
            "MyEngine::Admin::Widget" => {
              events: {
                "MyEngine::Admin::WidgetCreated" => { operation: "created" }
              }
            }
          }
        }
        Store.save(schema)

        EventClassRegistrar.register_all

        # Multiple :: should be removed
        assert Lyra::Events.const_defined?("MyEngineAdminWidgetCreated", false),
               "Should sanitize multiple :: from MyEngine::Admin::WidgetCreated"
      end

      private

      def cleanup_event_classes
        # Remove test event classes to avoid polluting other tests
        %w[
          TestUserCreated TestUserUpdated TestUserDestroyed
          LegacyModelCreated LegacyModelUpdated LegacyModelDestroyed
          OtherModelCreated
          MyEngineOrderCreated MyEngineOrderUpdated MyEngineOrderDestroyed
          MyEnginePaymentCreated MyEnginePaymentUpdated
          MyEngineAdminWidgetCreated
        ].each do |const|
          Lyra::Events.send(:remove_const, const) if Lyra::Events.const_defined?(const, false)
        end
      end
    end
  end
end
