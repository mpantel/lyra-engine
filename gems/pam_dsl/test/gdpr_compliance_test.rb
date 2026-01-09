require "test_helper"

module PamDsl
  class GDPRComplianceTest < Minitest::Test
    # Mock event class for testing
    MockEvent = Struct.new(:event_id, :data, :metadata, keyword_init: true) do
      def timestamp
        data[:timestamp]
      end

      def operation
        data[:operation]
      end

      def model_class
        data[:model_class]
      end

      def model_id
        data[:model_id]
      end

      def attributes
        data[:attributes] || {}
      end

      def changes
        data[:changes] || {}
      end
    end

    def setup
      @subject_id = 123
      @subject_type = 'User'

      @events = [
        MockEvent.new(
          event_id: "evt-1",
          data: {
            operation: :created,
            model_class: "User",
            model_id: 123,
            timestamp: Time.now - 30.days,
            attributes: { email: "alice@example.com", name: "Alice Smith" }
          },
          metadata: { user_id: 123, source: "registration" }
        ),
        MockEvent.new(
          event_id: "evt-2",
          data: {
            operation: :updated,
            model_class: "User",
            model_id: 123,
            timestamp: Time.now - 15.days,
            attributes: { email: "alice.new@example.com", name: "Alice Smith" },
            changes: { email: ["alice@example.com", "alice.new@example.com"] }
          },
          metadata: { user_id: 123, source: "profile_update" }
        ),
        MockEvent.new(
          event_id: "evt-3",
          data: {
            operation: :created,
            model_class: "Order",
            model_id: 456,
            timestamp: Time.now - 10.days,
            attributes: { user_id: 123, total: 100.00 }
          },
          metadata: { user_id: 123, source: "payment" }
        )
      ]

      @compliance = GDPRCompliance.new(
        subject_id: @subject_id,
        subject_type: @subject_type,
        event_reader: ->(_sid, _stype) { @events }
      )
    end

    # ===========================================================================
    # Initialization Tests
    # ===========================================================================

    def test_initialization
      assert_equal @subject_id, @compliance.subject_id
      assert_equal @subject_type, @compliance.subject_type
    end

    def test_initialization_with_custom_extractors
      custom_compliance = GDPRCompliance.new(
        subject_id: 1,
        event_reader: ->(_sid, _stype) { [] },
        attribute_extractor: ->(e) { e.data[:custom_attrs] || {} }
      )

      assert_instance_of GDPRCompliance, custom_compliance
    end

    # ===========================================================================
    # Data Export (Article 15) Tests
    # ===========================================================================

    def test_data_export_returns_hash
      result = @compliance.data_export
      assert_instance_of Hash, result
    end

    def test_data_export_includes_subject_info
      result = @compliance.data_export

      assert_equal @subject_id, result[:subject][:id]
      assert_equal @subject_type, result[:subject][:type]
    end

    def test_data_export_includes_generated_at
      result = @compliance.data_export
      assert_instance_of Time, result[:generated_at]
    end

    def test_data_export_includes_events
      result = @compliance.data_export

      assert_equal 3, result[:events].count
      assert_equal "evt-1", result[:events][0][:event_id]
    end

    def test_data_export_includes_pii_inventory
      result = @compliance.data_export

      assert_includes result[:pii_inventory].keys, :email
      assert_includes result[:pii_inventory].keys, :name
    end

    def test_data_export_includes_data_lineage
      result = @compliance.data_export

      assert_instance_of Hash, result[:data_lineage]
      assert result[:data_lineage][:email].is_a?(Array)
    end

    # ===========================================================================
    # Right to be Forgotten (Article 17) Tests
    # ===========================================================================

    def test_right_to_be_forgotten_report_structure
      result = @compliance.right_to_be_forgotten_report

      assert_equal @subject_id, result[:subject][:id]
      assert_equal 3, result[:total_events]
      assert result[:events_with_pii] > 0
    end

    def test_right_to_be_forgotten_identifies_affected_models
      result = @compliance.right_to_be_forgotten_report

      assert_includes result[:affected_models], "User"
      assert_includes result[:affected_models], "Order"
    end

    def test_right_to_be_forgotten_recommends_deletion_strategy
      result = @compliance.right_to_be_forgotten_report

      assert_includes [:direct_deletion, :batch_deletion], result[:deletion_strategy]
    end

    # ===========================================================================
    # Portable Export (Article 20) Tests
    # ===========================================================================

    def test_portable_export_json
      result = @compliance.portable_export(format: :json)

      assert_instance_of String, result
      parsed = JSON.parse(result)
      assert_equal "1.0", parsed["version"]
    end

    def test_portable_export_hash
      result = @compliance.portable_export(format: :hash)

      assert_instance_of Hash, result
      assert_equal "1.0", result[:version]
    end

    def test_portable_export_csv
      result = @compliance.portable_export(format: :csv)

      assert_instance_of String, result
      assert_includes result, "Field,Value"
    end

    def test_portable_export_xml
      result = @compliance.portable_export(format: :xml)

      assert_instance_of String, result
      assert_includes result, '<?xml version="1.0"?>'
      assert_includes result, '<data_export>'
    end

    # ===========================================================================
    # Rectification History (Article 16) Tests
    # ===========================================================================

    def test_rectification_history_returns_array
      result = @compliance.rectification_history
      assert_instance_of Array, result
    end

    def test_rectification_history_includes_updates_with_pii
      result = @compliance.rectification_history

      # We have one update event with PII changes
      assert result.any? { |r| r[:changes].key?(:email) }
    end

    def test_rectification_history_identifies_pii_changes
      result = @compliance.rectification_history

      update = result.find { |r| r[:changes].key?(:email) }
      assert update
      assert_includes update[:corrected_fields].keys, :email
    end

    # ===========================================================================
    # Processing Activities (Article 30) Tests
    # ===========================================================================

    def test_processing_activities_returns_array
      result = @compliance.processing_activities
      assert_instance_of Array, result
    end

    def test_processing_activities_groups_by_source
      result = @compliance.processing_activities

      sources = result.map { |a| a[:source] }
      assert_includes sources, "registration"
      assert_includes sources, "payment"
    end

    def test_processing_activities_includes_purpose
      result = @compliance.processing_activities

      registration = result.find { |a| a[:source] == "registration" }
      assert_equal "Account creation and management", registration[:purpose]
    end

    # ===========================================================================
    # Retention Compliance Tests
    # ===========================================================================

    def test_retention_compliance_check_returns_array
      result = @compliance.retention_compliance_check
      assert_instance_of Array, result
    end

    def test_retention_compliance_groups_by_model
      result = @compliance.retention_compliance_check

      models = result.map { |r| r[:model_class] }
      assert_includes models, "User"
      assert_includes models, "Order"
    end

    def test_retention_compliance_shows_status
      result = @compliance.retention_compliance_check

      user_result = result.find { |r| r[:model_class] == "User" }
      assert_includes [:compliant, :requires_action], user_result[:compliance_status]
    end

    def test_retention_compliance_with_custom_policy
      custom_compliance = GDPRCompliance.new(
        subject_id: @subject_id,
        event_reader: ->(_sid, _stype) { @events },
        retention_policy: {
          default: { duration: 1.day },
          'User' => { duration: 1.day }
        }
      )

      result = custom_compliance.retention_compliance_check
      user_result = result.find { |r| r[:model_class] == "User" }

      # Events are older than 1 day, should require action
      assert_equal :requires_action, user_result[:compliance_status]
    end

    # ===========================================================================
    # Consent Audit Tests
    # ===========================================================================

    def test_consent_audit_returns_hash
      result = @compliance.consent_audit

      assert_instance_of Hash, result
      assert_includes result.keys, :current_consents
      assert_includes result.keys, :consent_history
      assert_includes result.keys, :processing_legitimacy
    end

    def test_consent_audit_with_consent_events
      consent_event = MockEvent.new(
        event_id: "consent-1",
        data: {
          operation: :created,
          model_class: "Consent",
          model_id: 789,
          timestamp: Time.now - 60.days,
          consent: true,
          consent_type: "marketing",
          granted: true,
          purpose: "marketing"
        },
        metadata: { user_id: 123 }
      )

      events_with_consent = @events + [consent_event]
      compliance = GDPRCompliance.new(
        subject_id: @subject_id,
        event_reader: ->(_sid, _stype) { events_with_consent }
      )

      result = compliance.consent_audit
      assert result[:consent_history].any?
    end

    # ===========================================================================
    # Full Report Tests
    # ===========================================================================

    def test_full_report_includes_all_sections
      result = @compliance.full_report

      assert_includes result.keys, :data_export
      assert_includes result.keys, :erasure_report
      assert_includes result.keys, :rectification_history
      assert_includes result.keys, :processing_activities
      assert_includes result.keys, :retention_compliance
      assert_includes result.keys, :consent_audit
    end

    # ===========================================================================
    # Edge Cases
    # ===========================================================================

    def test_empty_events
      empty_compliance = GDPRCompliance.new(
        subject_id: 999,
        event_reader: ->(_sid, _stype) { [] }
      )

      result = empty_compliance.data_export
      assert_equal 0, result[:events].count
    end

    def test_events_without_pii
      non_pii_event = MockEvent.new(
        event_id: "evt-nopii",
        data: {
          operation: :created,
          model_class: "Setting",
          model_id: 1,
          timestamp: Time.now,
          attributes: { key: "theme", value: "dark" }
        },
        metadata: { user_id: 123 }
      )

      compliance = GDPRCompliance.new(
        subject_id: @subject_id,
        event_reader: ->(_sid, _stype) { [non_pii_event] }
      )

      result = compliance.right_to_be_forgotten_report
      assert_equal 0, result[:events_with_pii]
    end

    def test_events_with_nil_timestamps
      event_no_timestamp = MockEvent.new(
        event_id: "evt-notime",
        data: {
          operation: :created,
          model_class: "Log",
          model_id: 1,
          timestamp: nil,
          attributes: { message: "test" }
        },
        metadata: {}
      )

      compliance = GDPRCompliance.new(
        subject_id: @subject_id,
        event_reader: ->(_sid, _stype) { [event_no_timestamp] }
      )

      # Should not raise error
      result = compliance.data_export
      assert_instance_of Hash, result
    end
  end
end
