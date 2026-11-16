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
      @purposes.each_value { |p| gaps << [p.name, "Art. 6(1) legal basis (undetermined)"] if p.basis_undetermined? }
      gaps.concat(special_data_gaps)
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

    # The items of the controller's notice that a data subject's copy carries
    # (Art. 15(1)(e), (f), (h), and who the controller is), and the gap each
    # leaves when the policy does not state it.
    ACCESS_NOTICE_ITEMS = {
      controller: "identity and contact details of the controller (notice)",
      rights: "Art. 15(1)(e) rights of the data subject (notice)",
      complaint: "Art. 15(1)(f) right to lodge a complaint (notice)",
      automated_decisions: "Art. 15(1)(h) automated decision-making"
    }.freeze

    # The controller's notice for the Art. 15 copy, as text: who the controller
    # is (+controller+), the rights to rectification, erasure, restriction and
    # objection (+rights+), the right to complain to a supervisory authority
    # (+complaint+), and whether there is automated decision-making
    # (+automated_decisions+). PAM cannot know any of these; an item the policy
    # leaves out is a gap in every copy. Repeated calls add items. With no
    # argument, returns the notice ({} if none).
    #
    #   access_notice controller: "University of X, Registry, dpo@x.example",
    #                 rights: "...", complaint: "the Hellenic DPA, www.dpa.gr"
    def access_notice(**items)
      return @access_notice || {} if items.empty?

      unknown = items.keys - ACCESS_NOTICE_ITEMS.keys
      raise ArgumentError, "Unknown access_notice item(s) #{unknown.join(', ')}; known: #{ACCESS_NOTICE_ITEMS.keys.join(', ')}" if unknown.any?

      empty = items.select { |_item, text| text.nil? || text.to_s.strip.empty? }.keys
      # An empty item would read as declared; leave it out and the copy lists it as a gap.
      raise Error, "access_notice item(s) #{empty.join(', ')} need text" if empty.any?

      @access_notice = (@access_notice || {}).merge(items.transform_values { |text| text.to_s.strip })
      self
    end

    # Define a PII field. +options+ are the Art. 15 copy's field options:
    # withheld_from_access:, about:, collected_from: (see PamDsl::Field).
    def field(name, type:, sensitivity: :internal, **options, &block)
      field = Field.new(name, type: type, sensitivity: sensitivity, **options)
      field.instance_eval(&block) if block_given?
      @fields[field.name] = field
      field
    end

    # Define a processing purpose
    def purpose(name, &block)
      purpose = Purpose.new(name)
      purpose.instance_eval(&block) if block_given?
      @purposes[purpose.name] = purpose
      validate_consent_grammar!
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
      validate_consent_grammar!
      @consent_policy
    end

    # A purpose whose basis is consent (Art. 6(1)(a)) cannot make consent optional
    # (required! false) or not withdrawable (withdrawable! false): the Regulation
    # allows neither (Arts. 4(11), 7(3)). Checked after each purpose and each consent
    # block, whichever comes first, and again when define_policy completes a policy.
    def validate_consent_grammar!
      @consent_policy.requirements.each do |requirement|
        purpose = @purposes[requirement.purpose]
        next unless purpose && purpose.legal_basis == :consent

        unless requirement.required?
          raise ConsentGrammarError,
                "Purpose :#{purpose.name} has the legal basis :consent, so consent cannot be optional " \
                "(required! false): without it there is no basis (Art. 6(1)(a))."
        end
        next if requirement.withdrawable?

        raise ConsentGrammarError,
              "Purpose :#{purpose.name} has the legal basis :consent, so consent must be withdrawable " \
              "(withdrawable! false): withdrawing it must be as easy as giving it (Art. 7(3))."
      end
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
      enforce(access_violations(field_names, purpose_name, subject: subject), field_names, purpose_name, subject)
    end

    # Def. 1 for a use whose subjects are not known yet, such as a query
    # before it runs: every condition of validate_access! except consent
    # (Condition 4 for a :consent purpose) and Condition 6 (restrictions and
    # objections), which are decided per subject.
    # The purpose is declared, its basis determined, each field declared and
    # allowed for it, and special categories have an Art. 9(2) basis.
    #
    # Enforced as validate_access! is (strict raises the first violation,
    # audit reports every one and returns false) and recorded by the access
    # recorder. +subject+ is optional and only labels the record and the
    # reported violations (Lyra passes "Model$*").
    def validate_fields!(field_names, purpose_name, subject: nil)
      enforce(field_violations(field_names, purpose_name), field_names, purpose_name, subject)
    end

    # Condition 6 alone (Arts. 18 and 21): the subject's restrictions and
    # upheld objections that cover this access, for a use that names no
    # declared field, or whose other conditions are checked elsewhere. A host
    # calls it for a record loaded by columns the policy does not declare
    # (Lyra): a restriction of all of the subject's data, a pending
    # objection's restriction of the purpose and an upheld objection cover
    # such a load; a restriction of some fields covers it only when
    # +field_names+ includes one of them. Neither the purpose's declaration
    # nor consent is checked here.
    #
    # Free when nothing is in force anywhere (the store's any_active?). An
    # access it allows is not recorded; a refusal is enforced and recorded as
    # validate_access! enforces and records it (strict raises, audit reports
    # and returns false).
    def validate_rights!(field_names, purpose_name, subject:)
      violations = rights_violations(field_names, purpose_name, subject: subject)
      return true if violations.empty?

      enforce(violations, field_names, purpose_name, subject)
    end

    # The violations validate_rights! would enforce, without enforcing or
    # recording them: [] when nothing is in force, the purpose is not
    # declared, or the subject's requests do not cover the access.
    def rights_violations(field_names, purpose_name, subject:)
      return [] unless PamDsl.rights_store.any_active?

      # A purpose the policy does not declare declares no Art. 18(2)
      # exception: Condition 6 holds for it as for any other.
      purpose = @purposes[purpose_name.to_sym] || Purpose.new(purpose_name.to_sym)
      Rights.violations_for(self, purpose, field_names, subject)
    end

    # Every violation validate_fields! would find, without raising or
    # recording anything.
    def field_violations(field_names, purpose_name)
      violations_of(field_names, purpose_name, subject: nil, consent: false)
    end

    # Every violation of Def. 1 for this access, in the order validation
    # checks them (strict mode raises the first): purpose declared, then
    # Condition 4 (legal basis: consent), then each field (declared, then
    # allowed for the purpose), then Condition 5 (special categories), then
    # the Art. 10 condition (criminal-offence data), then Condition 6 (the
    # subject's restrictions and objections, Arts. 18 and 21).
    def access_violations(field_names, purpose_name, subject:)
      violations_of(field_names, purpose_name, subject: subject, consent: true)
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

    # The retention period the policy declares for a model (and field), or
    # nil when it declares none (RetentionPolicy#declared_duration_for).
    def declared_retention_for(model_class, field_name: nil)
      @retention_policy.declared_duration_for(model_class, field_name: field_name)
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
        access_notice: access_notice,
        metadata: @metadata
      }
    end

    # Does the purpose read a field the predicate selects (special_category?,
    # criminal_data?): one it lists, or one allowed for it.
    def purpose_reads?(purpose, predicate)
      @fields.each_value.any? { |f| f.public_send(predicate) && allowed?(f.name, purpose.name) }
    end

    private

    # A purpose that reads special-category data with no Art. 9(2) basis, or
    # Art. 10 data with no Art. 10 authorisation: access would be refused, and
    # the register cannot say what permits the processing.
    def special_data_gaps
      @purposes.each_value.flat_map do |p|
        gaps = []
        gaps << [p.name, "Art. 9(2) basis for special-category data"] if purpose_reads?(p, :special_category?) && !p.art9_basis?
        gaps << [p.name, "Art. 10 authorisation for criminal-offence data"] if purpose_reads?(p, :criminal_data?) && !p.art10_authorised?
        gaps
      end
    end

    def field_to_h(field)
      {
        type: field.type,
        sensitivity: field.sensitivity,
        purposes: field.purposes,
        withheld_from_access: field.withheld_from_access,
        about: field.about,
        collected_from: field.collected_from,
        metadata: field.metadata
      }.compact
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
        objectable: purpose.objectable,
        direct_marketing: purpose.direct_marketing?,
        research_or_statistics: purpose.research_or_statistics,
        allowed_when_restricted: purpose.restriction_exceptions,
        important_public_interest_reference: purpose.important_public_interest_reference,
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
            withdrawable: req.withdrawable?,
            description: req.description,
            expires_after: req.expires_after
          }
        }
      }
    end

    # Strict raises the first violation; audit reports each and returns false.
    # Every call is recorded first.
    def enforce(violations, field_names, purpose_name, subject)
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

    def violations_of(field_names, purpose_name, subject:, consent:)
      purpose = begin
        get_purpose(purpose_name)
      rescue UndeclaredPurposeError => e
        return [e]
      end
      violations = []

      # Condition 4 (Def. 1): legal basis satisfied — none yet for a generated
      # purpose whose basis is still to be decided; consent delegates to CS
      if purpose.basis_undetermined?
        violations << UndeterminedBasisError.new("Purpose #{purpose_name} has no legal basis yet: the controller decides one")
      elsif consent && purpose.requires_consent?
        # The basis is consent: an active consent is needed whether or not the
        # policy declares a consent block for the purpose (Art. 6(1)(a)).
        begin
          @consent_policy.validate!(purpose_name, subject: subject, required: true)
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
        violations << SpecialCategoryViolationError.new(
          "Purpose '#{purpose_name}' accesses special-category (Article 9) data but declares no Art. 9(2) basis"
        )
      end

      # The Art. 10 condition: criminal-offence data needs official authority or
      # an authorisation by Union or Member State law, declared on the purpose
      # (art10_authorisation). Its own condition, not Condition 5: an Art. 9(2)
      # basis does not satisfy Art. 10, nor an Art. 10 authorisation Art. 9.
      has_criminal_data = field_names.any? { |fn| @fields[fn.to_sym]&.criminal_data? }
      if has_criminal_data && !purpose.art10_authorised?
        violations << CriminalDataViolationError.new(
          "Purpose '#{purpose_name}' accesses criminal-offence (Article 10) data but declares no official " \
          "authority or Union or Member State law that authorises it (art10_authorisation)"
        )
      end

      # Condition 6 (Arts. 18 and 21), last: the subject's restrictions and
      # upheld objections (PamDsl::Rights). Per subject only, so not on the
      # subject-less path (validate_fields!).
      violations.concat(Rights.violations_for(self, purpose, field_names, subject)) if consent

      violations
    end
  end
end
