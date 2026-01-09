require "test_helper"

module PamDsl
  class FieldTest < Minitest::Test
    # ─────────────────────────────────────────────────────────────────────────
    # Basic Field Creation
    # ─────────────────────────────────────────────────────────────────────────

    def test_field_creation
      field = Field.new(:email, type: :email)
      assert_equal :email, field.name
      assert_equal :email, field.type
    end

    def test_field_converts_name_to_symbol
      field = Field.new("user_email", type: :email)
      assert_equal :user_email, field.name
    end

    def test_field_converts_type_to_symbol
      field = Field.new(:phone, type: "phone")
      assert_equal :phone, field.type
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Sensitivity Levels
    # ─────────────────────────────────────────────────────────────────────────

    def test_default_sensitivity
      field = Field.new(:data, type: :email)
      assert_equal :internal, field.sensitivity
    end

    def test_field_with_public_sensitivity
      field = Field.new(:name, type: :name, sensitivity: :public)
      assert_equal :public, field.sensitivity
    end

    def test_field_with_internal_sensitivity
      field = Field.new(:name, type: :name, sensitivity: :internal)
      assert_equal :internal, field.sensitivity
    end

    def test_field_with_confidential_sensitivity
      field = Field.new(:email, type: :email, sensitivity: :confidential)
      assert_equal :confidential, field.sensitivity
    end

    def test_field_with_restricted_sensitivity
      field = Field.new(:ssn, type: :ssn, sensitivity: :restricted)
      assert_equal :restricted, field.sensitivity
    end

    def test_sensitivity_levels_are_validated
      valid_levels = [:public, :internal, :confidential, :restricted]

      valid_levels.each do |level|
        field = Field.new(:data, type: :email, sensitivity: level)
        assert_equal level, field.sensitivity
      end
    end

    def test_invalid_sensitivity_raises_error
      assert_raises(InvalidFieldError) do
        Field.new(:data, type: :email, sensitivity: :invalid)
      end
    end

    # ─────────────────────────────────────────────────────────────────────────
    # PII Types
    # ─────────────────────────────────────────────────────────────────────────

    def test_pii_field_types
      valid_types = [
        :email, :name, :phone, :address, :ssn, :date_of_birth,
        :ip_address, :credit_card, :financial, :health, :biometric,
        :location, :identifier, :custom
      ]

      valid_types.each do |type|
        field = Field.new(:test, type: type)
        assert_equal type, field.type
      end
    end

    def test_invalid_type_raises_error
      assert_raises(InvalidFieldError) do
        Field.new(:test, type: :invalid_type)
      end
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Transformations
    # ─────────────────────────────────────────────────────────────────────────

    def test_field_with_transformations
      field = Field.new(:email, type: :email)
      field.transform(:display) { |v| v&.gsub(/@.*/, "@***") }
      field.transform(:log) { |_v| "[EMAIL]" }

      assert field.transformations.key?(:display)
      assert field.transformations.key?(:log)
    end

    def test_apply_transformation
      field = Field.new(:email, type: :email)
      field.transform(:display) { |v| v&.upcase }

      result = field.apply_transformation(:display, "test@example.com")
      assert_equal "TEST@EXAMPLE.COM", result
    end

    def test_apply_missing_transformation_returns_original
      field = Field.new(:email, type: :email)

      result = field.apply_transformation(:display, "test@example.com")
      assert_equal "test@example.com", result
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Purposes
    # ─────────────────────────────────────────────────────────────────────────

    def test_field_with_purposes
      field = Field.new(:email, type: :email)
      field.allow_for(:marketing, :billing)

      assert_includes field.purposes, :marketing
      assert_includes field.purposes, :billing
    end

    def test_allowed_for_purpose
      field = Field.new(:email, type: :email)
      field.allow_for(:marketing)

      assert field.allowed_for?(:marketing)
      refute field.allowed_for?(:analytics)
    end

    def test_field_without_purposes_allowed_for_all
      field = Field.new(:email, type: :email)

      assert field.allowed_for?(:marketing)
      assert field.allowed_for?(:anything)
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Metadata
    # ─────────────────────────────────────────────────────────────────────────

    def test_field_metadata
      field = Field.new(:user_id, type: :identifier)
      field.meta(:source, "database")
      field.meta(:table, "users")

      assert_equal "database", field.metadata[:source]
      assert_equal "users", field.metadata[:table]
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Sensitivity Helpers
    # ─────────────────────────────────────────────────────────────────────────

    def test_sensitive_for_confidential
      field = Field.new(:email, type: :email, sensitivity: :confidential)
      assert field.sensitive?
    end

    def test_sensitive_for_restricted
      field = Field.new(:ssn, type: :ssn, sensitivity: :restricted)
      assert field.sensitive?
    end

    def test_not_sensitive_for_public
      field = Field.new(:name, type: :name, sensitivity: :public)
      refute field.sensitive?
    end

    def test_not_sensitive_for_internal
      field = Field.new(:name, type: :name, sensitivity: :internal)
      refute field.sensitive?
    end

    def test_restricted_only_for_restricted
      field_restricted = Field.new(:ssn, type: :ssn, sensitivity: :restricted)
      field_confidential = Field.new(:email, type: :email, sensitivity: :confidential)

      assert field_restricted.restricted?
      refute field_confidential.restricted?
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Method Chaining
    # ─────────────────────────────────────────────────────────────────────────

    def test_method_chaining
      field = Field.new(:email, type: :email, sensitivity: :confidential)
        .allow_for(:marketing)
        .transform(:display) { |v| v&.upcase }
        .meta(:source, "signup")

      assert_includes field.purposes, :marketing
      assert field.transformations.key?(:display)
      assert_equal "signup", field.metadata[:source]
    end
  end
end
