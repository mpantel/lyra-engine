require "test_helper"
require "action_controller"
require "rails_event_store"

module Lyra
  class DashboardControllerTest < ActionController::TestCase
    tests DashboardController

    def setup
      # Start from a fresh configuration, not whatever an earlier test left in
      # the global one: several actions list every monitored model and query
      # it, which fails if a previous test registered a stub.
      Lyra.reset_config!
      @event_store = RailsEventStore::Client.new
      Lyra.configure do |config|
        config.event_store = @event_store
        config.mode = :monitor
      end

      # Use the TestModel defined in test_helper (backed by users table)
      @mock_model = TestModel

      # Register TestModel for monitoring
      Lyra.config.monitor_model(TestModel)
    end

    def teardown
      Lyra.reset_config!
    end

    # Tests for index action
    def test_index_returns_success
      get :index
      assert_response :success
    end

    def test_index_assigns_monitored_models
      # TestModel is already registered in setup
      get :index
      assert_includes assigns(:monitored_models), @mock_model
    end

    def test_index_assigns_mode
      Lyra.config.mode = :hijack
      get :index
      assert_equal :hijack, assigns(:mode)
    end

    def test_index_with_empty_monitored_models
      # Reset config to get empty monitored_models
      Lyra.reset_config!
      Lyra.configure do |config|
        config.event_store = @event_store
        config.mode = :monitor
      end
      get :index
      assert_equal [], assigns(:monitored_models)
    end

    # Tests for model_overview action
    def test_model_overview_success
      get :model_overview, params: { model_class: "TestModel" }
      assert_response :success
    end

    def test_model_overview_assigns_model_class
      get :model_overview, params: { model_class: "TestModel" }
      assert_equal @mock_model, assigns(:model_class)
    end

    def test_model_overview_assigns_records_count
      get :model_overview, params: { model_class: "TestModel" }
      # TestModel uses users table which starts empty (count = 0)
      assert_equal 0, assigns(:records_count)
    end

    def test_model_overview_assigns_events_count
      # Mock event store to return some events
      @event_store.stubs(:read).returns(stub(stream: stub(count: 5)))

      get :model_overview, params: { model_class: "TestModel" }
      assert_not_nil assigns(:events_count)
    end

    def test_model_overview_with_invalid_model_class
      assert_raises(NameError) do
        get :model_overview, params: { model_class: "NonExistentModel" }
      end
    end

    # Tests for compare action
    def test_compare_returns_json
      dual_view = mock("dual_view")
      dual_view.stubs(:compare).returns({ crud: {}, events: {} })
      dual_view.stubs(:audit_trail).returns([])

      DualView.stubs(:new).returns(dual_view)
      StateAnalyzer.stubs(:analyze).returns({ state: "synced" })

      get :compare, params: { model_class: "TestModel", id: 1 }, format: :json
      assert_response :success

      json = JSON.parse(response.body)
      assert json.key?("comparison")
      assert json.key?("audit_trail")
      assert json.key?("analysis")
    end

    def test_compare_assigns_comparison
      dual_view = mock("dual_view")
      comparison = { crud: { name: "Test" }, events: { name: "Test" } }
      dual_view.stubs(:compare).returns(comparison)
      dual_view.stubs(:audit_trail).returns([])

      DualView.stubs(:new).returns(dual_view)
      StateAnalyzer.stubs(:analyze).returns({})

      get :compare, params: { model_class: "TestModel", id: 1 }, format: :json
      assert_equal comparison, assigns(:comparison)
    end

    def test_compare_assigns_audit_trail
      dual_view = mock("dual_view")
      audit_trail = [
        { timestamp: Time.current, event: "created" },
        { timestamp: Time.current, event: "updated" }
      ]
      dual_view.stubs(:compare).returns({})
      dual_view.stubs(:audit_trail).returns(audit_trail)

      DualView.stubs(:new).returns(dual_view)
      StateAnalyzer.stubs(:analyze).returns({})

      get :compare, params: { model_class: "TestModel", id: 1 }, format: :json
      assert_equal audit_trail, assigns(:audit_trail)
    end

    def test_compare_assigns_analysis
      dual_view = mock("dual_view")
      analysis = {
        state: "synced",
        discrepancies: [],
        confidence: 100
      }
      dual_view.stubs(:compare).returns({})
      dual_view.stubs(:audit_trail).returns([])

      DualView.stubs(:new).returns(dual_view)
      StateAnalyzer.stubs(:analyze).returns(analysis)

      get :compare, params: { model_class: "TestModel", id: 1 }, format: :json
      assert_equal analysis, assigns(:analysis)
    end

    # Tests for discrepancies action
    def test_discrepancies_returns_json
      discrepancies = [
        { id: 1, field: "name", crud_value: "A", event_value: "B" }
      ]
      DualView.stubs(:find_discrepancies).returns(discrepancies)

      get :discrepancies, params: { model_class: "TestModel" }, format: :json
      assert_response :success

      json = JSON.parse(response.body)
      assert json.key?("discrepancies")
      assert_equal discrepancies.map(&:stringify_keys), json["discrepancies"]
    end

    def test_discrepancies_assigns_discrepancies
      discrepancies = [
        { id: 1, field: "status", crud_value: "active", event_value: "inactive" },
        { id: 2, field: "name", crud_value: "Old", event_value: "New" }
      ]
      DualView.stubs(:find_discrepancies).returns(discrepancies)

      get :discrepancies, params: { model_class: "TestModel" }, format: :json
      assert_equal discrepancies, assigns(:discrepancies)
    end

    def test_discrepancies_with_no_discrepancies
      DualView.stubs(:find_discrepancies).returns([])

      get :discrepancies, params: { model_class: "TestModel" }, format: :json
      assert_response :success

      json = JSON.parse(response.body)
      assert_equal [], json["discrepancies"]
    end

    # Tests for private methods
    def test_count_events_for_model
      # This tests the private method indirectly through model_overview
      stream = mock("stream")
      stream.stubs(:count).returns(10)

      read = mock("read")
      read.stubs(:stream).returns(stream)

      @event_store.stubs(:read).returns(read)

      get :model_overview, params: { model_class: "TestModel" }

      # The events_count should be calculated from the mocked streams
      assert assigns(:events_count) >= 0
    end

    def test_count_events_handles_exceptions
      # When an exception occurs, should return 0
      read = mock("read")
      read.stubs(:stream).raises(StandardError.new("Stream not found"))

      @event_store.stubs(:read).returns(read)

      get :model_overview, params: { model_class: "TestModel" }

      # Should not raise an error, events_count should be 0
      assert assigns(:events_count) == 0
    end

    # Tests for user_display_name helper
    def test_user_display_name_with_nil_returns_nil
      controller = DashboardController.new
      assert_nil controller.send(:user_display_name, nil)
    end

    def test_user_display_name_with_no_user_model_returns_fallback
      # Hide the User constant temporarily
      original_user = Object.send(:remove_const, :User) if Object.const_defined?(:User)

      begin
        controller = DashboardController.new
        result = controller.send(:user_display_name, 123)
        assert_equal "User #123", result
      ensure
        # Restore User constant
        Object.const_set(:User, original_user) if original_user
      end
    end

    def test_user_display_name_with_user_having_display_name_method
      # Create a test user with display_name method
      user_class = Class.new do
        attr_accessor :id

        def self.find_by(conditions)
          user = new
          user.id = conditions[:id]
          user
        end

        def display_name
          "Test User (Admin)"
        end
      end

      # Temporarily replace User constant
      original_user = Object.send(:remove_const, :User) if Object.const_defined?(:User)
      Object.const_set(:User, user_class)

      begin
        controller = DashboardController.new
        result = controller.send(:user_display_name, 1)
        assert_equal "Test User (Admin)", result
      ensure
        Object.send(:remove_const, :User)
        Object.const_set(:User, original_user) if original_user
      end
    end

    def test_user_display_name_with_user_having_name_method
      # Create a test user with name method but no display_name
      user_class = Class.new do
        attr_accessor :id

        def self.find_by(conditions)
          user = new
          user.id = conditions[:id]
          user
        end

        def name
          "John Doe"
        end
      end

      # Temporarily replace User constant
      original_user = Object.send(:remove_const, :User) if Object.const_defined?(:User)
      Object.const_set(:User, user_class)

      begin
        controller = DashboardController.new
        result = controller.send(:user_display_name, 1)
        assert_equal "John Doe", result
      ensure
        Object.send(:remove_const, :User)
        Object.const_set(:User, original_user) if original_user
      end
    end

    def test_user_display_name_with_user_not_found_returns_fallback
      # Create a user class that returns nil from find_by
      user_class = Class.new do
        def self.find_by(_conditions)
          nil
        end
      end

      # Temporarily replace User constant
      original_user = Object.send(:remove_const, :User) if Object.const_defined?(:User)
      Object.const_set(:User, user_class)

      begin
        controller = DashboardController.new
        result = controller.send(:user_display_name, 999)
        assert_equal "User #999", result
      ensure
        Object.send(:remove_const, :User)
        Object.const_set(:User, original_user) if original_user
      end
    end

    # Tests for audit_trail action
    def test_audit_trail_returns_success
      get :audit_trail
      assert_response :success
    end

    def test_audit_trail_assigns_monitored_models
      get :audit_trail
      assert_includes assigns(:monitored_models), @mock_model
    end

    def test_audit_trail_with_model_class_param
      get :audit_trail, params: { model_class: "TestModel" }
      assert_response :success
      assert_equal "TestModel", assigns(:selected_model)
    end

    def test_audit_trail_with_model_and_record_id
      AuditProjection.stubs(:audit_trail).returns([
        { operation: :created, timestamp: Time.current, user_id: 1, changes: {}, attributes: { name: "Test" } }
      ])

      get :audit_trail, params: { model_class: "TestModel", record_id: "1" }
      assert_response :success
      assert_equal "1", assigns(:selected_id)
      assert_not_nil assigns(:audit_entries)
    end

    def test_audit_trail_for_record_returns_success
      AuditProjection.stubs(:audit_trail).returns([])

      get :audit_trail_for_record, params: { model_class: "TestModel", id: 1 }
      assert_response :success
    end

    def test_audit_trail_for_record_json_format
      audit_entries = [
        { operation: :created, timestamp: Time.current, user_id: 1, changes: {}, attributes: { name: "Test" } }
      ]
      AuditProjection.stubs(:audit_trail).returns(audit_entries)

      get :audit_trail_for_record, params: { model_class: "TestModel", id: 1 }, format: :json
      assert_response :success

      json = JSON.parse(response.body)
      assert json.key?("audit_trail")
      assert json.key?("record_id")
      assert json.key?("model")
    end

    # Tests for projections action
    def test_projections_returns_success
      get :projections
      assert_response :success
    end

    def test_projections_assigns_mode
      Lyra.config.mode = :hijack
      get :projections
      assert_equal :hijack, assigns(:mode)
    end

    def test_projections_assigns_projection_types
      get :projections
      assert_not_nil assigns(:projection_types)
      assert assigns(:projection_types).is_a?(Array)
      assert assigns(:projection_types).any? { |p| p[:name] == "StateProjection" }
    end

    def test_projections_assigns_model_stats
      get :projections
      assert_not_nil assigns(:model_stats)
      assert assigns(:model_stats).is_a?(Hash)
    end

    def test_projections_assigns_model_configs
      get :projections
      assert_not_nil assigns(:model_configs)
      assert assigns(:model_configs).is_a?(Hash)
    end

    # ===========================================================================
    # Tests for schema action
    # ===========================================================================

    def test_schema_returns_success
      mock_schema = {
        version: 1,
        fingerprint: "sha256:abc123",
        created_at: Time.current.iso8601,
        lyra_version: "0.5.0",
        configuration: { mode: "monitor" },
        models: {},
        summary: { models_count: 0 }
      }
      Schema::Store.stubs(:load_current).returns(mock_schema)
      Schema::Store.stubs(:history).returns([])
      Schema::Reporter.stubs(:new).returns(stub(generate: {}))
      Schema::Generator.stubs(:generate).returns(mock_schema)
      Schema::Diff.stubs(:compare).returns([])

      get :schema
      assert_response :success
    end

    def test_schema_assigns_version_info
      mock_schema = {
        version: 3,
        fingerprint: "sha256:test123",
        created_at: "2024-01-01T00:00:00Z",
        lyra_version: "0.5.0",
        configuration: { mode: "monitor", projection_mode: "sync" },
        models: { "User" => { columns: {} } },
        summary: { models_count: 1 }
      }
      Schema::Store.stubs(:load_current).returns(mock_schema)
      Schema::Store.stubs(:history).returns([])
      Schema::Reporter.stubs(:new).returns(stub(generate: {}))
      Schema::Generator.stubs(:generate).returns(mock_schema)
      Schema::Diff.stubs(:compare).returns([])

      get :schema
      assert_equal 3, assigns(:version)
      assert_equal "sha256:test123", assigns(:fingerprint)
      assert_equal "0.5.0", assigns(:lyra_version)
    end

    def test_schema_assigns_models
      mock_schema = {
        version: 1,
        fingerprint: "sha256:abc",
        created_at: Time.current.iso8601,
        lyra_version: "0.5.0",
        configuration: {},
        models: {
          "Registration" => { columns: { id: { type: "integer" } } },
          "Payment" => { columns: { amount: { type: "decimal" } } }
        },
        summary: { models_count: 2 }
      }
      Schema::Store.stubs(:load_current).returns(mock_schema)
      Schema::Store.stubs(:history).returns([])
      Schema::Reporter.stubs(:new).returns(stub(generate: {}))
      Schema::Generator.stubs(:generate).returns(mock_schema)
      Schema::Diff.stubs(:compare).returns([])

      get :schema
      assert_equal 2, assigns(:models).size
      assert assigns(:models).key?("Registration")
      assert assigns(:models).key?("Payment")
    end

    def test_schema_detects_pending_changes
      stored_schema = {
        version: 1,
        fingerprint: "sha256:old",
        created_at: Time.current.iso8601,
        lyra_version: "0.5.0",
        configuration: { mode: "monitor" },
        models: {},
        summary: {}
      }
      current_schema = {
        version: 2,
        fingerprint: "sha256:new",
        created_at: Time.current.iso8601,
        lyra_version: "0.5.0",
        configuration: { mode: "hijack" },
        models: { "NewModel" => {} },
        summary: {}
      }
      pending_changes = [
        { type: "added", model: "NewModel", description: "New model added" }
      ]

      Schema::Store.stubs(:load_current).returns(stored_schema)
      Schema::Store.stubs(:history).returns([])
      Schema::Reporter.stubs(:new).returns(stub(generate: {}))
      Schema::Generator.stubs(:generate).returns(current_schema)
      Schema::Diff.stubs(:compare).returns(pending_changes)

      get :schema
      assert assigns(:has_pending_changes)
      assert_equal pending_changes, assigns(:pending_changes)
    end

    def test_schema_with_no_stored_schema_generates_new
      Schema::Store.stubs(:load_current).returns(nil)
      Schema::Store.stubs(:history).returns([])

      generated_schema = {
        version: 1,
        fingerprint: "sha256:generated",
        created_at: Time.current.iso8601,
        lyra_version: "0.5.0",
        configuration: {},
        models: {},
        summary: {}
      }
      Schema::Generator.stubs(:generate).returns(generated_schema)
      Schema::Reporter.stubs(:new).returns(stub(generate: {}))

      get :schema
      assert_response :success
      # When no stored schema, version comes from generated schema
      assert_equal 1, assigns(:version)
    end

    def test_schema_json_format
      mock_schema = {
        version: 1,
        fingerprint: "sha256:test",
        created_at: Time.current.iso8601,
        lyra_version: "0.5.0",
        configuration: {},
        models: {},
        summary: {}
      }
      Schema::Store.stubs(:load_current).returns(mock_schema)
      Schema::Store.stubs(:history).returns([])
      Schema::Reporter.stubs(:new).returns(stub(generate: {}))
      Schema::Generator.stubs(:generate).returns(mock_schema)
      Schema::Diff.stubs(:compare).returns([])

      get :schema, format: :json
      assert_response :success

      json = JSON.parse(response.body)
      assert_equal 1, json["version"]
      assert_equal "sha256:test", json["fingerprint"]
    end

    def test_schema_assigns_version_history
      history = [
        { version: 1, created_at: "2024-01-01", fingerprint: "sha256:v1" },
        { version: 2, created_at: "2024-01-02", fingerprint: "sha256:v2" }
      ]
      mock_schema = {
        version: 2,
        fingerprint: "sha256:v2",
        created_at: Time.current.iso8601,
        lyra_version: "0.5.0",
        configuration: {},
        models: {},
        summary: {}
      }

      Schema::Store.stubs(:load_current).returns(mock_schema)
      Schema::Store.stubs(:history).returns(history)
      Schema::Reporter.stubs(:new).returns(stub(generate: {}))
      Schema::Generator.stubs(:generate).returns(mock_schema)
      Schema::Diff.stubs(:compare).returns([])

      get :schema
      # History is reversed (most recent first)
      assert_equal 2, assigns(:history).size
      assert_equal 2, assigns(:history).first[:version]
    end

    # ===========================================================================
    # Tests for schema_version action
    # ===========================================================================

    def test_schema_version_returns_success
      mock_schema = {
        version: 1,
        fingerprint: "sha256:v1",
        created_at: "2024-01-01T00:00:00Z",
        lyra_version: "0.5.0",
        rails_version: "7.1.0",
        configuration: {},
        models: {},
        summary: {}
      }
      Schema::Store.stubs(:load_version).with(1).returns(mock_schema)
      Schema::Store.stubs(:history).returns([{ version: 1 }])

      get :schema_version, params: { version: 1 }
      assert_response :success
    end

    def test_schema_version_assigns_schema_data
      mock_schema = {
        version: 2,
        fingerprint: "sha256:version2",
        created_at: "2024-02-01T00:00:00Z",
        lyra_version: "0.5.0",
        rails_version: "7.1.0",
        configuration: { mode: "hijack", projection_mode: "async" },
        models: { "User" => { table_name: "users", columns: {} } },
        summary: { models_count: 1, total_columns: 5 }
      }
      prev_schema = {
        version: 1,
        fingerprint: "sha256:version1",
        created_at: "2024-01-01T00:00:00Z",
        lyra_version: "0.5.0",
        configuration: {},
        models: {},
        summary: {}
      }
      Schema::Store.stubs(:load_version).with(2).returns(mock_schema)
      Schema::Store.stubs(:load_version).with(1).returns(prev_schema)
      Schema::Store.stubs(:history).returns([{ version: 1 }, { version: 2 }])
      Schema::Diff.stubs(:compare).returns([])

      get :schema_version, params: { version: 2 }

      assert_equal 2, assigns(:version)
      assert_equal "sha256:version2", assigns(:fingerprint)
      assert_equal "0.5.0", assigns(:lyra_version)
      assert_equal "7.1.0", assigns(:rails_version)
      assert_equal 1, assigns(:models).size
      assert_equal 1, assigns(:summary)[:models_count]
    end

    def test_schema_version_redirects_when_not_found
      Schema::Store.stubs(:load_version).with(999).returns(nil)

      get :schema_version, params: { version: 999 }
      assert_redirected_to schema_path
    end

    def test_schema_version_calculates_navigation
      history = [
        { version: 1 },
        { version: 2 },
        { version: 3 }
      ]
      mock_schema = {
        version: 2,
        fingerprint: "sha256:v2",
        created_at: Time.current.iso8601,
        lyra_version: "0.5.0",
        rails_version: "7.1.0",
        configuration: {},
        models: {},
        summary: {}
      }
      prev_schema = {
        version: 1,
        fingerprint: "sha256:v1",
        created_at: Time.current.iso8601,
        lyra_version: "0.5.0",
        configuration: {},
        models: {},
        summary: {}
      }

      Schema::Store.stubs(:load_version).with(2).returns(mock_schema)
      Schema::Store.stubs(:load_version).with(1).returns(prev_schema)
      Schema::Store.stubs(:history).returns(history)
      Schema::Diff.stubs(:compare).returns([])

      get :schema_version, params: { version: 2 }

      assert_equal 1, assigns(:prev_version)
      assert_equal 3, assigns(:next_version)
    end

    def test_schema_version_first_version_has_no_prev
      history = [{ version: 1 }, { version: 2 }]
      mock_schema = {
        version: 1,
        fingerprint: "sha256:v1",
        created_at: Time.current.iso8601,
        lyra_version: "0.5.0",
        rails_version: "7.1.0",
        configuration: {},
        models: {},
        summary: {}
      }

      Schema::Store.stubs(:load_version).with(1).returns(mock_schema)
      Schema::Store.stubs(:history).returns(history)

      get :schema_version, params: { version: 1 }

      assert_nil assigns(:prev_version)
      assert_equal 2, assigns(:next_version)
    end

    def test_schema_version_last_version_has_no_next
      history = [{ version: 1 }, { version: 2 }]
      mock_schema = {
        version: 2,
        fingerprint: "sha256:v2",
        created_at: Time.current.iso8601,
        lyra_version: "0.5.0",
        rails_version: "7.1.0",
        configuration: {},
        models: {},
        summary: {}
      }
      prev_schema = {
        version: 1,
        fingerprint: "sha256:v1",
        created_at: Time.current.iso8601,
        lyra_version: "0.5.0",
        configuration: {},
        models: {},
        summary: {}
      }

      Schema::Store.stubs(:load_version).with(2).returns(mock_schema)
      Schema::Store.stubs(:load_version).with(1).returns(prev_schema)
      Schema::Store.stubs(:history).returns(history)
      Schema::Diff.stubs(:compare).returns([])

      get :schema_version, params: { version: 2 }

      assert_equal 1, assigns(:prev_version)
      assert_nil assigns(:next_version)
    end

    def test_schema_version_compares_with_previous
      prev_schema = {
        version: 1,
        fingerprint: "sha256:v1",
        created_at: Time.current.iso8601,
        lyra_version: "0.5.0",
        configuration: { mode: "monitor" },
        models: {},
        summary: {}
      }
      current_schema = {
        version: 2,
        fingerprint: "sha256:v2",
        created_at: Time.current.iso8601,
        lyra_version: "0.5.0",
        rails_version: "7.1.0",
        configuration: { mode: "hijack" },
        models: { "NewModel" => {} },
        summary: {}
      }
      diff = [{ type: "modified", field: "mode", from: "monitor", to: "hijack" }]

      Schema::Store.stubs(:load_version).with(2).returns(current_schema)
      Schema::Store.stubs(:load_version).with(1).returns(prev_schema)
      Schema::Store.stubs(:history).returns([{ version: 1 }, { version: 2 }])
      Schema::Diff.stubs(:compare).with(prev_schema, current_schema).returns(diff)

      get :schema_version, params: { version: 2 }

      assert_equal diff, assigns(:diff_from_previous)
    end

    def test_schema_version_json_format
      mock_schema = {
        version: 1,
        fingerprint: "sha256:v1",
        created_at: Time.current.iso8601,
        lyra_version: "0.5.0",
        rails_version: "7.1.0",
        configuration: {},
        models: {},
        summary: {}
      }
      Schema::Store.stubs(:load_version).with(1).returns(mock_schema)
      Schema::Store.stubs(:history).returns([{ version: 1 }])

      get :schema_version, params: { version: 1 }, format: :json
      assert_response :success

      json = JSON.parse(response.body)
      assert_equal 1, json["version"]
    end

    # ===========================================================================
    # Tests for schema_history action
    # ===========================================================================

    def test_schema_history_returns_success
      Schema::Store.stubs(:history).returns([])
      Schema::Store.stubs(:load_current).returns(nil)

      get :schema_history
      assert_response :success
    end

    def test_schema_history_assigns_history
      history = [
        { version: 1, created_at: "2024-01-01", fingerprint: "sha256:v1", lyra_version: "0.5.0", models_count: 2 },
        { version: 2, created_at: "2024-01-15", fingerprint: "sha256:v2", lyra_version: "0.5.0", models_count: 3 }
      ]

      Schema::Store.stubs(:history).returns(history)
      Schema::Store.stubs(:load_current).returns({ version: 2 })

      get :schema_history

      # History is reversed (most recent first)
      assert_equal 2, assigns(:history).size
      assert_equal 2, assigns(:history).first[:version]
    end

    def test_schema_history_assigns_current_version
      Schema::Store.stubs(:history).returns([{ version: 1 }, { version: 2 }])
      Schema::Store.stubs(:load_current).returns({ version: 2 })

      get :schema_history

      assert_equal 2, assigns(:current_version)
    end

    def test_schema_history_handles_no_current
      Schema::Store.stubs(:history).returns([{ version: 1 }])
      Schema::Store.stubs(:load_current).returns(nil)

      get :schema_history

      assert_nil assigns(:current_version)
    end

    def test_schema_history_json_format
      history = [
        { version: 1, created_at: "2024-01-01", fingerprint: "sha256:v1" }
      ]

      Schema::Store.stubs(:history).returns(history)
      Schema::Store.stubs(:load_current).returns({ version: 1 })

      get :schema_history, format: :json
      assert_response :success

      json = JSON.parse(response.body)
      assert json.key?("history")
      assert json.key?("current_version")
      assert_equal 1, json["current_version"]
    end

    def test_schema_history_with_empty_history
      Schema::Store.stubs(:history).returns([])
      Schema::Store.stubs(:load_current).returns(nil)

      get :schema_history
      assert_response :success
      assert_equal [], assigns(:history)
    end

    # ===========================================================================
    # Tests for helper methods
    # ===========================================================================

    def test_pam_dsl_available_helper
      controller = DashboardController.new
      # PAM_DSL_AVAILABLE is set at load time, just verify the helper works
      assert_equal PAM_DSL_AVAILABLE, controller.send(:pam_dsl_available?)
    end

    def test_user_tracking_configured_returns_true_when_current_class_has_user
      # Temporarily define Current class with user attribute if not present
      unless defined?(::Current) && ::Current.respond_to?(:user)
        current_class = Class.new(ActiveSupport::CurrentAttributes) do
          attribute :user
        end
        Object.const_set(:Current, current_class) unless Object.const_defined?(:Current)
      end

      controller = DashboardController.new
      result = controller.send(:user_tracking_configured?)
      assert result, "user_tracking_configured? should return true when Current.user is defined"
    end

    def test_user_tracking_configured_returns_false_when_current_class_missing
      # Temporarily remove Current class
      original_current = nil
      if Object.const_defined?(:Current)
        original_current = Object.send(:remove_const, :Current)
      end

      begin
        controller = DashboardController.new
        result = controller.send(:user_tracking_configured?)
        refute result, "user_tracking_configured? should return false when Current is not defined"
      ensure
        # Restore Current class
        Object.const_set(:Current, original_current) if original_current
      end
    end

    def test_user_tracking_configured_returns_false_when_current_lacks_user_method
      # Create a Current class without user attribute
      original_current = nil
      if Object.const_defined?(:Current)
        original_current = Object.send(:remove_const, :Current)
      end

      current_without_user = Class.new do
        def self.respond_to?(method, include_private = false)
          return false if method == :user
          super
        end
      end
      Object.const_set(:Current, current_without_user)

      begin
        controller = DashboardController.new
        result = controller.send(:user_tracking_configured?)
        refute result, "user_tracking_configured? should return false when Current lacks user method"
      ensure
        Object.send(:remove_const, :Current)
        Object.const_set(:Current, original_current) if original_current
      end
    end

    private

    def stub_const(name, value)
      Object.const_set(name, value) unless Object.const_defined?(name)
    end
  end
end
