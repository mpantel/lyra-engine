module PamDsl
  # Main policy class that combines all privacy aspects
  class Policy
    attr_reader :name, :fields, :purposes, :retention_policy, :consent_policy, :metadata

    def initialize(name)
      @name = name.to_sym
      @fields = {}
      @purposes = {}
      @retention_policy = RetentionPolicy.new
      @consent_policy = ConsentPolicy.new
      @metadata = {}
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
      @purposes[name.to_sym] || raise(Error, "Purpose '#{name}' not defined in policy '#{@name}'")
    end

    # Check if field is allowed for purpose
    def allowed?(field_name, purpose_name)
      field = @fields[field_name.to_sym]
      purpose = @purposes[purpose_name.to_sym]

      return false unless field && purpose

      # Check if field allows this purpose
      return false unless field.allowed_for?(purpose_name)

      # Check if purpose allows this field
      return false unless purpose.allows_field?(field_name)

      true
    end

    # Validate data access
    def validate_access!(field_names, purpose_name, consent_granted: false, consent_granted_at: nil)
      purpose = get_purpose(purpose_name)

      # Check consent if required
      if purpose.requires_consent?
        @consent_policy.validate!(
          purpose_name,
          granted: consent_granted,
          granted_at: consent_granted_at
        )
      end

      # Check if all fields are allowed for this purpose
      field_names.each do |field_name|
        unless allowed?(field_name, purpose_name)
          raise Error, "Field '#{field_name}' not allowed for purpose '#{purpose_name}'"
        end
      end

      true
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
