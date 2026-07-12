module PamDsl
  # Represents a processing purpose
  class Purpose
    attr_reader :name, :description, :legal_basis, :art9_bases, :required_fields, :optional_fields, :metadata

    # Art. 9(2) sub-clauses permitting processing of special-category data
    ART9_BASES = [
      :explicit_consent,          # 9(2)(a) - explicit consent
      :employment_law,            # 9(2)(b) - employment / social security law
      :vital_interests,           # 9(2)(c) - vital interests, subject incapable of consenting
      :non_profit,                # 9(2)(d) - legitimate non-profit body, members/former members only
      :made_public,               # 9(2)(e) - data manifestly made public by subject
      :legal_claims,              # 9(2)(f) - legal claims / judicial acts
      :substantial_public_interest, # 9(2)(g) - substantial public interest (Union/Member State law)
      :health_care,               # 9(2)(h) - medical diagnosis, health/social care
      :public_health,             # 9(2)(i) - public health
      :research_archiving         # 9(2)(j) - scientific/historical research, statistics
    ].freeze

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
      @art9_bases = []
      @lia_documented = false
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

    # Record that a Legitimate Interests Assessment (LIA) has been conducted and documented
    # for this purpose (Art. 6(1)(f)). This is a human-judgment obligation — PAM cannot
    # automate the balancing test, but it can verify that one has been recorded.
    def lia_documented!(value = true)
      @lia_documented = value
      self
    end

    # True when a LIA has been recorded for this purpose
    def lia_documented?
      @lia_documented
    end

    # Declare one or more Art. 9(2) bases for processing special-category (restricted) data.
    # Multiple calls accumulate; passing multiple symbols in one call is also accepted.
    def art9_basis(*bases)
      bases.flatten.each do |b|
        b = b.to_sym
        unless ART9_BASES.include?(b)
          raise Error, "Invalid Art. 9(2) basis: #{b}. Must be one of #{ART9_BASES.join(', ')}"
        end
        @art9_bases << b unless @art9_bases.include?(b)
      end
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

    # True when the purpose carries at least one Art. 9(2) basis (Def. 1, Condition 5)
    def art9_basis?
      @art9_bases.any?
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
