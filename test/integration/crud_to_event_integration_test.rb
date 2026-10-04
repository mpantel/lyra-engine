require "test_helper"

module Lyra
  module Integration
    # Integration test for complete CRUD → Event workflow
    class CrudToEventIntegrationTest < Minitest::Test
      def setup
        # Create a test model class
        @user_class = Class.new do
          attr_accessor :id, :name, :email, :age, :created_at, :updated_at
          attr_reader :changes, :previous_changes

          def self.name
            "User"
          end

          def initialize(attrs = {})
            @id = attrs[:id]
            @name = attrs[:name]
            @email = attrs[:email]
            @age = attrs[:age]
            @created_at = attrs[:created_at] || Time.current
            @updated_at = attrs[:updated_at] || Time.current
            @changes = {}
            @previous_changes = {}
          end

          def attributes
            {
              "id" => @id,
              "name" => @name,
              "email" => @email,
              "age" => @age,
              "created_at" => @created_at,
              "updated_at" => @updated_at
            }
          end

          def update_attributes(new_attrs)
            @previous_changes = {}
            new_attrs.each do |key, new_value|
              old_value = send(key)
              if old_value != new_value
                @previous_changes[key.to_s] = [old_value, new_value]
                send("#{key}=", new_value)
              end
            end
            @updated_at = Time.current
          end
        end

        # Configure Lyra for the test model, on a configuration of its own: the
        # stub is no ActiveRecord model, and left in the global registry it was
        # picked up by later tests that list monitored models (the dashboard
        # called .pluck on it, so the suite failed only in some orders).
        @original_config = Lyra.config
        Lyra.reset_config!
        Lyra.config.event_store = @original_config.event_store
        Lyra.config.monitor_model(@user_class, event_prefix: "User")
        Lyra.config.enable_monitor!
      end

      def teardown
        Lyra.instance_variable_set(:@config, @original_config)
      end

      def test_aggregate_state_reconstruction
        # Create events in sequence
        events = []

        # Created
        events << Event.new(
          data: {
            model_class: "User",
            model_id: 100,
            operation: :created,
            attributes: { name: "Frank", email: "frank@example.com", age: 35 },
            changes: {},
            timestamp: 3.hours.ago
          }
        )

        # Updated age
        events << Event.new(
          data: {
            model_class: "User",
            model_id: 100,
            operation: :updated,
            attributes: {},
            changes: { age: [35, 36] },
            timestamp: 2.hours.ago
          }
        )

        # Updated email
        events << Event.new(
          data: {
            model_class: "User",
            model_id: 100,
            operation: :updated,
            attributes: {},
            changes: { email: ["frank@example.com", "frank.miller@example.com"] },
            timestamp: 1.hour.ago
          }
        )

        # Rebuild state using StateProjection
        projection = StateProjection.new
        final_state = projection.rebuild_from_events(events)

        # Verify final state
        assert_equal "Frank", final_state[:name]
        assert_equal "frank.miller@example.com", final_state[:email]
        assert_equal 36, final_state[:age]
      end

      def test_monitor_mode_configuration
        # Verify we're in monitor mode
        assert Lyra.config.monitor_mode?
        refute Lyra.config.hijack_mode?
        refute Lyra.config.hijack_enabled

        # Verify model is monitored
        assert_includes Lyra.config.monitored_models, @user_class

        # Get model configuration
        config = Lyra.config.model_config(@user_class)
        assert_equal "User", config.event_prefix
      end
    end
  end
end
