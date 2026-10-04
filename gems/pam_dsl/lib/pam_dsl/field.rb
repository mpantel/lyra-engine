module PamDsl
  # Represents a PII field definition
  class Field
    attr_reader :name, :type, :sensitivity, :purposes, :transformations, :metadata

    SENSITIVITY_LEVELS = [:public, :internal, :confidential, :restricted].freeze

    PII_TYPES = [
      :email, :name, :phone, :address, :ssn, :date_of_birth,
      :ip_address, :online_identifier, :credit_card, :financial, :health, :biometric,
      :location, :identifier, :credential, :token, :payment_token, :custom
    ].freeze

    # GDPR Article 9 special-category data is determined by the *kind* of data,
    # not by a risk label: health, biometric, genetic, racial/ethnic, political,
    # religious, trade-union, or sex-life/orientation data. Of PAM's PII_TYPES,
    # :health and :biometric are the Article 9 categories; this set is the single
    # place to extend should the taxonomy grow (e.g., a future :genetic type).
    # The :restricted sensitivity *level* is an Article 32 risk tier and is
    # deliberately independent of this set (Definition 1, Condition 5).
    SPECIAL_CATEGORY_TYPES = [:health, :biometric].freeze

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

    # Check if field is highly restricted (Article 32 risk tier)
    def restricted?
      @sensitivity == :restricted
    end

    # Check if field holds GDPR Article 9 special-category data (by type, not by
    # sensitivity level). Triggers the Art. 9(2) basis requirement in Definition 1,
    # Condition 5.
    def special_category?
      SPECIAL_CATEGORY_TYPES.include?(@type)
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
