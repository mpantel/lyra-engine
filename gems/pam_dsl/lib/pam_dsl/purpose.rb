module PamDsl
  # Represents a processing purpose
  class Purpose
    attr_reader :name, :description, :legal_basis, :required_fields, :optional_fields, :metadata

    LEGAL_BASES = [
      :consent,              # Article 6(1)(a) - Data subject has given consent
      :contract,             # Article 6(1)(b) - Processing necessary for contract
      :legal_obligation,     # Article 6(1)(c) - Compliance with legal obligation
      :vital_interests,      # Article 6(1)(d) - Protection of vital interests
      :public_task,          # Article 6(1)(e) - Task in public interest
      :legitimate_interests  # Article 6(1)(f) - Legitimate interests
    ].freeze

    def initialize(name)
      @name = name.to_sym
      @description = ""
      @legal_basis = :consent
      @required_fields = []
      @optional_fields = []
      @metadata = {}
    end

    # Set description
    def describe(text)
      @description = text
      self
    end

    # Set legal basis
    def basis(legal_basis)
      legal_basis_sym = legal_basis.to_sym
      unless LEGAL_BASES.include?(legal_basis_sym)
        raise Error, "Invalid legal basis: #{legal_basis}. Must be one of #{LEGAL_BASES.join(', ')}"
      end
      @legal_basis = legal_basis_sym
      self
    end

    # Define required fields
    def requires(*field_names)
      @required_fields.concat(field_names.map(&:to_sym))
      self
    end

    # Define optional fields
    def optionally(*field_names)
      @optional_fields.concat(field_names.map(&:to_sym))
      self
    end

    # Add metadata
    def meta(key, value)
      @metadata[key] = value
      self
    end

    # Check if purpose requires consent
    def requires_consent?
      @legal_basis == :consent
    end

    # Get all fields (required + optional)
    def all_fields
      (@required_fields + @optional_fields).uniq
    end

    # Check if a field is required for this purpose
    def requires_field?(field_name)
      @required_fields.include?(field_name.to_sym)
    end

    # Check if a field is allowed for this purpose
    def allows_field?(field_name)
      all_fields.include?(field_name.to_sym)
    end
  end
end
