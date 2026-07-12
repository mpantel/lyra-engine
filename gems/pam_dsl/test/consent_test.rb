require "test_helper"

module PamDsl
  class ConsentRequirementTest < Minitest::Test
    # ─────────────────────────────────────────────────────────────────────────
    # Basic ConsentRequirement Creation
    # ─────────────────────────────────────────────────────────────────────────

    def test_consent_requirement_creation
      consent = ConsentRequirement.new(:marketing)
      assert_equal :marketing, consent.purpose
    end

    def test_consent_converts_purpose_to_symbol
      consent = ConsentRequirement.new("marketing")
      assert_equal :marketing, consent.purpose
    end

    def test_consent_defaults
      consent = ConsentRequirement.new(:marketing)

      assert consent.required?
      refute consent.granular?
      assert consent.withdrawable?
      assert_equal "", consent.description
      assert_nil consent.expires_after
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Required Flag
    # ─────────────────────────────────────────────────────────────────────────

    def test_consent_required_by_default
      consent = ConsentRequirement.new(:marketing)
      assert consent.required?
    end

    def test_consent_required_can_be_set
      consent = ConsentRequirement.new(:marketing)
      consent.required!(true)
      assert consent.required?
    end

    def test_consent_optional
      consent = ConsentRequirement.new(:analytics)
      consent.required!(false)
      refute consent.required?
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Granular Consent
    # ─────────────────────────────────────────────────────────────────────────

    def test_consent_not_granular_by_default
      consent = ConsentRequirement.new(:marketing)
      refute consent.granular?
    end

    def test_consent_granularity
      consent = ConsentRequirement.new(:marketing)
      consent.granular!
      assert consent.granular?
    end

    def test_consent_granularity_can_be_disabled
      consent = ConsentRequirement.new(:marketing)
      consent.granular!(true)
      consent.granular!(false)
      refute consent.granular?
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Withdrawable Consent
    # ─────────────────────────────────────────────────────────────────────────

    def test_consent_withdrawable_by_default
      consent = ConsentRequirement.new(:marketing)
      assert consent.withdrawable?
    end

    def test_consent_withdrawable_can_be_set
      consent = ConsentRequirement.new(:legal)
      consent.withdrawable!(false)
      refute consent.withdrawable?
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Description
    # ─────────────────────────────────────────────────────────────────────────

    def test_consent_description
      consent = ConsentRequirement.new(:marketing)
      consent.describe("We will send you promotional emails")
      assert_equal "We will send you promotional emails", consent.description
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Expiration
    # ─────────────────────────────────────────────────────────────────────────

    def test_consent_with_expiration
      consent = ConsentRequirement.new(:analytics)
      consent.expires_in(365.days)
      assert_equal 365.days, consent.expires_after
    end

    def test_consent_not_expired_if_no_expiration
      consent = ConsentRequirement.new(:marketing)
      refute consent.expired?(Time.current - 10.years)
    end

    def test_consent_expired_after_duration
      consent = ConsentRequirement.new(:marketing)
      consent.expires_in(1.year)
      assert consent.expired?(Time.current - 2.years)
    end

    def test_consent_not_expired_within_duration
      consent = ConsentRequirement.new(:marketing)
      consent.expires_in(1.year)
      refute consent.expired?(Time.current - 6.months)
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Method Chaining
    # ─────────────────────────────────────────────────────────────────────────

    def test_method_chaining
      consent = ConsentRequirement.new(:marketing)
        .required!
        .granular!
        .withdrawable!
        .describe("Marketing consent")
        .expires_in(2.years)

      assert consent.required?
      assert consent.granular?
      assert consent.withdrawable?
      assert_equal "Marketing consent", consent.description
      assert_equal 2.years, consent.expires_after
    end
  end

  class ConsentPolicyTest < Minitest::Test
    # ─────────────────────────────────────────────────────────────────────────
    # Basic ConsentPolicy Creation
    # ─────────────────────────────────────────────────────────────────────────

    def test_consent_policy_creation
      policy = ConsentPolicy.new
      assert_empty policy.requirements
    end

    def test_for_purpose_creates_requirement
      policy = ConsentPolicy.new
      policy.for_purpose(:marketing)

      assert_equal 1, policy.requirements.size
      assert_equal :marketing, policy.requirements.first.purpose
    end

    def test_for_purpose_with_block
      policy = ConsentPolicy.new
      policy.for_purpose(:marketing) do
        required!
        granular!
        expires_in 2.years
      end

      req = policy.requirements.first
      assert req.required?
      assert req.granular?
      assert_equal 2.years, req.expires_after
    end

    def test_multiple_requirements
      policy = ConsentPolicy.new
      policy.for_purpose(:marketing)
      policy.for_purpose(:analytics)

      assert_equal 2, policy.requirements.size
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Requirement Lookup
    # ─────────────────────────────────────────────────────────────────────────

    def test_requirement_for_finds_requirement
      policy = ConsentPolicy.new
      policy.for_purpose(:marketing)

      req = policy.requirement_for(:marketing)
      refute_nil req
      assert_equal :marketing, req.purpose
    end

    def test_requirement_for_returns_nil_if_not_found
      policy = ConsentPolicy.new
      assert_nil policy.requirement_for(:unknown)
    end

    def test_required_for_purpose
      policy = ConsentPolicy.new
      policy.for_purpose(:marketing) { required! }
      policy.for_purpose(:analytics) { required!(false) }

      assert policy.required_for?(:marketing)
      refute policy.required_for?(:analytics)
      refute policy.required_for?(:unknown)
    end

    # ─────────────────────────────────────────────────────────────────────────
    # ConsentRecord — state machine (P0 Pending → P1 Granted → P2/P3 absorbing)
    # ─────────────────────────────────────────────────────────────────────────

    def test_record_starts_in_pending_state
      record = ConsentRecord.new(purpose: :marketing, subject: 1)
      assert record.pending?
      assert_equal :pending, record.state
    end

    def test_record_grant_transitions_to_granted
      record = ConsentRecord.new(purpose: :marketing, subject: 1)
      record.grant!
      assert record.granted?
      assert_equal :granted, record.state
    end

    def test_record_withdraw_transitions_to_withdrawn
      record = ConsentRecord.new(purpose: :marketing, subject: 1)
      record.grant!
      record.withdraw!
      assert record.withdrawn?
      assert_equal :withdrawn, record.state
    end

    def test_record_expired_state_derived_from_expires_at
      record = ConsentRecord.new(purpose: :marketing, subject: 1)
      record.grant!(granted_at: Time.current - 2.years, expires_at: Time.current - 1.year)
      assert record.expired?
      assert_equal :expired, record.state
    end

    def test_record_not_expired_before_expires_at
      record = ConsentRecord.new(purpose: :marketing, subject: 1)
      record.grant!(granted_at: Time.current - 6.months, expires_at: Time.current + 6.months)
      assert record.granted?
      refute record.expired?
    end

    def test_record_no_expires_at_never_expires
      record = ConsentRecord.new(purpose: :marketing, subject: 1)
      record.grant!
      assert record.granted?
      refute record.expired?
    end

    def test_record_cannot_grant_from_granted
      record = ConsentRecord.new(purpose: :marketing, subject: 1)
      record.grant!
      assert_raises(PamDsl::Error) { record.grant! }
    end

    def test_record_cannot_withdraw_from_pending
      record = ConsentRecord.new(purpose: :marketing, subject: 1)
      assert_raises(PamDsl::Error) { record.withdraw! }
    end

    def test_record_cannot_withdraw_from_expired
      record = ConsentRecord.new(purpose: :marketing, subject: 1)
      record.grant!(expires_at: Time.current - 1.second)
      assert_raises(PamDsl::Error) { record.withdraw! }
    end

    # ─────────────────────────────────────────────────────────────────────────
    # ConsentStore — CS indexed by (purpose, subject)
    # ─────────────────────────────────────────────────────────────────────────

    def test_store_request_creates_pending_record
      store = ConsentStore.new
      store.request(purpose: :marketing, subject: 42)
      record = store.record_for(:marketing, 42)

      refute_nil record
      assert record.pending?
    end

    def test_store_grant_directly_creates_granted_record
      store = ConsentStore.new
      store.grant(purpose: :marketing, subject: 42)
      record = store.record_for(:marketing, 42)

      refute_nil record
      assert record.granted?
      assert_equal :granted, record.state
    end

    def test_store_grant_transitions_pending_record
      store = ConsentStore.new
      store.request(purpose: :marketing, subject: 42)
      store.grant(purpose: :marketing, subject: 42)

      assert store.granted?(:marketing, 42)
    end

    def test_store_withdraw_marks_record_withdrawn
      store = ConsentStore.new
      store.grant(purpose: :marketing, subject: 42)
      store.withdraw(purpose: :marketing, subject: 42)

      record = store.record_for(:marketing, 42)
      assert record.withdrawn?
      assert_equal :withdrawn, record.state
      refute store.granted?(:marketing, 42)
    end

    def test_store_request_raises_when_active_record_exists
      store = ConsentStore.new
      store.grant(purpose: :marketing, subject: 42)
      assert_raises(PamDsl::Error) { store.request(purpose: :marketing, subject: 42) }
    end

    def test_store_request_succeeds_after_withdrawal
      store = ConsentStore.new
      store.grant(purpose: :marketing, subject: 42)
      store.withdraw(purpose: :marketing, subject: 42)
      store.request(purpose: :marketing, subject: 42)  # re-consent enters P0

      record = store.record_for(:marketing, 42)
      assert record.pending?
    end

    def test_store_granted_returns_false_for_expired_record
      store = ConsentStore.new
      store.grant(purpose: :marketing, subject: 1, expires_at: Time.current - 1.second)
      refute store.granted?(:marketing, 1)
    end

    def test_store_isolates_subjects
      store = ConsentStore.new
      store.grant(purpose: :marketing, subject: 1)
      store.grant(purpose: :marketing, subject: 2)
      store.withdraw(purpose: :marketing, subject: 1)

      refute store.granted?(:marketing, 1)
      assert store.granted?(:marketing, 2)
    end

    def test_store_isolates_purposes
      store = ConsentStore.new
      store.grant(purpose: :marketing, subject: 1)

      assert store.granted?(:marketing, 1)
      refute store.granted?(:analytics, 1)
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Validation — per-subject (Def. 5: consent_active(u, s, C))
    # ─────────────────────────────────────────────────────────────────────────

    def test_validate_passes_when_consent_granted
      policy = ConsentPolicy.new
      policy.for_purpose(:marketing) { required! }
      policy.grant_consent(purpose: :marketing, subject: 1)

      assert policy.validate!(:marketing, subject: 1)
    end

    def test_validate_raises_when_no_consent_record_exists
      policy = ConsentPolicy.new
      policy.for_purpose(:marketing) { required! }

      assert_raises(ConsentRequiredError) do
        policy.validate!(:marketing, subject: 1)
      end
    end

    def test_validate_raises_when_consent_withdrawn
      policy = ConsentPolicy.new
      policy.for_purpose(:marketing) { required! }
      policy.grant_consent(purpose: :marketing, subject: 1)
      policy.withdraw_consent(purpose: :marketing, subject: 1)

      assert_raises(ConsentRequiredError) do
        policy.validate!(:marketing, subject: 1)
      end
    end

    def test_validate_raises_when_consent_expired
      policy = ConsentPolicy.new
      policy.for_purpose(:marketing) do
        required!
        expires_in 1.year
      end
      # grant_consent computes expires_at = (now - 2yr) + 1yr = now - 1yr → expired
      policy.grant_consent(purpose: :marketing, subject: 1, granted_at: Time.current - 2.years)

      assert_raises(ConsentRequiredError) do
        policy.validate!(:marketing, subject: 1)
      end
    end

    def test_validate_raises_when_consent_pending
      policy = ConsentPolicy.new
      policy.for_purpose(:marketing) { required! }
      policy.request_consent(purpose: :marketing, subject: 1)

      assert_raises(ConsentRequiredError) do
        policy.validate!(:marketing, subject: 1)
      end
    end

    def test_grant_consent_computes_expires_at_from_requirement
      policy = ConsentPolicy.new
      policy.for_purpose(:marketing) { required!; expires_in 1.year }
      policy.grant_consent(purpose: :marketing, subject: 1)

      record = policy.store.record_for(:marketing, 1)
      refute_nil record.expires_at
      assert record.expires_at > Time.current
    end

    def test_validate_passes_for_unknown_purpose
      policy = ConsentPolicy.new
      assert policy.validate!(:unknown, subject: 1)
    end

    def test_validate_passes_for_optional_consent_without_record
      policy = ConsentPolicy.new
      policy.for_purpose(:analytics) { required!(false) }

      assert policy.validate!(:analytics, subject: 1)
    end

    def test_withdrawn_consent_does_not_affect_other_subjects
      policy = ConsentPolicy.new
      policy.for_purpose(:marketing) { required! }
      policy.grant_consent(purpose: :marketing, subject: 1)
      policy.grant_consent(purpose: :marketing, subject: 2)
      policy.withdraw_consent(purpose: :marketing, subject: 1)

      assert_raises(ConsentRequiredError) { policy.validate!(:marketing, subject: 1) }
      assert policy.validate!(:marketing, subject: 2)
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Integration with Policy DSL
    # ─────────────────────────────────────────────────────────────────────────

    def test_consent_via_policy_dsl
      PamDsl.reset!

      PamDsl.define_policy :test_consent do
        field :email, type: :email

        consent do
          for_purpose :marketing do
            required!
            granular!
            withdrawable!
            expires_in 2.years
            describe "We will send you promotional offers"
          end

          for_purpose :analytics do
            required!(false)
          end
        end
      end

      policy = PamDsl.policy(:test_consent)
      refute_nil policy.consent

      assert policy.consent.required_for?(:marketing)
      refute policy.consent.required_for?(:analytics)

      marketing_req = policy.consent.requirement_for(:marketing)
      assert marketing_req.granular?
      assert marketing_req.withdrawable?
      assert_equal 2.years, marketing_req.expires_after

      PamDsl.reset!
    end
  end
end
