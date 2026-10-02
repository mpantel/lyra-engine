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

      def test_complete_create_workflow
        # Simulate CRUD create operation
        user = @user_class.new(
          id: 1,
          name: "Alice Smith",
          email: "alice@example.com",
          age: 30
        )

        # Map to event
        event_data = {
          id: user.id,
          attributes: {
            name: user.name,
            email: user.email,
            age: user.age
          },
          changes: {},
          user_id: "admin-123",
          request_id: "req-001"
        }

        event = EventMapper.map_operation(@user_class, :create, event_data)

        # Verify event structure
        assert_equal "User", event.model_class
        assert_equal 1, event.model_id
        assert_equal :create, event.operation
        assert_equal "Alice Smith", event.attributes[:name]
        assert_equal "alice@example.com", event.attributes[:email]
        assert_equal 30, event.attributes[:age]

        # Verify metadata
        assert_equal "admin-123", event.metadata[:user_id]
        assert_equal "req-001", event.metadata[:request_id]
        assert_equal "lyra_interceptor", event.metadata[:source]

        # Verify PII detection (only when PAM DSL available)
        if PAM_DSL_AVAILABLE
          pii_fields = Lyra::Privacy::PIIDetector.detect(event.attributes)
          assert pii_fields.key?(:email)
          assert pii_fields.key?(:name)
          refute pii_fields.key?(:age)
        end
      end

      def test_complete_update_workflow
        # Create initial user
        user = @user_class.new(
          id: 2,
          name: "Bob Jones",
          email: "bob@example.com",
          age: 25
        )

        # Simulate update
        user.update_attributes(email: "bob.jones@example.com", age: 26)

        # Map to event
        event_data = {
          id: user.id,
          attributes: user.attributes,
          changes: user.previous_changes,
          user_id: "user-456",
          request_id: "req-002"
        }

        event = EventMapper.map_operation(@user_class, :update, event_data)

        # Verify event
        assert_equal "User", event.model_class
        assert_equal 2, event.model_id
        assert_equal :update, event.operation

        # Verify changes
        assert_equal ["bob@example.com", "bob.jones@example.com"], event.changes["email"]
        assert_equal [25, 26], event.changes["age"]

        # Verify PII in changes (only when PAM DSL available)
        if PAM_DSL_AVAILABLE
          pii_changes = {}
          event.changes.each do |key, value|
            if Lyra::Privacy::PIIDetector.contains_pii?(key)
              pii_changes[key] = value
            end
          end
          assert pii_changes.key?("email")
          refute pii_changes.key?("age")
        end
      end

      def test_complete_destroy_workflow
        # Create user to destroy
        user = @user_class.new(
          id: 3,
          name: "Charlie Brown",
          email: "charlie@example.com"
        )

        # Map destroy to event
        event_data = {
          id: user.id,
          attributes: user.attributes,
          changes: {},
          user_id: "admin-789",
          request_id: "req-003"
        }

        event = EventMapper.map_operation(@user_class, :destroy, event_data)

        # Verify event
        assert_equal "User", event.model_class
        assert_equal 3, event.model_id
        assert_equal :destroy, event.operation
      end

      def test_correlation_workflow
        # Start a correlated user action
        correlation_id = Lyra::Correlation.generate_id

        Lyra::Correlation.with_id(correlation_id) do
          # Create first event
          event1_data = {
            id: 10,
            attributes: { name: "Diana", email: "diana@example.com" },
            changes: {},
            user_id: "user-100"
          }
          event1 = EventMapper.map_operation(@user_class, :create, event1_data)

          # Create second event in same correlation
          event2_data = {
            id: 10,
            attributes: { name: "Diana Prince", email: "diana@example.com" },
            changes: { name: ["Diana", "Diana Prince"] },
            user_id: "user-100"
          }
          event2 = EventMapper.map_operation(@user_class, :update, event2_data)

          # Verify correlation
          assert_equal Lyra::Correlation.current_id, correlation_id

          # Track causation (event1 caused event2)
          Lyra::Causation.track(event1.event_id, event2.event_id)
          chain = Lyra::Causation.chain_for(event2.event_id)

          assert_includes chain, event1.event_id
          assert_includes chain, event2.event_id
        end

        # Correlation should be cleared after block
        assert_nil Lyra::Correlation.current_id
      end

      def test_causation_id_in_event_metadata
        # Simulate an event handler processing event1 and creating event2
        # event2's causation_id should point to event1

        # Create the "cause" event
        event1_data = {
          id: 50,
          attributes: { name: "Root Event" },
          changes: {},
          user_id: "system"
        }
        event1 = EventMapper.map_operation(@user_class, :create, event1_data)

        # Now simulate an event handler processing event1 and creating event2
        # The handler sets causation_id to event1's id
        event2 = nil
        Lyra::Causation.with_id(event1.event_id) do
          event2_data = {
            id: 51,
            attributes: { name: "Effect Event" },
            changes: {},
            user_id: "system"
          }
          event2 = EventMapper.map_operation(@user_class, :create, event2_data)
        end

        # Verify event2 has causation_id pointing to event1
        assert_equal event1.event_id, event2.metadata[:causation_id]
        # event1 should have no causation_id (it's the root)
        assert_nil event1.metadata[:causation_id]
      end

      def test_nested_causation_chain_metadata
        # Simulate a chain: event1 -> event2 -> event3
        # Each event should have causation_id pointing to its direct cause

        event1_data = { id: 100, attributes: { step: 1 }, changes: {}, user_id: "system" }
        event1 = EventMapper.map_operation(@user_class, :create, event1_data)

        event2 = nil
        Lyra::Causation.with_id(event1.event_id) do
          event2_data = { id: 101, attributes: { step: 2 }, changes: {}, user_id: "system" }
          event2 = EventMapper.map_operation(@user_class, :create, event2_data)
        end

        event3 = nil
        Lyra::Causation.with_id(event2.event_id) do
          event3_data = { id: 102, attributes: { step: 3 }, changes: {}, user_id: "system" }
          event3 = EventMapper.map_operation(@user_class, :create, event3_data)
        end

        # Track the chain for reconstruction
        Lyra::Causation.track(event1.event_id, event2.event_id)
        Lyra::Causation.track(event2.event_id, event3.event_id)

        # Verify each event's causation_id
        assert_nil event1.metadata[:causation_id], "Root event should have no cause"
        assert_equal event1.event_id, event2.metadata[:causation_id], "event2 caused by event1"
        assert_equal event2.event_id, event3.metadata[:causation_id], "event3 caused by event2"

        # Verify chain reconstruction
        chain = Lyra::Causation.chain_for(event3.event_id)
        assert_equal [event1.event_id, event2.event_id, event3.event_id], chain
      end

      def test_user_action_context_workflow
        # Simulate a web request context
        Lyra::UserActionContext.with_context(
          action_type: :web_request,
          user_id: "user-999",
          controller: "UsersController",
          action_name: "create",
          params: {
            user: { name: "Eve", email: "eve@example.com" },
            password: "secret123" # Should be sanitized
          }
        ) do |context|
          # Verify context
          assert_equal :web_request, context.action_type
          assert_equal "user-999", context.user_id
          assert_equal "UsersController", context.controller
          assert_equal "create", context.action_name

          # Verify password was sanitized
          refute context.params.key?(:password)
          assert context.params.key?(:user)

          # Verify correlation ID was set
          assert_equal context.action_id, Lyra::Correlation.current_id

          # Create event within context
          event_data = {
            id: 20,
            attributes: { name: "Eve", email: "eve@example.com" },
            changes: {},
            user_id: context.user_id
          }
          event = EventMapper.map_operation(@user_class, :create, event_data)

          assert_equal "user-999", event.metadata[:user_id]
        end
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

      def test_privacy_impact_in_workflow
        # Create events with PII
        sensitive_event_data = {
          id: 200,
          attributes: {
            name: "Grace Hopper",
            email: "grace@navy.mil",
            social_security: "123-45-6789",
            telephone: "555-1234"
          },
          changes: {},
          user_id: "admin-001"
        }

        event = EventMapper.map_operation(@user_class, :create, sensitive_event_data)

        # Verify event was created successfully
        assert_equal "User", event.model_class
        assert_equal 200, event.model_id

        if PAM_DSL_AVAILABLE
          # Detect all PII
          pii_fields = Lyra::Privacy::PIIDetector.detect(event.attributes)

          # Verify PII detection
          assert pii_fields.key?(:name)
          assert pii_fields.key?(:email)
          assert pii_fields.key?(:social_security)
          assert pii_fields.key?(:telephone)

          # Verify SSN is marked as sensitive
          assert pii_fields[:ssn][:sensitive] if pii_fields[:ssn].is_a?(Hash)

          # Test masking
          masked_ssn = Lyra::Privacy::PIIDetector.mask("123-45-6789", :ssn)
          assert_equal "***REDACTED***", masked_ssn

          masked_email = Lyra::Privacy::PIIDetector.mask("grace@navy.mil", :email)
          assert_equal "g***@navy.mil", masked_email
        end
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

      def test_end_to_end_lifecycle_with_privacy
        lifecycle_events = []

        # 1. Create user with PII
        Lyra::UserActionContext.with_context(action_type: :api_call, user_id: "api-client-1") do
          create_data = {
            id: 500,
            attributes: {
              name: "Helen Keller",
              email: "helen@example.com",
              age: 42
            },
            changes: {},
            user_id: "api-client-1"
          }
          lifecycle_events << EventMapper.map_operation(@user_class, :create, create_data)
        end

        # 2. Update with PII change
        Lyra::UserActionContext.with_context(action_type: :web_request, user_id: "admin-2") do
          update_data = {
            id: 500,
            attributes: {},
            changes: { email: ["helen@example.com", "helen.keller@example.com"] },
            user_id: "admin-2"
          }
          lifecycle_events << EventMapper.map_operation(@user_class, :update, update_data)
        end

        # 3. Final deletion
        Lyra::UserActionContext.with_context(action_type: :console, user_id: "superadmin") do
          destroy_data = {
            id: 500,
            attributes: {},
            changes: {},
            user_id: "superadmin"
          }
          lifecycle_events << EventMapper.map_operation(@user_class, :destroy, destroy_data)
        end

        # Verify complete lifecycle
        assert_equal 3, lifecycle_events.length
        assert_equal :create, lifecycle_events[0].operation
        assert_equal :update, lifecycle_events[1].operation
        assert_equal :destroy, lifecycle_events[2].operation

        # All events should be for same entity
        assert lifecycle_events.all? { |e| e.model_id == 500 }
        assert lifecycle_events.all? { |e| e.model_class == "User" }

        # Verify privacy tracking through lifecycle (only when PAM DSL available)
        if PAM_DSL_AVAILABLE
          pii_in_create = Lyra::Privacy::PIIDetector.detect(lifecycle_events[0].attributes)
          assert pii_in_create.key?(:email)
          assert pii_in_create.key?(:name)
        end

        # PII changed in update (this check works without PAM DSL)
        assert(lifecycle_events[1].changes.key?("email") || lifecycle_events[1].changes.key?(:email))
      end
    end
  end
end
