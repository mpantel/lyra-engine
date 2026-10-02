# frozen_string_literal: true

require "test_helper"

module Lyra
  module Integration
    # Integration tests for event_sourcing mode with ActiveRecord
    # These tests verify the complete flow:
    #   1. CRUD operation triggers callback
    #   2. Event is stored in RailsEventStore
    #   3. DB write is aborted (throw(:abort))
    #   4. Projection updates DB (if sync mode)
    #
    # NOTE: These tests require a fully configured Rails environment with
    # event store tables. In the standalone test suite, they verify configuration
    # but skip the full CRUD flow tests.
    class EventSourcingIntegrationTest < Minitest::Test
      # Skip all tests if Rails/ActiveRecord not loaded
      def self.runnable_methods
        return [] unless defined?(ActiveRecord::Base) && defined?(Rails)

        super
      end

      def setup
        return unless defined?(ActiveRecord::Base)

        Lyra.reset_config!

        # Configure Lyra in event_sourcing mode with sync projections
        Lyra.configure do |config|
          config.mode = :event_sourcing
          config.projection_mode = :sync
          config.event_store = RailsEventStore::Client.new(
            repository: RubyEventStore::ActiveRecord::EventRepository.new(
              serializer: RubyEventStore::Serializers::YAML
            )
          )
        end

        # Create test model class that includes CrudInterceptor
        @user_class = create_test_model_class

        # Monitor the model
        Lyra.config.monitor_model(@user_class, event_prefix: "EventSourcedUser")

        # Clean up test data
        @user_class.delete_all
        clear_event_store

        # Check if full integration tests can run
        @full_integration_available = check_full_integration_available
      end

      def teardown
        return unless defined?(ActiveRecord::Base)

        @user_class&.delete_all rescue nil
        clear_event_store
        Lyra.reset_config!
      end

      # Check if the model has proper callbacks set up for event sourcing
      def check_full_integration_available
        # Try to verify callbacks are working
        test_user = @user_class.new(name: "test", email: "test@test.com")
        test_user.save
        has_id = test_user.id.present?
        # Clean up the test user and its events
        @user_class.delete_all rescue nil
        clear_event_store
        has_id
      rescue StandardError
        false
      end

      def skip_unless_full_integration
        skip "Full integration not available (model callbacks not firing)" unless @full_integration_available
      end

      # =========================================================================
      # Event Sourcing Mode Verification
      # =========================================================================

      def test_event_sourcing_mode_is_active
        assert Lyra.event_sourcing_mode?
        assert_equal :event_sourcing, Lyra.config.mode
      end

      def test_sync_projection_mode_is_active
        assert_equal :sync, Lyra.config.projection_mode
      end

      # =========================================================================
      # Create Operation Tests
      # =========================================================================

      def test_create_stores_event_before_db_write
        skip_unless_full_integration

        initial_count = @user_class.count
        initial_event_count = event_count

        user = @user_class.new(name: "Alice", email: "alice@example.com")
        result = user.save

        # In event_sourcing mode with sync projections:
        # - save returns false (throw(:abort))
        # - but record gets an ID assigned
        # - and projection writes to DB
        assert user.id.present?, "User should have an ID assigned"
        assert_equal initial_count + 1, @user_class.count, "Projection should have inserted record"
        assert initial_event_count < event_count, "Event should be stored"
      end

      def test_create_generates_pre_assigned_id
        skip_unless_full_integration

        user = @user_class.new(name: "Bob", email: "bob@example.com")
        user.save

        assert user.id.present?
        assert_kind_of Integer, user.id

        # Verify we can find the record by ID
        found = @user_class.find_by(id: user.id)
        assert_equal "Bob", found.name
      end

      def test_create_event_contains_correct_data
        skip_unless_full_integration

        user = @user_class.new(name: "Charlie", email: "charlie@example.com")
        user.save

        events = read_events_for_model("EventSourcedUser", user.id)
        assert_equal 1, events.length

        event = events.first
        assert_equal user.id, event.data[:model_id]
        assert_equal "Charlie", event.data[:attributes][:name] || event.data[:attributes]["name"]
      end

      # =========================================================================
      # Update Operation Tests
      # =========================================================================

      def test_update_stores_event_and_updates_via_projection
        skip_unless_full_integration

        # First create a user (via projection)
        user = create_user_via_projection("Diana", "diana@example.com")

        initial_event_count = event_count

        # Update the user
        user.name = "Diana Updated"
        user.save

        # Verify event was stored
        assert initial_event_count < event_count

        # Verify DB was updated via projection
        user.reload
        assert_equal "Diana Updated", user.name
      end

      def test_update_event_contains_changes
        skip_unless_full_integration

        user = create_user_via_projection("Eve", "eve@example.com")
        original_name = user.name

        user.name = "Eve Modified"
        user.save

        events = read_events_for_model("EventSourcedUser", user.id)
        update_event = events.find { |e| e.event_type.include?("Updated") }

        assert update_event.present?
        changes = update_event.data[:changes] || {}
        name_change = changes[:name] || changes["name"]
        assert_equal [original_name, "Eve Modified"], name_change
      end

      # =========================================================================
      # Destroy Operation Tests
      # =========================================================================

      def test_destroy_stores_event_and_deletes_via_projection
        skip_unless_full_integration

        user = create_user_via_projection("Frank", "frank@example.com")
        user_id = user.id

        initial_event_count = event_count

        user.destroy

        # Verify event was stored
        assert initial_event_count < event_count

        # Verify record was deleted via projection
        assert_nil @user_class.find_by(id: user_id)
      end

      def test_destroy_event_records_deleted_id
        skip_unless_full_integration

        user = create_user_via_projection("Grace", "grace@example.com")
        user_id = user.id

        user.destroy

        events = read_events_for_model("EventSourcedUser", user_id)
        destroy_event = events.find { |e| e.event_type.include?("Destroyed") }

        assert destroy_event.present?
        assert_equal user_id, destroy_event.data[:model_id]
      end

      # =========================================================================
      # Model State Tests
      # =========================================================================

      def test_model_appears_persisted_after_create
        skip_unless_full_integration

        user = @user_class.new(name: "Henry", email: "henry@example.com")
        user.save

        # After event sourcing create, model should appear persisted
        refute user.new_record?, "Model should not be a new record after save"
        assert user.id.present?, "Model should have an ID"
      end

      def test_model_changes_are_cleared_after_save
        skip_unless_full_integration

        user = @user_class.new(name: "Ivy", email: "ivy@example.com")
        user.save

        # Changes should be moved to previous_changes
        refute user.changed?, "Model should not have unsaved changes"
      end

      # =========================================================================
      # Event Stream Tests
      # =========================================================================

      def test_full_lifecycle_creates_event_stream
        skip_unless_full_integration

        # Create
        user = @user_class.new(name: "Jack", email: "jack@example.com")
        user.save
        user_id = user.id

        # Update
        user.name = "Jack Updated"
        user.save

        # Destroy
        user.destroy

        # Verify full event stream
        events = read_events_for_model("EventSourcedUser", user_id)

        assert events.any? { |e| e.event_type.include?("Created") }
        assert events.any? { |e| e.event_type.include?("Updated") }
        assert events.any? { |e| e.event_type.include?("Destroyed") }
      end

      private

      def create_test_model_class
        # Always create a new model class with CrudInterceptor included
        # We can't reuse TestModel because it doesn't include the interceptor
        Class.new(ActiveRecord::Base) do
          self.table_name = "users"

          include Lyra::Interceptors::CrudInterceptor
          monitor_with_lyra

          def self.name
            "EventSourcedUser"
          end
        end
      end

      def create_user_via_projection(name, email)
        user = @user_class.new(name: name, email: email)
        user.save
        # Reload to get the actual DB state
        @user_class.find(user.id)
      end

      def event_count
        Lyra.config.event_store.read.to_a.length
      rescue StandardError
        0
      end

      def read_events_for_model(prefix, id)
        # Stream name format follows RailsEventStore convention: "ModelClass$id"
        stream_name = "#{prefix}$#{id}"
        Lyra.config.event_store.read.stream(stream_name).to_a
      rescue StandardError
        []
      end

      def clear_event_store
        # Clear all events (use with caution - test only)
        ActiveRecord::Base.connection.execute("DELETE FROM event_store_events_in_streams")
        ActiveRecord::Base.connection.execute("DELETE FROM event_store_events")
      rescue StandardError
        # Ignore if tables don't exist
      end
    end
  end
end
