module PamDsl
  # Represents a PII field definition
  class Field
    attr_reader :name, :type, :sensitivity, :purposes, :transformations, :metadata

    SENSITIVITY_LEVELS = [:public, :internal, :confidential, :restricted].freeze

    PII_TYPES = [
      :email, :name, :phone, :address, :ssn, :date_of_birth,
      :ip_address, :credit_card, :financial, :health, :biometric,
      :location, :identifier, :credential, :token, :payment_token, :custom
    ].freeze

    def initialize(name, type:, sensitivity: :internal)
      @name = name.to_sym
      @type = type.to_sym
      @sensitivity = sensitivity.to_sym
      @purposes = []
      @transformations = {}
      @metadata = {}

      validate!
    end

    # Define allowed purposes for this field
    def allow_for(*purpose_names)
      @purposes.concat(purpose_names.map(&:to_sym))
      self
    end

    # Define transformation rules for different contexts
    def transform(context, &block)
      @transformations[context.to_sym] = block
      self
    end

    # Add metadata
    def meta(key, value)
      @metadata[key] = value
      self
    end

    # Check if field is allowed for a purpose
    def allowed_for?(purpose)
      @purposes.empty? || @purposes.include?(purpose.to_sym)
    end

    # Apply transformation if defined
    def apply_transformation(context, value)
      transformation = @transformations[context.to_sym]
      transformation ? transformation.call(value) : value
    end

    # Check if field is sensitive
    def sensitive?
      [:confidential, :restricted].include?(@sensitivity)
    end

    # Check if field is highly restricted
    def restricted?
      @sensitivity == :restricted
    end

    private

    def validate!
      unless SENSITIVITY_LEVELS.include?(@sensitivity)
        raise InvalidFieldError, "Invalid sensitivity level: #{@sensitivity}. Must be one of #{SENSITIVITY_LEVELS.join(', ')}"
      end

      unless PII_TYPES.include?(@type)
        raise InvalidFieldError, "Invalid PII type: #{@type}. Must be one of #{PII_TYPES.join(', ')}"
      end
    end
  end
end
