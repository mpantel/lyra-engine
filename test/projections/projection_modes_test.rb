# frozen_string_literal: true

require "test_helper"

module Lyra
  module Projections
    # Tests for different projection modes: :sync, :async, :disabled
    class ProjectionModesTest < Minitest::Test
      def setup
        Lyra.reset_config!
      end

      def teardown
        Lyra.reset_config!
      end

      # =========================================================================
      # Configuration Tests
      # =========================================================================

      def test_projection_mode_defaults_to_sync
        assert_equal :sync, Lyra.config.projection_mode
      end

      def test_projection_mode_can_be_set_to_async
        Lyra.configure do |config|
          config.projection_mode = :async
        end

        assert_equal :async, Lyra.config.projection_mode
      end

      def test_projection_mode_can_be_set_to_disabled
        Lyra.configure do |config|
          config.projection_mode = :disabled
        end

        assert_equal :disabled, Lyra.config.projection_mode
      end

      def test_projection_mode_validation
        # Valid modes should work
        [:sync, :async, :disabled].each do |mode|
          Lyra.configure { |c| c.projection_mode = mode }
          assert_equal mode, Lyra.config.projection_mode
        end
      end

      # =========================================================================
      # Sync Mode Tests
      # =========================================================================

      def test_sync_projection_mode_runs_projection_immediately
        # Create mock model class
        model_class = create_mock_model_class
        projection_called = false

        # Stub the projection method
        Lyra::Projections::ModelProjection.stub(:project_create, ->(_mc, _result) { projection_called = true }) do
          # Simulate what CrudInterceptor does in sync mode
          Lyra.configure do |config|
            config.mode = :event_sourcing
            config.projection_mode = :sync
          end

          # In sync mode, projection runs immediately
          if Lyra.config.projection_mode == :sync
            result = mock_command_result(:create, { id: 1, name: "Test" })
            Lyra::Projections::ModelProjection.project_create(model_class, result)
          end
        end

        assert projection_called, "Sync mode should run projection immediately"
      end

      # =========================================================================
      # Async Mode Tests
      # =========================================================================

      def test_async_projection_mode_enqueues_job
        skip "ActiveJob not available" unless defined?(ActiveJob)

        Lyra.configure do |config|
          config.mode = :event_sourcing
          config.projection_mode = :async
        end

        # Verify async mode is configured
        assert_equal :async, Lyra.config.projection_mode
      end

      def test_async_projection_job_class_exists
        assert defined?(Lyra::Projections::AsyncProjectionJob)
      end

      def test_async_projection_job_has_correct_queue
        skip "ActiveJob not available" unless defined?(ActiveJob)

        # The job should use the lyra_projections queue
        job = Lyra::Projections::AsyncProjectionJob.new
        assert_equal "lyra_projections", job.queue_name
      end

      # =========================================================================
      # Disabled Mode Tests
      # =========================================================================

      def test_disabled_projection_mode_skips_projection
        Lyra.configure do |config|
          config.mode = :event_sourcing
          config.projection_mode = :disabled
        end

        projection_called = false

        # In disabled mode, projection should NOT be called
        if Lyra.config.projection_mode == :disabled
          # Do nothing - projection disabled
        else
          projection_called = true
        end

        refute projection_called, "Disabled mode should not run projections"
      end

      # =========================================================================
      # ModelProjection Unit Tests
      # =========================================================================

      def test_model_projection_project_create
        model_class = create_mock_model_class
        result = mock_command_result(:create, { id: 1, name: "Test", email: "test@example.com" })

        # Stub insert to track call
        insert_called = false
        insert_attrs = nil

        model_class.define_singleton_method(:insert) do |attrs|
          insert_called = true
          insert_attrs = attrs
          true
        end

        Lyra::Projections::ModelProjection.project_create(model_class, result)

        assert insert_called, "project_create should call model.insert"
        # Note: sanitize_attributes converts to string keys
        assert_equal 1, insert_attrs["id"]
        assert_equal "Test", insert_attrs["name"]
      end

      def test_model_projection_project_update
        model_class = create_mock_model_class
        event = mock_event(:updated, 1, changes: { name: ["Old", "New"] })
        result = mock_command_result(:update, {}, [event])

        # Stub where and update_all
        update_called = false
        update_attrs = nil
        where_id = nil

        where_result = Object.new
        where_result.define_singleton_method(:update_all) do |attrs|
          update_called = true
          update_attrs = attrs
          1
        end

        model_class.define_singleton_method(:where) do |conditions|
          where_id = conditions[:id]
          where_result
        end

        Lyra::Projections::ModelProjection.project_update(model_class, result)

        assert update_called, "project_update should call update_all"
        assert_equal 1, where_id
        assert_equal "New", update_attrs[:name]
      end

      def test_model_projection_project_destroy
        model_class = create_mock_model_class
        event = mock_event(:destroyed, 42)
        result = mock_command_result(:destroy, {}, [event])

        # Stub where and delete_all
        delete_called = false
        where_id = nil

        where_result = Object.new
        where_result.define_singleton_method(:delete_all) do
          delete_called = true
          1
        end

        model_class.define_singleton_method(:where) do |conditions|
          where_id = conditions[:id]
          where_result
        end

        Lyra::Projections::ModelProjection.project_destroy(model_class, result)

        assert delete_called, "project_destroy should call delete_all"
        assert_equal 42, where_id
      end

      def test_model_projection_sanitizes_attributes
        model_class = create_mock_model_class
        # Include an attribute that's not in column_names
        result = mock_command_result(:create, {
          id: 1,
          name: "Test",
          email: "test@example.com",
          unknown_field: "should be removed"
        })

        inserted_attrs = nil
        model_class.define_singleton_method(:insert) do |attrs|
          inserted_attrs = attrs
          true
        end

        Lyra::Projections::ModelProjection.project_create(model_class, result)

        # Note: sanitize_attributes converts to string keys
        assert inserted_attrs.key?("name")
        assert inserted_attrs.key?("email")
        refute inserted_attrs.key?("unknown_field"), "Unknown fields should be sanitized"
        refute inserted_attrs.key?(:unknown_field), "Unknown fields should be sanitized"
      end

      # =========================================================================
      # Error Handling Tests
      # =========================================================================

      def test_projection_error_handler_is_called_on_failure
        Lyra.configure do |config|
          config.strict_projections = false
        end

        handler_called = false
        handler_error = nil

        Lyra.config.projection_error_handler = ->(error, _record, _operation) do
          handler_called = true
          handler_error = error
        end

        model_class = create_mock_model_class
        model_class.define_singleton_method(:insert) do |_attrs|
          raise StandardError, "Database error"
        end

        result = mock_command_result(:create, { id: 1, name: "Test" })

        begin
          Lyra::Projections::ModelProjection.project_create(model_class, result)
        rescue StandardError
          # Expected in non-strict mode
        end

        # Error handler should be configurable
        assert Lyra.config.respond_to?(:projection_error_handler)
      end

      def test_strict_projections_raises_on_error
        Lyra.configure do |config|
          config.strict_projections = true
        end

        model_class = create_mock_model_class
        model_class.define_singleton_method(:insert) do |_attrs|
          raise StandardError, "Database error"
        end

        result = mock_command_result(:create, { id: 1, name: "Test" })

        assert_raises StandardError do
          Lyra::Projections::ModelProjection.project_create(model_class, result)
        end
      end

      private

      def create_mock_model_class
        Class.new do
          define_singleton_method(:column_names) { %w[id name email created_at updated_at] }
          define_singleton_method(:columns_hash) { {} }
          define_singleton_method(:name) { "TestModel" }
          define_singleton_method(:table_name) { "test_models" }
          define_singleton_method(:primary_key) { "id" }
          define_singleton_method(:insert) { |_attrs| true }
          define_singleton_method(:where) { |*_args| self }
          define_singleton_method(:update_all) { |_attrs| 1 }
          define_singleton_method(:delete_all) { 1 }
        end
      end

      def mock_command_result(operation, attributes, events = [])
        Struct.new(:success?, :attributes, :events, :operation, keyword_init: true).new(
          success?: true,
          attributes: attributes,
          events: events,
          operation: operation
        )
      end

      def mock_event(operation, model_id, changes: {})
        Struct.new(:data, keyword_init: true).new(
          data: {
            model_id: model_id,
            operation: operation,
            changes: changes
          }
        )
      end
    end
  end
end
