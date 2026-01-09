require "test_helper"
require "stringio"

module PamDsl
  class ReporterTest < Minitest::Test
    def setup
      PamDsl.reset!
      define_test_policy
    end

    def teardown
      PamDsl.reset!
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Initialization Tests
    # ─────────────────────────────────────────────────────────────────────────

    def test_initializes_with_policy_name
      reporter = Reporter.new(:test_policy)

      assert_equal :test_policy, reporter.policy_name
      refute_nil reporter.policy
    end

    def test_initializes_with_options
      reporter = Reporter.new(
        :test_policy,
        organization: "Test Org",
        dpo_contact: "dpo@test.com"
      )

      assert_equal "Test Org", reporter.config.organization
      assert_equal "dpo@test.com", reporter.config.dpo_contact
    end

    def test_initializes_with_custom_output
      output = StringIO.new
      reporter = Reporter.new(:test_policy, output: output)

      assert_equal output, reporter.config.output
    end

    def test_handles_missing_policy_gracefully
      reporter = Reporter.new(:nonexistent_policy)

      assert_nil reporter.policy
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Policy Summary Tests
    # ─────────────────────────────────────────────────────────────────────────

    def test_policy_summary_includes_policy_name
      output = capture_output { |out| Reporter.new(:test_policy, output: out).policy_summary }

      assert_includes output, "Policy Name: test_policy"
    end

    def test_policy_summary_includes_fields
      output = capture_output { |out| Reporter.new(:test_policy, output: out).policy_summary }

      assert_includes output, "PII Fields Defined"
      assert_includes output, "email"
      assert_includes output, "phone"
      assert_includes output, "vat_number"
    end

    def test_policy_summary_includes_field_types
      output = capture_output { |out| Reporter.new(:test_policy, output: out).policy_summary }

      assert_includes output, "email"
      assert_includes output, "phone"
      assert_includes output, "identifier"
    end

    def test_policy_summary_includes_sensitivity_levels
      output = capture_output { |out| Reporter.new(:test_policy, output: out).policy_summary }

      assert_includes output, "confidential"
      assert_includes output, "restricted"
    end

    def test_policy_summary_includes_purposes
      output = capture_output { |out| Reporter.new(:test_policy, output: out).policy_summary }

      assert_includes output, "Processing Purposes"
      assert_includes output, "payment_processing"
      assert_includes output, "invoicing"
    end

    def test_policy_summary_includes_legal_basis
      output = capture_output { |out| Reporter.new(:test_policy, output: out).policy_summary }

      assert_includes output, "contract"
      assert_includes output, "legal_obligation"
    end

    def test_policy_summary_includes_retention_rules
      output = capture_output { |out| Reporter.new(:test_policy, output: out).policy_summary }

      assert_includes output, "Retention Rules"
      assert_includes output, "7 years"
    end

    def test_policy_summary_includes_sensitivity_breakdown
      output = capture_output { |out| Reporter.new(:test_policy, output: out).policy_summary }

      assert_includes output, "Sensitivity Breakdown"
    end

    def test_policy_summary_handles_missing_policy
      output = capture_output { |out| Reporter.new(:nonexistent, output: out).policy_summary }

      assert_includes output, "No policy loaded"
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Article 30 Report Tests
    # ─────────────────────────────────────────────────────────────────────────

    def test_article_30_includes_organization
      reporter = Reporter.new(:test_policy, organization: "Test University")
      output = capture_output { |out| Reporter.new(:test_policy, organization: "Test University", output: out).article_30_report }

      assert_includes output, "GDPR ARTICLE 30"
      assert_includes output, "Test University"
    end

    def test_article_30_includes_dpo_contact
      output = capture_output { |out| Reporter.new(:test_policy, dpo_contact: "privacy@test.edu", output: out).article_30_report }

      assert_includes output, "privacy@test.edu"
    end

    def test_article_30_includes_processing_activities
      output = capture_output { |out| Reporter.new(:test_policy, output: out).article_30_report }

      assert_includes output, "Processing Activities"
      assert_includes output, "Payment Processing"
      assert_includes output, "Invoicing"
    end

    def test_article_30_includes_legal_basis_text
      output = capture_output { |out| Reporter.new(:test_policy, output: out).article_30_report }

      assert_includes output, "GDPR Art. 6(1)(b)"  # Contract
      assert_includes output, "GDPR Art. 6(1)(c)"  # Legal obligation
    end

    def test_article_30_includes_data_subject_rights
      output = capture_output { |out| Reporter.new(:test_policy, output: out).article_30_report }

      assert_includes output, "Data Subject Rights"
      assert_includes output, "Right to Access"
      assert_includes output, "Right to Erasure"
    end

    def test_article_30_includes_technical_measures
      output = capture_output { |out| Reporter.new(:test_policy, output: out).article_30_report }

      assert_includes output, "Technical & Organizational Measures"
      assert_includes output, "Encryption"
      assert_includes output, "Access Control"
    end

    # ─────────────────────────────────────────────────────────────────────────
    # PII Analysis Tests (without event store)
    # ─────────────────────────────────────────────────────────────────────────

    def test_pii_analysis_without_event_store
      output = capture_output { |out| Reporter.new(:test_policy, output: out).pii_analysis }

      assert_includes output, "Event store not configured"
    end

    def test_retention_check_without_event_store
      output = capture_output { |out| Reporter.new(:test_policy, output: out).retention_check }

      assert_includes output, "Event store not configured"
    end

    def test_access_patterns_without_event_store
      output = capture_output { |out| Reporter.new(:test_policy, output: out).access_patterns }

      assert_includes output, "Event store not configured"
    end

    # ─────────────────────────────────────────────────────────────────────────
    # PII Analysis Tests (with mock event store)
    # ─────────────────────────────────────────────────────────────────────────

    def test_pii_analysis_with_events
      events = build_mock_events
      event_store = MockEventStore.new(events)

      output = capture_output do |out|
        Reporter.new(:test_policy, event_store: event_store, output: out).pii_analysis
      end

      assert_includes output, "PII ANALYSIS"
      assert_includes output, "Total events analyzed: 3"
    end

    def test_pii_analysis_detects_pii_fields
      events = build_mock_events
      event_store = MockEventStore.new(events)

      output = capture_output do |out|
        Reporter.new(:test_policy, event_store: event_store, output: out).pii_analysis
      end

      assert_includes output, "PII Field Occurrences"
    end

    def test_retention_check_with_events
      events = build_mock_events
      event_store = MockEventStore.new(events)

      output = capture_output do |out|
        Reporter.new(:test_policy, event_store: event_store, output: out).retention_check
      end

      assert_includes output, "RETENTION COMPLIANCE"
      assert_includes output, "Retention Status by Model"
    end

    def test_retention_check_shows_compliance_status
      events = build_mock_events
      event_store = MockEventStore.new(events)

      output = capture_output do |out|
        Reporter.new(:test_policy, event_store: event_store, output: out).retention_check
      end

      # Should show compliant status for recent events
      assert_match(/compliant/i, output)
    end

    def test_access_patterns_with_events
      events = build_mock_events
      event_store = MockEventStore.new(events)

      output = capture_output do |out|
        Reporter.new(:test_policy, event_store: event_store, output: out).access_patterns
      end

      assert_includes output, "ACCESS PATTERNS"
      assert_includes output, "Access by Operation"
      assert_includes output, "Access by Hour"
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Full Report Tests
    # ─────────────────────────────────────────────────────────────────────────

    def test_full_report_includes_all_sections
      output = capture_output { |out| Reporter.new(:test_policy, output: out).full_report }

      assert_includes output, "PRIVACY COMPLIANCE REPORT"
      assert_includes output, "PAM DSL POLICY SUMMARY"
      assert_includes output, "GDPR ARTICLE 30"
      assert_includes output, "END OF PRIVACY REPORT"
    end

    def test_full_report_includes_metadata
      output = capture_output do |out|
        Reporter.new(:test_policy, organization: "Acme Corp", output: out).full_report
      end

      assert_includes output, "Organization: Acme Corp"
      assert_includes output, "Policy: test_policy"
    end

    def test_full_report_with_event_store_includes_analytics
      events = build_mock_events
      event_store = MockEventStore.new(events)

      output = capture_output do |out|
        Reporter.new(:test_policy, event_store: event_store, output: out).full_report
      end

      assert_includes output, "PII ANALYSIS"
      assert_includes output, "RETENTION COMPLIANCE"
      assert_includes output, "ACCESS PATTERNS"
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Export Tests
    # ─────────────────────────────────────────────────────────────────────────

    def test_to_h_returns_hash
      reporter = Reporter.new(:test_policy)
      result = reporter.to_h

      assert_instance_of Hash, result
      assert result.key?(:generated_at)
      assert result.key?(:organization)
      assert result.key?(:policy)
      assert result.key?(:article_30)
    end

    def test_to_h_includes_policy_data
      reporter = Reporter.new(:test_policy)
      result = reporter.to_h

      assert_equal "test_policy", result[:policy][:name]
      assert result[:policy][:fields].is_a?(Array)
      assert result[:policy][:purposes].is_a?(Array)
    end

    def test_to_h_includes_fields_with_correct_structure
      reporter = Reporter.new(:test_policy)
      result = reporter.to_h

      email_field = result[:policy][:fields].find { |f| f[:name] == "email" }
      refute_nil email_field
      assert_equal "email", email_field[:type]
      assert_equal "confidential", email_field[:sensitivity]
    end

    def test_to_h_includes_purposes_with_correct_structure
      reporter = Reporter.new(:test_policy)
      result = reporter.to_h

      purpose = result[:policy][:purposes].find { |p| p[:name] == "payment_processing" }
      refute_nil purpose
      assert_equal "contract", purpose[:legal_basis]
      assert_includes purpose[:required_fields], "email"
    end

    def test_to_h_with_event_store_includes_analytics
      events = build_mock_events
      event_store = MockEventStore.new(events)

      reporter = Reporter.new(:test_policy, event_store: event_store)
      result = reporter.to_h

      assert result.key?(:events_analysis)
      assert result.key?(:retention_status)
      assert_equal 3, result[:events_analysis][:total_events]
    end

    def test_export_json_creates_file
      reporter = Reporter.new(:test_policy)
      output_path = File.join(Dir.tmpdir, "test_privacy_report_#{Time.now.to_i}.json")

      begin
        # Capture stdout to suppress output
        capture_output { |out| reporter.instance_variable_set(:@config, reporter.config.tap { |c| c.output = out }) }
        reporter.export_json(output_path)

        assert File.exist?(output_path)
        content = JSON.parse(File.read(output_path))
        assert content.key?("generated_at")
        assert content.key?("policy")
      ensure
        File.delete(output_path) if File.exist?(output_path)
      end
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Edge Cases
    # ─────────────────────────────────────────────────────────────────────────

    def test_handles_empty_event_store
      event_store = MockEventStore.new([])

      output = capture_output do |out|
        Reporter.new(:test_policy, event_store: event_store, output: out).pii_analysis
      end

      assert_includes output, "No events found"
    end

    def test_handles_policy_without_purposes
      PamDsl.define_policy(:minimal_policy) do
        field :email, type: :email
      end

      output = capture_output { |out| Reporter.new(:minimal_policy, output: out).policy_summary }

      assert_includes output, "email"
      # Should not crash even without purposes
    end

    def test_handles_policy_without_retention
      PamDsl.define_policy(:no_retention_policy) do
        field :email, type: :email
        purpose :testing
      end

      output = capture_output { |out| Reporter.new(:no_retention_policy, output: out).policy_summary }

      assert_includes output, "Retention Rules"
      assert_includes output, "Default:"
    end

    def test_duration_formatting
      reporter = Reporter.new(:test_policy)

      # Access private method for testing
      assert_equal "7 years", reporter.send(:format_duration, 7.years)
      assert_equal "6 months", reporter.send(:format_duration, 6.months)
      assert_equal "30 days", reporter.send(:format_duration, 30.days)
      assert_equal "N/A", reporter.send(:format_duration, nil)
    end

    def test_legal_basis_text_formatting
      reporter = Reporter.new(:test_policy)

      assert_includes reporter.send(:legal_basis_text, :consent), "GDPR Art. 6(1)(a)"
      assert_includes reporter.send(:legal_basis_text, :contract), "GDPR Art. 6(1)(b)"
      assert_includes reporter.send(:legal_basis_text, :legal_obligation), "GDPR Art. 6(1)(c)"
      assert_includes reporter.send(:legal_basis_text, :legitimate_interests), "GDPR Art. 6(1)(f)"
    end

    private

    def define_test_policy
      PamDsl.define_policy(:test_policy) do
        field :email, type: :email, sensitivity: :confidential do
          transform :display do |value|
            value&.gsub(/(.{2})(.*)(@.*)/) { "#{$1}***#{$3}" }
          end
        end

        field :phone, type: :phone, sensitivity: :confidential
        field :vat_number, type: :identifier, sensitivity: :restricted
        field :ip_address, type: :ip_address, sensitivity: :internal

        purpose :payment_processing do
          describe "Processing payments"
          basis :contract
          requires :email
        end

        purpose :invoicing do
          describe "Generating invoices"
          basis :legal_obligation
          requires :vat_number
        end

        retention do
          default 7.years

          for_model "User" do
            keep_for 7.years
          end

          for_model "Transaction" do
            keep_for 10.years
          end
        end
      end
    end

    def capture_output
      output = StringIO.new
      yield(output)
      output.string
    end

    def build_mock_events
      [
        MockEvent.new(
          event_type: "UserCreated",
          data: { email: "test@example.com", name: "Test User" },
          metadata: { model_class: "User", timestamp: Time.current },
          timestamp: Time.current
        ),
        MockEvent.new(
          event_type: "UserUpdated",
          data: { phone: "555-1234" },
          metadata: { model_class: "User", timestamp: Time.current - 1.hour },
          timestamp: Time.current - 1.hour
        ),
        MockEvent.new(
          event_type: "TransactionCreated",
          data: { amount: 100.0 },
          metadata: { model_class: "Transaction", timestamp: Time.current - 2.hours },
          timestamp: Time.current - 2.hours
        )
      ]
    end

    # Mock event store for testing
    class MockEventStore
      def initialize(events)
        @events = events
      end

      def read
        MockReader.new(@events)
      end
    end

    class MockReader
      def initialize(events)
        @events = events
      end

      def to_a
        @events
      end
    end

    # Mock event for testing
    class MockEvent
      attr_reader :event_type, :data, :metadata, :timestamp

      def initialize(event_type:, data:, metadata:, timestamp:)
        @event_type = event_type
        @data = data
        @metadata = metadata
        @timestamp = timestamp
      end
    end
  end
end
