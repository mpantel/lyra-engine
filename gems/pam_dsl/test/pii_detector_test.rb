require "test_helper"

module PamDsl
  class PIIDetectorTest < Minitest::Test
    # ===========================================================================
    # Basic Detection Tests
    # ===========================================================================

    def test_detect_email_field
      assert PIIDetector.contains_pii?(:email)
      assert PIIDetector.contains_pii?("email")
      assert PIIDetector.contains_pii?(:user_email)
      assert PIIDetector.contains_pii?(:contact_email)
    end

    def test_detect_name_fields
      assert PIIDetector.contains_pii?(:first_name)
      assert PIIDetector.contains_pii?(:firstname)
      assert PIIDetector.contains_pii?(:last_name)
      assert PIIDetector.contains_pii?(:lastname)
      assert PIIDetector.contains_pii?(:full_name)
      assert PIIDetector.contains_pii?(:name)
    end

    def test_detect_phone_fields
      assert PIIDetector.contains_pii?(:phone)
      assert PIIDetector.contains_pii?(:telephone)
      assert PIIDetector.contains_pii?(:mobile)
      assert PIIDetector.contains_pii?(:cell)
      assert PIIDetector.contains_pii?(:phone_number)
    end

    def test_detect_address_fields
      assert PIIDetector.contains_pii?(:address)
      assert PIIDetector.contains_pii?(:street)
      assert PIIDetector.contains_pii?(:city)
      assert PIIDetector.contains_pii?(:postal_code)
      assert PIIDetector.contains_pii?(:zip_code)
    end

    def test_detect_ssn_fields
      assert PIIDetector.contains_pii?(:ssn)
      assert PIIDetector.contains_pii?(:social_security)
      assert PIIDetector.contains_pii?(:social_security_number)
      assert PIIDetector.contains_pii?(:national_id)
    end

    def test_detect_credit_card_fields
      assert PIIDetector.contains_pii?(:credit_card)
      assert PIIDetector.contains_pii?(:card_number)
      assert PIIDetector.contains_pii?(:cvv)
    end

    def test_detect_financial_fields
      assert PIIDetector.contains_pii?(:iban)
      assert PIIDetector.contains_pii?(:bank_account)
      assert PIIDetector.contains_pii?(:salary)
      assert PIIDetector.contains_pii?(:income)
    end

    def test_detect_location_fields
      assert PIIDetector.contains_pii?(:latitude)
      assert PIIDetector.contains_pii?(:longitude)
      assert PIIDetector.contains_pii?(:location)
      assert PIIDetector.contains_pii?(:gps)
    end

    def test_detect_health_fields
      assert PIIDetector.contains_pii?(:medical)
      assert PIIDetector.contains_pii?(:health)
      assert PIIDetector.contains_pii?(:diagnosis)
    end

    def test_detect_biometric_fields
      assert PIIDetector.contains_pii?(:fingerprint)
      assert PIIDetector.contains_pii?(:biometric)
      assert PIIDetector.contains_pii?(:face_id)
    end

    def test_detect_ip_address_fields
      assert PIIDetector.contains_pii?(:ip_address)
      assert PIIDetector.contains_pii?(:remote_ip)
      assert PIIDetector.contains_pii?(:client_ip)
    end

    # ===========================================================================
    # Tax Identifier Tests (VAT, AFM)
    # ===========================================================================

    def test_detect_vat_number_fields
      assert PIIDetector.contains_pii?(:vat_number)
      assert PIIDetector.contains_pii?(:vat_id)
      assert PIIDetector.contains_pii?(:tax_id)
      assert PIIDetector.contains_pii?(:tax_number)
      assert PIIDetector.contains_pii?(:tin)
    end

    def test_detect_greek_tax_number_afm
      # AFM = Greek tax identification number (ΑΦΜ)
      assert PIIDetector.contains_pii?(:afm)
      assert PIIDetector.contains_pii?("afm")
    end

    def test_vat_number_detected_as_identifier_type
      assert_equal :identifier, PIIDetector.pii_type(:vat_number)
      assert_equal :identifier, PIIDetector.pii_type(:afm)
      assert_equal :identifier, PIIDetector.pii_type(:tax_id)
    end

    def test_identifier_is_restricted_sensitivity
      assert_equal :restricted, PIIDetector.sensitivity(:vat_number)
      assert_equal :restricted, PIIDetector.sensitivity(:afm)
    end

    # ===========================================================================
    # Exclusion Pattern Tests
    # ===========================================================================

    def test_excludes_timestamp_fields
      refute PIIDetector.contains_pii?(:created_at)
      refute PIIDetector.contains_pii?(:updated_at)
      refute PIIDetector.contains_pii?(:email_sent_at)
      refute PIIDetector.contains_pii?(:phone_verified_at)
    end

    def test_excludes_counter_fields
      refute PIIDetector.contains_pii?(:email_count)
      refute PIIDetector.contains_pii?(:login_count)
    end

    def test_excludes_amount_fields
      refute PIIDetector.contains_pii?(:vat_amount)
      refute PIIDetector.contains_pii?(:total_amount)
    end

    def test_excludes_flag_fields
      refute PIIDetector.contains_pii?(:email_verified)
      refute PIIDetector.contains_pii?(:email_confirmed)
      refute PIIDetector.contains_pii?(:is_active)
    end

    def test_excludes_foreign_keys
      refute PIIDetector.contains_pii?(:user_id)
      refute PIIDetector.contains_pii?(:order_id)
    end

    def test_excludes_code_fields_except_postal
      refute PIIDetector.contains_pii?(:country_code)
      refute PIIDetector.contains_pii?(:currency_code)
      # But postal_code IS address PII
      assert PIIDetector.contains_pii?(:postal_code)
    end

    def test_non_pii_fields
      refute PIIDetector.contains_pii?(:id)
      refute PIIDetector.contains_pii?(:status)
      refute PIIDetector.contains_pii?(:count)
      refute PIIDetector.contains_pii?(:total)
    end

    # ===========================================================================
    # detect() Method Tests
    # ===========================================================================

    def test_detect_returns_pii_hash
      data = {
        id: 1,
        name: "Alice",
        email: "alice@example.com",
        status: "active"
      }

      pii_fields = PIIDetector.detect(data)

      assert_includes pii_fields.keys, :name
      assert_includes pii_fields.keys, :email
      refute_includes pii_fields.keys, :id
      refute_includes pii_fields.keys, :status
    end

    def test_detect_returns_type_and_value
      data = { email: "alice@example.com" }
      pii_fields = PIIDetector.detect(data)

      assert_equal :email, pii_fields[:email][:type]
      assert_equal "alice@example.com", pii_fields[:email][:value]
      refute pii_fields[:email][:sensitive]
    end

    def test_detect_marks_sensitive_fields
      data = { ssn: "123-45-6789", credit_card: "4111111111111111" }
      pii_fields = PIIDetector.detect(data)

      assert pii_fields[:ssn][:sensitive]
      assert pii_fields[:credit_card][:sensitive]
    end

    def test_detect_includes_sensitivity_level
      data = { email: "test@example.com", ssn: "123-45-6789" }
      pii_fields = PIIDetector.detect(data)

      assert_equal :confidential, pii_fields[:email][:sensitivity]
      assert_equal :restricted, pii_fields[:ssn][:sensitivity]
    end

    # ===========================================================================
    # Masking Tests
    # ===========================================================================

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

    def test_mask_credit_card
      masked = PIIDetector.mask("4111111111111111", :credit_card)
      assert_equal "***REDACTED***", masked
    end

    def test_mask_identifier
      masked = PIIDetector.mask("EL123456789", :identifier)
      assert_equal "***REDACTED***", masked
    end

    def test_mask_name
      masked = PIIDetector.mask("Alice Smith", :name)
      assert_equal "Alice ***", masked
    end

    def test_mask_generic
      masked = PIIDetector.mask("some_value", :location)
      assert_equal "so***ue", masked
    end

    def test_mask_nil_returns_nil
      assert_nil PIIDetector.mask(nil, :email)
    end

    # ===========================================================================
    # Sensitivity Tests
    # ===========================================================================

    def test_sensitive_types
      assert PIIDetector.sensitive?(:ssn)
      assert PIIDetector.sensitive?(:credit_card)
      assert PIIDetector.sensitive?(:financial)
      assert PIIDetector.sensitive?(:health)
      assert PIIDetector.sensitive?(:biometric)
      assert PIIDetector.sensitive?(:identifier)
    end

    def test_non_sensitive_types
      refute PIIDetector.sensitive?(:email)
      refute PIIDetector.sensitive?(:name)
      refute PIIDetector.sensitive?(:phone)
      refute PIIDetector.sensitive?(:address)
    end

    # ===========================================================================
    # Partial Matching Mode Tests
    # ===========================================================================

    def test_partial_match_enabled_by_default
      PIIDetector.reset!
      assert PIIDetector.partial_match
    end

    def test_partial_match_detects_prefixed_fields
      # With partial matching (default), prefixed field names are detected
      assert PIIDetector.contains_pii?(:customer_email)
      assert PIIDetector.contains_pii?(:billing_phone)
      assert PIIDetector.contains_pii?(:primary_address)
      assert PIIDetector.contains_pii?(:user_name)
    end

    def test_partial_match_detects_suffixed_fields
      # With partial matching (default), suffixed field names are detected
      assert PIIDetector.contains_pii?(:home_phone)
      assert PIIDetector.contains_pii?(:work_email)
      assert PIIDetector.contains_pii?(:shipping_address)
    end

    def test_partial_match_detects_camelcase_suffix_boundaries
      # camelCase suffix boundary detection (PII keyword followed by uppercase)
      # e.g., emailAddress, phoneNumber - the PII keyword is at the START
      assert PIIDetector.contains_pii?(:emailAddress)
      assert PIIDetector.contains_pii?(:phoneNumber)
      assert PIIDetector.contains_pii?(:nameFirst)
      assert PIIDetector.contains_pii?(:addressHome)
    end

    def test_partial_match_snake_case_preferred_over_camelcase
      # Note: camelCase prefix detection (e.g., customerEmail) is NOT supported
      # Use snake_case (customer_email) for reliable detection
      # These are documented limitations:
      refute PIIDetector.contains_pii?(:customerEmail)   # Use customer_email instead
      refute PIIDetector.contains_pii?(:billingPhone)    # Use billing_phone instead

      # But snake_case equivalents work:
      assert PIIDetector.contains_pii?(:customer_email)
      assert PIIDetector.contains_pii?(:billing_phone)
    end

    def test_partial_match_does_not_match_partial_words
      # Should NOT match when PII keyword is embedded in a larger word
      refute PIIDetector.contains_pii?(:rename)        # contains "name" but not at boundary
      refute PIIDetector.contains_pii?(:phonetic)      # contains "phone" but not at boundary
      refute PIIDetector.contains_pii?(:metaphone)     # contains "phone" but not at boundary
    end

    # A *_id column is a foreign key (bill_address_id, country_id,
    # stock_location_id were flagged on Solidus), except the identifiers that
    # are personal data themselves.
    def test_partial_match_id_suffix_is_a_foreign_key_unless_a_known_identifier
      refute PIIDetector.contains_pii?(:telephone_id)
      refute PIIDetector.contains_pii?(:bill_address_id)
      refute PIIDetector.contains_pii?(:country_id)
      refute PIIDetector.contains_pii?(:id)
      refute PIIDetector.contains_pii?(:uuid)

      assert_equal :identifier, PIIDetector.pii_type(:vat_id)
      assert_equal :payment_token, PIIDetector.pii_type(:gateway_customer_profile_id)
    end

    def test_partial_match_handles_edge_cases
      # Empty and nil handling
      refute PIIDetector.contains_pii?("")
      refute PIIDetector.contains_pii?(nil.to_s)

      # Single character fields
      refute PIIDetector.contains_pii?(:x)
      refute PIIDetector.contains_pii?(:a)
    end

    def test_exact_match_mode
      # Switch to exact matching
      PIIDetector.partial_match = false

      begin
        # Exact fields should still be detected
        assert PIIDetector.contains_pii?(:email)
        assert PIIDetector.contains_pii?(:phone)
        assert PIIDetector.contains_pii?(:name)

        # But prefixed/suffixed variants should NOT be detected in exact mode
        refute PIIDetector.contains_pii?(:customer_email)
        refute PIIDetector.contains_pii?(:billing_phone)
        refute PIIDetector.contains_pii?(:customer_name)
      ensure
        # Reset to default
        PIIDetector.reset!
      end
    end

    def test_reset_restores_partial_match
      PIIDetector.partial_match = false
      refute PIIDetector.partial_match

      PIIDetector.reset!
      assert PIIDetector.partial_match
    end

    def test_pii_patterns_returns_correct_patterns
      # Default: partial patterns
      assert_equal PIIDetector::PARTIAL_PII_PATTERNS, PIIDetector.pii_patterns

      PIIDetector.partial_match = false
      begin
        assert_equal PIIDetector::EXACT_PII_PATTERNS, PIIDetector.pii_patterns
      ensure
        PIIDetector.reset!
      end
    end

    # ===========================================================================
    # Configuration Option Tests
    # ===========================================================================

    def test_partial_match_can_be_set_to_true_explicitly
      PIIDetector.partial_match = true
      begin
        assert PIIDetector.partial_match
        assert PIIDetector.contains_pii?(:customer_email)
      ensure
        PIIDetector.reset!
      end
    end

    def test_partial_match_can_be_set_to_false
      PIIDetector.partial_match = false
      begin
        refute PIIDetector.partial_match
        refute PIIDetector.contains_pii?(:customer_email)
      ensure
        PIIDetector.reset!
      end
    end

    def test_partial_match_toggle_affects_detect_method
      data = { customer_email: "test@example.com", email: "user@example.com" }

      # Partial mode: both detected
      PIIDetector.partial_match = true
      begin
        result = PIIDetector.detect(data)
        assert_includes result.keys, :customer_email
        assert_includes result.keys, :email
      ensure
        PIIDetector.reset!
      end

      # Exact mode: only exact match detected
      PIIDetector.partial_match = false
      begin
        result = PIIDetector.detect(data)
        refute_includes result.keys, :customer_email
        assert_includes result.keys, :email
      ensure
        PIIDetector.reset!
      end
    end

    def test_partial_match_toggle_affects_pii_type_method
      # Partial mode: prefixed fields have types
      PIIDetector.partial_match = true
      begin
        assert_equal :email, PIIDetector.pii_type(:customer_email)
        assert_equal :phone, PIIDetector.pii_type(:billing_phone)
      ensure
        PIIDetector.reset!
      end

      # Exact mode: prefixed fields return nil
      PIIDetector.partial_match = false
      begin
        assert_nil PIIDetector.pii_type(:customer_email)
        assert_nil PIIDetector.pii_type(:billing_phone)
        # But exact matches still work
        assert_equal :email, PIIDetector.pii_type(:email)
      ensure
        PIIDetector.reset!
      end
    end

    def test_partial_match_toggle_affects_sensitivity_method
      # Partial mode: prefixed fields have sensitivity
      PIIDetector.partial_match = true
      begin
        assert_equal :confidential, PIIDetector.sensitivity(:customer_email)
        assert_equal :restricted, PIIDetector.sensitivity(:user_ssn)
      ensure
        PIIDetector.reset!
      end

      # Exact mode: prefixed fields return nil
      PIIDetector.partial_match = false
      begin
        assert_nil PIIDetector.sensitivity(:customer_email)
        # But exact matches still work
        assert_equal :confidential, PIIDetector.sensitivity(:email)
      ensure
        PIIDetector.reset!
      end
    end

    def test_configuration_persists_across_multiple_calls
      PIIDetector.partial_match = false
      begin
        # First call
        refute PIIDetector.contains_pii?(:customer_email)
        # Second call - setting should persist
        refute PIIDetector.contains_pii?(:billing_phone)
        # Third call
        refute PIIDetector.contains_pii?(:customer_name)

        # Exact matches still work
        assert PIIDetector.contains_pii?(:email)
        assert PIIDetector.contains_pii?(:phone)
      ensure
        PIIDetector.reset!
      end
    end

    def test_exact_mode_detects_all_exact_pattern_fields
      PIIDetector.partial_match = false
      begin
        # Test a sample from each PII category in exact mode
        assert PIIDetector.contains_pii?(:email)
        assert PIIDetector.contains_pii?(:user_email)
        assert PIIDetector.contains_pii?(:first_name)
        assert PIIDetector.contains_pii?(:phone)
        assert PIIDetector.contains_pii?(:ip_address)
        assert PIIDetector.contains_pii?(:street)
        assert PIIDetector.contains_pii?(:vat_number)
        assert PIIDetector.contains_pii?(:ssn)
        assert PIIDetector.contains_pii?(:credit_card)
        assert PIIDetector.contains_pii?(:iban)
        assert PIIDetector.contains_pii?(:medical)
        assert PIIDetector.contains_pii?(:fingerprint)
        assert PIIDetector.contains_pii?(:latitude)
      ensure
        PIIDetector.reset!
      end
    end

    # ===========================================================================
    # CVC/CVV Tests (recently added)
    # ===========================================================================

    def test_detect_cvc_field
      assert PIIDetector.contains_pii?(:cvc)
      assert PIIDetector.contains_pii?(:cvv)
    end

    # ===========================================================================
    # Source IP Tests (recently added)
    # ===========================================================================

    def test_detect_source_ip_field
      assert PIIDetector.contains_pii?(:source_ip)
    end

    # ===========================================================================
    # extract_pii_from_records Tests
    # ===========================================================================

    def test_extract_pii_from_records_basic
      records = [
        { id: 1, email: "alice@example.com", name: "Alice", status: "active" },
        { id: 2, email: "bob@example.com", name: "Bob", status: "inactive" }
      ]

      inventory = PIIDetector.extract_pii_from_records(
        records,
        attribute_extractor: ->(r) { r }
      )

      # Should have email and name categories
      assert_includes inventory.keys, :email
      assert_includes inventory.keys, :name

      # Should have 2 email entries
      assert_equal 2, inventory[:email].size
      assert_equal "alice@example.com", inventory[:email][0][:value]
      assert_equal "bob@example.com", inventory[:email][1][:value]

      # Should have 2 name entries
      assert_equal 2, inventory[:name].size
    end

    def test_extract_pii_from_records_with_metadata
      records = [
        { id: 1, email: "test@example.com" }
      ]

      inventory = PIIDetector.extract_pii_from_records(
        records,
        attribute_extractor: ->(r) { r },
        metadata_extractor: ->(r) { { record_id: r[:id], source: "test" } }
      )

      # Metadata should be merged into each entry
      entry = inventory[:email].first
      assert_equal 1, entry[:record_id]
      assert_equal "test", entry[:source]
      assert_equal :email, entry[:pii_type]
      assert_equal "test@example.com", entry[:value]
    end

    def test_extract_pii_from_records_with_event_like_objects
      # Simulate event objects with methods (like Lyra::Event or RubyEventStore::Event)
      event_class = Struct.new(:event_id, :data, :timestamp, :model_class, :model_id)

      events = [
        event_class.new("evt-1", { email: "alice@example.com", age: 30 }, Time.now, "User", 1),
        event_class.new("evt-2", { phone: "555-1234", status: "active" }, Time.now, "Contact", 2)
      ]

      inventory = PIIDetector.extract_pii_from_records(
        events,
        attribute_extractor: ->(e) { e.data },
        metadata_extractor: ->(e) {
          {
            event_id: e.event_id,
            timestamp: e.timestamp,
            model_class: e.model_class,
            model_id: e.model_id
          }
        }
      )

      # Email PII from first event
      assert_equal 1, inventory[:email].size
      email_entry = inventory[:email].first
      assert_equal "evt-1", email_entry[:event_id]
      assert_equal "User", email_entry[:model_class]
      assert_equal 1, email_entry[:model_id]

      # Phone PII from second event
      assert_equal 1, inventory[:phone].size
      phone_entry = inventory[:phone].first
      assert_equal "evt-2", phone_entry[:event_id]
      assert_equal "Contact", phone_entry[:model_class]
    end

    def test_extract_pii_from_records_empty_collection
      inventory = PIIDetector.extract_pii_from_records(
        [],
        attribute_extractor: ->(r) { r }
      )

      assert_empty inventory
    end

    def test_extract_pii_from_records_no_pii_found
      records = [
        { id: 1, status: "active", count: 10 },
        { id: 2, status: "inactive", count: 20 }
      ]

      inventory = PIIDetector.extract_pii_from_records(
        records,
        attribute_extractor: ->(r) { r }
      )

      assert_empty inventory
    end

    def test_extract_pii_from_records_nil_attributes
      records = [
        { id: 1, email: nil, name: nil },
        { id: 2, email: "test@example.com" }
      ]

      inventory = PIIDetector.extract_pii_from_records(
        records,
        attribute_extractor: ->(r) { r }
      )

      # Should still detect PII fields even with nil values
      # email appears twice (once nil, once with value)
      assert_equal 2, inventory[:email].size
    end

    def test_extract_pii_from_records_skips_empty_attributes
      records = [
        { data: { email: "test@example.com" } },
        { data: {} },
        { data: nil },
        { data: { phone: "555-1234" } }
      ]

      inventory = PIIDetector.extract_pii_from_records(
        records,
        attribute_extractor: ->(r) { r[:data] || {} }
      )

      assert_equal 1, inventory[:email].size
      assert_equal 1, inventory[:phone].size
    end

    def test_extract_pii_from_records_includes_sensitivity
      records = [
        { ssn: "123-45-6789", email: "test@example.com" }
      ]

      inventory = PIIDetector.extract_pii_from_records(
        records,
        attribute_extractor: ->(r) { r }
      )

      # SSN should be restricted
      ssn_entry = inventory[:ssn].first
      assert_equal :restricted, ssn_entry[:sensitivity]

      # Email should be confidential
      email_entry = inventory[:email].first
      assert_equal :confidential, email_entry[:sensitivity]
    end

    def test_extract_pii_from_records_groups_by_pii_type
      records = [
        { email: "a@example.com", phone: "111" },
        { email: "b@example.com", name: "Bob" },
        { phone: "222", name: "Carol" }
      ]

      inventory = PIIDetector.extract_pii_from_records(
        records,
        attribute_extractor: ->(r) { r }
      )

      assert_equal 2, inventory[:email].size
      assert_equal 2, inventory[:phone].size
      assert_equal 2, inventory[:name].size
    end

    def test_extract_pii_from_records_works_with_activerecord_like_objects
      # Simulate ActiveRecord models with .attributes method
      user_class = Struct.new(:id, :email, :name) do
        def attributes
          { "id" => id, "email" => email, "name" => name }
        end
      end

      users = [
        user_class.new(1, "alice@example.com", "Alice"),
        user_class.new(2, "bob@example.com", "Bob")
      ]

      inventory = PIIDetector.extract_pii_from_records(
        users,
        attribute_extractor: ->(u) { u.attributes },
        metadata_extractor: ->(u) { { id: u.id, type: "User" } }
      )

      assert_equal 2, inventory[:email].size
      assert_equal 2, inventory[:name].size

      # Verify metadata
      assert_equal 1, inventory[:email][0][:id]
      assert_equal "User", inventory[:email][0][:type]
    end
  end
end
