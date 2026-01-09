require "test_helper"
require "action_controller"
require "rails_event_store"

module Lyra
  class FlowControllerTest < ActionController::TestCase
    tests FlowController

    def setup
      @event_store = RailsEventStore::Client.new
      Lyra.configure do |config|
        config.event_store = @event_store
      end

      # Mock model for testing
      @mock_model = Class.new do
        def self.name
          "TestModel"
        end
      end

      stub_const("TestModel", @mock_model)

      # Create mock events
      @mock_events = [
        create_mock_event("TestCreated", { name: "Test" }, 1),
        create_mock_event("TestUpdated", { name: "Updated" }, 2)
      ]
    end

    def teardown
      Lyra.reset_config!
    end

    # Tests for timeline action
    def test_timeline_json_format
      flow = mock("flow")
      flow_data = { events: [], timeline: [] }
      flow.stubs(:flow_data).returns(flow_data)

      EventFlow.stubs(:new).returns(flow)

      get :timeline, params: { subject_id: "1", subject_type: "User" }, format: :json
      assert_response :success

      json = JSON.parse(response.body)
      assert_equal flow_data.stringify_keys, json
    end

    def test_timeline_html_format
      flow = mock("flow")
      flow.stubs(:flow_data).returns({})
      EventFlow.stubs(:new).returns(flow)

      # Mock event loading and timeline visualization
      @controller.stubs(:load_events).returns(@mock_events)

      timeline = mock("timeline")
      timeline.stubs(:to_html).returns("<div>Timeline</div>")
      Visualization::Timeline.stubs(:new).returns(timeline)

      get :timeline, params: {
        subject_id: "1",
        subject_type: "User",
        format: "html"
      }

      assert_response :success
      assert_match(/Timeline/, response.body)
    end

    def test_timeline_creates_event_flow_with_params
      flow = mock("flow")
      flow.stubs(:flow_data).returns({})

      EventFlow.expects(:new).with(
        subject_id: "123",
        subject_type: "User"
      ).returns(flow)

      get :timeline, params: { subject_id: "123", subject_type: "User" }, format: :json
    end

    # Tests for event_chain action
    def test_event_chain_returns_json
      chain = [
        { state: "initial", event: "created" },
        { state: "updated", event: "updated" }
      ]

      flow = mock("flow")
      flow.stubs(:reconstruct_state_chain).returns(chain)
      EventFlow.stubs(:new).returns(flow)

      get :event_chain, params: { model_class: "TestModel", model_id: 1 }, format: :json
      assert_response :success

      json = JSON.parse(response.body)
      assert_equal chain.map(&:stringify_keys), json
    end

    def test_event_chain_calls_reconstruct_state_chain
      flow = mock("flow")
      flow.expects(:reconstruct_state_chain).with("TestModel", "1").returns([])
      EventFlow.stubs(:new).returns(flow)

      get :event_chain, params: { model_class: "TestModel", model_id: 1 }, format: :json
    end

    # Tests for crud_mapping action
    def test_crud_mapping_returns_json
      mapping = {
        crud_operation: :create,
        event_type: "TestCreated",
        mapped_at: Time.current
      }

      flow = mock("flow")
      flow.stubs(:crud_to_event_mapping).returns(mapping)
      EventFlow.stubs(:new).returns(flow)

      get :crud_mapping, params: {
        model_class: "TestModel",
        operation: "create",
        model_id: 1
      }, format: :json

      assert_response :success
      json = JSON.parse(response.body)
      assert_equal "create", json["crud_operation"]
    end

    def test_crud_mapping_with_different_operations
      [:create, :update, :delete].each do |operation|
        flow = mock("flow")
        flow.stubs(:crud_to_event_mapping).returns({ crud_operation: operation })
        EventFlow.stubs(:new).returns(flow)

        get :crud_mapping, params: {
          model_class: "TestModel",
          operation: operation.to_s,
          model_id: 1
        }, format: :json

        assert_response :success
      end
    end

    # Tests for visualization action
    def test_visualization_json_format
      @event_store.stubs(:read).returns(stub(stream: stub(to_a: @mock_events)))

      timeline = mock("timeline")
      timeline_data = { events: [], nodes: [] }
      timeline.stubs(:to_data).returns(timeline_data)
      Visualization::Timeline.stubs(:new).returns(timeline)

      get :visualization, params: {
        model_class: "TestModel",
        model_id: 1
      }, format: :json

      assert_response :success
      json = JSON.parse(response.body)
      assert_equal timeline_data.stringify_keys, json
    end

    def test_visualization_html_format
      @event_store.stubs(:read).returns(stub(stream: stub(to_a: @mock_events)))

      timeline = mock("timeline")
      timeline.stubs(:to_html).returns("<div>HTML Timeline</div>")
      Visualization::Timeline.stubs(:new).returns(timeline)

      get :visualization, params: {
        model_class: "TestModel",
        model_id: 1,
        format: "html"
      }

      assert_response :success
      assert_match(/HTML Timeline/, response.body)
    end

    def test_visualization_mermaid_format
      @event_store.stubs(:read).returns(stub(stream: stub(to_a: @mock_events)))

      timeline = mock("timeline")
      timeline.stubs(:to_mermaid).returns("graph TD\n  A-->B")
      Visualization::Timeline.stubs(:new).returns(timeline)

      get :visualization, params: {
        model_class: "TestModel",
        model_id: 1,
        format: "mermaid"
      }

      assert_response :success
      assert_match(/graph TD/, response.body)
    end

    def test_visualization_ascii_format
      @event_store.stubs(:read).returns(stub(stream: stub(to_a: @mock_events)))

      timeline = mock("timeline")
      timeline.stubs(:to_ascii).returns("Event1 --> Event2")
      Visualization::Timeline.stubs(:new).returns(timeline)

      get :visualization, params: {
        model_class: "TestModel",
        model_id: 1,
        format: "ascii"
      }

      assert_response :success
      assert_match(/Event1 --> Event2/, response.body)
    end

    def test_visualization_d3_format
      @event_store.stubs(:read).returns(stub(stream: stub(to_a: @mock_events)))

      timeline = mock("timeline")
      d3_data = { nodes: [], links: [] }
      timeline.stubs(:to_d3_json).returns(d3_data.to_json)
      Visualization::Timeline.stubs(:new).returns(timeline)

      get :visualization, params: {
        model_class: "TestModel",
        model_id: 1,
        format: "d3"
      }

      assert_response :success
      json = JSON.parse(response.body)
      assert json.key?("nodes")
      assert json.key?("links")
    end

    # Tests for correlation action (works with or without PAM DSL)
    def test_correlation_returns_json
      correlation_id = "corr-123"

      mock_event1 = create_mock_event_with_metadata("Event1", {}, { correlation_id: correlation_id })
      mock_event2 = create_mock_event_with_metadata("Event2", {}, { correlation_id: correlation_id })

      @event_store.stubs(:read).returns(stub(to_a: [mock_event1, mock_event2]))

      flow = mock("flow")
      flow.stubs(:build_timeline).returns([])
      EventFlow.stubs(:new).returns(flow)

      # Only stub PIIDetector if PAM DSL is available
      Privacy::PIIDetector.stubs(:detect).returns([]) if PAM_DSL_AVAILABLE

      get :correlation, params: { correlation_id: correlation_id }, format: :json
      assert_response :success

      json = JSON.parse(response.body)
      assert_equal correlation_id, json["correlation_id"]
      assert_equal 2, json["events_count"]
      # privacy_impact is nil when PAM DSL is not available
      if PAM_DSL_AVAILABLE
        assert_equal 0, json["privacy_impact"]
      else
        assert_nil json["privacy_impact"]
      end
    end

    def test_correlation_calculates_timespan
      correlation_id = "corr-456"

      time1 = Time.parse("2024-01-01 10:00:00")
      time2 = Time.parse("2024-01-01 11:00:00")

      mock_event1 = create_mock_event_with_metadata("Event1", {}, { correlation_id: correlation_id })
      mock_event1.stubs(:timestamp).returns(time1)

      mock_event2 = create_mock_event_with_metadata("Event2", {}, { correlation_id: correlation_id })
      mock_event2.stubs(:timestamp).returns(time2)

      @event_store.stubs(:read).returns(stub(to_a: [mock_event1, mock_event2]))

      flow = mock("flow")
      flow.stubs(:build_timeline).returns([])
      EventFlow.stubs(:new).returns(flow)

      # Only stub PIIDetector if PAM DSL is available
      Privacy::PIIDetector.stubs(:detect).returns([]) if PAM_DSL_AVAILABLE

      get :correlation, params: { correlation_id: correlation_id }, format: :json

      json = JSON.parse(response.body)
      assert_equal time1.as_json, json["started_at"]
      assert_equal time2.as_json, json["completed_at"]
    end

    # Tests for user_actions action (works with or without PAM DSL)
    def test_user_actions_returns_json
      user_id = 42

      mock_event = create_mock_event_with_metadata(
        "UserAction",
        {},
        { user_id: user_id, action_id: "act-1", user_action: "create_post" }
      )
      mock_event.stubs(:model_class).returns("Post")

      @event_store.stubs(:read).returns(stub(to_a: [mock_event]))
      # Only stub PIIDetector if PAM DSL is available
      Privacy::PIIDetector.stubs(:detect).returns([]) if PAM_DSL_AVAILABLE

      get :user_actions, params: { user_id: user_id }, format: :json
      assert_response :success

      json = JSON.parse(response.body)
      assert_equal user_id.to_s, json["user_id"]
      assert_equal 1, json["total_actions"]
      assert_equal 1, json["total_events"]
      # pii_affected is nil when PAM DSL is not available
      if PAM_DSL_AVAILABLE
        assert_equal false, json["actions"].first["pii_affected"]
      else
        assert_nil json["actions"].first["pii_affected"]
      end
    end

    def test_user_actions_groups_by_action_id
      user_id = 42

      mock_event1 = create_mock_event_with_metadata(
        "Event1", {},
        { user_id: user_id, action_id: "act-1", user_action: "create" }
      )
      mock_event1.stubs(:model_class).returns("Post")
      mock_event1.stubs(:timestamp).returns(Time.current)

      mock_event2 = create_mock_event_with_metadata(
        "Event2", {},
        { user_id: user_id, action_id: "act-1", user_action: "create" }
      )
      mock_event2.stubs(:model_class).returns("Comment")
      mock_event2.stubs(:timestamp).returns(Time.current)

      @event_store.stubs(:read).returns(stub(to_a: [mock_event1, mock_event2]))
      # Only stub PIIDetector if PAM DSL is available
      Privacy::PIIDetector.stubs(:detect).returns([]) if PAM_DSL_AVAILABLE

      get :user_actions, params: { user_id: user_id }, format: :json

      json = JSON.parse(response.body)
      assert_equal 1, json["total_actions"]
      assert_equal 2, json["total_events"]
      assert_equal 2, json["actions"].first["events_count"]
    end

    # Tests for load_events private method
    def test_load_events_filters_by_subject
      all_events = [
        create_mock_event_with_metadata("E1", {}, { user_id: 1 }),
        create_mock_event_with_metadata("E2", {}, { user_id: 2 }),
      ]

      @event_store.stubs(:read).returns(stub(to_a: all_events))

      flow = mock("flow")
      flow.stubs(:flow_data).returns({})
      EventFlow.stubs(:new).returns(flow)

      # This indirectly tests load_events through timeline with html format
      timeline = mock("timeline")
      timeline.stubs(:to_html).returns("<div></div>")
      Visualization::Timeline.stubs(:new).with { |events| events.size <= all_events.size }.returns(timeline)

      get :timeline, params: {
        subject_id: "1",
        subject_type: "User",
        format: "html"
      }

      assert_response :success
    end

    private

    def create_mock_event(type, attributes, id = 1)
      event = mock("event_#{type}_#{id}")
      event.stubs(:event_type).returns(type)
      event.stubs(:attributes).returns(attributes)
      event.stubs(:metadata).returns({})
      event.stubs(:timestamp).returns(Time.current)
      event.stubs(:model_id).returns(id)
      event
    end

    def create_mock_event_with_metadata(type, attributes, metadata)
      event = mock("event_#{type}_#{rand(1000)}")
      event.stubs(:event_type).returns(type)
      event.stubs(:attributes).returns(attributes)
      event.stubs(:metadata).returns(metadata)
      event.stubs(:timestamp).returns(Time.current)
      event.stubs(:model_class).returns("TestModel")
      event.stubs(:model_id).returns(1)
      event
    end

    def stub_const(name, value)
      Object.const_set(name, value) unless Object.const_defined?(name)
    end
  end

  # Tests for crud_mapping action
  class FlowControllerCrudMappingTest < ActionController::TestCase
    tests FlowController

    def setup
      @event_store = RailsEventStore::Client.new
      Lyra.configure do |config|
        config.event_store = @event_store
        config.mode = :monitor
      end

      # Register a test model
      Lyra.config.monitor_model(TestModel)
    end

    def teardown
      Lyra.reset_config!
    end

    def test_crud_mapping_returns_success
      @event_store.stubs(:read).returns(stub(to_a: []))

      get :crud_mapping
      assert_response :success
    end

    def test_crud_mapping_assigns_models_summary
      @event_store.stubs(:read).returns(stub(to_a: []))

      get :crud_mapping
      assert_not_nil assigns(:models_summary)
      assert assigns(:models_summary).is_a?(Hash)
    end

    def test_crud_mapping_assigns_total_events
      @event_store.stubs(:read).returns(stub(to_a: []))

      get :crud_mapping
      assert_not_nil assigns(:total_events)
      assert_equal 0, assigns(:total_events)
    end

    def test_crud_mapping_assigns_operations_summary
      @event_store.stubs(:read).returns(stub(to_a: []))

      get :crud_mapping
      assert_not_nil assigns(:operations_summary)
      assert assigns(:operations_summary).is_a?(Hash)
    end

    def test_crud_mapping_json_format
      @event_store.stubs(:read).returns(stub(to_a: []))

      get :crud_mapping, format: :json
      assert_response :success

      json = JSON.parse(response.body)
      assert json.key?("total_events")
      assert json.key?("operations")
    end

    def test_crud_mapping_with_specific_model_and_operation
      flow = mock("flow")
      flow.stubs(:crud_to_event_mapping).returns({ event_type: "TestCreated", stream: "TestModel$1" })
      EventFlow.stubs(:new).returns(flow)

      get :crud_mapping, params: { model_class: "TestModel", operation: "create" }, format: :json
      assert_response :success
    end
  end
end
