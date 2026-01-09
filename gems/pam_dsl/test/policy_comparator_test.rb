# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "tmpdir"

module PamDsl
  class PolicyComparatorTest < Minitest::Test
    def setup
      PamDsl.reset!
      define_test_policies
    end

    def teardown
      PamDsl.reset!
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Initialization Tests
    # ─────────────────────────────────────────────────────────────────────────

    def test_initializes_with_two_policy_names
      comparator = PolicyComparator.new(:policy_a, :policy_b)

      assert_equal :policy_a, comparator.name1
      assert_equal :policy_b, comparator.name2
      refute_nil comparator.policy1
      refute_nil comparator.policy2
    end

    def test_raises_error_for_nonexistent_policy
      assert_raises(PolicyNotFoundError) do
        PolicyComparator.new(:policy_a, :nonexistent)
      end
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Summary Tests
    # ─────────────────────────────────────────────────────────────────────────

    def test_summary_returns_policy_names
      comparator = PolicyComparator.new(:policy_a, :policy_b)
      summary = comparator.summary

      assert_equal :policy_a, summary[:first][:name]
      assert_equal :policy_b, summary[:second][:name]
    end

    def test_summary_returns_field_counts
      comparator = PolicyComparator.new(:policy_a, :policy_b)
      summary = comparator.summary

      assert_equal 3, summary[:first][:fields]  # email, phone, ssn
      assert_equal 2, summary[:second][:fields] # email, address
    end

    def test_summary_returns_purpose_counts
      comparator = PolicyComparator.new(:policy_a, :policy_b)
      summary = comparator.summary

      assert_equal 2, summary[:first][:purposes]  # auth, marketing
      assert_equal 1, summary[:second][:purposes] # billing
    end

    def test_summary_returns_retention_rule_counts
      comparator = PolicyComparator.new(:policy_a, :policy_b)
      summary = comparator.summary

      assert_equal 1, summary[:first][:retention_rules]  # User
      assert_equal 1, summary[:second][:retention_rules] # Order
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Field Comparison Tests
    # ─────────────────────────────────────────────────────────────────────────

    def test_field_comparison_finds_common_fields
      comparator = PolicyComparator.new(:policy_a, :policy_b)
      comparison = comparator.field_comparison

      assert_includes comparison[:common], :email
    end

    def test_field_comparison_finds_fields_only_in_first
      comparator = PolicyComparator.new(:policy_a, :policy_b)
      comparison = comparator.field_comparison

      assert_includes comparison[:only_in_first], :phone
      assert_includes comparison[:only_in_first], :ssn
    end

    def test_field_comparison_finds_fields_only_in_second
      comparator = PolicyComparator.new(:policy_a, :policy_b)
      comparison = comparator.field_comparison

      assert_includes comparison[:only_in_second], :address
    end

    def test_field_comparison_returns_sorted_arrays
      comparator = PolicyComparator.new(:policy_a, :policy_b)
      comparison = comparator.field_comparison

      assert_equal comparison[:only_in_first], comparison[:only_in_first].sort
    end

    def test_field_matches_returns_true_for_matching_fields
      # Both policies have email with same type and sensitivity
      comparator = PolicyComparator.new(:policy_a, :policy_b)

      assert comparator.field_matches?(:email)
    end

    def test_field_matches_returns_false_for_mismatched_type
      # Create policies with same field but different types
      PamDsl.define_policy :type_mismatch_a do
        field :data, type: :email, sensitivity: :internal
      end
      PamDsl.define_policy :type_mismatch_b do
        field :data, type: :phone, sensitivity: :internal
      end

      comparator = PolicyComparator.new(:type_mismatch_a, :type_mismatch_b)

      refute comparator.field_matches?(:data)
    end

    def test_field_matches_returns_false_for_mismatched_sensitivity
      PamDsl.define_policy :sensitivity_mismatch_a do
        field :data, type: :email, sensitivity: :internal
      end
      PamDsl.define_policy :sensitivity_mismatch_b do
        field :data, type: :email, sensitivity: :restricted
      end

      comparator = PolicyComparator.new(:sensitivity_mismatch_a, :sensitivity_mismatch_b)

      refute comparator.field_matches?(:data)
    end

    def test_field_matches_returns_false_for_nonexistent_field
      comparator = PolicyComparator.new(:policy_a, :policy_b)

      refute comparator.field_matches?(:nonexistent)
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Purpose Comparison Tests
    # ─────────────────────────────────────────────────────────────────────────

    def test_purpose_comparison_returns_first_policy_purposes
      comparator = PolicyComparator.new(:policy_a, :policy_b)
      comparison = comparator.purpose_comparison

      purpose_names = comparison[:first].map { |p| p[:name] }
      assert_includes purpose_names, :authentication
      assert_includes purpose_names, :marketing
    end

    def test_purpose_comparison_returns_second_policy_purposes
      comparator = PolicyComparator.new(:policy_a, :policy_b)
      comparison = comparator.purpose_comparison

      purpose_names = comparison[:second].map { |p| p[:name] }
      assert_includes purpose_names, :billing
    end

    def test_purpose_comparison_includes_legal_basis
      comparator = PolicyComparator.new(:policy_a, :policy_b)
      comparison = comparator.purpose_comparison

      auth_purpose = comparison[:first].find { |p| p[:name] == :authentication }
      assert_equal :contract, auth_purpose[:legal_basis]
    end

    def test_purpose_comparison_includes_required_fields
      comparator = PolicyComparator.new(:policy_a, :policy_b)
      comparison = comparator.purpose_comparison

      auth_purpose = comparison[:first].find { |p| p[:name] == :authentication }
      assert_includes auth_purpose[:required_fields], :email
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Retention Comparison Tests
    # ─────────────────────────────────────────────────────────────────────────

    def test_retention_comparison_returns_default_durations
      comparator = PolicyComparator.new(:policy_a, :policy_b)
      comparison = comparator.retention_comparison

      assert_equal 5.years, comparison[:first][:default_duration]
      assert_equal 7.years, comparison[:second][:default_duration]
    end

    def test_retention_comparison_returns_rules_counts
      comparator = PolicyComparator.new(:policy_a, :policy_b)
      comparison = comparator.retention_comparison

      assert_equal 1, comparison[:first][:rules_count]
      assert_equal 1, comparison[:second][:rules_count]
    end

    def test_retention_comparison_with_no_explicit_retention_block
      # Policies without explicit retention block still get default 7 years
      PamDsl.define_policy :no_explicit_retention do
        field :email, type: :email, sensitivity: :internal
      end

      comparator = PolicyComparator.new(:policy_a, :no_explicit_retention)
      comparison = comparator.retention_comparison

      # Default retention is 7 years even without explicit block
      assert_equal 7.years, comparison[:second][:default_duration]
      assert_equal 0, comparison[:second][:rules_count]
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Report Generation Tests
    # ─────────────────────────────────────────────────────────────────────────

    def test_generate_report_returns_markdown_string
      comparator = PolicyComparator.new(:policy_a, :policy_b)
      report = comparator.generate_report

      assert_kind_of String, report
      assert report.start_with?("# PAM DSL Policy Comparison Report")
    end

    def test_generate_report_includes_policy_names
      comparator = PolicyComparator.new(:policy_a, :policy_b)
      report = comparator.generate_report

      assert_includes report, "**policy_a**"
      assert_includes report, "**policy_b**"
    end

    def test_generate_report_includes_summary_section
      comparator = PolicyComparator.new(:policy_a, :policy_b)
      report = comparator.generate_report

      assert_includes report, "## Summary"
      assert_includes report, "| Fields |"
      assert_includes report, "| Purposes |"
      assert_includes report, "| Retention Rules |"
    end

    def test_generate_report_includes_field_comparison_section
      comparator = PolicyComparator.new(:policy_a, :policy_b)
      report = comparator.generate_report

      assert_includes report, "## Field Comparison"
      assert_includes report, "### Common Fields"
      assert_includes report, "### Only in policy_a"
      assert_includes report, "### Only in policy_b"
    end

    def test_generate_report_includes_purpose_comparison_section
      comparator = PolicyComparator.new(:policy_a, :policy_b)
      report = comparator.generate_report

      assert_includes report, "## Purpose Comparison"
      assert_includes report, "### policy_a Purposes"
      assert_includes report, "### policy_b Purposes"
    end

    def test_generate_report_includes_retention_comparison_section
      comparator = PolicyComparator.new(:policy_a, :policy_b)
      report = comparator.generate_report

      assert_includes report, "## Retention Comparison"
      assert_includes report, "| Policy | Default Duration |"
    end

    def test_generate_report_shows_match_indicators
      comparator = PolicyComparator.new(:policy_a, :policy_b)
      report = comparator.generate_report

      # email field should match
      assert_includes report, "| email |"
      assert_match(/email.*✓/, report)
    end

    def test_generate_report_writes_to_file_when_output_path_given
      Dir.mktmpdir do |dir|
        output_path = File.join(dir, "comparison.md")
        comparator = PolicyComparator.new(:policy_a, :policy_b)

        report = comparator.generate_report(output_path: output_path)

        assert File.exist?(output_path)
        assert_equal report, File.read(output_path)
      end
    end

    def test_generate_report_creates_parent_directories
      Dir.mktmpdir do |dir|
        output_path = File.join(dir, "nested", "path", "comparison.md")
        comparator = PolicyComparator.new(:policy_a, :policy_b)

        comparator.generate_report(output_path: output_path)

        assert File.exist?(output_path)
      end
    end

    def test_generate_report_handles_empty_common_fields
      PamDsl.define_policy :disjoint_a do
        field :email, type: :email, sensitivity: :internal
      end
      PamDsl.define_policy :disjoint_b do
        field :phone, type: :phone, sensitivity: :internal
      end

      comparator = PolicyComparator.new(:disjoint_a, :disjoint_b)
      report = comparator.generate_report

      assert_includes report, "_No common fields_"
    end

    def test_generate_report_handles_no_unique_fields
      PamDsl.define_policy :identical_a do
        field :email, type: :email, sensitivity: :internal
      end
      PamDsl.define_policy :identical_b do
        field :email, type: :email, sensitivity: :internal
      end

      comparator = PolicyComparator.new(:identical_a, :identical_b)
      report = comparator.generate_report

      assert_includes report, "### Only in identical_a (0)"
      assert_includes report, "_None_"
    end

    # ─────────────────────────────────────────────────────────────────────────
    # to_h Tests
    # ─────────────────────────────────────────────────────────────────────────

    def test_to_h_returns_hash
      comparator = PolicyComparator.new(:policy_a, :policy_b)
      result = comparator.to_h

      assert_kind_of Hash, result
    end

    def test_to_h_includes_generated_timestamp
      comparator = PolicyComparator.new(:policy_a, :policy_b)
      result = comparator.to_h

      assert result.key?(:generated_at)
      assert_match(/\d{4}-\d{2}-\d{2}T/, result[:generated_at])
    end

    def test_to_h_includes_policy_names
      comparator = PolicyComparator.new(:policy_a, :policy_b)
      result = comparator.to_h

      assert_equal %w[policy_a policy_b], result[:policies]
    end

    def test_to_h_includes_summary
      comparator = PolicyComparator.new(:policy_a, :policy_b)
      result = comparator.to_h

      assert result.key?(:summary)
      assert result[:summary].key?(:first)
      assert result[:summary].key?(:second)
    end

    def test_to_h_includes_field_comparison_detail
      comparator = PolicyComparator.new(:policy_a, :policy_b)
      result = comparator.to_h

      assert result.key?(:fields)
      assert result[:fields].key?(:common)
      assert result[:fields].key?(:only_in_first)
      assert result[:fields].key?(:only_in_second)
    end

    def test_to_h_common_fields_include_match_status
      comparator = PolicyComparator.new(:policy_a, :policy_b)
      result = comparator.to_h

      email_comparison = result[:fields][:common].find { |f| f[:name] == :email }
      assert email_comparison.key?(:matches)
      assert email_comparison[:matches] # email should match
    end

    def test_to_h_includes_purpose_comparison
      comparator = PolicyComparator.new(:policy_a, :policy_b)
      result = comparator.to_h

      assert result.key?(:purposes)
      assert result[:purposes].key?(:first)
      assert result[:purposes].key?(:second)
    end

    def test_to_h_includes_retention_comparison
      comparator = PolicyComparator.new(:policy_a, :policy_b)
      result = comparator.to_h

      assert result.key?(:retention)
      assert result[:retention].key?(:first)
      assert result[:retention].key?(:second)
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Duration Formatting Tests
    # ─────────────────────────────────────────────────────────────────────────

    def test_report_formats_years_correctly
      comparator = PolicyComparator.new(:policy_a, :policy_b)
      report = comparator.generate_report

      assert_includes report, "5 years"
      assert_includes report, "7 years"
    end

    def test_report_shows_default_duration_when_no_explicit_retention
      # Policies without explicit retention block still get default 7 years
      PamDsl.define_policy :implicit_retention_policy do
        field :email, type: :email, sensitivity: :internal
      end

      comparator = PolicyComparator.new(:policy_a, :implicit_retention_policy)
      report = comparator.generate_report

      # Should show 7 years (the default) not N/A
      assert_includes report, "| implicit_retention_policy | 7 years |"
    end

    private

    def define_test_policies
      PamDsl.define_policy :policy_a do
        field :email, type: :email, sensitivity: :confidential
        field :phone, type: :phone, sensitivity: :confidential
        field :ssn, type: :ssn, sensitivity: :restricted

        purpose :authentication do
          describe "User login"
          basis :contract
          requires :email
        end

        purpose :marketing do
          describe "Marketing communications"
          basis :consent
          requires :email
          optionally :phone
        end

        retention do
          default 5.years

          for_model "User" do
            keep_for 7.years
            on_expiry :anonymize
          end
        end
      end

      PamDsl.define_policy :policy_b do
        field :email, type: :email, sensitivity: :confidential
        field :address, type: :address, sensitivity: :confidential

        purpose :billing do
          describe "Payment processing"
          basis :contract
          requires :email, :address
        end

        retention do
          default 7.years

          for_model "Order" do
            keep_for 10.years
            on_expiry :archive
          end
        end
      end
    end
  end
end
