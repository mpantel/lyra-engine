module PamDsl
  # Represents a PII field definition
  class Field
    attr_reader :name, :type, :sensitivity, :purposes, :transformations, :metadata

    SENSITIVITY_LEVELS = [:public, :internal, :confidential, :restricted].freeze

    PII_TYPES = [
      :email, :name, :phone, :address, :ssn, :date_of_birth,
      :ip_address, :online_identifier, :credit_card, :financial, :health, :biometric,
      :location, :identifier, :credential, :token, :payment_token, :custom,
      # GDPR Art. 9(1) special categories beyond health and biometric data
      :genetic, :racial_ethnic_origin, :political_opinion, :religious_belief,
      :trade_union_membership, :sex_life_orientation,
      # GDPR Art. 10: criminal convictions and offences or related security measures
      :criminal_offence
    ].freeze

    # GDPR Article 9 special-category data is determined by the *kind* of data,
    # not by a risk label: one type per Art. 9(1) category (health, biometric,
    # genetic, racial or ethnic origin, political opinions, religious or
    # philosophical beliefs, trade-union membership, sex life or sexual
    # orientation). The :restricted sensitivity *level* is an Article 32 risk
    # tier and is deliberately independent of this set (Definition 1, Condition 5).
    SPECIAL_CATEGORY_TYPES = %i[
      health biometric genetic racial_ethnic_origin political_opinion
      religious_belief trade_union_membership sex_life_orientation
    ].freeze

    # GDPR Article 10 data (criminal convictions and offences): not a special
    # category. Its processing needs official authority or an authorisation by
    # Union or Member State law (Purpose#art10_authorisation), which an
    # Art. 9(2) basis does not give.
    CRIMINAL_DATA_TYPES = %i[criminal_offence].freeze

    # +withheld_from_access+, +about+ and +collected_from+ are what the Art. 15
    # copy reads (GDPRCompliance#data_export); they can also be declared in the
    # field's block. See the methods of the same name.
    def initialize(name, type:, sensitivity: :internal, withheld_from_access: nil, about: nil, collected_from: nil)
      @name = name.to_sym
      @type = type.to_sym
      @sensitivity = sensitivity.to_sym
      @purposes = []
      @transformations = {}
      @metadata = {}

      validate!
      self.withheld_from_access(withheld_from_access) unless withheld_from_access.nil?
      self.about(about) unless about.nil?
      self.collected_from(collected_from) unless collected_from.nil?
    end

    UNSET = Object.new.freeze
    private_constant :UNSET

    # The controller's stated basis for leaving this field out of a data
    # subject's copy (Art. 15(3)): text, such as "Art. 15(4): <the assessment>"
    # or the national restriction relied on. The copy names the field and this
    # basis under +withheld+ instead of its value. A field without it is
    # exported: PAM picks no basis. With no argument, returns it (nil if none).
    def withheld_from_access(basis = UNSET)
      return @withheld_from_access if basis.equal?(UNSET)

      unless basis.is_a?(String) && !basis.strip.empty?
        raise InvalidFieldError, "withheld_from_access on #{@name} needs the basis the controller relies on, as text " \
                                 "(got #{basis.inspect})"
      end
      @withheld_from_access = basis.strip
      self
    end

    def withheld_from_access?
      !@withheld_from_access.nil?
    end

    # Whose data the field is, when it is not the data subject's own: about
    # :payer for a payer's name on a student's registration. Such a field goes
    # to the copy's +review+, for the controller to weigh the other person's
    # rights (Art. 15(4)), not to its +attributes+. :data_subject (or nothing)
    # is the subject's own. With no argument, returns it.
    def about(party = UNSET)
      return @about if party.equal?(UNSET)

      unless (party.is_a?(Symbol) || party.is_a?(String)) && !party.to_s.strip.empty?
        raise InvalidFieldError, "about on #{@name} needs whose data the field is (:payer, :guardian), got #{party.inspect}"
      end
      @about = party.to_s.strip.to_sym
      self
    end

    def about_another_person?
      !@about.nil? && @about != :data_subject
    end

    # Where the data comes from (Art. 15(1)(g)): :data_subject, or text naming
    # the source ("the tax registry"). Undeclared, the copy lists the field
    # among its gaps. With no argument, returns it.
    def collected_from(source = UNSET)
      return @collected_from if source.equal?(UNSET)

      unless (source.is_a?(Symbol) || source.is_a?(String)) && !source.to_s.strip.empty?
        raise InvalidFieldError, "collected_from on #{@name} needs the source (:data_subject or text), got #{source.inspect}"
      end
      @collected_from = source.is_a?(Symbol) ? source : source.strip
      self
    end

    # Purposes this field is allowed for. It widens, it does not restrict:
    # Policy#allowed?(field, purpose) holds when the field lists the purpose
    # here OR the purpose lists the field (requires/optionally), so a field
    # listed in allow_for(:p) is allowed for :p even if :p's own field lists
    # do not name it, and a purpose that lists the field is allowed it even
    # if allow_for does not name that purpose. To keep a field from a
    # purpose, leave it out of both.
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

    # Whether this field's own allow_for list admits +purpose+ (true when
    # the list is empty). Only the field's side: whether a purpose may use
    # the field is Policy#allowed?, which also admits a purpose that lists
    # the field.
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

    # Check if field holds GDPR Article 10 data (criminal convictions and
    # offences). Requires an Art. 10 authorisation on the reading purpose.
    def criminal_data?
      CRIMINAL_DATA_TYPES.include?(@type)
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
