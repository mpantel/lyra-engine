module PamDsl
  class << self
    # A consent store shared by every policy, or nil (the default): each
    # policy then keeps consent in its own in-memory ConsentStore. When one is
    # set, ConsentPolicy#store returns it, so a grant or withdrawal made
    # through any policy is seen through every other. It answers what
    # ConsentStore answers (request, grant, withdraw, record_for, granted?)
    # and durable?. Lyra installs one that keeps consent as events in its
    # event store, shared by every process. PamDsl.reset! leaves it in place.
    attr_accessor :consent_store
  end

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

    # A record in a state already reached, as a durable store keeps it:
    # +state+ is :pending, :granted or :withdrawn (expiry stays derived from
    # +expires_at+). No transition is checked here; the store checked each
    # one when it was recorded.
    def self.restore(purpose:, subject:, state:, granted_at: nil, withdrawn_at: nil, expires_at: nil)
      new(purpose: purpose, subject: subject).tap do |record|
        record.instance_variable_set(:@internal, state.to_sym)
        record.instance_variable_set(:@granted_at, granted_at)
        record.instance_variable_set(:@withdrawn_at, withdrawn_at)
        record.instance_variable_set(:@expires_at, expires_at)
      end
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
  #
  # Held in memory, per process, per policy, and not persisted: a restart loses
  # every record, and a grant or withdrawal in one process is not seen by the
  # others. It is the fallback when no shared store is installed
  # (PamDsl.consent_store). With Lyra, consent is kept as events in Lyra's
  # event store instead, shared by every policy and every process.
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

    # In memory, per process: not durable.
    def durable?
      false
    end
  end

  # Represents a consent requirement
  class ConsentRequirement
    attr_reader :purpose, :required, :withdrawable, :description, :expires_after

    def initialize(purpose)
      @purpose = purpose.to_sym
      @required = true
      @withdrawable = true
      @description = ""
      @expires_after = nil
    end

    # Set if consent is required
    def required!(value = true)
      @required = value
      self
    end

    # Removed in 1.0.0: the flag was recorded and never enforced, so a policy that
    # declared it looked as if consent were per field when it was not. Declare one
    # consent block per purpose (Recital 32 asks for consent per purpose).
    def granular!(_value = true)
      raise ConsentGrammarError,
            "granular! was removed in 1.0.0: it was recorded but never enforced. " \
            "Declare one consent block per purpose instead."
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
    attr_reader :requirements

    def initialize
      @requirements = []
      @store = ConsentStore.new
    end

    # The runtime consent store (CS): the shared one when installed
    # (PamDsl.consent_store; with Lyra, durable and seen by every process),
    # else this policy's own, in memory.
    def store
      PamDsl.consent_store || @store
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
      store.request(purpose: purpose, subject: subject)
    end

    # Runtime: grant consent for (purpose, subject), computing expires_at from the
    # requirement's expires_after so the record can derive its own Expired state
    def grant_consent(purpose:, subject:, granted_at: Time.current)
      req = requirement_for(purpose)
      expires_at = req&.expires_after ? granted_at + req.expires_after : nil
      store.grant(purpose: purpose, subject: subject, granted_at: granted_at, expires_at: expires_at)
    end

    # Runtime: withdraw consent for (purpose, subject) — transitions to Withdrawn (P3)
    def withdraw_consent(purpose:, subject:)
      store.withdraw(purpose: purpose, subject: subject)
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
    # required: true when the purpose's basis is consent, so consent is needed
    # even if no requirement is declared for it.
    def validate!(purpose, subject:, required: false)
      requirement = requirement_for(purpose)
      return true unless required || requirement&.required?

      current_state = store.record_for(purpose, subject)&.state

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
