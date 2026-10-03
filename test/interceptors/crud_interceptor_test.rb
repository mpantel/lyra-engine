# frozen_string_literal: true

require "test_helper"
require_relative "../../lib/lyra/interceptors/crud_interceptor"

module Lyra
  module Interceptors
    class CrudInterceptorTest < Minitest::Test
      def setup
        @event_store = RailsEventStore::Client.new
        Lyra.configure do |config|
          config.event_store = @event_store
          config.mode = :monitor
        end
        @email_counter = 0
      end

      def teardown
        Lyra.reset_config!
      end

      def next_email
        @email_counter += 1
        "test#{@email_counter}_#{rand(10000)}@example.com"
      end

      # ===========================================================================
      # Module Structure Tests
      # ===========================================================================

      def test_module_exists
        assert defined?(Lyra::Interceptors::CrudInterceptor)
      end

      def test_module_is_a_concern
        assert Lyra::Interceptors::CrudInterceptor.is_a?(Module)
      end

      def test_module_defines_class_methods
        assert Lyra::Interceptors::CrudInterceptor.const_defined?(:ClassMethods)
      end

      def test_monitor_with_lyra_class_method_exists
        class_methods = Lyra::Interceptors::CrudInterceptor::ClassMethods
        assert class_methods.instance_methods.include?(:monitor_with_lyra)
      end

      # ===========================================================================
      # Mode Detection Tests (using User model from test_helper)
      # ===========================================================================

      def test_lyra_monitored_returns_true_when_enabled
        user = ::User.new(name: "Test", email: next_email)
        assert user.send(:lyra_monitored?)
      end

      def test_lyra_hijack_mode_returns_false_in_monitor_mode
        user = ::User.new(name: "Test", email: next_email)
        refute user.send(:lyra_hijack_mode?)
      end

      def test_lyra_hijack_mode_returns_true_in_hijack_mode
        Lyra.config.mode = :hijack
        user = ::User.new(name: "Test", email: next_email)
        assert user.send(:lyra_hijack_mode?)
      end

      def test_lyra_event_sourcing_mode_returns_false_in_monitor_mode
        user = ::User.new(name: "Test", email: next_email)
        refute user.send(:lyra_event_sourcing_mode?)
      end

      def test_lyra_event_sourcing_mode_returns_true_in_event_sourcing_mode
        Lyra.config.mode = :event_sourcing
        user = ::User.new(name: "Test", email: next_email)
        assert user.send(:lyra_event_sourcing_mode?)
      end

      # ===========================================================================
      # Build Event Data Tests
      # ===========================================================================

      def test_build_event_data_includes_model_class
        user = ::User.create!(name: "Test", email: next_email)
        data = user.send(:build_event_data, :created)

        assert_equal "User", data[:model_class]
      ensure
        user&.destroy
      end

      def test_build_event_data_includes_model_id
        user = ::User.create!(name: "Test", email: next_email)
        data = user.send(:build_event_data, :created)

        assert_equal user.id, data[:model_id]
      ensure
        user&.destroy
      end

      def test_build_event_data_includes_operation
        user = ::User.create!(name: "Test", email: next_email)
        data = user.send(:build_event_data, :updated)

        assert_equal :updated, data[:operation]
      ensure
        user&.destroy
      end

      def test_build_event_data_includes_attributes
        user = ::User.create!(name: "TestUser", email: next_email)
        data = user.send(:build_event_data, :created)

        assert data[:attributes].key?("name")
        assert_equal "TestUser", data[:attributes]["name"]
      ensure
        user&.destroy
      end

      def test_build_event_data_excludes_timestamps_from_attributes
        user = ::User.create!(name: "Test", email: next_email)
        data = user.send(:build_event_data, :created)

        refute data[:attributes].key?("created_at")
        refute data[:attributes].key?("updated_at")
      ensure
        user&.destroy
      end

      def test_build_event_data_includes_timestamp
        user = ::User.create!(name: "Test", email: next_email)
        data = user.send(:build_event_data, :created)

        assert data[:timestamp].is_a?(Time)
      ensure
        user&.destroy
      end

      def test_build_event_data_includes_metadata
        user = ::User.create!(name: "Test", email: next_email)
        data = user.send(:build_event_data, :created)

        assert data[:metadata].is_a?(Hash)
        assert data[:metadata].key?(:user_id)
        assert data[:metadata].key?(:request_id)
        assert data[:metadata].key?(:correlation_id)
        assert data[:metadata].key?(:causation_id)
      ensure
        user&.destroy
      end

      # ===========================================================================
      # Stream Name Tests
      # ===========================================================================

      def test_lyra_stream_name_format
        user = ::User.create!(name: "Test", email: next_email)
        stream_name = user.send(:lyra_stream_name)

        assert_equal "User$#{user.id}", stream_name
      ensure
        user&.destroy
      end

      # ===========================================================================
      # Current Context Tests
      # ===========================================================================

      def test_lyra_current_user_id_returns_nil_when_no_current
        user = ::User.new(name: "Test", email: next_email)
        assert_nil user.send(:lyra_current_user_id)
      end

      def test_lyra_current_request_id_returns_nil_when_no_current
        user = ::User.new(name: "Test", email: next_email)
        assert_nil user.send(:lyra_current_request_id)
      end

      def test_lyra_current_action_id_returns_nil_when_no_context
        user = ::User.new(name: "Test", email: next_email)
        assert_nil user.send(:lyra_current_action_id)
      end

      def test_lyra_current_user_action_returns_nil_when_no_context
        user = ::User.new(name: "Test", email: next_email)
        assert_nil user.send(:lyra_current_user_action)
      end

      # ===========================================================================
      # Event Class Resolution Tests
      # ===========================================================================

      def test_lyra_event_class_for_created_returns_event_class
        user = ::User.new(name: "Test", email: next_email)
        event_class = user.send(:lyra_event_class_for, :created)

        assert event_class < Lyra::Event
      end

      def test_lyra_event_class_for_updated_returns_event_class
        user = ::User.new(name: "Test", email: next_email)
        event_class = user.send(:lyra_event_class_for, :updated)

        assert event_class < Lyra::Event
      end

      def test_lyra_event_class_for_destroyed_returns_event_class
        user = ::User.new(name: "Test", email: next_email)
        event_class = user.send(:lyra_event_class_for, :destroyed)

        assert event_class < Lyra::Event
      end

      # ===========================================================================
      # Monitor Mode Callback Tests
      # ===========================================================================

      def test_monitor_mode_creates_event_after_create
        Lyra.config.mode = :monitor
        events_before = @event_store.read.to_a.count

        user = ::User.create!(name: "MonitorTest", email: next_email)

        events_after = @event_store.read.to_a.count
        assert events_after > events_before
      ensure
        user&.destroy
      end

      def test_monitor_mode_creates_event_after_update
        Lyra.config.mode = :monitor
        user = ::User.create!(name: "Original", email: next_email)

        events_before = @event_store.read.to_a.count
        user.update!(name: "Updated")
        events_after = @event_store.read.to_a.count

        assert events_after > events_before
      ensure
        user&.destroy
      end

      def test_monitor_mode_creates_event_after_destroy
        Lyra.config.mode = :monitor
        user = ::User.create!(name: "ToDelete", email: next_email)

        events_before = @event_store.read.to_a.count
        user.destroy
        events_after = @event_store.read.to_a.count

        assert events_after > events_before
      end

      # ===========================================================================
      # SQL Override Tests
      # ===========================================================================

      def test_update_row_calls_super_when_not_skipping
        # Use TestModel which doesn't have Lyra callbacks to avoid interference
        model = TestModel.create!(name: "Test", email: next_email)
        model.update!(name: "Updated")

        model.reload
        assert_equal "Updated", model.name
      ensure
        model&.destroy
      end

      def test_delete_row_calls_super_when_not_skipping
        user = ::User.create!(name: "Test", email: next_email)
        user_id = user.id

        user.destroy

        refute ::User.exists?(user_id)
      end

      # ===========================================================================
      # Disabled Paper Trail Integration Tests
      # ===========================================================================

      def test_lyra_disable_paper_trail_does_not_crash_without_paper_trail
        user = ::User.new(name: "Test", email: next_email)

        assert_nothing_raised do
          user.send(:lyra_disable_paper_trail!)
        end
      end

      # ===========================================================================
      # Read Override Tests (for event sourcing disabled projection mode)
      # ===========================================================================

      def test_lyra_read_from_events_returns_false_in_monitor_mode
        Lyra.config.mode = :monitor
        refute ::User.send(:lyra_read_from_events?)
      end

      # ===========================================================================
      # Thread Safety Tests
      # ===========================================================================

      def test_thread_current_lyra_skip_insert_cleared_when_no_result
        # When there's no event result, finalize should still clear the flag
        Thread.current[:lyra_skip_insert] = true

        user = ::User.new(name: "Test", email: next_email)
        user.instance_variable_set(:@lyra_event_result, nil)
        user.send(:lyra_finalize_event_source)

        # Finalize clears its state on every exit, the early return included.
        # It used to leave the flag set there, and after a failed store too, so
        # the next insert of any model on the thread skipped its row.
        assert_nil Thread.current[:lyra_skip_insert]
      ensure
        Thread.current[:lyra_skip_insert] = nil
      end

      def test_thread_current_lyra_bypass_read_override
        Thread.current[:lyra_bypass_read_override] = true

        Lyra.config.mode = :event_sourcing
        Lyra.config.projection_mode = :disabled

        refute ::User.send(:lyra_read_from_events?)
      ensure
        Thread.current[:lyra_bypass_read_override] = nil
      end

      # ===========================================================================
      # Error Handling Tests
      # ===========================================================================

      def test_lyra_store_events_raises_when_strict
        Lyra.config.strict_projections = true
        user = ::User.new(name: "Test", email: next_email)

        events = [Lyra::Event.new(data: { test: true })]
        @event_store.stubs(:publish).raises(StandardError.new("Store error"))

        assert_raises(StandardError) do
          user.send(:lyra_store_events, events)
        end
      end

      # ===========================================================================
      # Metadata Proc Tests
      # ===========================================================================

      def test_lyra_custom_metadata_returns_empty_hash_when_no_proc
        Lyra.config.metadata_proc = nil
        user = ::User.new(name: "Test", email: next_email)

        result = user.send(:lyra_custom_metadata, :created)
        assert_equal({}, result)
      end

      def test_lyra_custom_metadata_calls_proc_with_record_and_operation
        called_with = nil
        Lyra.config.metadata_proc = lambda do |record, operation|
          called_with = { record: record, operation: operation }
          { custom: true }
        end

        user = ::User.new(name: "Test", email: next_email)
        user.send(:lyra_custom_metadata, :updated)

        assert_equal user, called_with[:record]
        assert_equal :updated, called_with[:operation]
      end

      def test_lyra_custom_metadata_returns_proc_result
        Lyra.config.metadata_proc = lambda do |record, operation|
          { user_id: 123, source: "test_app" }
        end

        user = ::User.new(name: "Test", email: next_email)
        result = user.send(:lyra_custom_metadata, :created)

        assert_equal 123, result[:user_id]
        assert_equal "test_app", result[:source]
      end

      def test_lyra_custom_metadata_returns_empty_hash_on_proc_error
        Lyra.config.metadata_proc = lambda do |record, operation|
          raise "Something went wrong"
        end

        user = ::User.new(name: "Test", email: next_email)
        result = user.send(:lyra_custom_metadata, :created)

        assert_equal({}, result)
      end

      def test_lyra_custom_metadata_returns_empty_hash_when_proc_returns_non_hash
        Lyra.config.metadata_proc = lambda do |record, operation|
          "not a hash"
        end

        user = ::User.new(name: "Test", email: next_email)
        result = user.send(:lyra_custom_metadata, :created)

        assert_equal({}, result)
      end

      def test_build_event_data_merges_custom_metadata
        Lyra.config.metadata_proc = lambda do |record, operation|
          { custom_user_id: 999, custom_source: "my_app" }
        end

        user = ::User.create!(name: "Test", email: next_email)
        data = user.send(:build_event_data, :created)

        # Custom metadata should be merged
        assert_equal 999, data[:metadata][:custom_user_id]
        assert_equal "my_app", data[:metadata][:custom_source]

        # Built-in metadata should still be present
        assert data[:metadata].key?(:correlation_id)
        assert data[:metadata].key?(:causation_id)
      ensure
        user&.destroy
      end

      def test_custom_metadata_overwrites_built_in_when_same_key
        # Custom metadata should overwrite built-in values
        Lyra.config.metadata_proc = lambda do |record, operation|
          { user_id: 42 }  # Overwrite the built-in user_id
        end

        user = ::User.create!(name: "Test", email: next_email)
        data = user.send(:build_event_data, :created)

        assert_equal 42, data[:metadata][:user_id]
      ensure
        user&.destroy
      end

      def test_metadata_proc_receives_operation_for_each_crud_type
        operations_received = []
        Lyra.config.metadata_proc = lambda do |record, operation|
          operations_received << operation
          {}
        end

        user = ::User.create!(name: "Test", email: next_email)
        user.update!(name: "Updated")
        user.destroy

        assert_includes operations_received, :created
        assert_includes operations_received, :updated
        assert_includes operations_received, :destroyed
      end

      private

      def assert_nothing_raised
        yield
      rescue => e
        flunk "Expected no exception, got: #{e.class}: #{e.message}"
      end
    end
  end
end
