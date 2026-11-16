require "test_helper"
require "stringio"

module PamDsl
  # Restriction of processing (Art. 18) and the right to object (Art. 21) at
  # run time: the rights API records each request, notice, decision and lift
  # as an event in PamDsl.rights_store, and Condition 6 of Def. 1 refuses an
  # access that a subject's active restriction or upheld objection covers.
  class RightsTest < Minitest::Test
    T0 = Time.utc(2026, 11, 2, 9, 0, 0)
    Registration = Struct.new(:id, :payer_id)

    def setup
      PamDsl.reset!
      PamDsl.logger = Logger.new(StringIO.new)
      define_shop
    end

    def teardown
      PamDsl.reset!
      PamDsl.logger = nil
      PamDsl.access_recorder = nil
      PamDsl.subject_key_resolver = nil
      PamDsl.require_durable_rights_store = false
      PamDsl.rights_store = nil # a test may install its own; reset! keeps those
    end

    def rights = PamDsl.rights
    def shop = PamDsl.policy(:shop)

    # ── 13: nothing recorded, nothing changes ──

    def test_with_no_rights_recorded_every_access_is_as_before
      assert shop.validate_access!([:email], :analytics, subject: "Payer$7")
      assert_empty rights.state("Payer$7").restrictions
      assert_empty rights.open_requests
    end

    # ── 2: a whole-subject restriction ──

    def test_a_restricted_subject_is_refused_under_an_ordinary_purpose
      rights.restrict!(subject: "Payer$7", ground: :accuracy_contested)

      error = assert_raises(RestrictedProcessingError) { shop.validate_access!([:email], :payment, subject: "Payer$7") }
      assert_match(/Art\. 18/, error.message)
      assert_match(/accuracy_contested/, error.message)
      assert_raises(RestrictedProcessingError) { shop.validate_access!([:name], :analytics, subject: "Payer$7") }
    end

    def test_a_declared_exception_continues_under_restriction
      rights.restrict!(subject: "Payer$7", ground: :needed_for_legal_claims)

      assert shop.validate_access!([:email, :name], :defence_of_claims, subject: "Payer$7")
    end

    def test_another_subject_is_unaffected
      rights.restrict!(subject: "Payer$7", ground: :accuracy_contested)

      assert shop.validate_access!([:email], :payment, subject: "Payer$8")
    end

    def test_an_integer_subject_matches_its_string_key
      rights.restrict!(subject: 7, ground: :accuracy_contested)

      assert_raises(RestrictedProcessingError) { shop.validate_access!([:email], :payment, subject: 7) }
      assert_raises(RestrictedProcessingError) { shop.validate_access!([:email], :payment, subject: "7") }
    end

    def test_a_restriction_belongs_to_the_subject_not_to_a_policy
      rights.restrict!(subject: "Payer$7", ground: :accuracy_contested)
      define_shop # the policy is redefined (a code reload): the restriction stays
      PamDsl.define_policy(:other) { field(:email, type: :email); purpose(:mail) { basis :contract; requires :email } }

      assert_raises(RestrictedProcessingError) { PamDsl.policy(:shop).validate_access!([:email], :payment, subject: "Payer$7") }
      assert_raises(RestrictedProcessingError) { PamDsl.policy(:other).validate_access!([:email], :mail, subject: "Payer$7") }
    end

    # ── 3: a field-scoped restriction ──

    def test_a_field_scoped_restriction_refuses_only_accesses_that_use_its_fields
      rights.restrict!(subject: "Payer$7", ground: :accuracy_contested, fields: [:name])

      assert_raises(RestrictedProcessingError) { shop.validate_access!([:email, :name], :analytics, subject: "Payer$7") }
      assert shop.validate_access!([:email], :analytics, subject: "Payer$7")
    end

    # ── 4: the :consent exception ──

    def test_the_consent_exception_holds_only_with_a_consent_granted_after_the_restriction_began
      shop.consent_policy.grant_consent(purpose: :survey, subject: "Payer$7", granted_at: T0 - 86_400)
      rights.restrict!(subject: "Payer$7", ground: :accuracy_contested, requested_at: T0)

      assert_raises(RestrictedProcessingError) { shop.validate_access!([:email], :survey, subject: "Payer$7") }

      shop.consent_policy.withdraw_consent(purpose: :survey, subject: "Payer$7")
      shop.consent_policy.grant_consent(purpose: :survey, subject: "Payer$7", granted_at: T0 + 3600)
      assert shop.validate_access!([:email], :survey, subject: "Payer$7")
    end

    def test_the_consent_exception_needs_an_active_consent
      rights.restrict!(subject: "Payer$7", ground: :accuracy_contested, requested_at: T0)

      # No consent at all: the consent purpose's own condition (Condition 4) fails first.
      assert_raises(ConsentRequiredError) { shop.validate_access!([:email], :survey, subject: "Payer$7") }
    end

    # ── 5: notice, then lift ──

    def test_lift_without_a_notice_raises
      r = rights.restrict!(subject: "Payer$7", ground: :accuracy_contested)

      error = assert_raises(RightsTransitionError) { rights.lift!(r.id, reason: :verified_accurate) }
      assert_match(/Art\. 18\(3\)/, error.message)
      assert_raises(RestrictedProcessingError) { shop.validate_access!([:email], :payment, subject: "Payer$7") }
    end

    def test_notice_then_lift_resumes_processing_and_keeps_the_history
      r = rights.restrict!(subject: "Payer$7", ground: :accuracy_contested, requested_at: T0, recorded_by: "dpo-office")
      notified = rights.notify_lift!(r.id, at: T0 + 86_400, by: "dpo-office")
      assert_equal :lift_notified, notified.state
      # Notified is not lifted: processing is still restricted.
      assert_raises(RestrictedProcessingError) { shop.validate_access!([:email], :payment, subject: "Payer$7") }

      lifted = rights.lift!(r.id, reason: :verified_accurate, at: T0 + 2 * 86_400, by: "dpo-office")

      assert_equal :lifted, lifted.state
      assert_equal T0 + 86_400, lifted.lift_notified_at
      assert_equal T0 + 2 * 86_400, lifted.lifted_at
      assert shop.validate_access!([:email], :payment, subject: "Payer$7")
      assert_equal %w[ProcessingRestricted RestrictionLiftNotified RestrictionLifted],
                   rights.state("Payer$7").events.map(&:type)
      assert_raises(RightsTransitionError) { rights.lift!(r.id, reason: :again) }
      assert_raises(RightsTransitionError) { rights.notify_lift!(r.id) }
    end

    def test_requested_at_is_kept_apart_from_recorded_at
      r = rights.restrict!(subject: "Payer$7", ground: :unlawful_erasure_opposed, requested_at: T0)

      assert_equal T0, r.requested_at
      assert_operator r.recorded_at, :>, T0
    end

    def test_restrict_validates_its_ground_and_fields
      assert_raises(ArgumentError) { rights.restrict!(subject: "Payer$7", ground: :because) }
      error = assert_raises(ArgumentError) { rights.restrict!(subject: "Payer$7", ground: :objection_pending) }
      assert_match(/object!/, error.message)
      assert_raises(ArgumentError) { rights.restrict!(subject: "Payer$*", ground: :accuracy_contested) }
      assert_raises(ArgumentError) { rights.restrict!(subject: nil, ground: :accuracy_contested) }
    end

    def test_a_restriction_lists_the_declared_recipients_of_the_purposes_using_its_fields
      r = rights.restrict!(subject: "Payer$7", ground: :accuracy_contested, fields: [:name])

      assert_equal ["analytics vendor"], r.recipients
      whole = rights.restrict!(subject: "Payer$8", ground: :accuracy_contested)
      assert_equal ["analytics vendor", "card processor"], whole.recipients.sort
    end

    # ── 6: an objection on legitimate interests (Art. 21(1)) ──

    def test_an_objection_restricts_the_objected_purpose_only_until_it_is_decided
      o = rights.object!(subject: "Payer$7", policy: :shop, purpose: :analytics, grounds: "my situation", requested_at: T0)

      assert_equal :pending, o.state
      assert_equal "Art. 21(1)", o.article
      error = assert_raises(RestrictedProcessingError) { shop.validate_access!([:email], :analytics, subject: "Payer$7") }
      assert_match(/18\(1\)\(d\)/, error.message)
      assert shop.validate_access!([:email], :payment, subject: "Payer$7") # other purposes go on
      assert_equal 1, rights.state("Payer$7").restrictions.count(&:in_force?)
      assert_equal :objection_pending, rights.state("Payer$7").restrictions.first.ground
    end

    def test_an_overridden_objection_lifts_its_restriction
      o = rights.object!(subject: "Payer$7", policy: :shop, purpose: :analytics, requested_at: T0)
      decided = rights.decide!(o.id, outcome: :overridden, grounds: :compelling_legitimate_grounds,
                                     reason: "fraud prevention outweighs", by: "dpo-office", notified_at: T0 + 86_400)

      assert_equal :overridden, decided.state
      assert shop.validate_access!([:email], :analytics, subject: "Payer$7")
      restriction = rights.state("Payer$7").restrictions.first
      assert_equal :lifted, restriction.state
      assert_equal T0 + 86_400, restriction.lift_notified_at
    end

    def test_an_override_needs_a_notice_grounds_and_a_reason
      o = rights.object!(subject: "Payer$7", policy: :shop, purpose: :analytics)

      assert_raises(ArgumentError) do
        rights.decide!(o.id, outcome: :overridden, grounds: :compelling_legitimate_grounds, reason: "x")
      end
      assert_raises(ArgumentError) do
        rights.decide!(o.id, outcome: :overridden, grounds: :compelling_legitimate_grounds, notified_at: T0)
      end
      assert_raises(ArgumentError) do # a 21(6) ground does not answer a 21(1) objection
        rights.decide!(o.id, outcome: :overridden, grounds: :necessary_for_public_task, reason: "x", notified_at: T0)
      end
      assert_raises(ArgumentError) { rights.decide!(o.id, outcome: :maybe) }
      assert_equal :pending, rights.find(o.id).state
    end

    def test_an_upheld_objection_blocks_the_purpose
      o = rights.object!(subject: "Payer$7", policy: :shop, purpose: :analytics)
      rights.decide!(o.id, outcome: :upheld, by: "dpo-office")

      error = assert_raises(ObjectedProcessingError) { shop.validate_access!([:email], :analytics, subject: "Payer$7") }
      assert_match(/Art\. 21\(1\)/, error.message)
      assert shop.validate_access!([:email], :payment, subject: "Payer$7")
      assert_raises(RightsTransitionError) { rights.decide!(o.id, outcome: :overridden) }
      # The (d) restriction ended with the decision; the objection now does the blocking.
      refute rights.state("Payer$7").restrictions.any?(&:in_force?)
    end

    def test_an_upheld_objection_blocks_even_a_declared_restriction_exception
      o = rights.object!(subject: "Payer$7", policy: :shop, purpose: :defence_of_claims)
      # Pending: an 18(1)(d) restriction, and the purpose may continue under one (legal claims).
      assert shop.validate_access!([:email], :defence_of_claims, subject: "Payer$7")

      rights.decide!(o.id, outcome: :upheld)
      assert_raises(ObjectedProcessingError) { shop.validate_access!([:email], :defence_of_claims, subject: "Payer$7") }
    end

    def test_a_withdrawn_objection_allows_processing_again
      o = rights.object!(subject: "Payer$7", policy: :shop, purpose: :analytics)
      rights.decide!(o.id, outcome: :upheld)
      withdrawn = rights.withdraw_objection!(o.id, at: Time.now)

      assert_equal :withdrawn, withdrawn.state
      assert shop.validate_access!([:email], :analytics, subject: "Payer$7")
      assert_raises(RightsTransitionError) { rights.withdraw_objection!(o.id) }
    end

    def test_withdrawing_a_pending_objection_lifts_its_restriction
      o = rights.object!(subject: "Payer$7", policy: :shop, purpose: :analytics)
      rights.withdraw_objection!(o.id)

      assert shop.validate_access!([:email], :analytics, subject: "Payer$7")
      assert_equal :lifted, rights.state("Payer$7").restrictions.first.state
    end

    def test_an_objection_restriction_is_ended_only_by_the_decision
      o = rights.object!(subject: "Payer$7", policy: :shop, purpose: :analytics)
      restriction = rights.state("Payer$7").restrictions.first

      assert_equal o.id, restriction.objection_id
      assert_raises(RightsTransitionError) { rights.notify_lift!(restriction.id) }
      assert_raises(RightsTransitionError) { rights.lift!(restriction.id, reason: :x) }
    end

    # ── 7: objections that do not apply ──

    def test_an_objection_on_contract_is_rejected_and_recorded
      error = assert_raises(ObjectionNotApplicableError) do
        rights.object!(subject: "Payer$7", policy: :shop, purpose: :payment, requested_at: T0)
      end
      assert_match(/Art\. 6\(1\)\(b\)/, error.message)

      rejected = rights.state("Payer$7").objections.first
      assert_equal :rejected, rejected.state
      assert_match(/Art\. 6\(1\)\(b\)/, rejected.rejection_reason)
      assert_equal %w[ObjectionReceived ObjectionRejected], rights.state("Payer$7").events.map(&:type)
      assert shop.validate_access!([:email], :payment, subject: "Payer$7")
      assert_empty rights.open_requests
    end

    def test_an_objection_on_consent_points_to_withdrawal
      error = assert_raises(ObjectionNotApplicableError) do
        rights.object!(subject: "Payer$7", policy: :shop, purpose: :survey)
      end
      assert_match(/withdraw/i, error.message)
    end

    def test_an_objection_names_a_declared_purpose
      assert_raises(UndeclaredPurposeError) { rights.object!(subject: "Payer$7", policy: :shop, purpose: :nope) }
      assert_raises(PolicyNotFoundError) { rights.object!(subject: "Payer$7", policy: :nope, purpose: :analytics) }
    end

    # ── 8: direct marketing (Art. 21(2)-(3)) ──

    def test_a_direct_marketing_objection_blocks_at_once_whatever_the_basis
      shop.consent_policy.grant_consent(purpose: :newsletter, subject: "Payer$7", granted_at: T0)
      o = rights.object!(subject: "Payer$7", policy: :shop, purpose: :newsletter)

      assert_equal :upheld, o.state
      assert_equal "Art. 21(2)", o.article
      assert_raises(ObjectedProcessingError) { shop.validate_access!([:email], :newsletter, subject: "Payer$7") }

      shop.consent_policy.withdraw_consent(purpose: :newsletter, subject: "Payer$7")
      shop.consent_policy.grant_consent(purpose: :newsletter, subject: "Payer$7", granted_at: T0 + 86_400)
      assert_raises(ObjectedProcessingError) { shop.validate_access!([:email], :newsletter, subject: "Payer$7") }

      p2 = rights.object!(subject: "Payer$7", policy: :shop, purpose: :promotions) # basis contract
      assert_equal :upheld, p2.state
      assert_raises(ObjectedProcessingError) { shop.validate_access!([:email], :promotions, subject: "Payer$7") }
    end

    # ── 9: research and statistics (Art. 21(6)) ──

    def test_research_on_a_public_interest_task_rejects_the_objection
      error = assert_raises(ObjectionNotApplicableError) do
        rights.object!(subject: "Payer$7", policy: :shop, purpose: :census)
      end
      assert_match(/Art\. 21\(6\)/, error.message)
    end

    def test_other_research_is_pending_then_decided
      o = rights.object!(subject: "Payer$7", policy: :shop, purpose: :usage_statistics)

      assert_equal "Art. 21(6)", o.article
      assert_equal :pending, o.state
      assert_raises(RestrictedProcessingError) { shop.validate_access!([:email], :usage_statistics, subject: "Payer$7") }
      # Declared not necessary for a public-interest task: Art. 21(6) leaves no ground to override on.
      error = assert_raises(ArgumentError) do
        rights.decide!(o.id, outcome: :overridden, grounds: :necessary_for_public_task, reason: "statutory survey",
                             notified_at: Time.now)
      end
      assert_match(/public_interest_task/, error.message)
      rights.decide!(o.id, outcome: :upheld)
      assert_raises(ObjectedProcessingError) { shop.validate_access!([:email], :usage_statistics, subject: "Payer$7") }
    end

    def test_research_on_public_task_or_legitimate_interests_follows_art_21_1
      o = rights.object!(subject: "Payer$7", policy: :shop, purpose: :public_research)

      assert_equal "Art. 21(1)", o.article
      rights.decide!(o.id, outcome: :overridden, grounds: :compelling_legitimate_grounds, reason: "r", notified_at: Time.now)
      assert shop.validate_access!([:email], :public_research, subject: "Payer$7")
    end

    # ── 10: no subject, or every subject ──

    def test_model_wide_subjects_and_field_checks_are_not_checked_by_condition_6
      rights.restrict!(subject: "Payer$7", ground: :accuracy_contested)

      assert shop.validate_access!([:email], :payment, subject: "Payer$*")
      assert shop.validate_access!([:email], :payment, subject: nil)
      assert shop.validate_fields!([:email], :payment, subject: "Payer$7")
      assert_empty shop.field_violations([:email], :payment)
    end

    def test_a_subject_key_resolver_maps_a_subject_to_its_keys
      PamDsl.subject_key_resolver = ->(s) { s.is_a?(Registration) ? ["Registration$#{s.id}", "Payer$#{s.payer_id}"] : nil }
      rights.restrict!(subject: "Payer$7", ground: :accuracy_contested)

      assert_raises(RestrictedProcessingError) { shop.validate_access!([:email], :payment, subject: Registration.new(42, 7)) }
      assert shop.validate_access!([:email], :payment, subject: Registration.new(43, 8))
      assert_equal ["Payer$7"], PamDsl.subject_keys("Payer$7") # nil from the resolver: the default applies
    end

    # ── Condition 6 comes last ──

    def test_condition_6_comes_after_the_other_conditions_in_strict_mode
      rights.restrict!(subject: "Payer$7", ground: :accuracy_contested)

      assert_raises(PurposeFieldMismatchError) { shop.validate_access!([:name], :payment, subject: "Payer$7") }
      assert_raises(CriminalDataViolationError) { shop.validate_access!([:record], :payment, subject: "Payer$7") }
      assert_raises(ConsentRequiredError) { shop.validate_access!([:email], :survey, subject: "Payer$7") }
    end

    def test_audit_mode_reports_condition_6_after_the_others_and_lets_the_access_through
      PamDsl.enforcement_mode = :audit
      seen = []
      PamDsl.on_violation { |v| seen << v.error_class }
      rights.restrict!(subject: "Payer$7", ground: :accuracy_contested)
      o = rights.object!(subject: "Payer$8", policy: :shop, purpose: :analytics)
      rights.decide!(o.id, outcome: :upheld)

      refute shop.validate_access!([:name, :record], :payment, subject: "Payer$7")
      assert_equal [PurposeFieldMismatchError, CriminalDataViolationError, RestrictedProcessingError], seen

      seen.clear
      refute shop.validate_access!([:email], :analytics, subject: "Payer$8")
      assert_equal [ObjectedProcessingError], seen
    end

    def test_the_access_recorder_records_a_refusal_with_its_class
      recorded = []
      PamDsl.access_recorder = Object.new.tap do |rec|
        rec.define_singleton_method(:record?) { |_policy| true }
        rec.define_singleton_method(:call) { |access| recorded << access }
      end
      rights.restrict!(subject: "Payer$7", ground: :accuracy_contested)

      assert_raises(RestrictedProcessingError) { shop.validate_access!([:email], :payment, subject: "Payer$7") }
      assert_equal :denied, recorded.last.outcome
      assert_equal [RestrictedProcessingError], recorded.last.violations.map(&:class)
    end

    # ── state and open requests ──

    def test_open_requests_lists_active_restrictions_and_pending_objections_with_their_age
      r = rights.restrict!(subject: "Payer$7", ground: :accuracy_contested, requested_at: T0)
      o = rights.object!(subject: "Payer$8", policy: :shop, purpose: :analytics, requested_at: T0 + 86_400)
      u = rights.object!(subject: "Payer$9", policy: :shop, purpose: :analytics)
      rights.decide!(u.id, outcome: :upheld)

      open = rights.open_requests
      ids = open.map(&:id)
      assert_includes ids, r.id
      assert_includes ids, o.id
      refute_includes ids, u.id # decided: not open, though in force
      assert_equal 2 * 86_400, rights.find(r.id).age(T0 + 2 * 86_400).to_i
      assert_equal r.id, open.first.id # oldest first
    end

    def test_find_raises_for_an_unknown_request
      assert_raises(RightsTransitionError) { rights.lift!("nope", reason: :x) }
      assert_nil rights.find("nope")
    end

    # ── on_rights_event ──

    def test_the_rights_event_hook_fires_for_every_event
      events = []
      PamDsl.on_rights_event { |e| events << e }

      r = rights.restrict!(subject: "Payer$7", ground: :accuracy_contested, fields: [:name], recorded_by: "dpo-office")
      rights.object!(subject: "Payer$7", policy: :shop, purpose: :analytics)
      assert_raises(ObjectionNotApplicableError) { rights.object!(subject: "Payer$7", policy: :shop, purpose: :payment) }

      assert_equal %w[ProcessingRestricted ObjectionReceived ProcessingRestricted ObjectionReceived ObjectionRejected],
                   events.map(&:type)
      first = events.first
      assert_equal r.id, first.request_id
      assert_equal "Payer$7", first.subject_key
      assert_equal "dpo-office", first.recorded_by
      assert_equal [:name], first.data[:fields]
      assert_equal ["analytics vendor"], first.data[:recipients]
    end

    # ── the store ──

    def test_the_memory_store_refuses_to_record_when_a_durable_store_is_required
      PamDsl.require_durable_rights_store = true

      error = assert_raises(RightsStoreNotDurableError) { rights.restrict!(subject: "Payer$7", ground: :accuracy_contested) }
      assert_match(/durable/, error.message)
      assert_raises(RightsStoreNotDurableError) { rights.object!(subject: "Payer$7", policy: :shop, purpose: :analytics) }
      # Reading still works, and finds nothing.
      assert shop.validate_access!([:email], :payment, subject: "Payer$7")
      assert_empty rights.state("Payer$7").events
    end

    def test_a_durable_store_satisfies_the_requirement
      PamDsl.require_durable_rights_store = true
      PamDsl.rights_store = durable_store

      rights.restrict!(subject: "Payer$7", ground: :accuracy_contested)
      assert_raises(RestrictedProcessingError) { shop.validate_access!([:email], :payment, subject: "Payer$7") }
    end

    def test_reset_keeps_a_host_installed_store_and_clears_the_memory_store
      rights.restrict!(subject: "Payer$7", ground: :accuracy_contested)
      PamDsl.reset!
      assert_empty PamDsl.rights.state("Payer$7").events

      store = durable_store
      PamDsl.rights_store = store
      PamDsl.reset!
      assert_same store, PamDsl.rights_store
    end

    def test_the_memory_store_refuses_an_append_at_a_stale_version
      store = RightsStore::Memory.new
      event = Rights::Event.new(type: "ProcessingRestricted", request_id: "r1", subject_key: "Payer$7",
                                data: { ground: :accuracy_contested, fields: [] }, at: T0, recorded_at: T0,
                                recorded_by: nil)
      store.append([event], expected_version: 0)

      assert_raises(RightsConcurrencyError) { store.append([event], expected_version: 0) }
      assert_equal 1, store.events_for("Payer$7").size
      assert_equal "Payer$7", store.subject_key_for("r1")
    end

    def test_two_lifts_of_the_same_restriction_one_is_refused
      r = rights.restrict!(subject: "Payer$7", ground: :accuracy_contested)
      rights.notify_lift!(r.id)
      # A second ledger reads the same version, then the first lifts.
      stale = rights.store.events_for("Payer$7").size
      rights.lift!(r.id, reason: :verified_accurate)
      lifted = Rights.lift_event(rights.find(r.id), reason: :again, at: T0, by: nil)

      assert_raises(RightsConcurrencyError) { rights.store.append([lifted], expected_version: stale) }
    end

    private

    # A minimal durable store for the protocol: what Lyra's store implements.
    def durable_store
      Class.new(RightsStore::Memory) do
        def durable? = true
      end.new
    end

    def define_shop
      PamDsl.define_policy(:shop) do
        field(:email, type: :email)
        field(:name, type: :name)
        field(:record, type: :criminal_offence)

        purpose(:payment) { basis :contract; requires :email; recipients "card processor"; optionally :record }
        purpose(:analytics) do
          basis :legitimate_interests
          lia_documented!
          requires :email, :name
          recipients "analytics vendor"
        end
        purpose(:defence_of_claims) do
          basis :legitimate_interests
          lia_documented!
          requires :email, :name
          allowed_when_restricted :legal_claims
        end
        purpose(:survey) { basis :consent; requires :email; allowed_when_restricted :consent }
        purpose(:newsletter) { basis :consent; direct_marketing!; requires :email }
        purpose(:promotions) { basis :contract; direct_marketing!; requires :email }
        purpose(:usage_statistics) { basis :contract; research_or_statistics! public_interest_task: false; requires :email }
        purpose(:public_research) { basis :public_task; research_or_statistics! public_interest_task: true; requires :email }
        purpose(:census) { basis :legal_obligation; research_or_statistics! public_interest_task: true; requires :email }
      end
    end
  end
end
