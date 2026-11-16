# frozen_string_literal: true

require "test_helper"

# Lyra::Rights: the durable store of the data subject's restrictions and
# objections (Arts. 18 and 21) and of consent, which Lyra installs into PAM
# DSL, and the subject key resolver that maps a record to its own key and to
# the people it names.
class RightsStoreTest < Minitest::Test
  def setup
    skip "Requires Rails and database" unless defined?(ActiveRecord::Base) && ActiveRecord::Base.connection.table_exists?(:users)
    skip "Requires pam_dsl" unless Lyra.pam_dsl_available?

    PamDsl.reset!
    PamDsl.logger = Logger.new(nil)
    PamDsl.define_policy(:rights_policy) do
      field :name, type: :name
      field :email, type: :email
      field :title, type: :custom
      field :body, type: :custom
      purpose :publishing do
        basis :contract
        requires :title, :body, :name, :email
      end
      purpose :defence do
        basis :legitimate_interests
        lia_documented!
        allowed_when_restricted :legal_claims
        requires :title, :body, :name, :email
      end
      purpose :survey do
        basis :legitimate_interests
        lia_documented!
        allowed_when_restricted :consent
        requires :title, :body
      end
      purpose :newsletter do
        basis :consent
        requires :title, :body, :name, :email
      end
      consent do
        for_purpose(:newsletter) do
          required!
          expires_in 365 * 24 * 3600
        end
        for_purpose(:survey) { required! false }
      end
    end
    PamDsl.define_policy(:other_policy) do
      field :email, type: :email
      purpose :newsletter do
        basis :consent
        requires :email
      end
    end

    %i[RightsAuthor RightsArticle].each { |c| Object.send(:remove_const, c) if Object.const_defined?(c) }
    Object.const_set(:RightsAuthor, Class.new(ActiveRecord::Base) { self.table_name = "users" })
    Object.const_set(:RightsArticle, Class.new(ActiveRecord::Base) do
      self.table_name = "articles"
      belongs_to :author, class_name: "RightsAuthor", optional: true
    end)
    [RightsAuthor, RightsArticle].each do |model|
      model.include(Lyra::Interceptors::CrudInterceptor)
      model.monitor_with_lyra(privacy_policy: :rights_policy)
      Lyra.config.monitor_model(model, privacy_policy: :rights_policy)
    end
    clean
    Lyra.config.enable_monitor!
    @ann = RightsAuthor.create!(name: "Ann", email: "ann@example.com")
    @bob = RightsAuthor.create!(name: "Bob", email: "bob@example.com")
    @anns = RightsArticle.create!(title: "Ann's", body: "text", author_id: @ann.id)
    @bobs = RightsArticle.create!(title: "Bob's", body: "text", author_id: @bob.id)
    @ann_key = "RightsAuthor$#{@ann.id}"
  end

  def teardown
    return unless defined?(RightsAuthor)

    PamDsl.rights_store = Lyra::Rights.store
    PamDsl.consent_store = Lyra::Rights.consent_store
    PamDsl.require_durable_rights_store = nil
    Lyra.config.record_access_events = false
    clean
    PamDsl.reset!
    PamDsl.logger = nil
  end

  def rights = PamDsl.rights
  def connection = ActiveRecord::Base.connection

  # ── Installation and the resolver ──

  def test_lyra_installs_its_durable_stores_and_the_resolver_and_reset_keeps_them
    assert_same Lyra::Rights.consent_store, PamDsl.policy(:rights_policy).consent_policy.store,
                "every policy uses the shared consent store"
    PamDsl.reset!
    assert_same Lyra::Rights.store, PamDsl.rights_store
    assert_same Lyra::Rights.consent_store, PamDsl.consent_store
    assert_same Lyra::Rights::SubjectKeys, PamDsl.subject_key_resolver
    assert PamDsl.rights_store.durable?
    assert PamDsl.consent_store.durable?
  end

  def test_a_record_maps_to_its_own_key_and_to_the_people_it_names
    keys = PamDsl.subject_keys(@anns)
    assert_equal "RightsArticle$#{@anns.id}", keys.first, "the record's own key first"
    assert_includes keys, @ann_key, "the person it names, by its belongs_to"
    assert_equal [@ann_key], PamDsl.subject_keys(@ann), "a person names no one else"
    assert_equal ["Payer$7"], PamDsl.subject_keys("Payer$7"), "a key names itself"
    assert_empty PamDsl.subject_keys("RightsArticle$*")

    orphan = RightsArticle.create!(title: "x", body: "y", author_id: nil)
    assert_equal ["RightsArticle$#{orphan.id}"], PamDsl.subject_keys(orphan)
  end

  # ── Events and projection ──

  def test_a_restriction_is_an_event_in_the_subject_s_stream_and_a_row
    r = rights.restrict!(subject: @ann_key, ground: :accuracy_contested, fields: [:body], recorded_by: "dpo")

    stream = Lyra.config.event_store.read.stream("Lyra::Rights$#{@ann_key}").to_a
    assert_equal [Lyra::Rights::Events::ProcessingRestricted], stream.map(&:class)
    assert_equal stream.map(&:event_id), Lyra.config.event_store.read.stream("Lyra::Rights").to_a.map(&:event_id)
    refute_includes stream.first.data.to_s, "ann@example.com"

    row = connection.select_all("SELECT * FROM lyra_rights").to_a.sole
    assert_equal [r.id, "restriction", @ann_key, "RightsAuthor", @ann.id.to_s, "accuracy_contested", "Art. 18(1)(a)",
                  "active", 1],
                 row.values_at("request_id", "kind", "subject_key", "subject_type", "subject_id", "ground", "article",
                               "state", "stream_version")
    assert_equal ["body"], JSON.parse(row["fields"])
    assert [true, "t", 1].include?(row["in_force"])

    found = rights.find(r.id)
    assert_equal [:accuracy_contested, [:body], "dpo"], [found.ground, found.fields, found.recorded_by]
    assert_kind_of Time, found.requested_at
  end

  def test_the_rights_survive_a_new_store_instance
    r = rights.restrict!(subject: @ann_key, ground: :needed_for_legal_claims)
    o = rights.object!(subject: @ann_key, policy: :rights_policy, purpose: :defence)

    PamDsl.rights_store = Lyra::Rights::Store.new # another process
    state = rights.state(@ann_key)
    assert_equal [r.id, o.restriction_id].sort, state.restrictions.map(&:id).sort
    assert_equal [:pending], state.objections.map(&:state)
    assert_equal 3, PamDsl.rights_store.active.size
    assert_equal @ann_key, PamDsl.rights_store.subject_key_for(o.id)

    rights.notify_lift!(r.id)
    rights.lift!(r.id, reason: :claims_settled)
    assert_equal :lifted, Lyra::Rights::Store.new.then { |s| PamDsl::Rights.project(s.events_for(@ann_key)) }
                                                .find { _1.id == r.id }.state
  end

  # Symbols stay symbols and times come back as Time, whatever the serializer.
  def test_event_data_comes_back_as_it_was_recorded
    o = rights.object!(subject: @ann_key, policy: :rights_policy, purpose: :defence, grounds: "my situation")
    told = Time.now
    rights.decide!(o.id, outcome: :overridden, grounds: :compelling_legitimate_grounds, reason: "fraud case",
                         by: "dpo", notified_at: told)

    overridden = Lyra::Rights::Store.new.events_for(@ann_key).find { _1.type == "ObjectionOverridden" }
    assert_equal :compelling_legitimate_grounds, overridden.data[:grounds]
    assert_kind_of Time, overridden.data[:notified_at]
    assert_in_delta told, overridden.data[:notified_at], 0.001
    assert_kind_of Time, overridden.at
    assert_kind_of Time, overridden.recorded_at
    assert overridden.data.keys.all?(Symbol)
  end

  def test_rebuild_reproduces_the_live_projection
    r = rights.restrict!(subject: @ann_key, ground: :accuracy_contested)
    rights.notify_lift!(r.id)
    rights.object!(subject: "RightsAuthor$#{@bob.id}", policy: :rights_policy, purpose: :defence)
    PamDsl.policy(:rights_policy).consent_policy.grant_consent(purpose: :newsletter, subject: @ann_key)

    live = connection.select_rows("SELECT request_id, kind, state, in_force, stream_version FROM lyra_rights ORDER BY request_id")
    consents = connection.select_rows("SELECT subject_key, purpose, state FROM lyra_consents")
    connection.execute("DELETE FROM lyra_rights")
    connection.execute("DELETE FROM lyra_consents")

    assert_equal [3, 1], Lyra::Rights.rebuild!
    assert_equal live, connection.select_rows("SELECT request_id, kind, state, in_force, stream_version FROM lyra_rights ORDER BY request_id")
    assert_equal consents, connection.select_rows("SELECT subject_key, purpose, state FROM lyra_consents")
  end

  # ── Concurrency ──

  def test_two_processes_with_the_same_version_cannot_both_record
    r = rights.restrict!(subject: @ann_key, ground: :accuracy_contested)
    first = Lyra::Rights::Store.new
    second = Lyra::Rights::Store.new
    version = first.events_for(@ann_key).size

    notice = PamDsl::Rights.build_event("RestrictionLiftNotified", r.id, @ann_key, {}, at: nil, by: "a")
    first.append([notice], expected_version: version)
    other = PamDsl::Rights.build_event("RestrictionLiftNotified", r.id, @ann_key, {}, at: nil, by: "b")
    assert_raises(PamDsl::RightsConcurrencyError) { second.append([other], expected_version: version) }

    assert_equal %w[ProcessingRestricted RestrictionLiftNotified], second.events_for(@ann_key).map(&:type)
    assert_equal "a", second.events_for(@ann_key).last.recorded_by
  end

  # Two connections in two open transactions: the second waits for the first
  # to commit on the stream's unique position, then is refused, and stores
  # nothing; the caller's own transaction survives the refusal.
  def test_two_connections_deciding_at_once_one_wins_the_other_is_refused
    r = rights.restrict!(subject: @ann_key, ground: :accuracy_contested)
    version = Lyra::Rights.store.events_for(@ann_key).size
    appended = Queue.new
    commit = Queue.new

    winner = Thread.new do
      ActiveRecord::Base.transaction do
        Lyra::Rights::Store.new.append(
          [PamDsl::Rights.build_event("RestrictionLiftNotified", r.id, @ann_key, {}, at: nil, by: "winner")],
          expected_version: version
        )
        appended << true
        commit.pop
      end
    end
    appended.pop
    loser = Thread.new do
      ActiveRecord::Base.transaction do
        begin
          Lyra::Rights::Store.new.append(
            [PamDsl::Rights.build_event("RestrictionLiftNotified", r.id, @ann_key, {}, at: nil, by: "loser")],
            expected_version: version
          )
          :appended
        rescue PamDsl::RightsConcurrencyError
          ActiveRecord::Base.connection.select_value("SELECT 1") # the transaction is still usable
          :refused
        end
      end
    end
    sleep 0.3
    assert loser.alive?, "the second append waits for the first transaction"
    commit << true
    winner.join

    assert_equal :refused, loser.value
    events = Lyra::Rights.store.events_for(@ann_key)
    assert_equal %w[ProcessingRestricted RestrictionLiftNotified], events.map(&:type)
    assert_equal "winner", events.last.recorded_by
    assert_equal ["lift_notified"], connection.select_values("SELECT state FROM lyra_rights")
  end

  def test_a_decision_recorded_elsewhere_is_seen_by_the_next_transition
    o = rights.object!(subject: @ann_key, policy: :rights_policy, purpose: :defence)
    rights.decide!(o.id, outcome: :upheld, by: "dpo")

    PamDsl.rights_store = Lyra::Rights::Store.new
    assert_raises(PamDsl::RightsTransitionError) { rights.decide!(o.id, outcome: :upheld, by: "other desk") }
  end

  def test_an_append_that_does_not_replay_stores_nothing
    lift = PamDsl::Rights.build_event("RestrictionLifted", "no-such-request", @ann_key, { reason: :x }, at: nil, by: nil)
    assert_raises(PamDsl::RightsTransitionError) { Lyra::Rights.store.append([lift], expected_version: 0) }

    assert_empty Lyra::Rights.store.events_for(@ann_key)
    refute connection.table_exists?("lyra_rights") && connection.select_value("SELECT count(*) FROM lyra_rights").to_i.positive?
  end

  def test_an_append_with_a_stale_version_is_refused_before_anything_is_written
    rights.restrict!(subject: @ann_key, ground: :accuracy_contested)
    event = PamDsl::Rights.build_event("ProcessingRestricted", SecureRandom.uuid, @ann_key,
                                       { ground: :needed_for_legal_claims, fields: [] }, at: nil, by: nil)
    assert_raises(PamDsl::RightsConcurrencyError) { Lyra::Rights.store.append([event], expected_version: 0) }
    assert_raises(PamDsl::RightsConcurrencyError) { Lyra::Rights.store.append([event], expected_version: 5) }
    assert_equal 1, Lyra::Rights.store.events_for(@ann_key).size
  end

  # ── The snapshot ──

  def test_the_snapshot_answers_without_a_query_until_it_is_due
    Lyra.config.rights_refresh_interval = 60
    store = Lyra::Rights::Store.new
    refute store.any_active?
    assert_equal 0, rights_queries { 100.times { store.any_active?; store.active_for([@ann_key]) } }

    Lyra::Rights.store.invalidate!
    assert_equal 1, rights_queries { Lyra::Rights.store.any_active? }, "one query when due, none per subject"
  end

  def test_another_process_s_restriction_is_seen_from_the_next_refresh
    Lyra.config.rights_refresh_interval = 60
    here = Lyra::Rights::Store.new
    elsewhere = Lyra::Rights::Store.new
    refute here.any_active?

    PamDsl.rights_store = elsewhere
    r = rights.restrict!(subject: @ann_key, ground: :accuracy_contested)
    assert elsewhere.any_active?, "the recording process sees it at once"
    refute here.any_active?, "another process sees it from its next refresh"

    here.refresh!
    assert_equal [r.id], here.active_for([@ann_key]).map(&:id)
    assert_empty here.active_for(["RightsAuthor$#{@bob.id}"])

    rights.notify_lift!(r.id)
    rights.lift!(r.id, reason: :verified_accurate)
    assert here.any_active?
    here.refresh!
    refute here.any_active?
  end

  def test_the_snapshot_is_refreshed_once_the_interval_has_passed
    Lyra.config.rights_refresh_interval = 0.05
    here = Lyra::Rights::Store.new
    refute here.any_active?
    Lyra::Rights.store.then { PamDsl.rights_store = _1 }
    rights.restrict!(subject: @ann_key, ground: :accuracy_contested)
    sleep 0.1
    assert here.any_active?
  end

  def test_a_restriction_recorded_in_a_rolled_back_transaction_is_dropped
    ActiveRecord::Base.transaction do
      rights.restrict!(subject: @ann_key, ground: :accuracy_contested)
      assert Lyra::Rights.store.any_active?
      raise ActiveRecord::Rollback
    end
    refute Lyra::Rights.store.any_active?
    assert_empty Lyra::Rights.store.events_for(@ann_key)
  end

  # ── Condition 6 end to end, through Lyra's reads ──

  def test_a_person_s_restriction_refuses_a_read_of_their_record_unless_the_purpose_is_excepted
    rights.restrict!(subject: @ann_key, ground: :accuracy_contested)

    error = assert_raises(PamDsl::RestrictedProcessingError) do
      Lyra.with_purpose(:publishing) { RightsArticle.find(@anns.id) }
    end
    assert_match(/#{Regexp.escape(@ann_key)}/, error.message)
    assert_raises(PamDsl::RestrictedProcessingError) { Lyra.with_purpose(:publishing) { RightsAuthor.find(@ann.id) } }
    assert_equal "Bob's", Lyra.with_purpose(:publishing) { RightsArticle.find(@bobs.id) }.title, "others unaffected"
    assert_equal "Ann's", Lyra.with_purpose(:defence) { RightsArticle.find(@anns.id) }.title, "Art. 18(2) legal claims"
    assert_equal "Ann's", RightsArticle.find(@anns.id).title, "no purpose under :allow: not checked (part of the documented limit)"
  end

  def test_a_field_scoped_restriction_refuses_only_reads_of_its_fields
    rights.restrict!(subject: @ann_key, ground: :accuracy_contested, fields: [:body])

    assert_raises(PamDsl::RestrictedProcessingError) { Lyra.with_purpose(:publishing) { RightsArticle.find(@anns.id) } }
    title = Lyra.with_purpose(:publishing) { RightsArticle.select(:id, :title, :author_id).find(@anns.id) }.title
    assert_equal "Ann's", title
  end

  def test_a_restriction_of_one_record_covers_that_record_only
    other = RightsArticle.create!(title: "Ann's other", body: "text", author_id: @ann.id)
    rights.restrict!(subject: @anns, ground: :needed_for_legal_claims)

    assert_raises(PamDsl::RestrictedProcessingError) { Lyra.with_purpose(:publishing) { RightsArticle.find(@anns.id) } }
    assert Lyra.with_purpose(:publishing) { RightsArticle.find(other.id) }
  end

  def test_the_refusal_is_recorded_in_the_access_log
    Lyra.config.record_access_events = true
    rights.restrict!(subject: @ann_key, ground: :accuracy_contested)
    assert_raises(PamDsl::RestrictedProcessingError) { Lyra.with_purpose(:publishing) { RightsArticle.find(@anns.id) } }

    event = Lyra::AccessLog.for(@anns).last
    assert_kind_of Lyra::Events::DataAccessDenied, event
    assert_equal ["PamDsl::RestrictedProcessingError"], event.data[:violations].map { _1[:error] }
  end

  def test_an_upheld_objection_stops_the_purpose_for_the_person_s_records
    o = rights.object!(subject: @ann_key, policy: :rights_policy, purpose: :survey)
    assert_raises(PamDsl::RestrictedProcessingError) do
      Lyra.with_purpose(:survey) { RightsArticle.select(:id, :title, :body, :author_id).find(@anns.id) }
    end
    rights.decide!(o.id, outcome: :upheld, by: "dpo")
    assert_raises(PamDsl::ObjectedProcessingError) do
      Lyra.with_purpose(:survey) { RightsArticle.select(:id, :title, :body, :author_id).find(@anns.id) }
    end
    assert Lyra.with_purpose(:publishing) { RightsArticle.find(@anns.id) }, "other purposes go on"
  end

  # ── The production setting ──

  def test_where_a_durable_store_is_required_lyra_s_store_records
    PamDsl.require_durable_rights_store = true
    assert rights.restrict!(subject: @ann_key, ground: :accuracy_contested)

    PamDsl.rights_store = PamDsl::RightsStore::Memory.new
    assert_raises(PamDsl::RightsStoreNotDurableError) do
      rights.restrict!(subject: @ann_key, ground: :accuracy_contested)
    end
  end

  # ── Consent ──

  def test_consent_granted_through_one_policy_and_process_is_seen_by_another
    PamDsl.policy(:rights_policy).consent_policy.grant_consent(purpose: :newsletter, subject: @ann_key)

    assert PamDsl.policy(:other_policy).consent_policy.store.granted?(:newsletter, @ann_key), "another policy"
    assert Lyra::Rights::ConsentStore.new.granted?(:newsletter, @ann_key), "another process"
    assert PamDsl.policy(:other_policy).validate_access!([:email], :newsletter, subject: @ann_key)
    assert_equal [%w[granted newsletter]], connection.select_rows("SELECT state, purpose FROM lyra_consents")
    assert_equal [Lyra::Rights::Events::ConsentGranted],
                 Lyra.config.event_store.read.stream("Lyra::Consent$#{@ann_key}").to_a.map(&:class)

    PamDsl.reset! # the policies are defined again; the consent stays
    assert Lyra::Rights.consent_store.granted?(:newsletter, @ann_key)
  end

  def test_a_withdrawal_elsewhere_applies_here_from_the_next_refresh
    Lyra.config.rights_refresh_interval = 60
    PamDsl.policy(:rights_policy).consent_policy.grant_consent(purpose: :newsletter, subject: @ann_key)
    here = Lyra::Rights.consent_store
    assert here.granted?(:newsletter, @ann_key)

    Lyra::Rights::ConsentStore.new.withdraw(purpose: :newsletter, subject: @ann_key)
    assert here.granted?(:newsletter, @ann_key), "remembered for the interval"
    Lyra::Rights.refresh!
    assert_equal :withdrawn, here.record_for(:newsletter, @ann_key).state
    assert_raises(PamDsl::ConsentRequiredError) do
      PamDsl.policy(:rights_policy).validate_access!([:email], :newsletter, subject: @ann_key)
    end
  end

  def test_a_person_s_consent_covers_their_records_in_lyra_s_reads
    assert_raises(PamDsl::ConsentRequiredError) { Lyra.with_purpose(:newsletter) { RightsArticle.find(@anns.id) } }
    PamDsl.policy(:rights_policy).consent_policy.grant_consent(purpose: :newsletter, subject: @ann)

    assert Lyra.with_purpose(:newsletter) { RightsArticle.find(@anns.id) }
    assert_raises(PamDsl::ConsentRequiredError) { Lyra.with_purpose(:newsletter) { RightsArticle.find(@bobs.id) } }
  end

  def test_consent_expires_after_the_requirement_s_period
    policy = PamDsl.policy(:rights_policy)
    policy.consent_policy.grant_consent(purpose: :newsletter, subject: @ann_key, granted_at: Time.current - (2 * 365 * 24 * 3600))

    record = Lyra::Rights::ConsentStore.new.record_for(:newsletter, @ann_key)
    assert_equal :expired, record.state
    assert_in_delta Time.current - (365 * 24 * 3600), record.expires_at, 5
    error = assert_raises(PamDsl::ConsentRequiredError) { policy.validate_access!([:email], :newsletter, subject: @ann_key) }
    assert_match(/expired/, error.message)
    assert_raises(PamDsl::Error) { policy.consent_policy.withdraw_consent(purpose: :newsletter, subject: @ann_key) }

    policy.consent_policy.grant_consent(purpose: :newsletter, subject: @ann_key) # re-consent
    assert policy.validate_access!([:email], :newsletter, subject: @ann_key)
  end

  def test_consent_follows_pam_s_transitions
    consent = PamDsl.policy(:rights_policy).consent_policy
    assert_nil consent.withdraw_consent(purpose: :newsletter, subject: @ann_key), "nothing to withdraw"
    consent.request_consent(purpose: :newsletter, subject: @ann_key)
    assert_equal :pending, consent.store.record_for(:newsletter, @ann_key).state
    assert_raises(PamDsl::Error) { consent.request_consent(purpose: :newsletter, subject: @ann_key) }
    consent.grant_consent(purpose: :newsletter, subject: @ann_key)
    consent.withdraw_consent(purpose: :newsletter, subject: @ann_key)
    assert_equal :withdrawn, consent.store.record_for(:newsletter, @ann_key).state
    assert_equal %w[ConsentRequested ConsentGranted ConsentWithdrawn],
                 Lyra::Rights.consent_store.events_for(@ann_key).map { _1[:type] }
  end

  def test_the_consent_exception_of_art_18_2_reads_the_durable_consent
    r = rights.restrict!(subject: @ann_key, ground: :accuracy_contested)
    read = -> { Lyra.with_purpose(:survey) { RightsArticle.select(:id, :title, :body, :author_id).find(@anns.id) } }
    assert_raises(PamDsl::RestrictedProcessingError) { read.call }

    # Given through another policy object, after the restriction was requested.
    Lyra::Rights.consent_store.grant(purpose: :survey, subject: @ann_key, granted_at: r.requested_at + 1)
    assert read.call
  end

  def test_the_consent_audit_reads_the_store
    PamDsl.policy(:rights_policy).consent_policy.grant_consent(purpose: :newsletter, subject: @ann)

    audit = Lyra::Privacy::GDPRCompliance.new(subject_id: @ann.id, subject_type: "RightsAuthor").consent_audit
    entry = audit[:recorded_consents].sole
    assert_equal [:newsletter, @ann_key, :granted], entry.values_at(:purpose, :subject_key, :state)
    assert_equal ["ConsentGranted"], entry[:history].map { _1[:type] }
    assert_equal true, audit[:current_consents][:newsletter][:granted]
  end

  # ── Review findings ──

  # A rolled-back transition reuses the stream version the next real one
  # gets: the snapshot must not take the rolled-back content for it.
  def test_a_rolled_back_transition_does_not_stand_in_for_the_next_real_one
    Lyra.config.rights_refresh_interval = 60
    store = Lyra::Rights.store
    r1 = rights.restrict!(subject: @ann_key, ground: :accuracy_contested, fields: [:body])
    store.refresh!
    ActiveRecord::Base.transaction do
      rights.notify_lift!(r1.id)
      assert_equal [:lift_notified], store.active_for([@ann_key]).map(&:state), "its own transaction sees it"
      raise ActiveRecord::Rollback
    end
    PamDsl.rights_store = Lyra::Rights::Store.new # another process
    r3 = rights.restrict!(subject: @ann_key, ground: :accuracy_contested, fields: [:email])
    PamDsl.rights_store = store
    Lyra::Rights.refresh!

    assert_equal [[r1.id, :active], [r3.id, :active]].sort, store.active_for([@ann_key]).map { [_1.id, _1.state] }.sort
    assert_raises(PamDsl::RestrictedProcessingError) do
      Lyra.with_purpose(:publishing) { RightsAuthor.select(:id, :email).find(@ann.id) }
    end
  end

  # The snapshot is shared by the process's threads; a transaction's own
  # uncommitted rights are its own.
  def test_a_transaction_sees_its_own_uncommitted_rights_and_no_other_thread_does
    Lyra.config.rights_refresh_interval = 60
    store = Lyra::Rights.store
    lifted = rights.restrict!(subject: "RightsAuthor$#{@bob.id}", ground: :accuracy_contested)
    rights.notify_lift!(lifted.id)
    store.refresh!
    recorded = Queue.new
    go = Queue.new
    seen = nil
    writer = Thread.new do
      ActiveRecord::Base.transaction do
        rights.restrict!(subject: @ann_key, ground: :accuracy_contested)
        rights.lift!(lifted.id, reason: :verified_accurate)
        recorded << true
        go.pop
        seen = [store.active_for([@ann_key]).size, store.active_for(["RightsAuthor$#{@bob.id}"]).size]
      end
    end
    recorded.pop
    other = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        store.refresh!
        [store.active_for([@ann_key]).size, store.active_for(["RightsAuthor$#{@bob.id}"]).size]
      end
    end.value
    go << true
    writer.join

    assert_equal [0, 1], other, "another thread sees committed rights only"
    assert_equal [1, 0], seen, "the writing transaction sees its own"
    store.refresh!
    assert_equal [1, 0], [store.active_for([@ann_key]).size, store.active_for(["RightsAuthor$#{@bob.id}"]).size]
  end

  def test_a_consent_withdrawal_in_an_open_transaction_is_its_own
    Lyra.config.rights_refresh_interval = 60
    consent = PamDsl.policy(:rights_policy).consent_policy
    consent.grant_consent(purpose: :newsletter, subject: @ann_key)
    Lyra::Rights.refresh!
    withdrawn = Queue.new
    go = Queue.new
    seen = nil
    writer = Thread.new do
      ActiveRecord::Base.transaction do
        consent.withdraw_consent(purpose: :newsletter, subject: @ann_key)
        withdrawn << true
        go.pop
        seen = Lyra::Rights.consent_store.record_for(:newsletter, @ann_key).state
      end
    end
    withdrawn.pop
    other = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection { Lyra::Rights.consent_store.granted?(:newsletter, @ann_key) }
    end.value
    go << true
    writer.join

    assert other, "not withdrawn for anyone else before the commit"
    assert_equal :withdrawn, seen
    refute Lyra::Rights.consent_store.granted?(:newsletter, @ann_key)
  end

  def test_a_rebuild_and_a_transition_at_once_are_serialised
    r = rights.restrict!(subject: @ann_key, ground: :accuracy_contested)
    rebuilt = Queue.new
    finish = Queue.new
    rebuild = Thread.new do
      ActiveRecord::Base.transaction do
        Lyra::Rights.rebuild!
        rebuilt << true
        finish.pop
      end
    end
    rebuilt.pop
    transition = Thread.new do
      rights.notify_lift!(r.id)
      :ok
    rescue StandardError => e
      e
    end
    sleep 0.3
    finish << true
    rebuild.join

    assert_equal :ok, transition.value
    assert_equal [[r.id, "lift_notified"]], connection.select_rows("SELECT request_id, state FROM lyra_rights")
  end

  # The keys of a record: an association's column links to that association's
  # class only; the <type>_id convention reads only columns no association
  # owns, for a monitored model of that name.
  def test_a_record_names_the_people_its_associations_name
    with_side_tables do
      note = ProbeNote.create!(title: "t", body: "b", owner_type: "RightsAuthor", owner_id: @ann.id)
      assert_equal ["ProbeNote$#{note.id}", @ann_key], PamDsl.subject_keys(note)
      assert_equal ["RightsArticle$#{@anns.id}", @ann_key], PamDsl.subject_keys(@anns), "author_id is RightsAuthor's"
      transfer = ProbeTransfer.create!(title: "t", body: "b", payer_id: @ann.id, payee_id: @bob.id)
      assert_equal ["ProbeTransfer$#{transfer.id}", @ann_key, "RightsAuthor$#{@bob.id}"], PamDsl.subject_keys(transfer)
      tagged = ProbeTag.create!(title: "t", rights_author_id: @bob.id, widget_id: 5)
      assert_equal ["ProbeTag$#{tagged.id}", "RightsAuthor$#{@bob.id}"], PamDsl.subject_keys(tagged),
                   "the convention, for a monitored model only"
    end
  end

  # Whose consent a record shared by several people needs is not decided in
  # 1.0.0: a consent check on such a record is refused, whatever each person
  # consented to and in whichever column they are named.
  def test_consent_for_a_record_naming_several_people_is_refused
    with_side_tables do
      Lyra.config.record_access_events = true
      consent = PamDsl.policy(:rights_policy).consent_policy
      ann_pays = ProbeTransfer.create!(title: "t", body: "b", payer_id: @ann.id, payee_id: @bob.id)
      bob_pays = ProbeTransfer.create!(title: "t", body: "b", payer_id: @bob.id, payee_id: @ann.id)
      ann_only = ProbeTransfer.create!(title: "t", body: "b", payer_id: @ann.id)
      shared = Lyra::Rights::ConsentStore::SharedRecordConsentError

      [[], [@ann], [@ann, @bob]].each do |granted|
        granted.each { consent.grant_consent(purpose: :newsletter, subject: _1) }
        [ann_pays, bob_pays].each do |transfer|
          error = assert_raises(shared) { Lyra.with_purpose(:newsletter) { ProbeTransfer.find(transfer.id) } }
          assert_kind_of PamDsl::ConsentRequiredError, error
          assert_match(/several people.*not supported yet/, error.message)
        end
      end
      assert Lyra.with_purpose(:newsletter) { ProbeTransfer.find(ann_only.id) }, "one person: that person's consent"
      consent.withdraw_consent(purpose: :newsletter, subject: @ann)
      assert_raises(PamDsl::ConsentRequiredError) { Lyra.with_purpose(:newsletter) { ProbeTransfer.find(ann_only.id) } }

      denied = Lyra::AccessLog.for(ann_pays).last
      assert_kind_of Lyra::Events::DataAccessDenied, denied
      assert_equal [shared.name], denied.data[:violations].map { _1[:error] }

      # The :consent exception of Art. 18(2) is refused the same way, and says why.
      rights.restrict!(subject: @ann_key, ground: :accuracy_contested)
      violations = PamDsl.policy(:rights_policy).access_violations(%i[title body], :survey, subject: ann_pays)
      assert_equal [PamDsl::RestrictedProcessingError, shared], violations.map(&:class)
    end
  end

  def test_a_record_loaded_without_its_link_column_is_still_matched_to_its_person
    rights.restrict!(subject: @ann_key, ground: :accuracy_contested)
    assert_raises(PamDsl::RestrictedProcessingError) do
      Lyra.with_purpose(:publishing) { RightsArticle.select(:id, :title, :body).find(@anns.id) }
    end
    assert Lyra.with_purpose(:publishing) { RightsArticle.select(:id, :title, :body).find(@bobs.id) }
  end

  def test_consent_reads_of_many_records_do_not_query_per_record
    articles = 20.times.map { |i| RightsArticle.create!(title: "a#{i}", body: "b", author_id: @ann.id) }
    PamDsl.policy(:rights_policy).consent_policy.grant_consent(purpose: :newsletter, subject: @ann)
    Lyra::Rights.refresh!
    queries = consent_queries { Lyra.with_purpose(:newsletter) { RightsArticle.where(id: articles.map(&:id)).to_a } }
    assert_operator queries, :<=, 2
  end

  def test_granting_a_granted_consent_again_records_nothing
    consent = PamDsl.policy(:rights_policy).consent_policy
    at = Time.current - 100
    3.times { consent.grant_consent(purpose: :newsletter, subject: @ann_key, granted_at: at) }
    assert_equal ["ConsentGranted"], Lyra::Rights.consent_store.events_for(@ann_key).map { _1[:type] }
    consent.grant_consent(purpose: :newsletter, subject: @ann_key, granted_at: at + 50)
    assert_equal 2, Lyra::Rights.consent_store.events_for(@ann_key).size, "a new grant is recorded"
  end

  def test_stores_the_application_installed_are_kept_at_boot
    own = PamDsl::RightsStore::Memory.new
    PamDsl.rights_store = own
    PamDsl.consent_store = (consents = PamDsl::ConsentStore.new)
    Lyra::Rights.install!(only_unset: true)
    assert_same own, PamDsl.rights_store
    assert_same consents, PamDsl.consent_store

    PamDsl.rights_store = nil
    PamDsl.consent_store = nil
    Lyra::Rights.install!(only_unset: true)
    assert_same Lyra::Rights.store, PamDsl.rights_store
    assert_same Lyra::Rights.consent_store, PamDsl.consent_store
  end

  # ── Erasure leaves the rights ──

  def test_erasure_and_access_log_erasure_leave_the_rights_and_consent_streams
    Lyra.config.record_access_events = true
    # A pending objection (and its Art. 18(1)(d) restriction of one purpose):
    # a restriction of her data would refuse the erasure (Lyra::Rights::ErasureGuard).
    rights.object!(subject: @ann, policy: :rights_policy, purpose: :survey)
    PamDsl.policy(:rights_policy).consent_policy.grant_consent(purpose: :newsletter, subject: @ann)
    Lyra.with_purpose(:defence) { RightsAuthor.find(@ann.id) }
    before = rights_and_consent_counts

    assert Lyra::AccessLog.erase!(@ann, reason: "Art. 17").positive?
    assert_equal before, rights_and_consent_counts

    Lyra::Erasure.erase!(RightsAuthor, @ann.id, reason: "Art. 17", access_log: true, everywhere: true)
    assert_equal before, rights_and_consent_counts
    assert_equal 2, Lyra::Rights::Store.new.active_for([@ann_key]).size
    assert Lyra::Rights.consent_store.granted?(:newsletter, @ann_key)
  end

  private

  def rights_and_consent_counts
    [connection.select_value("SELECT count(*) FROM event_store_events_in_streams WHERE stream LIKE 'Lyra::Rights%'").to_i,
     connection.select_value("SELECT count(*) FROM event_store_events_in_streams WHERE stream LIKE 'Lyra::Consent%'").to_i,
     connection.select_value("SELECT count(*) FROM lyra_rights").to_i,
     connection.select_value("SELECT count(*) FROM lyra_consents").to_i]
  end

  def with_side_tables
    connection.create_table("probe_notes", force: true) do |t|
      t.string :title
      t.string :body
      t.string :owner_type
      t.integer :owner_id
    end
    connection.create_table("probe_transfers", force: true) do |t|
      t.string :title
      t.string :body
      t.integer :payer_id
      t.integer :payee_id
    end
    connection.create_table("probe_tags", force: true) do |t|
      t.string :title
      t.integer :rights_author_id
      t.integer :widget_id
    end
    %i[ProbeNote ProbeTransfer ProbeTag Owner Payer Payee].each { Object.send(:remove_const, _1) if Object.const_defined?(_1) }
    Object.const_set(:ProbeNote, Class.new(ActiveRecord::Base) do
      self.table_name = "probe_notes"
      belongs_to :owner, polymorphic: true, optional: true
    end)
    Object.const_set(:ProbeTransfer, Class.new(ActiveRecord::Base) do
      self.table_name = "probe_transfers"
      belongs_to :payer, class_name: "RightsAuthor", optional: true
      belongs_to :payee, class_name: "RightsAuthor", optional: true
    end)
    Object.const_set(:ProbeTag, Class.new(ActiveRecord::Base) { self.table_name = "probe_tags" })
    # Models the convention would wrongly match.
    %i[Owner Payer Payee].each { |name| Object.const_set(name, Class.new(ActiveRecord::Base) { self.table_name = "users" }) }
    [ProbeNote, ProbeTransfer, ProbeTag].each do |model|
      model.include(Lyra::Interceptors::CrudInterceptor)
      model.monitor_with_lyra(privacy_policy: :rights_policy)
      Lyra.config.monitor_model(model, privacy_policy: :rights_policy)
    end
    [Owner, Payer, Payee].each { Lyra.config.monitor_model(_1) }
    yield
  ensure
    %w[probe_notes probe_transfers probe_tags].each { connection.drop_table(_1, if_exists: true) }
    %i[Owner Payer Payee].each { Object.send(:remove_const, _1) if Object.const_defined?(_1) }
  end

  def consent_queries
    count = 0
    callback = ->(*, payload) { count += 1 if payload[:sql].to_s.include?("lyra_consents") }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    count
  end

  def rights_queries
    count = 0
    callback = ->(*, payload) { count += 1 if payload[:sql].to_s.include?("lyra_rights") }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    count
  end

  def clean
    connection.execute("DELETE FROM articles")
    connection.execute("DELETE FROM users")
    connection.execute("DELETE FROM event_store_events_in_streams")
    connection.execute("DELETE FROM event_store_events")
    LyraRightsIsolation.purge!
  end
end
