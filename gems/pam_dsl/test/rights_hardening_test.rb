require "test_helper"
require "stringio"
require "date"

module PamDsl
  # The rights API refuses what it cannot record faithfully: times that are
  # not times or that run backwards, a second objection to what is already
  # objected to, a subject or field that names nothing, and transitions that
  # skip the Art. 18(3) notice even when appended to the store directly.
  class RightsHardeningTest < Minitest::Test
    T0 = Time.utc(2026, 11, 2, 9, 0, 0)
    DAY = 86_400

    def setup
      PamDsl.reset!
      PamDsl.rights_store = nil
      PamDsl.logger = Logger.new(StringIO.new)
      define_shop
    end

    def teardown
      PamDsl.reset!
      PamDsl.rights_store = nil
      PamDsl.logger = nil
      PamDsl.subject_key_resolver = nil
      PamDsl.require_durable_rights_store = false
    end

    def rights = PamDsl.rights
    def shop = PamDsl.policy(:shop)

    # ── 1. Times ──

    def test_times_must_be_times
      [Date.new(2026, 11, 1), "2026-11-01", 1_700_000_000].each do |bad|
        assert_raises(ArgumentError, bad.inspect) { rights.restrict!(subject: "S", ground: :accuracy_contested, requested_at: bad) }
      end
      r = rights.restrict!(subject: "S", ground: :accuracy_contested, requested_at: T0)
      assert_raises(ArgumentError) { rights.notify_lift!(r.id, at: "tomorrow") }
      rights.notify_lift!(r.id, at: T0 + DAY)
      assert_raises(ArgumentError) { rights.lift!(r.id, reason: :x, at: Date.today) }
      assert_empty rights.state("S").restrictions.first.history.select { |e| e.type == "RestrictionLifted" }
    end

    def test_a_datetime_is_accepted_as_a_time
      r = rights.restrict!(subject: "S", ground: :accuracy_contested, requested_at: DateTime.new(2026, 11, 2, 9))

      assert_kind_of Time, r.requested_at
      assert_equal T0, r.requested_at
    end

    def test_a_request_is_not_recorded_before_it_is_made
      assert_raises(ArgumentError) do
        rights.restrict!(subject: "S", ground: :accuracy_contested, requested_at: Time.now + DAY)
      end
    end

    def test_a_lift_is_not_before_its_notice_nor_the_notice_before_the_request
      r = rights.restrict!(subject: "S", ground: :accuracy_contested, requested_at: T0)

      assert_raises(ArgumentError) { rights.notify_lift!(r.id, at: T0 - DAY) }
      rights.notify_lift!(r.id, at: T0 + 2 * DAY)
      assert_raises(ArgumentError) { rights.lift!(r.id, reason: :x, at: T0 + DAY) }
      assert_equal :lifted, rights.lift!(r.id, reason: :x, at: T0 + 2 * DAY).state
    end

    def test_an_override_notice_is_a_time_not_after_the_decision_and_not_before_the_request
      o = rights.object!(subject: "S", policy: :shop, purpose: :analytics, requested_at: T0)
      override = ->(**kw) { rights.decide!(o.id, outcome: :overridden, grounds: :legal_claims, reason: "r", **kw) }

      assert_raises(ArgumentError) { override.(notified_at: "yes") }
      assert_raises(ArgumentError) { override.(notified_at: true) }
      assert_raises(ArgumentError) { override.(at: T0 + DAY, notified_at: T0 + 30 * DAY) }
      assert_raises(ArgumentError) { override.(at: T0 + DAY, notified_at: T0 - DAY) }
      assert_raises(ArgumentError) { rights.decide!(o.id, outcome: :upheld, at: T0 - DAY) }
      assert_equal :pending, rights.find(o.id).state
      assert_equal :overridden, override.(at: T0 + 2 * DAY, notified_at: T0 + DAY).state
    end

    def test_withdrawal_is_not_before_the_request
      o = rights.object!(subject: "S", policy: :shop, purpose: :analytics, requested_at: T0)

      assert_raises(ArgumentError) { rights.withdraw_objection!(o.id, at: T0 - DAY) }
    end

    def test_open_requests_age_and_the_consent_exception_work_with_the_times_accepted
      rights.restrict!(subject: "S", ground: :accuracy_contested, requested_at: DateTime.new(2026, 11, 1))
      shop.consent_policy.grant_consent(purpose: :survey, subject: "S")

      assert_equal 1, rights.open_requests.size
      assert_kind_of Numeric, rights.open_requests.first.age
      assert shop.validate_access!([:email], :survey, subject: "S")
    end

    # ── 2. One objection per (subject, policy, purpose) ──

    def test_objecting_again_returns_the_objection_in_force
      first = rights.object!(subject: "S", policy: :shop, purpose: :analytics)
      again = rights.object!(subject: "S", policy: :shop, purpose: :analytics)

      assert_equal first.id, again.id
      assert_equal 1, rights.state("S").objections.size
      rights.decide!(first.id, outcome: :overridden, grounds: :legal_claims, reason: "r", notified_at: Time.now)
      assert shop.validate_access!([:email], :analytics, subject: "S")
    end

    def test_an_objection_after_the_last_was_decided_is_a_new_one
      first = rights.object!(subject: "S", policy: :shop, purpose: :analytics)
      rights.decide!(first.id, outcome: :overridden, grounds: :legal_claims, reason: "r", notified_at: Time.now)

      refute_equal first.id, rights.object!(subject: "S", policy: :shop, purpose: :analytics).id
    end

    def test_a_retry_after_a_failing_hook_does_not_record_twice
      calls = 0
      PamDsl.on_rights_event { |_e| calls += 1; raise "mail server down" if calls == 1 }

      assert_raises(RuntimeError) { rights.object!(subject: "S", policy: :shop, purpose: :analytics) }
      again = rights.object!(subject: "S", policy: :shop, purpose: :analytics)

      assert_equal :pending, again.state
      assert_equal %w[ObjectionReceived ProcessingRestricted], rights.state("S").events.map(&:type)
    end

    def test_concurrent_duplicate_objections_end_as_one
      slow = Class.new(RightsStore::Memory) do
        def append(events, expected_version:)
          sleep 0.05
          super
        end
      end
      PamDsl.rights_store = slow.new

      ids = 2.times.map { Thread.new { rights.object!(subject: "S", policy: :shop, purpose: :analytics).id } }.map(&:value)

      assert_equal 1, ids.uniq.size
      assert_equal 1, rights.state("S").objections.size
    end

    # ── 3. Art. 21(3): one direct-marketing objection stops all direct marketing ──

    def test_an_upheld_direct_marketing_objection_blocks_every_direct_marketing_purpose
      PamDsl.define_policy(:club) { field(:email, type: :email); purpose(:offers) { basis :consent; direct_marketing!; requires :email } }
      PamDsl.policy(:club).consent_policy.grant_consent(purpose: :offers, subject: "S")
      shop.consent_policy.grant_consent(purpose: :newsletter, subject: "S")
      o = rights.object!(subject: "S", policy: :shop, purpose: :promo)

      assert_equal :promo, o.purpose
      assert_raises(ObjectedProcessingError) { shop.validate_access!([:email], :newsletter, subject: "S") }
      assert_raises(ObjectedProcessingError) { PamDsl.policy(:club).validate_access!([:email], :offers, subject: "S") }
      assert shop.validate_access!([:email], :analytics, subject: "S") # not direct marketing
      assert_equal o.id, rights.object!(subject: "S", policy: :club, purpose: :offers).id

      rights.withdraw_objection!(o.id)
      assert shop.validate_access!([:email], :newsletter, subject: "S")
    end

    # ── 4. Subjects without a resolver ──

    def test_without_a_resolver_a_subject_is_a_non_empty_string_symbol_or_integer
      record = Struct.new(:id).new(1)
      [Object.new, record, %w[a b], "", "  ", 1.5].each do |bad|
        assert_raises(ArgumentError, bad.inspect) { rights.restrict!(subject: bad, ground: :accuracy_contested) }
      end
      assert_equal "alice", rights.restrict!(subject: :alice, ground: :accuracy_contested).subject_key
      assert_equal "7", rights.restrict!(subject: 7, ground: :accuracy_contested).subject_key

      # An access whose subject cannot be resolved is not silently let through.
      assert_raises(ArgumentError) { shop.validate_access!([:email], :payment, subject: record) }
      assert_equal [], PamDsl.subject_keys(nil)
      assert_equal [], PamDsl.subject_keys("Payer$*")
    end

    # ── 5. Fields ──

    def test_restrict_refuses_fields_no_policy_declares
      error = assert_raises(ArgumentError) do
        rights.restrict!(subject: "S", ground: :accuracy_contested, fields: [:e_mail, :name, :phone_no])
      end
      assert_match(/e_mail, phone_no/, error.message)
      assert_empty rights.state("S").events
    end

    # ── 6. The store keeps the Art. 18(3) order, and the durable check is the ledger's ──

    def test_the_store_refuses_an_illegal_transition_and_stores_nothing
      store = PamDsl.rights_store
      r = rights.restrict!(subject: "S", ground: :accuracy_contested)

      lift = Rights.lift_event(r, reason: :x, at: nil, by: nil)
      assert_raises(RightsTransitionError) { store.append([lift], expected_version: 1) }
      dangling = Rights.build_event("RestrictionLifted", "no-such-id", "S", { reason: :x }, at: nil, by: nil)
      assert_raises(RightsTransitionError) { store.append([dangling], expected_version: 1) }
      bogus = Rights::Event.new(type: "Bogus", request_id: "q", subject_key: "T", data: {}, at: Time.now,
                                recorded_at: Time.now, recorded_by: nil)
      assert_raises(RightsTransitionError) { store.append([bogus], expected_version: 0) }

      assert_equal %w[ProcessingRestricted], store.events_for("S").map(&:type)
      assert_empty store.events_for("T")
      assert_raises(RestrictedProcessingError) { shop.validate_access!([:email], :payment, subject: "S") }
      assert_equal :lift_notified, rights.notify_lift!(r.id).state
    end

    def test_an_objection_restriction_cannot_be_lifted_by_a_direct_append
      o = rights.object!(subject: "S", policy: :shop, purpose: :analytics)
      notice = Rights.build_event("RestrictionLiftNotified", o.restriction_id, "S", {}, at: nil, by: nil)

      assert_raises(RightsTransitionError) { PamDsl.rights_store.append([notice], expected_version: 2) }
    end

    def test_a_non_durable_host_store_is_refused_too
      host = Class.new do
        include RightsStore::Base
        def append(events, expected_version:) = raise("must not be reached")
        def events_for(_key) = []
        def subject_key_for(_id) = nil
        def active = []
      end
      PamDsl.rights_store = host.new
      PamDsl.require_durable_rights_store = true

      assert_raises(RightsStoreNotDurableError) { rights.restrict!(subject: "S", ground: :accuracy_contested) }
    end

    def test_reset_keeps_a_memory_store_the_host_installed
      mine = RightsStore::Memory.new
      PamDsl.rights_store = mine
      PamDsl.reset!

      assert_same mine, PamDsl.rights_store
    end

    # ── Lower ──

    def test_every_handler_sees_every_event_of_a_transition_before_the_error_is_raised
      seen_a = []
      seen_b = []
      PamDsl.on_rights_event { |e| seen_a << e.type; raise "boom" if e.type == "ObjectionReceived" }
      PamDsl.on_rights_event { |e| seen_b << e.type }

      error = assert_raises(RuntimeError) { rights.object!(subject: "S", policy: :shop, purpose: :analytics) }
      assert_equal "boom", error.message
      assert_equal %w[ObjectionReceived ProcessingRestricted], seen_a
      assert_equal %w[ObjectionReceived ProcessingRestricted], seen_b
      assert_equal 2, rights.state("S").events.size
    end

    def test_a_failing_hook_does_not_mask_a_rejected_objection
      PamDsl.on_rights_event { |_e| raise "boom" }

      error = assert_raises(ObjectionNotApplicableError) { rights.object!(subject: "S", policy: :shop, purpose: :payment) }
      assert_equal "boom", error.cause&.message
      assert_equal :rejected, rights.state("S").objections.first.state
    end

    def test_open_requests_list_a_pending_objection_once
      o = rights.object!(subject: "S", policy: :shop, purpose: :analytics)

      assert_equal [o.id], rights.open_requests.map(&:id)
      assert rights.open_requests.first.restriction_id
    end

    def test_clear_argument_errors
      assert_raises(ArgumentError) { rights.restrict!(subject: "S", ground: nil) }
      assert_raises(ArgumentError) { rights.object!(subject: "S", policy: :shop, purpose: :analytics, grounds: 42) }
      assert_raises(ArgumentError) { rights.object!(subject: "S", policy: shop, purpose: :analytics) }
      o = rights.object!(subject: "S", policy: :shop, purpose: :analytics)
      assert_raises(ArgumentError) do
        rights.decide!(o.id, outcome: :overridden, grounds: 5, reason: "x", notified_at: Time.now)
      end
      assert_raises(ArgumentError) { rights.decide!(o.id, outcome: nil) }
    end

    def test_the_lazy_store_is_created_once_under_threads
      PamDsl.rights_store = nil
      stores = 8.times.map { Thread.new { PamDsl.rights_store } }.map(&:value)

      assert_equal 1, stores.map(&:object_id).uniq.size
    end

    private

    def define_shop
      PamDsl.define_policy(:shop) do
        field(:email, type: :email)
        field(:name, type: :name)
        purpose(:analytics) { basis :legitimate_interests; lia_documented!; requires :email; optionally :name }
        purpose(:payment) { basis :contract; requires :email }
        purpose(:newsletter) { basis :consent; direct_marketing!; requires :email }
        purpose(:promo) { basis :legitimate_interests; direct_marketing!; requires :email }
        purpose(:survey) { basis :consent; allowed_when_restricted :consent; requires :email }
      end
    end
  end
end
