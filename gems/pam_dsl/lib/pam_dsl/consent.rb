module PamDsl
  # Runtime consent record for a single (purpose, subject) pair — one entry in CS.
  #
  # Implements the four-state lifecycle from the formal model (paper §4.2, Fig. consent-cpn):
  #   P0 Pending  — consent requested, not yet granted
  #   P1 Granted  — consent active; data processing permitted
  #   P2 Expired  — consent passed its expiry time (absorbing)
  #   P3 Withdrawn — subject revoked consent (absorbing)
  #
  # Transitions:
  #   t1 grant    — P0 → P1, fires on subject approval
  #   t2 expire   — P1 → P2, guard [now >= expires_at] (evaluated lazily in #state)
  #   t3 withdraw — P1 → P3, fires on explicit revocation
  #
  # Re-consent after P2 or P3 requires a new record entering P0.
  class ConsentRecord
    attr_reader :purpose, :subject, :granted_at, :withdrawn_at, :expires_at

    def initialize(purpose:, subject:)
      @purpose      = purpose.to_sym
      @subject      = subject
      @internal     = :pending
      @granted_at   = nil
      @withdrawn_at = nil
      @expires_at   = nil
    end

    # t1: P0 → P1
    def grant!(granted_at: Time.current, expires_at: nil)
      unless @internal == :pending
        raise Error, "Cannot grant: consent for (#{@purpose}, #{@subject}) is in state '#{state}'"
      end
      @granted_at = granted_at
      @expires_at = expires_at
      @internal   = :granted
    end

    # t3: P1 → P3 (absorbing)
    def withdraw!(at: Time.current)
      unless state == :granted
        raise Error, "Cannot withdraw: consent for (#{@purpose}, #{@subject}) is in state '#{state}'"
      end
      @withdrawn_at = at
      @internal     = :withdrawn
    end

    # Derives the current state, applying the t2 expiry guard lazily (paper: [now >= t_exp])
    def state
      return @internal unless @internal == :granted
      return :expired if @expires_at && Time.current >= @expires_at
      :granted
    end

    def pending?;   state == :pending;   end
    def granted?;   state == :granted;   end
    def expired?;   state == :expired;   end
    def withdrawn?; state == :withdrawn; end
  end

  # Runtime consent state store — the CS component of the formal runtime context C.
  # Indexed by [purpose, subject] pairs.
  class ConsentStore
    def initialize
      @records = {}
    end

    # Create a Pending record (P0) for (purpose, subject).
    # Replaces an absorbing record (Expired/Withdrawn) to model re-consent entering P0.
    # Raises if an active (Pending/Granted) record already exists.
    def request(purpose:, subject:)
      key = [purpose.to_sym, subject]
      existing = @records[key]
      if existing && %i[pending granted].include?(existing.state)
        raise Error,
          "Cannot request consent: record for (#{purpose}, #{subject}) already in state '#{existing.state}'"
      end
      @records[key] = ConsentRecord.new(purpose: purpose, subject: subject)
    end

    # Grant consent (t1). Transitions an existing Pending record, or creates one and grants it
    # immediately when no prior record exists (convenience shortcut for the common case).
    def grant(purpose:, subject:, granted_at: Time.current, expires_at: nil)
      key = [purpose.to_sym, subject]
      record = @records[key]
      if record&.state == :pending
        record.grant!(granted_at: granted_at, expires_at: expires_at)
      else
        fresh = ConsentRecord.new(purpose: purpose, subject: subject)
        fresh.grant!(granted_at: granted_at, expires_at: expires_at)
        @records[key] = fresh
      end
    end

    # Withdraw consent (t3). No-op if no record exists.
    def withdraw(purpose:, subject:)
      @records[[purpose.to_sym, subject]]&.withdraw!
    end

    def record_for(purpose, subject)
      @records[[purpose.to_sym, subject]]
    end

    def granted?(purpose, subject)
      record_for(purpose, subject)&.state == :granted
    end
  end

  # Represents a consent requirement
  class ConsentRequirement
    attr_reader :purpose, :required, :granular, :withdrawable, :description, :expires_after

    def initialize(purpose)
      @purpose = purpose.to_sym
      @required = true
      @granular = false
      @withdrawable = true
      @description = ""
      @expires_after = nil
    end

    # Set if consent is required
    def required!(value = true)
      @required = value
      self
    end

    # Enable granular consent
    def granular!(value = true)
      @granular = value
      self
    end

    # Set if consent is withdrawable
    def withdrawable!(value = true)
      @withdrawable = value
      self
    end

    # Set description
    def describe(text)
      @description = text
      self
    end

    # Set expiration duration
    def expires_in(duration)
      @expires_after = duration
      self
    end

    # Check if consent is required
    def required?
      @required
    end

    # Check if consent is granular
    def granular?
      @granular
    end

    # Check if consent is withdrawable
    def withdrawable?
      @withdrawable
    end

    # Check if consent has expired
    def expired?(granted_at)
      return false unless @expires_after
      granted_at < (Time.current - @expires_after)
    end
  end

  # Container for consent requirements (policy-time spec) and the runtime consent store (CS).
  class ConsentPolicy
    attr_reader :requirements, :store

    def initialize
      @requirements = []
      @store = ConsentStore.new
    end

    # DSL: declare consent requirement for a purpose
    def for_purpose(purpose, &block)
      requirement = ConsentRequirement.new(purpose)
      requirement.instance_eval(&block) if block_given?
      @requirements << requirement
      requirement
    end

    # Runtime: create a Pending record — call before grant_consent when you need to
    # track that a consent request was sent to the subject (P0 state)
    def request_consent(purpose:, subject:)
      @store.request(purpose: purpose, subject: subject)
    end

    # Runtime: grant consent for (purpose, subject), computing expires_at from the
    # requirement's expires_after so the record can derive its own Expired state
    def grant_consent(purpose:, subject:, granted_at: Time.current)
      req = requirement_for(purpose)
      expires_at = req&.expires_after ? granted_at + req.expires_after : nil
      @store.grant(purpose: purpose, subject: subject, granted_at: granted_at, expires_at: expires_at)
    end

    # Runtime: withdraw consent for (purpose, subject) — transitions to Withdrawn (P3)
    def withdraw_consent(purpose:, subject:)
      @store.withdraw(purpose: purpose, subject: subject)
    end

    def requirement_for(purpose)
      @requirements.find { |req| req.purpose == purpose.to_sym }
    end

    def required_for?(purpose)
      requirement = requirement_for(purpose)
      requirement ? requirement.required? : false
    end

    # Validate consent for (purpose, subject) — implements consent_active(u, s, C) from Def. 5.
    # consent_active holds iff (u,s) ∈ CS and state(u,s) = Granted.
    def validate!(purpose, subject:)
      requirement = requirement_for(purpose)
      return true unless requirement&.required?

      current_state = @store.record_for(purpose, subject)&.state

      unless current_state == :granted
        reason = case current_state
                 when :pending   then "consent requested but not yet granted"
                 when :expired   then "consent has expired"
                 when :withdrawn then "consent has been withdrawn"
                 else                 "no consent record found"
                 end
        raise ConsentRequiredError,
          "Consent not active for purpose '#{purpose}', subject '#{subject}': #{reason}"
      end

      true
    end
  end
end
