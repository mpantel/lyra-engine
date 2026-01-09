require "test_helper"

module Lyra
  module Privacy
    class PIIDetectorTest < Minitest::Test
      def setup
        skip "PIIDetector tests require PAM DSL" unless PAM_DSL_AVAILABLE
      end

      def test_detect_email_field
        assert PIIDetector.contains_pii?(:email)
        assert PIIDetector.contains_pii?("user_email")
        assert PIIDetector.contains_pii?(:contact_email)
      end

      def test_detect_phone_field
        # These match because 'phone', 'mobile', 'cell', 'telephone' appear as complete words
        assert PIIDetector.contains_pii?("telephone")
        assert PIIDetector.contains_pii?("mobile")
        assert PIIDetector.contains_pii?("cell")
      end

      def test_detect_ssn_field
        # These match because the patterns appear as complete words
        assert PIIDetector.contains_pii?("social_security")
        assert PIIDetector.contains_pii?("national_id")
        assert PIIDetector.contains_pii?("ssn")
      end

      def test_detect_address_fields
        # These match because 'street', 'address', 'city' appear as words
        assert PIIDetector.contains_pii?("street")
        assert PIIDetector.contains_pii?("address")
        assert PIIDetector.contains_pii?("city")
      end

      def test_detect_name_fields
        assert PIIDetector.contains_pii?(:first_name)
        assert PIIDetector.contains_pii?(:last_name)
        assert PIIDetector.contains_pii?(:full_name)
      end

      def test_non_pii_fields
        refute PIIDetector.contains_pii?(:id)
        refute PIIDetector.contains_pii?(:created_at)
        refute PIIDetector.contains_pii?(:updated_at)
        refute PIIDetector.contains_pii?(:count)
        refute PIIDetector.contains_pii?(:status)
      end

      # ===========================================================================
      # Exclusion Pattern Tests - ensure timestamp/counter fields are NOT detected
      # ===========================================================================

      def test_excludes_timestamp_fields_with_at_suffix
        # These contain PII keywords but are timestamps, not PII
        refute PIIDetector.contains_pii?(:email_sent_at)
        refute PIIDetector.contains_pii?(:email_verified_at)
        refute PIIDetector.contains_pii?(:phone_verified_at)
        refute PIIDetector.contains_pii?(:name_updated_at)
        refute PIIDetector.contains_pii?(:address_confirmed_at)
      end

      def test_excludes_counter_fields
        refute PIIDetector.contains_pii?(:email_count)
        refute PIIDetector.contains_pii?(:phone_count)
        refute PIIDetector.contains_pii?(:login_count)
      end

      def test_excludes_flag_fields
        refute PIIDetector.contains_pii?(:email_enabled)
        refute PIIDetector.contains_pii?(:phone_verified)
        refute PIIDetector.contains_pii?(:email_confirmed)
        refute PIIDetector.contains_pii?(:notification_sent)
        refute PIIDetector.contains_pii?(:email_sent)
      end

      def test_excludes_prefixed_timestamp_fields
        refute PIIDetector.contains_pii?(:created_email)
        refute PIIDetector.contains_pii?(:updated_phone)
        refute PIIDetector.contains_pii?(:sent_email_id)
      end

      def test_still_detects_actual_pii_fields
        # Ensure exclusions don't break real PII detection
        assert PIIDetector.contains_pii?(:email)
        assert PIIDetector.contains_pii?(:user_email)
        assert PIIDetector.contains_pii?(:contact_email)
        assert PIIDetector.contains_pii?(:primary_email)
        assert PIIDetector.contains_pii?(:phone)
        assert PIIDetector.contains_pii?(:mobile_phone)
      end

      def test_detect_pii_in_data
        data = {
          id: 1,
          name: "Alice",
          email: "alice@example.com",
          status: "active",
          created_at: Time.now
        }

        pii_fields = PIIDetector.detect(data)

        assert_includes pii_fields.keys, :name
        assert_includes pii_fields.keys, :email
        refute_includes pii_fields.keys, :id
        refute_includes pii_fields.keys, :status
      end

      def test_pii_field_details
        data = {
          email: "alice@example.com",
          ssn: "123-45-6789"
        }

        pii_fields = PIIDetector.detect(data)

        assert_equal :email, pii_fields[:email][:type]
        assert_equal "alice@example.com", pii_fields[:email][:value]

        assert_equal :ssn, pii_fields[:ssn][:type]
        assert pii_fields[:ssn][:sensitive]
      end

      def test_mask_email
        masked = PIIDetector.mask("alice@example.com", :email)
        assert_equal "a***@example.com", masked
      end

      def test_mask_phone
        masked = PIIDetector.mask("1234567890", :phone)
        assert_equal "***-***-7890", masked
      end

      def test_mask_ssn
        masked = PIIDetector.mask("123-45-6789", :ssn)
        assert_equal "***REDACTED***", masked
      end

      def test_mask_name
        masked = PIIDetector.mask("Alice Smith", :name)
        assert_equal "Alice ***", masked
      end

      def test_detect_credit_card_field
        assert PIIDetector.contains_pii?(:credit_card)
        assert PIIDetector.contains_pii?(:card_number)
      end

      def test_detect_location_fields
        assert PIIDetector.contains_pii?(:latitude)
        assert PIIDetector.contains_pii?(:longitude)
        assert PIIDetector.contains_pii?(:gps)
      end

      def test_detect_health_fields
        assert PIIDetector.contains_pii?(:medical)
        assert PIIDetector.contains_pii?(:health)
        assert PIIDetector.contains_pii?(:diagnosis)
      end

      def test_detect_financial_fields
        assert PIIDetector.contains_pii?(:salary)
        assert PIIDetector.contains_pii?(:bank_account)
        assert PIIDetector.contains_pii?(:income)
      end

      # ===========================================================================
      # VAT Number and Tax Identifier Tests (added for EU/Greek compliance)
      # ===========================================================================

      def test_detect_vat_number_fields
        # VAT number variations
        assert PIIDetector.contains_pii?(:vat_number)
        assert PIIDetector.contains_pii?("vat_number")
        assert PIIDetector.contains_pii?(:vat)
        assert PIIDetector.contains_pii?("company_vat")
        assert PIIDetector.contains_pii?(:vatNumber)  # camelCase
      end

      def test_detect_greek_tax_number_afm
        # AFM = Greek tax identification number (ΑΦΜ)
        assert PIIDetector.contains_pii?(:afm)
        assert PIIDetector.contains_pii?("afm")
        assert PIIDetector.contains_pii?(:customer_afm)
      end

      def test_vat_number_detected_as_identifier_type
        data = { vat_number: "EL123456789" }
        pii_fields = PIIDetector.detect(data)

        assert_includes pii_fields.keys, :vat_number
        assert_equal :identifier, pii_fields[:vat_number][:type]
        assert_equal "EL123456789", pii_fields[:vat_number][:value]
      end

      def test_afm_detected_as_identifier_type
        data = { afm: "123456789" }
        pii_fields = PIIDetector.detect(data)

        assert_includes pii_fields.keys, :afm
        assert_equal :identifier, pii_fields[:afm][:type]
      end

      def test_vat_number_with_string_keys
        # Ensure detection works with string keys (as stored in events)
        data = { "vat_number" => "EL999888777" }
        pii_fields = PIIDetector.detect(data)

        assert_includes pii_fields.keys, "vat_number"
        assert_equal :identifier, pii_fields["vat_number"][:type]
      end
    end
  end
end
