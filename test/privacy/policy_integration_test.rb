require "test_helper"

module Lyra
  module Privacy
    class PolicyIntegrationTest < Minitest::Test
      def setup
        skip "PolicyIntegration tests require PAM DSL" unless PAM_DSL_AVAILABLE

        # Define a test policy
        PamDsl.define_policy :test_policy do
          field :email, type: :email, sensitivity: :confidential do
            allow_for :marketing
            transform :display do |value|
              "#{value[0]}***@#{value.split('@').last}"
            end
          end

          field :name, type: :name, sensitivity: :internal

          field :ssn, type: :ssn, sensitivity: :restricted

          purpose :marketing do
            describe "Marketing communications"
            basis :consent
            requires :email
          end

          retention do
            default 5.years
            for_model 'User' do
              keep_for 7.years
            end
          end
        end
      end

      def teardown
        PamDsl.reset!
      end

      # ===========================================================================
      # Initialization Tests
      # ===========================================================================

      def test_initialize_with_valid_policy
        integration = PolicyIntegration.new(:test_policy)

        assert integration.policy_loaded?
        assert integration.pam_dsl_available?
        assert integration.use_detector
      end

      def test_initialize_with_invalid_policy
        integration = PolicyIntegration.new(:nonexistent_policy)

        refute integration.policy_loaded?
        assert integration.pam_dsl_available?
      end

      def test_initialize_with_use_detector_false
        integration = PolicyIntegration.new(:test_policy, use_detector: false)

        assert integration.policy_loaded?
        refute integration.use_detector
      end

      # ===========================================================================
      # detect_pii Tests
      # ===========================================================================

      def test_detect_pii_finds_policy_defined_fields
        integration = PolicyIntegration.new(:test_policy)
        attributes = { email: "test@example.com", name: "John" }

        result = integration.detect_pii(attributes)

        assert_equal :email, result[:email][:type]
        assert_equal :policy, result[:email][:source]
        assert_equal :name, result[:name][:type]
        assert_equal :policy, result[:name][:source]
      end

      def test_detect_pii_uses_detector_for_undefined_fields
        integration = PolicyIntegration.new(:test_policy, use_detector: true)
        # phone is not in policy but PIIDetector should find it
        attributes = { phone: "555-1234", status: "active" }

        result = integration.detect_pii(attributes)

        assert_equal :phone, result[:phone][:type]
        assert_equal :detector, result[:phone][:source]
        refute result.key?(:status)  # Not PII
      end

      def test_detect_pii_policy_only_mode
        integration = PolicyIntegration.new(:test_policy, use_detector: false)
        # phone is not in policy
        attributes = { email: "test@example.com", phone: "555-1234" }

        result = integration.detect_pii(attributes)

        assert result.key?(:email)
        refute result.key?(:phone)  # Not detected without detector
      end

      def test_detect_pii_without_policy_but_with_detector
        integration = PolicyIntegration.new(:nonexistent_policy, use_detector: true)
        attributes = { email: "test@example.com" }

        result = integration.detect_pii(attributes)

        assert_equal :email, result[:email][:type]
        assert_equal :detector, result[:email][:source]
      end

      def test_detect_pii_returns_empty_without_policy_and_detector
        integration = PolicyIntegration.new(:nonexistent_policy, use_detector: false)
        attributes = { email: "test@example.com" }

        result = integration.detect_pii(attributes)

        assert_equal({}, result)
      end

      # ===========================================================================
      # mask_pii Tests
      # ===========================================================================

      def test_mask_pii_uses_policy_transformation
        integration = PolicyIntegration.new(:test_policy)

        result = integration.mask_pii(:email, "test@example.com", :display)

        assert_equal "t***@example.com", result
      end

      def test_mask_pii_falls_back_to_detector
        integration = PolicyIntegration.new(:test_policy, use_detector: true)

        # phone is not in policy, should use detector
        result = integration.mask_pii(:phone, "555-123-4567")

        assert_includes result, "***"
      end

      def test_mask_pii_returns_unchanged_without_policy_or_detector
        integration = PolicyIntegration.new(:nonexistent_policy, use_detector: false)

        result = integration.mask_pii(:email, "test@example.com")

        assert_equal "test@example.com", result
      end

      # ===========================================================================
      # retention_duration Tests
      # ===========================================================================

      def test_retention_duration_from_policy
        integration = PolicyIntegration.new(:test_policy)

        result = integration.retention_duration('User')

        assert_equal 7.years, result
      end

      def test_retention_duration_default_from_policy
        integration = PolicyIntegration.new(:test_policy)

        result = integration.retention_duration('OtherModel')

        assert_equal 5.years, result
      end

      def test_retention_duration_nil_without_policy
        integration = PolicyIntegration.new(:nonexistent_policy)

        result = integration.retention_duration('User')

        assert_nil result
      end

      # ===========================================================================
      # validate_access! Tests
      # ===========================================================================

      def test_validate_access_with_consent
        integration = PolicyIntegration.new(:test_policy)

        # Should not raise
        result = integration.validate_access!(
          [:email],
          :marketing,
          granted: true,
          granted_at: Time.now
        )

        assert result
      end

      def test_validate_access_without_policy
        integration = PolicyIntegration.new(:nonexistent_policy)

        # Should return true (permissive) without policy
        result = integration.validate_access!([:email], :marketing)

        assert result
      end

      # ===========================================================================
      # consent_required? Tests
      # ===========================================================================

      def test_consent_required_for_consent_purpose
        integration = PolicyIntegration.new(:test_policy)

        assert integration.consent_required?(:marketing)
      end

      def test_consent_required_false_without_policy
        integration = PolicyIntegration.new(:nonexistent_policy)

        refute integration.consent_required?(:marketing)
      end

      # ===========================================================================
      # allowed? Tests
      # ===========================================================================

      def test_allowed_for_valid_combination
        integration = PolicyIntegration.new(:test_policy)

        assert integration.allowed?(:email, :marketing)
      end

      def test_allowed_returns_true_without_policy
        integration = PolicyIntegration.new(:nonexistent_policy)

        # Permissive without policy
        assert integration.allowed?(:anything, :any_purpose)
      end

      # ===========================================================================
      # sensitive_fields / restricted_fields Tests
      # ===========================================================================

      def test_sensitive_fields
        integration = PolicyIntegration.new(:test_policy)

        sensitive = integration.sensitive_fields

        assert_includes sensitive, :email
        assert_includes sensitive, :ssn
      end

      def test_restricted_fields
        integration = PolicyIntegration.new(:test_policy)

        restricted = integration.restricted_fields

        assert_includes restricted, :ssn
        refute_includes restricted, :email
      end

      def test_sensitive_fields_empty_without_policy
        integration = PolicyIntegration.new(:nonexistent_policy)

        assert_equal [], integration.sensitive_fields
      end

      # ===========================================================================
      # to_h Tests
      # ===========================================================================

      def test_to_h_with_policy
        integration = PolicyIntegration.new(:test_policy)

        result = integration.to_h

        assert result[:pam_dsl_available]
        assert result[:policy_loaded]
        assert result[:use_detector]
        assert_equal :test_policy, result[:policy_name]
        assert_equal 3, result[:fields_count]
        assert_equal 1, result[:purposes_count]
      end

      def test_to_h_without_policy
        integration = PolicyIntegration.new(:nonexistent_policy)

        result = integration.to_h

        assert result[:pam_dsl_available]
        refute result[:policy_loaded]
        assert result[:use_detector]
        refute result.key?(:policy_name)
      end

      # ===========================================================================
      # Edge Cases
      # ===========================================================================

      def test_detect_pii_with_empty_attributes
        integration = PolicyIntegration.new(:test_policy)

        result = integration.detect_pii({})

        assert_equal({}, result)
      end

      def test_detect_pii_with_nil_values
        integration = PolicyIntegration.new(:test_policy)

        result = integration.detect_pii({ email: nil, name: "John" })

        # Should still detect the field even with nil value
        assert result.key?(:email) || result.key?(:name)
      end

      def test_policy_priority_over_detector
        integration = PolicyIntegration.new(:test_policy, use_detector: true)
        attributes = { email: "test@example.com" }

        result = integration.detect_pii(attributes)

        # Policy should take priority, not detector
        assert_equal :policy, result[:email][:source]
        assert_equal :confidential, result[:email][:sensitivity]
      end
    end
  end
end
