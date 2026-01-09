# frozen_string_literal: true

module PamDsl
  # Generates PAM DSL policy files with sensible defaults
  #
  # Can generate a basic policy template or scan ActiveRecord models
  # to detect PII fields and generate a policy based on them.
  #
  # @example Generate basic policy
  #   generator = PamDsl::PolicyGenerator.new("my_app")
  #   generator.generate  # Creates config/initializers/pam_dsl_policy.rb
  #
  # @example Generate from models
  #   generator = PamDsl::PolicyGenerator.new("my_app")
  #   generator.generate_from_models  # Scans models for PII
  #
  class PolicyGenerator
    # Patterns that should be excluded (timestamps, counts, amounts, flags, etc.)
    EXCLUDE_PATTERNS = [
      /_at\z/i,           # Timestamps: created_at, updated_at, email_sent_at, cancelled_at
      /_on\z/i,           # Date fields: published_on, expires_on
      /_count\z/i,        # Counters: login_count, failed_attempts_count
      /_amount\z/i,       # Amounts: vat_amount, total_amount, discount_amount
      /_total\z/i,        # Totals: grand_total, subtotal
      /_reason\z/i,       # Reason text: cancellation_reason, rejection_reason
      /_notes?\z/i,       # Notes: admin_notes, internal_note
      /_status\z/i,       # Status flags: payment_status, order_status
      /_type\z/i,         # Type flags: payment_type, user_type
      /_id\z/i,           # Foreign keys: user_id, order_id
      /_uuid\z/i,         # UUIDs: order_uuid
      /_code\z/i,         # Codes: country_code, currency_code (but not postal_code)
      /\A(id|uuid)\z/i,   # Primary keys
      /\Ais_/i,           # Boolean flags: is_active, is_verified
      /\Ahas_/i,          # Boolean flags: has_consent
      /_enabled\z/i,      # Flags: two_factor_enabled
      /_verified\z/i,     # Flags: email_verified
      /_confirmed\z/i,    # Flags: payment_confirmed
      /encrypted_/i,      # Already encrypted: encrypted_password
      /_digest\z/i,       # Hashes: password_digest
      /_token\z/i,        # Tokens: reset_token, auth_token
      /_hash\z/i,         # Hashes: password_hash
    ].freeze

    # Common PII field patterns and their types
    # More specific patterns to reduce false positives
    PII_PATTERNS = {
      # Email - must be the actual email field, not email_sent_at, email_verified, etc.
      /\A(email|e_mail|mail_address|user_email|contact_email|billing_email)\z/i => { type: :email, sensitivity: :confidential },

      # Names - exact matches only
      /\A(first_?name|given_?name|fname)\z/i => { type: :name, sensitivity: :internal },
      /\A(last_?name|surname|family_?name|lname)\z/i => { type: :name, sensitivity: :internal },
      /\A(full_?name|display_?name)\z/i => { type: :name, sensitivity: :internal },
      /\A(father_?name|fathername|mother_?name|parent_?name)\z/i => { type: :name, sensitivity: :internal },
      /\A(name|firstname|lastname)\z/i => { type: :name, sensitivity: :internal },

      # Phone - exact field names only
      /\A(phone|telephone|mobile|cell|fax|phone_number|mobile_number|cell_phone)\z/i => { type: :phone, sensitivity: :confidential },

      # Address - exact matches
      /\A(address|street|city|state|province|country|postal|zip|postcode|postal_code|zip_code)\z/i => { type: :address, sensitivity: :confidential },
      /\A(address_line_?\d?|street_address|billing_address|shipping_address|home_address|work_address)\z/i => { type: :address, sensitivity: :confidential },

      # Financial - exact matches for account identifiers
      /\A(iban|swift|bic|bank_account|account_number|routing_number)\z/i => { type: :financial, sensitivity: :restricted },
      /\A(credit_card|card_number|card_number_first\d|card_number_last\d|cvv|cvc)\z/i => { type: :credit_card, sensitivity: :restricted },

      # Tax/VAT identifiers - the actual number, not amounts
      # AFM = Greek tax identification number (ΑΦΜ - Αριθμός Φορολογικού Μητρώου)
      /\A(vat_number|vat_id|tax_id|tin|tax_number|vat_reg_number|afm)\z/i => { type: :identifier, sensitivity: :restricted },

      # Personal identifiers - exact matches
      /\A(ssn|social_security|social_security_number|national_id|passport|passport_number|driver_license|drivers_license|license_number)\z/i => { type: :ssn, sensitivity: :restricted },
      /\A(dob|date_of_birth|birth_date|birthday|birthdate)\z/i => { type: :date_of_birth, sensitivity: :confidential },

      # Technical - IP addresses
      /\A(ip|ip_address|remote_ip|client_ip|source_ip)\z/i => { type: :ip_address, sensitivity: :internal },

      # Health - exact matches to avoid false positives
      /\A(health_condition|medical_record|diagnosis|prescription|medical_history)\z/i => { type: :health, sensitivity: :restricted },

      # Biometric - exact matches
      /\A(fingerprint|face_id|biometric|biometric_data|retina_scan)\z/i => { type: :biometric, sensitivity: :restricted },

      # Location - exact matches for coordinates
      /\A(latitude|longitude|lat|lng|geo_location|gps_coordinates)\z/i => { type: :location, sensitivity: :confidential },
      /\A(location)\z/i => { type: :location, sensitivity: :confidential },

      # Credentials and tokens - security sensitive (usually excluded from auto-detection)
      # These patterns are for manual matching when tokens are explicitly included
      /\A(encrypted_password|password_salt|password_digest)\z/i => { type: :credential, sensitivity: :restricted },
      /\A(api_key|spree_api_key|secret_key|access_key)\z/i => { type: :credential, sensitivity: :restricted },
      /\A(reset_password_token|remember_token|confirmation_token|unlock_token)\z/i => { type: :token, sensitivity: :restricted },
      /\A(authentication_token|auth_token|session_token|bearer_token)\z/i => { type: :token, sensitivity: :restricted },
      /\A(guest_token|persistence_token|perishable_token)\z/i => { type: :token, sensitivity: :restricted },
      /\A(gateway_customer_profile_id|gateway_payment_profile_id)\z/i => { type: :payment_token, sensitivity: :restricted }
    }.freeze

    # Common purposes with sensible defaults
    DEFAULT_PURPOSES = {
      service_delivery: {
        description: "Core service delivery and functionality",
        basis: :contract,
        requires: [:email, :name]
      },
      account_management: {
        description: "User account creation and management",
        basis: :contract,
        requires: [:email]
      },
      communication: {
        description: "Sending transactional and service-related communications",
        basis: :contract,
        requires: [:email]
      },
      billing: {
        description: "Processing payments and generating invoices",
        basis: :contract,
        requires: [:email, :address]
      },
      legal_compliance: {
        description: "Compliance with legal and regulatory requirements",
        basis: :legal_obligation,
        requires: [:email, :address]
      },
      audit_trail: {
        description: "Maintaining security and audit logs",
        basis: :legal_obligation,
        requires: [:ip_address]
      },
      analytics: {
        description: "Analyzing usage patterns to improve services",
        basis: :legitimate_interests,
        requires: []
      },
      marketing: {
        description: "Marketing communications and promotions",
        basis: :consent,
        requires: [:email]
      }
    }.freeze

    attr_reader :name, :output_path

    def initialize(name, output_path: nil)
      @name = name.to_s.underscore.to_sym
      @output_path = output_path || default_output_path
    end

    # Generate a basic policy template
    def generate
      content = generate_basic_policy
      write_file(content)
      print_summary
    end

    # Generate policy by scanning ActiveRecord models
    def generate_from_models
      detected_fields = scan_models
      content = generate_policy_from_fields(detected_fields)
      write_file(content)
      print_summary(detected_fields)
    end

    private

    def default_output_path
      if defined?(Rails)
        Rails.root.join("config", "initializers", "pam_dsl_policy.rb")
      else
        "pam_dsl_policy.rb"
      end
    end

    def generate_basic_policy
      <<~RUBY
        # frozen_string_literal: true

        # PAM DSL Privacy Policy for #{@name.to_s.titleize}
        #
        # This file defines PII fields, processing purposes, retention rules,
        # and consent requirements for GDPR compliance.
        #
        # Generated: #{Time.current.strftime('%Y-%m-%d %H:%M:%S')}
        #
        # Documentation: https://github.com/mpantel/lyra-engine/tree/main/gems/pam_dsl

        PamDsl.define_policy :#{@name} do
          # ─────────────────────────────────────────────────────────────────────────
          # PII FIELD DEFINITIONS
          # ─────────────────────────────────────────────────────────────────────────
          #
          # Sensitivity levels:
          #   :public      - Publicly accessible
          #   :internal    - Internal use only (low risk)
          #   :confidential - Sensitive, requires protection
          #   :restricted  - Highly restricted (financial, health, etc.)

          # Names
          field :first_name, type: :name, sensitivity: :internal
          field :last_name, type: :name, sensitivity: :internal

          # Contact
          field :email, type: :email, sensitivity: :confidential do
            transform :display do |value|
              value&.gsub(/(.{2})(.*)(@.*)/) { "\#{$1}" + "*" * $2.length + "\#{$3}" }
            end
            transform :log do |_value|
              "[EMAIL]"
            end
          end

          field :phone, type: :phone, sensitivity: :confidential do
            transform :display do |value|
              value ? "\#{value[0..3]}****\#{value[-2..]}" : nil
            end
            transform :log do |_value|
              "[PHONE]"
            end
          end

          # Address
          field :address, type: :address, sensitivity: :confidential

          # Technical
          field :ip_address, type: :ip_address, sensitivity: :internal

          # ─────────────────────────────────────────────────────────────────────────
          # PROCESSING PURPOSES
          # ─────────────────────────────────────────────────────────────────────────
          #
          # Legal bases (GDPR Article 6):
          #   :consent            - Data subject has given consent
          #   :contract           - Processing necessary for contract
          #   :legal_obligation   - Compliance with legal obligation
          #   :vital_interests    - Protection of vital interests
          #   :public_task        - Task in public interest
          #   :legitimate_interests - Legitimate interests

          purpose :service_delivery do
            describe "Core service delivery and functionality"
            basis :contract
            requires :email, :first_name, :last_name
          end

          purpose :communication do
            describe "Sending transactional and service-related communications"
            basis :contract
            requires :email
          end

          purpose :audit_trail do
            describe "Maintaining security and audit logs"
            basis :legal_obligation
            requires :ip_address, :email
          end

          # Uncomment if you need marketing with consent
          # purpose :marketing do
          #   describe "Marketing communications and promotions"
          #   basis :consent
          #   requires :email
          # end

          # ─────────────────────────────────────────────────────────────────────────
          # RETENTION RULES
          # ─────────────────────────────────────────────────────────────────────────

          retention do
            default 7.years

            # Add model-specific retention rules
            # for_model "User" do
            #   keep_for 7.years
            #   on_expiry :anonymize
            # end

            # for_model "Transaction" do
            #   keep_for 10.years  # Financial records
            # end
          end

          # ─────────────────────────────────────────────────────────────────────────
          # CONSENT REQUIREMENTS
          # ─────────────────────────────────────────────────────────────────────────

          consent do
            # Uncomment if you have marketing purpose
            # for_purpose :marketing do
            #   required!
            #   granular!
            #   withdrawable!
            #   expires_in 2.years
            #   describe "We'll send you product updates and promotional offers"
            # end
          end
        end

        # ─────────────────────────────────────────────────────────────────────────
        # RAILS CONFIGURATION
        # ─────────────────────────────────────────────────────────────────────────

        Rails.application.config.pam_dsl.default_policy = :#{@name}
        Rails.application.config.pam_dsl.organization = "Your Organization Name"
        Rails.application.config.pam_dsl.dpo_contact = "dpo@example.com"
      RUBY
    end

    def scan_models
      detected = {}

      if defined?(ActiveRecord::Base)
        # Get all ActiveRecord models
        Rails.application.eager_load! if defined?(Rails) && Rails.application

        ActiveRecord::Base.descendants.each do |model|
          next if model.abstract_class?
          next if model.name.start_with?("ActiveRecord::")
          next unless model.table_exists?

          model.column_names.each do |column|
            # Skip excluded patterns (timestamps, amounts, flags, etc.)
            next if excluded_field?(column)

            PII_PATTERNS.each do |pattern, config|
              if column.match?(pattern)
                detected[column.to_sym] ||= config.merge(models: [])
                detected[column.to_sym][:models] << model.name unless detected[column.to_sym][:models].include?(model.name)
              end
            end
          end
        end
      end

      detected
    end

    def excluded_field?(column)
      EXCLUDE_PATTERNS.any? { |pattern| column.match?(pattern) }
    end

    def generate_policy_from_fields(detected_fields)
      fields_code = generate_fields_code(detected_fields)
      purposes_code = generate_purposes_code(detected_fields)
      retention_code = generate_retention_code(detected_fields)

      <<~RUBY
        # frozen_string_literal: true

        # PAM DSL Privacy Policy for #{@name.to_s.titleize}
        #
        # Auto-generated from ActiveRecord models
        # Generated: #{Time.current.strftime('%Y-%m-%d %H:%M:%S')}
        #
        # Detected PII fields: #{detected_fields.keys.count}
        # Models scanned: #{detected_fields.values.flat_map { |v| v[:models] }.uniq.count}

        PamDsl.define_policy :#{@name} do
          # ─────────────────────────────────────────────────────────────────────────
          # PII FIELD DEFINITIONS (Auto-detected)
          # ─────────────────────────────────────────────────────────────────────────

        #{fields_code}

          # ─────────────────────────────────────────────────────────────────────────
          # PROCESSING PURPOSES
          # ─────────────────────────────────────────────────────────────────────────

        #{purposes_code}

          # ─────────────────────────────────────────────────────────────────────────
          # RETENTION RULES
          # ─────────────────────────────────────────────────────────────────────────

        #{retention_code}
        end

        # Configuration
        Rails.application.config.pam_dsl.default_policy = :#{@name}
        Rails.application.config.pam_dsl.organization = "Your Organization Name"
        Rails.application.config.pam_dsl.dpo_contact = "dpo@example.com"
      RUBY
    end

    def generate_fields_code(detected_fields)
      lines = []

      detected_fields.sort_by { |name, _| name }.each do |name, config|
        models_comment = "# Found in: #{config[:models].join(', ')}"
        field_def = "  field :#{name}, type: :#{config[:type]}, sensitivity: :#{config[:sensitivity]}"

        # Add masking transforms for sensitive fields
        if config[:sensitivity] == :confidential || config[:sensitivity] == :restricted
          lines << models_comment
          lines << "#{field_def} do"
          lines << generate_transform_code(name, config[:type])
          lines << "  end"
          lines << ""
        else
          lines << models_comment
          lines << field_def
        end
      end

      lines.join("\n")
    end

    def generate_transform_code(name, type)
      indent = "    "
      case type
      when :email
        lines = []
        lines << "#{indent}transform :display do |value|"
        lines << '#{indent}  value&.gsub(/(.{2})(.*)(@.*)/) { "#' + '{$1}" + \'*\' * $2.length + "#' + '{$3}" }'
        lines << "#{indent}end"
        lines << "#{indent}transform :log do |_value|"
        lines << '#{indent}  "[EMAIL]"'
        lines << "#{indent}end"
        lines.map { |l| l.gsub('#{indent}', indent) }.join("\n")
      when :phone
        lines = []
        lines << "#{indent}transform :display do |value|"
        lines << '#{indent}  value ? "#' + '{value[0..3]}****#' + '{value[-2..]}" : nil'
        lines << "#{indent}end"
        lines << "#{indent}transform :log do |_value|"
        lines << '#{indent}  "[PHONE]"'
        lines << "#{indent}end"
        lines.map { |l| l.gsub('#{indent}', indent) }.join("\n")
      when :identifier, :ssn, :credit_card
        type_label = type.to_s.upcase
        lines = []
        lines << "#{indent}transform :display do |value|"
        lines << '#{indent}  value ? "#' + '{value[0..2]}*****#' + '{value[-2..]}" : nil'
        lines << "#{indent}end"
        lines << "#{indent}transform :log do |_value|"
        lines << "#{indent}  \"[#{type_label}]\""
        lines << "#{indent}end"
        lines.map { |l| l.gsub('#{indent}', indent) }.join("\n")
      when :credential
        lines = []
        lines << "#{indent}transform :display do |_value|"
        lines << "#{indent}  \"[HIDDEN]\""
        lines << "#{indent}end"
        lines << "#{indent}transform :log do |_value|"
        lines << "#{indent}  \"[CREDENTIAL]\""
        lines << "#{indent}end"
        lines.join("\n")
      when :token, :payment_token
        type_label = type == :payment_token ? "PAYMENT_TOKEN" : "TOKEN"
        lines = []
        lines << "#{indent}transform :display do |value|"
        lines << "#{indent}  value ? \"\#{value[0..3]}...\" : nil"
        lines << "#{indent}end"
        lines << "#{indent}transform :log do |_value|"
        lines << "#{indent}  \"[#{type_label}]\""
        lines << "#{indent}end"
        lines.join("\n")
      else
        lines = []
        lines << "#{indent}transform :log do |_value|"
        lines << '#{indent}  "[REDACTED]"'
        lines << "#{indent}end"
        lines.map { |l| l.gsub('#{indent}', indent) }.join("\n")
      end
    end

    def generate_purposes_code(detected_fields)
      # Determine which purposes make sense based on detected fields
      field_names = detected_fields.keys

      purposes = []

      # Service delivery if we have names/emails
      if field_names.any? { |f| f.to_s.include?("name") || f.to_s.include?("email") }
        purposes << <<~RUBY
            purpose :service_delivery do
              describe "Core service delivery and functionality"
              basis :contract
              requires #{([:email] & field_names).map { |f| ":#{f}" }.join(", ")}
            end
        RUBY
      end

      # Billing if we have financial fields
      if field_names.any? { |f| f.to_s.include?("address") || f.to_s.include?("vat") }
        purposes << <<~RUBY
            purpose :billing do
              describe "Processing payments and generating invoices"
              basis :contract
              requires #{([:email, :address, :vat_number] & field_names).map { |f| ":#{f}" }.join(", ")}
            end
        RUBY
      end

      # Audit trail if we have IP address
      if field_names.include?(:ip_address)
        purposes << <<~RUBY
            purpose :audit_trail do
              describe "Maintaining security and audit logs"
              basis :legal_obligation
              requires :ip_address
            end
        RUBY
      end

      purposes.join("\n")
    end

    def generate_retention_code(detected_fields)
      models = detected_fields.values.flat_map { |v| v[:models] }.uniq

      lines = ["  retention do", "    default 7.years"]

      models.sort.each do |model|
        # Financial models get longer retention
        if model.match?(/payment|transaction|invoice|order/i)
          lines << ""
          lines << "    for_model \"#{model}\" do"
          lines << "      keep_for 10.years  # Financial records"
          lines << "    end"
        end
      end

      lines << "  end"
      lines.join("\n")
    end

    def write_file(content)
      FileUtils.mkdir_p(File.dirname(@output_path))
      File.write(@output_path, content)
    end

    def print_summary(detected_fields = nil)
      puts "\n" + "=" * 60
      puts " PAM DSL Policy Generated"
      puts "=" * 60
      puts "Policy name: #{@name}"
      puts "Output file: #{@output_path}"

      if detected_fields
        puts "\nDetected PII fields: #{detected_fields.keys.count}"
        puts "Models scanned: #{detected_fields.values.flat_map { |v| v[:models] }.uniq.count}"

        puts "\nFields by sensitivity:"
        detected_fields.group_by { |_, v| v[:sensitivity] }.each do |sens, fields|
          puts "  #{sens}: #{fields.count} (#{fields.map(&:first).join(', ')})"
        end
      end

      puts "\nNext steps:"
      puts "1. Review and customize the generated policy"
      puts "2. Update organization name and DPO contact"
      puts "3. Add model-specific retention rules"
      puts "4. Test with: rake privacy:policy"
      puts "=" * 60 + "\n"
    end
  end
end
