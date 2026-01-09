require "test_helper"
require "action_controller"
require "rails_event_store"

module Lyra
  class PrivacyControllerTest < ActionController::TestCase
    tests PrivacyController

    def setup
      skip "Privacy controller tests require PAM DSL" unless PAM_DSL_AVAILABLE

      @event_store = RailsEventStore::Client.new
      Lyra.configure do |config|
        config.event_store = @event_store
      end

      @subject_id = "123"
      @subject_type = "User"
    end

    def teardown
      Lyra.reset_config!
    end

    # Tests for subject_data action
    def test_subject_data_returns_json
      compliance = mock("compliance")
      data_export = { name: "John", email: "john@example.com" }
      compliance.stubs(:data_export).returns(data_export)

      Privacy::GDPRCompliance.stubs(:new).returns(compliance)

      get :subject_data, params: {
        subject_type: @subject_type,
        subject_id: @subject_id
      }, format: :json

      assert_response :success

      json = JSON.parse(response.body)
      assert_equal @subject_type, json["subject"]["type"]
      assert_equal @subject_id, json["subject"]["id"]
      assert_equal data_export.stringify_keys, json["data_export"]
      assert json.key?("generated_at")
    end

    def test_subject_data_creates_compliance_with_params
      compliance = mock("compliance")
      compliance.stubs(:data_export).returns({})

      Privacy::GDPRCompliance.expects(:new).with(
        subject_id: @subject_id,
        subject_type: @subject_type
      ).returns(compliance)

      get :subject_data, params: {
        subject_type: @subject_type,
        subject_id: @subject_id
      }, format: :json
    end

    # Tests for gdpr_report action
    def test_gdpr_report_returns_comprehensive_data
      compliance = mock("compliance")
      compliance.stubs(:data_export).returns({ name: "John" })
      compliance.stubs(:right_to_be_forgotten_report).returns({ can_delete: true })
      compliance.stubs(:rectification_history).returns([])
      compliance.stubs(:processing_activities).returns([])
      compliance.stubs(:retention_compliance_check).returns({ compliant: true })
      compliance.stubs(:consent_audit).returns({ consents: [] })

      Privacy::GDPRCompliance.stubs(:new).returns(compliance)

      get :gdpr_report, params: {
        subject_type: @subject_type,
        subject_id: @subject_id
      }, format: :json

      assert_response :success

      json = JSON.parse(response.body)
      assert json.key?("subject")
      assert json.key?("right_to_access")
      assert json.key?("right_to_be_forgotten")
      assert json.key?("rectification_history")
      assert json.key?("processing_activities")
      assert json.key?("retention_compliance")
      assert json.key?("consent_audit")
    end

    def test_gdpr_report_includes_all_rights
      compliance = mock("compliance")
      compliance.stubs(:data_export).returns({ email: "test@test.com" })
      compliance.stubs(:right_to_be_forgotten_report).returns({
        can_delete: true,
        dependencies: []
      })
      compliance.stubs(:rectification_history).returns([
        { field: "email", old: "old@test.com", new: "new@test.com" }
      ])
      compliance.stubs(:processing_activities).returns([
        { activity: "email_marketing", purpose: "newsletter" }
      ])
      compliance.stubs(:retention_compliance_check).returns({ compliant: true })
      compliance.stubs(:consent_audit).returns({ consents: ["marketing"] })

      Privacy::GDPRCompliance.stubs(:new).returns(compliance)

      get :gdpr_report, params: {
        subject_type: @subject_type,
        subject_id: @subject_id
      }, format: :json

      json = JSON.parse(response.body)
      assert_equal true, json["right_to_be_forgotten"]["can_delete"]
      assert_equal 1, json["rectification_history"].size
      assert_equal 1, json["processing_activities"].size
    end

    # Tests for portable_export action
    def test_portable_export_json_format
      compliance = mock("compliance")
      export_data = { user: { name: "John", email: "john@test.com" } }
      compliance.stubs(:portable_export).returns(export_data)

      Privacy::GDPRCompliance.stubs(:new).returns(compliance)

      get :portable_export, params: {
        subject_type: @subject_type,
        subject_id: @subject_id
      }, format: :json

      assert_response :success

      json = JSON.parse(response.body)
      assert_equal export_data.deep_stringify_keys, json
    end

    def test_portable_export_csv_format
      compliance = mock("compliance")
      csv_data = "name,email\nJohn,john@test.com"
      compliance.stubs(:portable_export).with(format: :csv).returns(csv_data)

      Privacy::GDPRCompliance.stubs(:new).returns(compliance)

      get :portable_export, params: {
        subject_type: @subject_type,
        subject_id: @subject_id,
        format: "csv"
      }

      assert_response :success
      assert_equal "text/csv", response.content_type
      assert_match(/data_export_#{@subject_id}.csv/, response.headers["Content-Disposition"])
    end

    def test_portable_export_xml_format
      compliance = mock("compliance")
      xml_data = "<?xml version=\"1.0\"?><user><name>John</name></user>"
      compliance.stubs(:portable_export).with(format: :xml).returns(xml_data)

      Privacy::GDPRCompliance.stubs(:new).returns(compliance)

      get :portable_export, params: {
        subject_type: @subject_type,
        subject_id: @subject_id,
        format: "xml"
      }

      assert_response :success
      assert_equal "application/xml", response.content_type
      assert_match(/data_export_#{@subject_id}.xml/, response.headers["Content-Disposition"])
    end

    def test_portable_export_unsupported_format
      # No need to mock - the controller handles unsupported formats directly
      get :portable_export, params: {
        subject_type: @subject_type,
        subject_id: @subject_id,
        format: "pdf"
      }

      assert_response :bad_request
      json = JSON.parse(response.body)
      assert_equal "Unsupported format", json["error"]
    end

    # Tests for pii_inventory action
    def test_pii_inventory_returns_privacy_impact
      flow = mock("flow")
      privacy_data = {
        pii_fields: ["email", "phone"],
        events_with_pii: 5,
        total_events: 10
      }
      flow.stubs(:privacy_impact_analysis).returns(privacy_data)

      EventFlow.stubs(:new).returns(flow)

      get :pii_inventory, params: {
        subject_type: @subject_type,
        subject_id: @subject_id
      }, format: :json

      assert_response :success

      json = JSON.parse(response.body)
      assert_equal privacy_data.stringify_keys, json
    end

    def test_pii_inventory_creates_event_flow_with_params
      flow = mock("flow")
      flow.stubs(:privacy_impact_analysis).returns({})

      EventFlow.expects(:new).with(
        subject_id: @subject_id,
        subject_type: @subject_type
      ).returns(flow)

      get :pii_inventory, params: {
        subject_type: @subject_type,
        subject_id: @subject_id
      }, format: :json
    end

    # Tests for data_lineage action
    def test_data_lineage_returns_field_history
      field_name = "email"
      model_class = "User"

      lineage = {
        field: field_name,
        changes: [
          { from: "old@test.com", to: "new@test.com", at: Time.current }
        ]
      }

      flow = mock("flow")
      flow.stubs(:data_lineage).returns(lineage)
      EventFlow.stubs(:new).returns(flow)

      get :data_lineage, params: {
        field_name: field_name,
        model_class: model_class
      }, format: :json

      assert_response :success

      json = JSON.parse(response.body)
      assert_equal field_name, json["field"]
      assert_equal 1, json["changes"].size
    end

    def test_data_lineage_calls_event_flow
      field_name = "phone"
      model_class = "Contact"

      flow = mock("flow")
      flow.expects(:data_lineage).with(field_name, model_class).returns({})
      EventFlow.stubs(:new).returns(flow)

      get :data_lineage, params: {
        field_name: field_name,
        model_class: model_class
      }, format: :json
    end

    # Tests for pii_detection action
    def test_pii_detection_scans_all_events
      mock_events = [
        create_mock_event({ email: "test@test.com" }),
        create_mock_event({ name: "John" }),
        create_mock_event({ ssn: "123-45-6789" })
      ]

      @event_store.stubs(:read).returns(stub(to_a: mock_events))

      pii_inventory = {
        email: ["test@test.com"],
        ssn: ["123-45-6789"]
      }
      Privacy::PIIDetector.stubs(:extract_from_event_stream).returns(pii_inventory)
      Privacy::PIIDetector.stubs(:detect).returns([])

      get :pii_detection, format: :json
      assert_response :success

      json = JSON.parse(response.body)
      assert_equal 3, json["total_events"]
      assert json.key?("pii_inventory")
      assert json.key?("summary")
    end

    def test_pii_detection_categorizes_sensitive_pii
      # Create mock events with PII data
      mock_event = create_mock_event({
        email: "test@test.com",
        ssn: "123-45-6789",
        credit_card: "4111-1111-1111-1111"
      })
      @event_store.stubs(:read).returns(stub(to_a: [mock_event]))

      # Stub detect to return hash with :type keys (as the controller expects)
      pii_result = {
        email: { type: :email, value: "test@test.com" },
        ssn: { type: :ssn, value: "123-45-6789" },
        credit_card: { type: :credit_card, value: "4111-1111-1111-1111" }
      }
      Privacy::PIIDetector.stubs(:detect).returns(pii_result)

      get :pii_detection, format: :json

      json = JSON.parse(response.body)
      assert_includes json["summary"]["sensitive_pii"], "ssn"
      assert_includes json["summary"]["sensitive_pii"], "credit_card"
      assert_includes json["summary"]["contact_pii"], "email"
    end

    def test_pii_detection_counts_events_with_pii
      mock_event_with_pii = create_mock_event({ email: "test@test.com" })
      mock_event_without_pii = create_mock_event({ status: "active" })

      @event_store.stubs(:read).returns(stub(to_a: [mock_event_with_pii, mock_event_without_pii]))

      Privacy::PIIDetector.stubs(:extract_from_event_stream).returns({})
      Privacy::PIIDetector.stubs(:detect).with(mock_event_with_pii.attributes).returns([:email])
      Privacy::PIIDetector.stubs(:detect).with(mock_event_without_pii.attributes).returns([])

      get :pii_detection, format: :json

      json = JSON.parse(response.body)
      assert_equal 2, json["total_events"]
      assert_equal 1, json["events_with_pii"]
    end

    def test_pii_detection_with_no_pii
      mock_events = [create_mock_event({ status: "active" })]
      @event_store.stubs(:read).returns(stub(to_a: mock_events))

      Privacy::PIIDetector.stubs(:extract_from_event_stream).returns({})
      Privacy::PIIDetector.stubs(:detect).returns([])

      get :pii_detection, format: :json

      json = JSON.parse(response.body)
      assert_equal 1, json["total_events"]
      assert_equal 0, json["events_with_pii"]
      assert_equal [], json["pii_categories"]
    end

    # ===========================================================================
    # Tests for PII inventory data structure (model_class and value keys)
    # ===========================================================================

    def test_pii_detection_inventory_includes_model_class_key
      # Create mock event with proper data structure
      mock_event = mock("event")
      mock_event.stubs(:respond_to?).returns(false)
      mock_event.stubs(:respond_to?).with(:attributes).returns(true)
      mock_event.stubs(:respond_to?).with(:data).returns(true)
      mock_event.stubs(:respond_to?).with(:model_class).returns(false)
      mock_event.stubs(:attributes).returns({ email: "test@test.com" })
      mock_event.stubs(:data).returns({
        attributes: { email: "test@test.com" },
        model_class: "User"
      })

      @event_store.stubs(:read).returns(stub(to_a: [mock_event]))

      # Let the real PIIDetector run
      get :pii_detection, format: :json

      json = JSON.parse(response.body)
      inventory = json["pii_inventory"]

      # Check that inventory uses model_class key (not model)
      assert inventory["email"]&.any?, "Should have email in inventory"
      first_item = inventory["email"].first
      assert first_item.key?("model_class"), "Inventory item should have 'model_class' key"
      refute first_item.key?("model"), "Inventory item should NOT have 'model' key (use model_class instead)"
    end

    def test_pii_detection_inventory_includes_value_key
      mock_event = mock("event")
      mock_event.stubs(:respond_to?).returns(false)
      mock_event.stubs(:respond_to?).with(:attributes).returns(true)
      mock_event.stubs(:respond_to?).with(:data).returns(true)
      mock_event.stubs(:respond_to?).with(:model_class).returns(false)
      mock_event.stubs(:attributes).returns({ email: "sample@example.com" })
      mock_event.stubs(:data).returns({
        attributes: { email: "sample@example.com" },
        model_class: "Contact"
      })

      @event_store.stubs(:read).returns(stub(to_a: [mock_event]))

      get :pii_detection, format: :json

      json = JSON.parse(response.body)
      inventory = json["pii_inventory"]

      # Check that inventory includes the value for sample display
      assert inventory["email"]&.any?, "Should have email in inventory"
      first_item = inventory["email"].first
      assert first_item.key?("value"), "Inventory item should have 'value' key for sample display"
      assert_equal "sample@example.com", first_item["value"]
    end

    def test_pii_detection_inventory_structure_complete
      mock_event = mock("event")
      mock_event.stubs(:respond_to?).returns(false)
      mock_event.stubs(:respond_to?).with(:attributes).returns(true)
      mock_event.stubs(:respond_to?).with(:data).returns(true)
      mock_event.stubs(:respond_to?).with(:model_class).returns(false)
      mock_event.stubs(:attributes).returns({ vat_number: "EL123456789" })
      mock_event.stubs(:data).returns({
        attributes: { vat_number: "EL123456789" },
        model_class: "Invoice"
      })

      @event_store.stubs(:read).returns(stub(to_a: [mock_event]))

      get :pii_detection, format: :json

      json = JSON.parse(response.body)
      inventory = json["pii_inventory"]

      # Verify the complete structure for identifier (vat_number)
      assert inventory["identifier"]&.any?, "Should have identifier in inventory"
      item = inventory["identifier"].first
      assert_equal "vat_number", item["field"].to_s
      assert_equal "Invoice", item["model_class"]
      assert_equal "EL123456789", item["value"]
    end

    # ===========================================================================
    # Tests for policy action (HTML view rendering)
    # ===========================================================================

    def test_policy_renders_without_syntax_error
      # This test ensures the policy.html.erb template compiles correctly
      # Catches bugs like using 'unless...elsif' which is invalid Ruby syntax
      get :policy

      assert_response :success
      assert_select ".lyra-policy" # Verify the main container renders
    end

    def test_policy_shows_pam_dsl_not_available_when_disabled
      # Temporarily stub PAM DSL availability on PrivacyController (it has its own implementation)
      Lyra::PrivacyController.any_instance.stubs(:pam_dsl_available?).returns(false)

      get :policy

      assert_response :success
      assert_match(/PAM DSL Not Available/i, response.body)
    end

    def test_policy_shows_policies_when_available
      # Stub PAM DSL with policies
      mock_policy = mock("policy")
      mock_policy.stubs(:respond_to?).returns(true)
      mock_policy.stubs(:to_h).returns({})
      mock_policy.stubs(:fields).returns({})
      mock_policy.stubs(:purposes).returns({})
      mock_policy.stubs(:sensitive_fields).returns([])
      mock_policy.stubs(:restricted_fields).returns([])
      mock_policy.stubs(:retention_policy).returns({})

      mock_registry = mock("registry")
      mock_registry.stubs(:policies).returns({ test_policy: mock_policy })

      PamDsl.stubs(:respond_to?).with(:registry).returns(true)
      PamDsl.stubs(:registry).returns(mock_registry)

      get :policy

      assert_response :success
      assert_select ".policy-card"
    end

    private

    def create_mock_event(attributes)
      event = mock("event_#{rand(1000)}")
      event.stubs(:attributes).returns(attributes)
      event
    end
  end
end
