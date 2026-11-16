module PamDsl
  # Represents a processing purpose
  class Purpose
    attr_reader :name, :description, :legal_basis, :art9_bases, :art10_authorisations, :required_fields,
                :optional_fields, :metadata, :data_subjects, :recipients, :transfers,
                :restriction_exceptions, :important_public_interest_reference

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

    # Not a legal basis: the marker a generated draft carries until the
    # controller decides one (PolicyGenerator). Access under such a purpose
    # is refused (UndeterminedBasisError) and the register lists the purpose
    # among its gaps, so a draft cannot run as if its basis were settled.
    UNDETERMINED = :undetermined

    def initialize(name)
      @name = name.to_sym
      @description = ""
      # No basis declared is no basis decided: access is refused and the register
      # lists the purpose as a gap. It used to default to :consent, which the
      # register printed as Art. 6(1)(a) and nothing checked.
      @legal_basis = UNDETERMINED
      @art9_bases = []
      @art10_authorisations = []
      @lia_documented = false
      @required_fields = []
      @optional_fields = []
      @metadata = {}
      @data_subjects = []
      @recipients = []
      @transfers = nil # nil: not declared; []: declared none
      @restriction_exceptions = []
      @important_public_interest_reference = nil
      @direct_marketing = false
      @research_or_statistics = nil # nil: not research; else { public_interest_task: true|false }
    end

    # Set description
    def describe(text)
      @description = text
      self
    end

    # Set legal basis
    def basis(legal_basis)
      legal_basis_sym = legal_basis.to_sym
      return @legal_basis = UNDETERMINED if legal_basis_sym == UNDETERMINED
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

    # Declare what authorises processing Art. 10 data (criminal convictions and
    # offences) for this purpose: the official authority under whose control it
    # is processed, or the Union or Member State law that authorises it, named
    # in text (the act and article). Art. 10 has no list of grounds like
    # Art. 9(2), so the authorisation is named, not chosen from a set; an
    # Art. 9(2) basis does not stand in for it. Multiple calls accumulate.
    def art10_authorisation(*authorisations)
      authorisations.flatten.each do |authorisation|
        unless authorisation.is_a?(String) && !authorisation.strip.empty?
          raise Error, "Invalid Art. 10 authorisation: #{authorisation.inspect}. Name the official authority " \
                       "or the Union or Member State law that authorises the processing, as text"
        end
        text = authorisation.strip
        @art10_authorisations << text unless @art10_authorisations.include?(text)
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

    # ── Article 30(1) facts about the purpose, for the record of processing ──

    # Categories of data subjects (Art. 30(1)(c)): "applicants", "customers".
    def data_subjects(*categories)
      return @data_subjects if categories.empty?

      @data_subjects |= categories.flatten.map(&:to_s)
      self
    end

    # Categories of recipients the data is disclosed to (Art. 30(1)(d)),
    # including processors: "card payment processor", "tax authority".
    def recipients(*names)
      return @recipients if names.empty?

      @recipients |= names.flatten.map(&:to_s)
      self
    end

    # A transfer to a third country or international organisation and its
    # safeguard (Art. 30(1)(e), Chapter V): transfer to: "US", safeguard:
    # :standard_contractual_clauses.
    def transfer(to:, safeguard:)
      (@transfers ||= []) << { to: to.to_s, safeguard: safeguard.to_s }
      self
    end

    # Declare that the purpose involves no international transfer.
    def no_transfers!
      @transfers = []
      self
    end

    def transfers_declared?
      !@transfers.nil?
    end

    # Add metadata
    def meta(key, value)
      @metadata[key] = value
      self
    end

    # ── Arts. 18 and 21: what the purpose does when a subject exercises a right ──

    # The Art. 18(2) grounds on which a purpose may go on processing a subject's
    # data while its processing is restricted. Storage needs none: it is not a
    # purpose, and Art. 18(2) excepts it.
    RESTRICTION_EXCEPTIONS = {
      consent: "the data subject's consent",
      legal_claims: "the establishment, exercise or defence of legal claims",
      protection_of_rights: "the protection of the rights of another natural or legal person",
      important_public_interest: "important public interest of the Union or of a Member State"
    }.freeze

    # Declare that the purpose continues while a subject's processing is
    # restricted, on one or more Art. 18(2) grounds. :important_public_interest
    # needs reference: naming the Union or Member State law. The :consent
    # exception holds only with an active consent for (purpose, subject) granted
    # after the restriction was requested. Multiple calls accumulate.
    def allowed_when_restricted(*exceptions, reference: nil)
      exceptions = exceptions.flatten.map(&:to_sym)
      raise Error, "allowed_when_restricted needs at least one Art. 18(2) exception" if exceptions.empty?

      unknown = exceptions - RESTRICTION_EXCEPTIONS.keys
      if unknown.any?
        raise Error, "Invalid Art. 18(2) exception: #{unknown.join(', ')}. " \
                     "Must be one of #{RESTRICTION_EXCEPTIONS.keys.join(', ')}"
      end
      apply_public_interest_reference(exceptions, reference)
      @restriction_exceptions |= exceptions
      self
    end

    # Does the purpose declare this Art. 18(2) exception?
    def continues_under_restriction?(exception)
      @restriction_exceptions.include?(exception.to_sym)
    end

    # Mark the purpose as direct marketing (Art. 21(2)): the subject can object
    # whatever the basis, and an objection is upheld at once (Art. 21(3)).
    def direct_marketing!
      raise Error, "Purpose #{@name} cannot be both direct marketing and research or statistics" if @research_or_statistics

      @direct_marketing = true
      self
    end

    def direct_marketing?
      @direct_marketing
    end

    # Mark the purpose as scientific or historical research or statistics under
    # Art. 89(1). The subject can object (Art. 21(6)) unless the processing is
    # necessary for a task carried out in the public interest, which the
    # controller states with public_interest_task:.
    def research_or_statistics!(public_interest_task:)
      unless [true, false].include?(public_interest_task)
        raise Error, "research_or_statistics! needs public_interest_task: true or false"
      end
      raise Error, "Purpose #{@name} cannot be both research or statistics and direct marketing" if @direct_marketing

      @research_or_statistics = { public_interest_task: public_interest_task }.freeze
      self
    end

    # The research marker as declared: nil, or { public_interest_task: true|false }.
    def research_or_statistics
      @research_or_statistics
    end

    def research_or_statistics?
      !@research_or_statistics.nil?
    end

    def public_interest_task?
      @research_or_statistics&.fetch(:public_interest_task) == true
    end

    # The article that gives a subject the right to object to this purpose, or
    # nil when there is none: "Art. 21(2)" for direct marketing (any basis);
    # "Art. 21(1)" for the bases :public_task and :legitimate_interests,
    # research or not (Art. 21(1) covers all processing on Art. 6(1)(e) or (f),
    # and Art. 21(6) does not take it away); "Art. 21(6)" for research or
    # statistics on another basis, unless it is necessary for a task in the
    # public interest. Derived, never declared.
    def objectable
      return "Art. 21(2)" if direct_marketing?
      return "Art. 21(1)" if %i[public_task legitimate_interests].include?(@legal_basis)

      "Art. 21(6)" if research_or_statistics? && !public_interest_task?
    end

    # True when the purpose carries at least one Art. 9(2) basis (Def. 1, Condition 5)
    def art9_basis?
      @art9_bases.any?
    end

    # True when the purpose declares at least one Art. 10 authorisation
    def art10_authorised?
      @art10_authorisations.any?
    end

    # Check if purpose requires consent
    def requires_consent?
      @legal_basis == :consent
    end

    def basis_undetermined?
      @legal_basis == UNDETERMINED
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

    private

    # :important_public_interest names its law; a reference names nothing else.
    def apply_public_interest_reference(exceptions, reference)
      if exceptions.include?(:important_public_interest)
        unless reference.is_a?(String) && !reference.strip.empty?
          raise Error, "allowed_when_restricted :important_public_interest needs reference: naming the Union " \
                       "or Member State law (Art. 18(2))"
        end
        @important_public_interest_reference = reference.strip
      elsif reference
        raise Error, "reference: names the law of an :important_public_interest exception; none is declared here"
      end
    end
  end
end
