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
    # PII is detected by PIIDetector, the one dictionary PAM has. The generator
    # used to keep its own exact-name patterns and exclusions; on Solidus the
    # two disagreed, and the generator's found 7 fields where 26 were
    # personal (it never saw address1, zipcode or any IP column, and dropped
    # vat_id with every other *_id).

    # Types too common to call personal on their own: a bare "name" is a
    # product's, a programme's or a payment plan's as often as a person's. A
    # model's name column counts only alongside other personal data in the
    # same model (an address's name does; a product's does not).
    CONTEXT_DEPENDENT_TYPES = %i[name].freeze

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
        requires: [:email, :address, :identifier, :financial, :credit_card]
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

    # Raised instead of overwriting an existing policy file (a policy the
    # team has reviewed and edited) unless the generator was told to force.
    class FileExistsError < StandardError; end

    attr_reader :name, :output_path

    # +force+: overwrite +output_path+ if it already exists. Without it the
    # generator refuses, before scanning anything.
    def initialize(name, output_path: nil, force: false)
      @name = name.to_s.underscore.to_sym
      @output_path = output_path || default_output_path
      @force = force
    end

    # Generate a basic policy template
    def generate
      refuse_overwrite!
      content = generate_basic_policy
      write_file(content)
      print_summary
    end

    # Generate policy by scanning ActiveRecord models
    def generate_from_models
      refuse_overwrite!
      detected_fields = scan_models
      content = generate_policy_from_fields(detected_fields)
      write_file(content)
      print_summary(detected_fields)
    end

    private

    def refuse_overwrite!
      return if @force || !File.exist?(@output_path)

      raise FileExistsError, "#{@output_path} already exists; not overwriting it. " \
                             "Rerun with FORCE=1 to replace it (or move the file aside)."
    end

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

    # field => { type:, sensitivity:, models: [...], ignored_in: [...] }. The
    # table's real columns are scanned, not only the model's: a column the
    # model ignores (ignored_columns) still holds data the application can no
    # longer see or erase, so it is reported, in ignored_in.
    def scan_models
      detected = {}
      return detected unless defined?(ActiveRecord::Base)

      Rails.application.eager_load! if defined?(Rails) && Rails.application
      ActiveRecord::Base.descendants.each do |model|
        next if model.abstract_class?
        next if model.name.nil? || model.name.start_with?("ActiveRecord::")
        next unless model.table_exists?

        scan_model(model).each do |column, config|
          entry = detected[column.to_sym] ||= config.slice(:type, :sensitivity).merge(models: [], ignored_in: [])
          entry[:models] |= [model.name]
          entry[:ignored_in] |= [model.name] if config[:ignored]
        end
      end
      detected
    end

    # The personal columns of one model: column => { type:, sensitivity:, ignored: }.
    def scan_model(model)
      columns = model.connection.columns(model.table_name).map(&:name) - [model.primary_key.to_s]
      ignored = model.ignored_columns.map(&:to_s)
      found = columns.filter_map do |column|
        type = PIIDetector.pii_type(column)
        next unless type

        [column, { type: type, sensitivity: PIIDetector.sensitivity(column), ignored: ignored.include?(column) }]
      end.to_h
      return found if found.values.any? { |c| !CONTEXT_DEPENDENT_TYPES.include?(c[:type]) }

      found.reject { |_, c| CONTEXT_DEPENDENT_TYPES.include?(c[:type]) }
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
        if config[:ignored_in].to_a.any?
          models_comment += "\n# Ignored by #{config[:ignored_in].join(', ')} (ignored_columns): the application cannot " \
                            "see or erase what this column holds; empty it by migration"
        end
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
      return "" if detected_fields.empty?

      detected_types = detected_fields.values.map { |c| c[:type] }.uniq
      fields_by_type = detected_fields.each_with_object(Hash.new { |h, k| h[k] = [] }) do |(name, config), h|
        h[config[:type]] << name
      end

      purposes = []

      DEFAULT_PURPOSES.each do |purpose_name, config|
        required_types = config[:requires]
        next unless required_types.empty? || required_types.any? { |t| detected_types.include?(t) }

        matching_fields = required_types.flat_map { |t| fields_by_type[t] }
        requires_clause = matching_fields.map { |f| ":#{f}" }.join(", ")

        lia_line = config[:basis] == :legitimate_interests \
          ? "# lia_documented!  # uncomment after conducting the LIA balancing test\n              " \
          : ""

        purposes << <<~RUBY
            purpose :#{purpose_name} do
              describe "#{config[:description]}"
              basis :#{config[:basis]}
              #{lia_line}#{"requires #{requires_clause}" unless requires_clause.empty?}
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
