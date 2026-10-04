module PamDsl
  # Main policy class that combines all privacy aspects
  class Policy
    attr_reader :name, :fields, :purposes, :retention_policy, :consent_policy, :metadata

    # Article 30(1) items each purpose must declare for the record of
    # processing, and the clause that asks for each.
    ARTICLE_30_PURPOSE_ITEMS = {
      data_subjects: "Art. 30(1)(c) categories of data subjects",
      recipients: "Art. 30(1)(d) categories of recipients",
      transfers: "Art. 30(1)(e) transfers to third countries"
    }.freeze

    def initialize(name)
      @name = name.to_sym
      @fields = {}
      @purposes = {}
      @retention_policy = RetentionPolicy.new
      @consent_policy = ConsentPolicy.new
      @metadata = {}
      @security_measures = []
    end

    # A general description of the technical and organisational security
    # measures (Art. 30(1)(g)): "TLS in transit", "role-based access".
    def security_measures(*measures)
      return @security_measures if measures.empty?

      @security_measures |= measures.flatten.map(&:to_s)
      self
    end

    # What the record of processing cannot state because the policy does not
    # declare it: [[purpose name or nil, the Article 30(1) item]]. Empty when
    # the register is complete.
    def article_30_gaps
      gaps = @purposes.values.flat_map do |purpose|
        ARTICLE_30_PURPOSE_ITEMS.filter_map do |item, clause|
          declared = item == :transfers ? purpose.transfers_declared? : purpose.public_send(item).any?
          [purpose.name, clause] unless declared
        end
      end
      gaps << [nil, "Art. 30(1)(g) security measures"] if @security_measures.empty?
      gaps
    end

    # Enforcement mode for this policy, overriding PamDsl.enforcement_mode:
    # `enforcement :audit` in the definition. See PamDsl::Enforcement.
    def enforcement(mode)
      @enforcement_mode = Enforcement.validate_mode!(mode)
    end

    # The mode this policy enforces with: its own, or the global one.
    def enforcement_mode
      @enforcement_mode || PamDsl.enforcement_mode
    end

    # Define a PII field
    def field(name, type:, sensitivity: :internal, &block)
      field = Field.new(name, type: type, sensitivity: sensitivity)
      field.instance_eval(&block) if block_given?
      @fields[field.name] = field
      field
    end

    # Define a processing purpose
    def purpose(name, &block)
      purpose = Purpose.new(name)
      purpose.instance_eval(&block) if block_given?
      @purposes[purpose.name] = purpose
      purpose
    end

    # Configure retention policy
    def retention(&block)
      @retention_policy.instance_eval(&block) if block_given?
      @retention_policy
    end

    # Configure consent policy
    def consent(&block)
      @consent_policy.instance_eval(&block) if block_given?
      @consent_policy
    end

    # Add metadata
    def meta(key, value)
      @metadata[key] = value
      self
    end

    # Get a field by name
    def get_field(name)
      @fields[name.to_sym] || raise(InvalidFieldError, "Field '#{name}' not defined in policy '#{@name}'")
    end

    # Get a purpose by name
    def get_purpose(name)
      @purposes[name.to_sym] || raise(UndeclaredPurposeError, "Purpose '#{name}' not defined in policy '#{@name}'")
    end

    # Check if field is allowed for purpose.
    #
    # The two declaration notations are equivalent (paper §3.2): `allow_for :p` on a field
    # and listing the field under `requires`/`optionally` on the purpose are alternative
    # entry points to the same constraint. When the field carries an explicit allow_for
    # declaration, either side is sufficient. When the field has no allow_for declarations
    # it imposes no restriction and the purpose-side declaration is authoritative.
    def allowed?(field_name, purpose_name)
      field = @fields[field_name.to_sym]
      purpose = @purposes[purpose_name.to_sym]

      return false unless field && purpose

      if field.purposes.empty?
        purpose.allows_field?(field_name)
      else
        field.purposes.include?(purpose_name.to_sym) || purpose.allows_field?(field_name)
      end
    end

    # Validate data access for a (fields, purpose, subject) triple — Def. 1.
    #
    # Strict mode (the default) raises the first violation as its typed
    # exception. Audit mode records every violation (logged, and passed to
    # PamDsl.on_violation handlers) and returns false instead of raising.
    # Either way, true means the access is valid. See PamDsl::Enforcement.
    # Every call, whatever its outcome, goes to PamDsl.access_recorder if
    # one is set.
    def validate_access!(field_names, purpose_name, subject:)
      violations = access_violations(field_names, purpose_name, subject: subject)
      PamDsl.record_access(self, field_names, purpose_name, subject, violations)
      return true if violations.empty?
      raise violations.first if enforcement_mode == :strict

      violations.each do |error|
        PamDsl.report_violation(Enforcement::Violation.new(
          policy: name, purpose: purpose_name, fields: field_names, subject: subject,
          error_class: error.class, message: error.message, at: Time.now
        ))
      end
      false
    end

    # Every violation of Def. 1 for this access, in the order validation
    # checks them (strict mode raises the first): purpose declared, then
    # Condition 4 (legal basis: consent), then each field (declared, then
    # allowed for the purpose), then Condition 5 (special categories).
    def access_violations(field_names, purpose_name, subject:)
      purpose = begin
        get_purpose(purpose_name)
      rescue UndeclaredPurposeError => e
        return [e]
      end
      violations = []

      # Condition 4 (Def. 1): legal basis satisfied — consent check delegates to CS
      if purpose.requires_consent?
        begin
          @consent_policy.validate!(purpose_name, subject: subject)
        rescue ConsentRequiredError => e
          violations << e
        end
      end

      # Each field: existence first (InvalidFieldError), then membership (PurposeFieldMismatchError)
      field_names.each do |field_name|
        begin
          get_field(field_name)
        rescue InvalidFieldError => e
          violations << e
          next
        end
        unless allowed?(field_name, purpose_name)
          violations << PurposeFieldMismatchError.new("Field '#{field_name}' not allowed for purpose '#{purpose_name}'")
        end
      end

      # Condition 5 (Def. 1): special-category fields require an Art. 9(2) basis on
      # the purpose. Special category is determined by the *type* of data (Art. 9 —
      # health, biometric, ...), independently of the :restricted sensitivity *level*
      # (an Art. 32 risk tier). High-risk-but-ordinary data such as tax or bank
      # identifiers may be :restricted without demanding an Art. 9(2) basis.
      has_special_category = field_names.any? do |fn|
        f = @fields[fn.to_sym]
        f&.special_category?
      end

      if has_special_category && !purpose.art9_basis?
        violations << SensitivityViolationError.new(
          "Purpose '#{purpose_name}' accesses special-category (Article 9) data but declares no Art. 9(2) basis"
        )
      end

      violations
    end

    # Returns purposes whose legal basis is :legitimate_interests but whose LIA has not
    # been recorded via lia_documented!. These represent compliance gaps: Art. 6(1)(f)
    # requires a balancing test — a human-judgment obligation PAM cannot enforce at runtime
    # but can verify has been documented (paper §3.2, Def. 2).
    def lia_compliance_gaps
      @purposes.values.select do |p|
        p.legal_basis == :legitimate_interests && !p.lia_documented?
      end
    end

    # Get all sensitive fields
    def sensitive_fields
      @fields.values.select(&:sensitive?)
    end

    # Get all restricted fields
    def restricted_fields
      @fields.values.select(&:restricted?)
    end

    # Get retention duration for a model
    def retention_for(model_class, field_name: nil)
      @retention_policy.duration_for(model_class, field_name: field_name)
    end

    # Export policy as hash
    def to_h
      {
        name: @name,
        fields: @fields.transform_values { |f| field_to_h(f) },
        purposes: @purposes.transform_values { |p| purpose_to_h(p) },
        retention: retention_to_h,
        consent: consent_to_h,
        security_measures: @security_measures,
        metadata: @metadata
      }
    end

    private

    def field_to_h(field)
      {
        type: field.type,
        sensitivity: field.sensitivity,
        purposes: field.purposes,
        metadata: field.metadata
      }
    end

    def purpose_to_h(purpose)
      {
        description: purpose.description,
        legal_basis: purpose.legal_basis,
        required_fields: purpose.required_fields,
        optional_fields: purpose.optional_fields,
        data_subjects: purpose.data_subjects,
        recipients: purpose.recipients,
        transfers: purpose.transfers,
        metadata: purpose.metadata
      }
    end

    def retention_to_h
      {
        default_duration: @retention_policy.default_duration,
        rules: @retention_policy.rules.map { |rule|
          {
            model_class: rule.model_class,
            duration: rule.duration,
            field_overrides: rule.field_overrides,
            deletion_strategy: rule.deletion_strategy
          }
        }
      }
    end

    def consent_to_h
      {
        requirements: @consent_policy.requirements.map { |req|
          {
            purpose: req.purpose,
            required: req.required?,
            granular: req.granular?,
            withdrawable: req.withdrawable?,
            description: req.description,
            expires_after: req.expires_after
          }
        }
      }
    end
  end
end
