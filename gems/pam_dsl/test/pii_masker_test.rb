require "test_helper"

module PamDsl
  class PIIMaskerTest < Minitest::Test
    # ===========================================================================
    # Basic Masking Tests
    # ===========================================================================

    def test_mask_returns_hash_with_masked_pii
      data = { email: "alice@example.com", name: "Alice Smith", status: "active" }
      masked = PIIMasker.mask(data)

      assert_equal "a***@example.com", masked[:email]
      assert_equal "Alice ***", masked[:name]
      assert_equal "active", masked[:status]  # Non-PII unchanged
    end

    def test_mask_does_not_modify_original
      data = { email: "alice@example.com" }
      PIIMasker.mask(data)

      assert_equal "alice@example.com", data[:email]
    end

    def test_mask_handles_empty_hash
      assert_equal({}, PIIMasker.mask({}))
    end

    def test_mask_handles_nil
      assert_nil PIIMasker.mask(nil)
    end

    def test_mask_handles_no_pii_fields
      data = { id: 1, status: "active", count: 10 }
      masked = PIIMasker.mask(data)

      assert_equal data, masked
    end

    # ===========================================================================
    # Strategy Tests
    # ===========================================================================

    def test_mask_partial_strategy_default
      data = { email: "alice@example.com", phone: "1234567890" }
      masked = PIIMasker.mask(data)  # Default is :partial

      assert_equal "a***@example.com", masked[:email]
      assert_equal "***-***-7890", masked[:phone]
    end

    def test_mask_full_strategy
      data = { email: "alice@example.com", name: "Alice", status: "active" }
      masked = PIIMasker.mask(data, strategy: :full)

      assert_equal "[REDACTED]", masked[:email]
      assert_equal "[REDACTED]", masked[:name]
      assert_equal "active", masked[:status]
    end

    def test_mask_redact_sensitive_strategy
      data = {
        email: "alice@example.com",  # Not sensitive
        ssn: "123-45-6789",          # Sensitive
        credit_card: "4111111111111111"  # Sensitive
      }
      masked = PIIMasker.mask(data, strategy: :redact_sensitive)

      # Sensitive fields fully redacted
      assert_equal "[REDACTED]", masked[:ssn]
      assert_equal "[REDACTED]", masked[:credit_card]

      # Non-sensitive PII partially masked
      assert_equal "a***@example.com", masked[:email]
    end

    # ===========================================================================
    # mask_field Tests
    # ===========================================================================

    def test_mask_field_by_name
      masked = PIIMasker.mask_field("alice@example.com", :email)
      assert_equal "a***@example.com", masked
    end

    def test_mask_field_returns_original_if_not_pii
      masked = PIIMasker.mask_field("some_value", :status)
      assert_equal "some_value", masked
    end

    def test_mask_field_with_strategy
      masked = PIIMasker.mask_field("alice@example.com", :email, strategy: :full)
      assert_equal "[REDACTED]", masked
    end

    def test_mask_field_works_with_prefixed_fields
      masked = PIIMasker.mask_field("alice@example.com", :customer_email)
      assert_equal "a***@example.com", masked
    end

    # ===========================================================================
    # mask_by_type Tests
    # ===========================================================================

    def test_mask_by_type_email
      masked = PIIMasker.mask_by_type("alice@example.com", :email)
      assert_equal "a***@example.com", masked
    end

    def test_mask_by_type_phone
      masked = PIIMasker.mask_by_type("1234567890", :phone)
      assert_equal "***-***-7890", masked
    end

    def test_mask_by_type_ssn
      masked = PIIMasker.mask_by_type("123-45-6789", :ssn)
      assert_equal "***REDACTED***", masked
    end

    def test_mask_by_type_with_full_strategy
      masked = PIIMasker.mask_by_type("alice@example.com", :email, strategy: :full)
      assert_equal "[REDACTED]", masked
    end

    def test_mask_by_type_redact_sensitive_for_sensitive_type
      masked = PIIMasker.mask_by_type("123-45-6789", :ssn, strategy: :redact_sensitive)
      assert_equal "[REDACTED]", masked
    end

    def test_mask_by_type_redact_sensitive_for_non_sensitive_type
      masked = PIIMasker.mask_by_type("alice@example.com", :email, strategy: :redact_sensitive)
      assert_equal "a***@example.com", masked
    end

    # ===========================================================================
    # mask_records Tests
    # ===========================================================================

    def test_mask_records_with_hashes
      records = [
        { id: 1, email: "alice@example.com" },
        { id: 2, email: "bob@example.com" }
      ]

      masked = PIIMasker.mask_records(
        records,
        attribute_extractor: ->(r) { r },
        attribute_setter: ->(r, masked_attrs) { masked_attrs }
      )

      assert_equal "a***@example.com", masked[0][:email]
      assert_equal "b***@example.com", masked[1][:email]
    end

    def test_mask_records_with_objects
      record_class = Struct.new(:id, :data) do
        def with_data(new_data)
          self.class.new(id, new_data)
        end
      end

      records = [
        record_class.new(1, { email: "alice@example.com" }),
        record_class.new(2, { email: "bob@example.com" })
      ]

      masked = PIIMasker.mask_records(
        records,
        attribute_extractor: ->(r) { r.data },
        attribute_setter: ->(r, masked_attrs) { r.with_data(masked_attrs) }
      )

      assert_equal 1, masked[0].id
      assert_equal "a***@example.com", masked[0].data[:email]
      assert_equal 2, masked[1].id
      assert_equal "b***@example.com", masked[1].data[:email]
    end

    def test_mask_records_with_full_strategy
      records = [{ email: "alice@example.com" }]

      masked = PIIMasker.mask_records(
        records,
        attribute_extractor: ->(r) { r },
        attribute_setter: ->(r, masked_attrs) { masked_attrs },
        strategy: :full
      )

      assert_equal "[REDACTED]", masked[0][:email]
    end

    def test_mask_records_empty_collection
      masked = PIIMasker.mask_records(
        [],
        attribute_extractor: ->(r) { r },
        attribute_setter: ->(r, masked_attrs) { masked_attrs }
      )

      assert_empty masked
    end

    # ===========================================================================
    # Edge Cases
    # ===========================================================================

    def test_mask_with_nil_values
      data = { email: nil, name: nil, status: "active" }
      masked = PIIMasker.mask(data)

      assert_nil masked[:email]
      assert_nil masked[:name]
      assert_equal "active", masked[:status]
    end

    def test_mask_with_mixed_key_types
      data = { "email" => "alice@example.com", name: "Alice" }
      masked = PIIMasker.mask(data)

      assert_equal "a***@example.com", masked["email"]
      assert_equal "Alice ***", masked[:name]
    end

    def test_mask_preserves_non_pii_values
      data = {
        id: 123,
        email: "alice@example.com",
        created_at: Time.now,
        active: true,
        tags: ["ruby", "rails"]
      }
      masked = PIIMasker.mask(data)

      assert_equal 123, masked[:id]
      assert_kind_of Time, masked[:created_at]
      assert_equal true, masked[:active]
      assert_equal ["ruby", "rails"], masked[:tags]
    end

    def test_mask_all_sensitive_pii_types
      data = {
        ssn: "123-45-6789",
        credit_card: "4111111111111111",
        iban: "DE89370400440532013000",
        vat_number: "EL123456789"
      }

      masked = PIIMasker.mask(data, strategy: :redact_sensitive)

      # All sensitive types should be fully redacted
      assert_equal "[REDACTED]", masked[:ssn]
      assert_equal "[REDACTED]", masked[:credit_card]
      assert_equal "[REDACTED]", masked[:iban]
      assert_equal "[REDACTED]", masked[:vat_number]
    end
  end
end
