require "test_helper"
require "fileutils"
require "tmpdir"

module PamDsl
  class PolicyGeneratorTest < Minitest::Test
    def setup
      PamDsl.reset!
      @tmp_dir = Dir.mktmpdir("pam_dsl_test")
    end

    def teardown
      PamDsl.reset!
      FileUtils.rm_rf(@tmp_dir) if @tmp_dir && File.exist?(@tmp_dir)
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Initialization Tests
    # ─────────────────────────────────────────────────────────────────────────

    def test_initializes_with_name
      generator = PolicyGenerator.new(:my_app, output_path: tmp_output_path)

      assert_equal :my_app, generator.name
    end

    def test_initializes_with_custom_output_path
      custom_path = File.join(@tmp_dir, "custom_policy.rb")
      generator = PolicyGenerator.new(:my_app, output_path: custom_path)

      assert_equal custom_path, generator.output_path
    end

    def test_converts_name_to_symbol
      generator = PolicyGenerator.new("MyApp", output_path: tmp_output_path)

      assert_equal :my_app, generator.name
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Exclusion Pattern Tests
    # ─────────────────────────────────────────────────────────────────────────

    def test_excludes_timestamp_fields
      generator = PolicyGenerator.new(:test, output_path: tmp_output_path)

      assert excluded?("created_at")
      assert excluded?("updated_at")
      assert excluded?("deleted_at")
      assert excluded?("email_sent_at")
      assert excluded?("cancelled_at")
    end

    def test_excludes_amount_fields
      generator = PolicyGenerator.new(:test, output_path: tmp_output_path)

      assert excluded?("total_amount")
      assert excluded?("vat_amount")
      assert excluded?("discount_amount")
    end

    def test_excludes_reason_fields
      generator = PolicyGenerator.new(:test, output_path: tmp_output_path)

      assert excluded?("cancellation_reason")
      assert excluded?("rejection_reason")
    end

    def test_excludes_foreign_keys
      generator = PolicyGenerator.new(:test, output_path: tmp_output_path)

      assert excluded?("user_id")
      assert excluded?("order_id")
      assert excluded?("payment_id")
    end

    def test_excludes_status_fields
      generator = PolicyGenerator.new(:test, output_path: tmp_output_path)

      assert excluded?("payment_status")
      assert excluded?("order_status")
    end

    def test_excludes_boolean_flags
      generator = PolicyGenerator.new(:test, output_path: tmp_output_path)

      assert excluded?("is_active")
      assert excluded?("is_verified")
      assert excluded?("has_consent")
      assert excluded?("email_verified")
      assert excluded?("two_factor_enabled")
    end

    # Credentials and the tokens that stand for a person's account are
    # personal data (a breach of them is a personal-data breach); a generic
    # token is not detected.
    def test_credentials_and_account_tokens_are_personal_data
      assert_pii_match(:encrypted_password, :credential, :restricted)
      assert_pii_match(:password_digest, :credential, :restricted)
      assert_pii_match(:password_hash, :credential, :restricted)
      assert_pii_match(:reset_password_token, :token, :restricted)
      assert excluded?("reset_token")
    end

    def test_does_not_exclude_valid_pii_fields
      generator = PolicyGenerator.new(:test, output_path: tmp_output_path)

      refute excluded?("email")
      refute excluded?("phone")
      refute excluded?("firstname")
      refute excluded?("lastname")
      refute excluded?("address")
      refute excluded?("iban")
      refute excluded?("vat_number")
    end

    # ─────────────────────────────────────────────────────────────────────────
    # PII Pattern Detection Tests
    # ─────────────────────────────────────────────────────────────────────────

    def test_detects_email_fields
      assert_pii_match(:email, :email, :confidential)
      assert_pii_match(:user_email, :email, :confidential)
      assert_pii_match(:contact_email, :email, :confidential)
      assert_pii_match(:billing_email, :email, :confidential)
    end

    def test_detects_name_fields
      assert_pii_match(:firstname, :name, :internal)
      assert_pii_match(:first_name, :name, :internal)
      assert_pii_match(:lastname, :name, :internal)
      assert_pii_match(:last_name, :name, :internal)
      assert_pii_match(:fathername, :name, :internal)
      assert_pii_match(:name, :name, :internal)
    end

    def test_detects_phone_fields
      assert_pii_match(:phone, :phone, :confidential)
      assert_pii_match(:telephone, :phone, :confidential)
      assert_pii_match(:mobile, :phone, :confidential)
      assert_pii_match(:cell, :phone, :confidential)
      assert_pii_match(:phone_number, :phone, :confidential)
    end

    def test_detects_address_fields
      assert_pii_match(:address, :address, :confidential)
      assert_pii_match(:street, :address, :confidential)
      assert_pii_match(:city, :address, :confidential)
      assert_pii_match(:postal_code, :address, :confidential)
      assert_pii_match(:zip_code, :address, :confidential)
    end

    def test_detects_financial_fields
      assert_pii_match(:iban, :financial, :restricted)
      assert_pii_match(:bic, :financial, :restricted)
      assert_pii_match(:swift, :financial, :restricted)
      assert_pii_match(:bank_account, :financial, :restricted)
    end

    def test_detects_credit_card_fields
      assert_pii_match(:credit_card, :credit_card, :restricted)
      assert_pii_match(:card_number, :credit_card, :restricted)
      assert_pii_match(:card_number_first4, :credit_card, :restricted)
      assert_pii_match(:card_number_last3, :credit_card, :restricted)
    end

    def test_detects_tax_identifier_fields
      assert_pii_match(:vat_number, :identifier, :restricted)
      assert_pii_match(:vat_id, :identifier, :restricted)
      assert_pii_match(:tax_id, :identifier, :restricted)
      assert_pii_match(:tax_number, :identifier, :restricted)
      assert_pii_match(:afm, :identifier, :restricted)  # Greek tax number (ΑΦΜ)
    end

    def test_detects_ssn_fields
      assert_pii_match(:ssn, :ssn, :restricted)
      assert_pii_match(:social_security_number, :ssn, :restricted)
      assert_pii_match(:national_id, :ssn, :restricted)
      assert_pii_match(:passport_number, :identifier, :restricted) # a document number, as PIIDetector types it
    end

    def test_detects_date_of_birth_fields
      assert_pii_match(:dob, :date_of_birth, :confidential)
      assert_pii_match(:date_of_birth, :date_of_birth, :confidential)
      assert_pii_match(:birthday, :date_of_birth, :confidential)
      assert_pii_match(:birthdate, :date_of_birth, :confidential)
    end

    def test_detects_ip_address_fields
      assert_pii_match(:ip_address, :ip_address, :internal)
      assert_pii_match(:remote_ip, :ip_address, :internal)
      assert_pii_match(:client_ip, :ip_address, :internal)
    end

    def test_detects_location_fields
      assert_pii_match(:latitude, :location, :confidential)
      assert_pii_match(:longitude, :location, :confidential)
      assert_pii_match(:location, :location, :confidential)
      assert_pii_match(:geo_location, :location, :confidential)
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Basic Policy Generation Tests
    # ─────────────────────────────────────────────────────────────────────────

    def test_generate_creates_file
      output_path = File.join(@tmp_dir, "pam_dsl_policy.rb")
      generator = PolicyGenerator.new(:test_app, output_path: output_path)

      # Suppress output
      capture_output { generator.generate }

      assert File.exist?(output_path)
    end

    def test_generate_includes_policy_name
      output_path = File.join(@tmp_dir, "pam_dsl_policy.rb")
      generator = PolicyGenerator.new(:test_app, output_path: output_path)

      capture_output { generator.generate }

      content = File.read(output_path)
      assert_includes content, "PamDsl.define_policy :test_app"
    end

    def test_generate_includes_default_fields
      output_path = File.join(@tmp_dir, "pam_dsl_policy.rb")
      generator = PolicyGenerator.new(:test_app, output_path: output_path)

      capture_output { generator.generate }

      content = File.read(output_path)
      assert_includes content, "field :email"
      assert_includes content, "field :phone"
      assert_includes content, "field :first_name"
      assert_includes content, "field :last_name"
    end

    def test_generate_includes_default_purposes
      output_path = File.join(@tmp_dir, "pam_dsl_policy.rb")
      generator = PolicyGenerator.new(:test_app, output_path: output_path)

      capture_output { generator.generate }

      content = File.read(output_path)
      assert_includes content, "purpose :service_delivery"
      assert_includes content, "purpose :communication"
      assert_includes content, "purpose :audit_trail"
    end

    def test_generate_includes_retention_section
      output_path = File.join(@tmp_dir, "pam_dsl_policy.rb")
      generator = PolicyGenerator.new(:test_app, output_path: output_path)

      capture_output { generator.generate }

      content = File.read(output_path)
      assert_includes content, "retention do"
      assert_includes content, "default 7.years"
    end

    def test_generate_includes_transformations_for_email
      output_path = File.join(@tmp_dir, "pam_dsl_policy.rb")
      generator = PolicyGenerator.new(:test_app, output_path: output_path)

      capture_output { generator.generate }

      content = File.read(output_path)
      assert_includes content, 'transform :display'
      assert_includes content, 'transform :log'
    end

    def test_generate_includes_rails_config
      output_path = File.join(@tmp_dir, "pam_dsl_policy.rb")
      generator = PolicyGenerator.new(:test_app, output_path: output_path)

      capture_output { generator.generate }

      content = File.read(output_path)
      assert_includes content, "Rails.application.config.pam_dsl.default_policy"
      assert_includes content, "Rails.application.config.pam_dsl.organization"
      assert_includes content, "Rails.application.config.pam_dsl.dpo_contact"
    end

    def test_generate_includes_documentation_header
      output_path = File.join(@tmp_dir, "pam_dsl_policy.rb")
      generator = PolicyGenerator.new(:test_app, output_path: output_path)

      capture_output { generator.generate }

      content = File.read(output_path)
      assert_includes content, "# PAM DSL Privacy Policy"
      assert_includes content, "# Generated:"
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Transform Code Generation Tests
    # ─────────────────────────────────────────────────────────────────────────

    def test_generate_transform_code_for_email
      generator = PolicyGenerator.new(:test, output_path: tmp_output_path)
      code = generator.send(:generate_transform_code, :email, :email)

      assert_includes code, "transform :display"
      assert_includes code, "transform :log"
      assert_includes code, "[EMAIL]"
    end

    def test_generate_transform_code_for_phone
      generator = PolicyGenerator.new(:test, output_path: tmp_output_path)
      code = generator.send(:generate_transform_code, :phone, :phone)

      assert_includes code, "transform :display"
      assert_includes code, "transform :log"
      assert_includes code, "[PHONE]"
    end

    def test_generate_transform_code_for_credit_card
      generator = PolicyGenerator.new(:test, output_path: tmp_output_path)
      code = generator.send(:generate_transform_code, :card, :credit_card)

      assert_includes code, "transform :display"
      assert_includes code, "transform :log"
      assert_includes code, "[CREDIT_CARD]"
    end

    def test_generate_transform_code_for_identifier
      generator = PolicyGenerator.new(:test, output_path: tmp_output_path)
      code = generator.send(:generate_transform_code, :vat, :identifier)

      assert_includes code, "transform :display"
      assert_includes code, "transform :log"
      assert_includes code, "[IDENTIFIER]"
    end

    def test_generate_transform_code_for_other_types
      generator = PolicyGenerator.new(:test, output_path: tmp_output_path)
      code = generator.send(:generate_transform_code, :other, :custom)

      assert_includes code, "transform :log"
      assert_includes code, "[REDACTED]"
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Purpose Generation Tests
    # ─────────────────────────────────────────────────────────────────────────

    def test_generates_service_delivery_purpose_when_email_present
      generator = PolicyGenerator.new(:test, output_path: tmp_output_path)
      detected = { email: { type: :email, sensitivity: :confidential, models: ["User"] } }

      code = generator.send(:generate_purposes_code, detected)

      assert_includes code, "purpose :service_delivery"
      assert_includes code, "basis :contract"
    end

    def test_generates_billing_purpose_when_address_present
      generator = PolicyGenerator.new(:test, output_path: tmp_output_path)
      detected = {
        email: { type: :email, sensitivity: :confidential, models: ["User"] },
        address: { type: :address, sensitivity: :confidential, models: ["User"] },
        vat_number: { type: :identifier, sensitivity: :restricted, models: ["User"] }
      }

      code = generator.send(:generate_purposes_code, detected)

      assert_includes code, "purpose :billing"
      assert_includes code, ":email"
      assert_includes code, ":address"
      assert_includes code, ":vat_number"
    end

    def test_generates_audit_trail_purpose_when_ip_address_present
      generator = PolicyGenerator.new(:test, output_path: tmp_output_path)
      detected = { ip_address: { type: :ip_address, sensitivity: :internal, models: ["Log"] } }

      code = generator.send(:generate_purposes_code, detected)

      assert_includes code, "purpose :audit_trail"
      assert_includes code, "basis :legal_obligation"
      assert_includes code, ":ip_address"
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Retention Generation Tests
    # ─────────────────────────────────────────────────────────────────────────

    def test_generates_default_retention
      generator = PolicyGenerator.new(:test, output_path: tmp_output_path)
      detected = { email: { type: :email, sensitivity: :confidential, models: ["User"] } }

      code = generator.send(:generate_retention_code, detected)

      assert_includes code, "retention do"
      assert_includes code, "default 7.years"
    end

    def test_generates_longer_retention_for_financial_models
      generator = PolicyGenerator.new(:test, output_path: tmp_output_path)
      detected = {
        email: { type: :email, sensitivity: :confidential, models: ["PaymentTransaction"] }
      }

      code = generator.send(:generate_retention_code, detected)

      assert_includes code, 'for_model "PaymentTransaction"'
      assert_includes code, "keep_for 10.years"
      assert_includes code, "Financial records"
    end

    def test_generates_longer_retention_for_invoice_models
      generator = PolicyGenerator.new(:test, output_path: tmp_output_path)
      detected = {
        vat_number: { type: :identifier, sensitivity: :restricted, models: ["Invoice"] }
      }

      code = generator.send(:generate_retention_code, detected)

      assert_includes code, 'for_model "Invoice"'
      assert_includes code, "keep_for 10.years"
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Edge Cases
    # ─────────────────────────────────────────────────────────────────────────

    def test_handles_empty_detected_fields
      generator = PolicyGenerator.new(:test, output_path: tmp_output_path)

      code = generator.send(:generate_fields_code, {})
      assert_equal "", code.strip

      purposes_code = generator.send(:generate_purposes_code, {})
      assert_equal "", purposes_code.strip
    end

    def test_handles_special_characters_in_name
      generator = PolicyGenerator.new("My-Special_App", output_path: tmp_output_path)

      assert_equal :my_special_app, generator.name
    end

    def test_creates_output_directory_if_missing
      nested_path = File.join(@tmp_dir, "nested", "dir", "policy.rb")
      generator = PolicyGenerator.new(:test_app, output_path: nested_path)

      capture_output { generator.generate }

      assert File.exist?(nested_path)
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Summary Output Tests
    # ─────────────────────────────────────────────────────────────────────────

    def test_print_summary_shows_policy_name
      output_path = File.join(@tmp_dir, "policy.rb")
      generator = PolicyGenerator.new(:my_test_app, output_path: output_path)

      output = capture_output { generator.generate }

      assert_includes output, "Policy name: my_test_app"
    end

    def test_print_summary_shows_output_file
      output_path = File.join(@tmp_dir, "policy.rb")
      generator = PolicyGenerator.new(:test_app, output_path: output_path)

      output = capture_output { generator.generate }

      assert_includes output, "Output file:"
      assert_includes output, output_path
    end

    def test_print_summary_shows_next_steps
      output_path = File.join(@tmp_dir, "policy.rb")
      generator = PolicyGenerator.new(:test_app, output_path: output_path)

      output = capture_output { generator.generate }

      assert_includes output, "Next steps:"
      assert_includes output, "Review and customize"
    end

    def test_print_summary_with_detected_fields_shows_counts
      generator = PolicyGenerator.new(:test, output_path: tmp_output_path)
      detected = {
        email: { type: :email, sensitivity: :confidential, models: ["User"] },
        phone: { type: :phone, sensitivity: :confidential, models: ["User"] },
        iban: { type: :financial, sensitivity: :restricted, models: ["Account"] }
      }

      output = capture_output { generator.send(:print_summary, detected) }

      assert_includes output, "Detected PII fields: 3"
      assert_includes output, "Models scanned: 2"
    end

    def test_print_summary_shows_sensitivity_breakdown
      generator = PolicyGenerator.new(:test, output_path: tmp_output_path)
      detected = {
        email: { type: :email, sensitivity: :confidential, models: ["User"] },
        iban: { type: :financial, sensitivity: :restricted, models: ["Account"] },
        name: { type: :name, sensitivity: :internal, models: ["User"] }
      }

      output = capture_output { generator.send(:print_summary, detected) }

      assert_includes output, "Fields by sensitivity:"
      assert_includes output, "confidential:"
      assert_includes output, "restricted:"
      assert_includes output, "internal:"
    end

    private

    def tmp_output_path
      @tmp_output_path ||= File.join(@tmp_dir, "test_policy.rb")
    end

    def assert_pii_match(field_name, expected_type, expected_sensitivity)
      match = find_pii_match(field_name.to_s)
      refute_nil match, "Expected #{field_name} to match a PII pattern"
      assert_equal expected_type, match[:type], "Expected #{field_name} to have type #{expected_type}"
      assert_equal expected_sensitivity, match[:sensitivity], "Expected #{field_name} to have sensitivity #{expected_sensitivity}"
    end

    # The generator detects with PIIDetector, PAM's one dictionary.
    def find_pii_match(field_name)
      type = PIIDetector.pii_type(field_name)
      type && { type: type, sensitivity: PIIDetector.sensitivity(field_name) }
    end

    def excluded?(column) = PIIDetector.pii_type(column).nil?

    def capture_output
      original_stdout = $stdout
      $stdout = StringIO.new
      yield
      $stdout.string
    ensure
      $stdout = original_stdout
    end
  end
end
