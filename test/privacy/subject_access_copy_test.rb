# frozen_string_literal: true

require "test_helper"

# The Art. 15 copy (from 1.0.0): data_export gives each of the subject's
# records whole, current values and stored past values, selected by what the
# record is (its row, its create or import event) rather than by which events
# repeat the foreign key; the access log; the context the policies declare;
# the controller's notice; and what the policies leave undeclared.
class SubjectAccessCopyTest < Minitest::Test
  PEOPLE = "lyra_sa_people"
  REGISTRATIONS = "lyra_sa_registrations"
  WITHHOLDING = "Art. 15(4), the controller's assessment (example; to be checked with the DPO)"

  def setup
    skip "Requires Rails and PostgreSQL" unless defined?(ActiveRecord::Base) && connection.adapter_name.match?(/postgres/i)
    skip "Requires pam_dsl" unless Lyra.pam_dsl_available?

    ActiveRecord::Encryption.configure(primary_key: "p" * 32, deterministic_key: "d" * 32, key_derivation_salt: "s" * 32)
    connection.create_table(PEOPLE, force: true) do |t|
      t.string :name
      t.string :email
      t.string :password_digest
      t.timestamps
    end
    connection.create_table(REGISTRATIONS, force: true) do |t|
      t.integer :sa_person_id, index: true
      t.integer :amount
      t.string :status
      t.string :payer_name
      t.text :vat_number
      t.timestamps
    end
    define_policies
    define_models
    clean
    Rails.cache.clear
    use(:monitor)
  end

  def teardown
    return unless defined?(SaRegistration)

    Lyra.reset_config!
    clean
    connection.drop_table(REGISTRATIONS, if_exists: true)
    connection.drop_table(PEOPLE, if_exists: true)
    PamDsl.reset!
  end

  # 1. Every attribute, not only those a detector flags.
  def test_a_monitor_created_record_s_copy_holds_its_non_personal_fields
    person = SaPerson.create!(name: "Ann", email: "ann@example.com")
    SaRegistration.create!(sa_person_id: person.id, amount: 500, status: "paid")

    registration = record(export(person), "SaRegistration")
    assert_equal :current, registration[:state]
    assert_equal 500, registration[:attributes]["amount"]
    assert_equal "paid", registration[:attributes]["status"]
  end

  # 2. A row that pre-dates monitoring, with no Genesis.
  def test_a_row_with_no_events_is_in_the_copy
    connection.execute("INSERT INTO #{PEOPLE} (name, email, created_at, updated_at) VALUES ('Old', 'old@example.com', now(), now())")
    id = connection.select_value("SELECT id FROM #{PEOPLE}")
    connection.execute("INSERT INTO #{REGISTRATIONS} (sa_person_id, amount, status, created_at, updated_at) VALUES (#{id}, 70, 'paid', now(), now())")

    copy = export(id)
    person = record(copy, "SaPerson")
    registration = record(copy, "SaRegistration")
    assert_equal "old@example.com", person[:attributes]["email"]
    assert_equal 70, registration[:attributes]["amount"]
    assert_equal [], registration[:history]
    assert_nil registration[:history_from], "history starts at a record's first event; there is none"
  end

  # 3. ES-NoProj: the record is replayed, with the attributes the row would have.
  def test_es_noproj_records_are_replayed
    use(:es_noproj)
    person = SaPerson.create!(name: "Ann", email: "ann@example.com")
    SaRegistration.create!(sa_person_id: person.id, amount: 500, status: "pending").update!(status: "paid")

    registration = record(export(person), "SaRegistration")
    assert_equal :replayed, registration[:state]
    assert_equal %w[amount created_at id payer_name sa_person_id status updated_at vat_number],
                 (registration[:attributes].keys | registration[:review].map { _1[:field] }).sort
    assert_equal "paid", registration[:attributes]["status"]
    assert_equal 500, registration[:attributes]["amount"]
  end

  # 4. and 5. A related record's create, update and destroy are all in its
  # history, in every mode, and a destroyed record is found by its create.
  %i[monitor hijack es_sync es_noproj].each do |mode|
    define_method(:"test_#{mode}_a_related_record_s_whole_history_is_in_the_copy") do
      use(mode)
      person = SaPerson.create!(name: "Ann", email: "ann@example.com")
      registration = SaRegistration.create!(sa_person_id: person.id, amount: 500, status: "pending")
      SaRegistration.find(registration.id).update!(status: "paid")
      SaRegistration.find(registration.id).destroy!
      SaRegistration.create!(sa_person_id: person.id + 1000, amount: 1, status: "other")

      copy = export(person)
      found = copy[:records].select { _1[:model] == "SaRegistration" }
      assert_equal [registration.id], found.map { _1[:id] }, "another person's registration is not in the copy"
      destroyed = found.first
      assert_equal :destroyed, destroyed[:state]
      assert_equal "paid", destroyed[:attributes]["status"], "a destroyed record's last state"
      assert_equal %i[created updated destroyed], destroyed[:history].map { _1[:operation] }.uniq
      assert_includes destroyed[:history], destroyed[:history].find { _1[:field] == "status" && _1[:to] == "paid" }
    end
  end

  # 6. A record whose foreign key moves to another person.
  def test_a_moved_record_belongs_to_each_person_for_the_period_it_named_them
    ann = SaPerson.create!(name: "Ann", email: "ann@example.com")
    bob = SaPerson.create!(name: "Bob", email: "bob@example.com")
    registration = SaRegistration.create!(sa_person_id: ann.id, amount: 500, status: "pending")
    registration.update!(status: "paid")
    registration.update!(sa_person_id: bob.id)
    registration.update!(status: "refunded")

    anns = record(export(ann), "SaRegistration")
    assert_equal :reassigned, anns[:state]
    assert_equal "paid", anns[:attributes]["status"], "as it was when it last named Ann"
    refute anns[:history].any? { _1[:to] == "refunded" }, "Bob's period is not in Ann's copy"
    assert_equal 1, anns[:periods].size
    refute_nil anns[:periods].first[:to]

    bobs = record(export(bob), "SaRegistration")
    assert_equal :current, bobs[:state]
    assert_equal "refunded", bobs[:attributes]["status"]
    refute bobs[:history].any? { _1[:operation] == :created }, "Ann's period is not in Bob's copy"
    assert_nil bobs[:periods].first[:to]
  end

  # 7. History by default, from/to per field; after an import it starts there.
  def test_history_starts_at_the_import
    connection.execute("INSERT INTO #{PEOPLE} (name, email, created_at, updated_at) VALUES ('Old', 'old@example.com', now(), now())")
    id = connection.select_value("SELECT id FROM #{PEOPLE}")
    connection.execute("INSERT INTO #{REGISTRATIONS} (sa_person_id, amount, status, created_at, updated_at) VALUES (#{id}, 70, 'pending', now(), now())")
    Lyra.config.genesis = true
    Lyra::Genesis.first_use(SaRegistration)
    SaRegistration.find_by(sa_person_id: id).update!(status: "paid")

    registration = record(export(id), "SaRegistration")
    assert_equal :imported, registration[:history].first[:operation]
    assert_equal registration[:history].first[:at], registration[:history_from]
    change = registration[:history].find { _1[:operation] == :updated && _1[:field] == "status" }
    assert_equal %w[pending paid], [change[:from], change[:to]]
  end

  # 8. The access log, with role labels; nil and a gap when it is off.
  def test_the_access_log_is_in_the_copy
    Lyra.config.record_access_events = true
    Lyra.config.access_metadata_proc = ->(_access) { { user_id: 99 } }
    person = SaPerson.create!(name: "Ann", email: "ann@example.com")
    registration = SaRegistration.create!(sa_person_id: person.id, amount: 500, status: "paid", vat_number: "GR1")
    PamDsl.policy(:sa_registrations).validate_access!([:vat_number], :invoicing, subject: registration)

    accesses = export(person)[:accesses]
    entry = accesses.find { _1[:record] == "SaRegistration$#{registration.id}" }
    assert_equal "invoicing", entry[:purpose]
    assert_equal %w[vat_number], entry[:fields]
    assert_equal "granted", entry[:outcome]
    assert_equal "staff", entry[:by]

    # Off, the copy still lists the earlier exports (a stream of their own),
    # and says that is all it can list.
    Lyra.config.record_access_events = false
    copy = export(person)
    assert_equal ["exported"], copy[:accesses].map { _1[:outcome] }
    assert_includes copy[:gaps], [nil, "access log not enabled (accesses lists earlier exports only)"]
  end

  # 9. A withheld field is named with its basis; an encrypted column is plaintext.
  def test_a_withheld_field_is_named_and_an_encrypted_one_opened
    person = SaPerson.create!(name: "Ann", email: "ann@example.com", password_digest: "$2a$12$hash")
    registration = SaRegistration.create!(sa_person_id: person.id, amount: 5, status: "paid", vat_number: "GR123")
    registration.update!(vat_number: "GR456")

    copy = export(person)
    own = record(copy, "SaPerson")
    refute own[:attributes].key?("password_digest")
    assert_equal [{ field: "password_digest", basis: WITHHOLDING }], own[:withheld]
    refute_includes copy[:records].inspect, "$2a$12$hash"

    reg = record(copy, "SaRegistration")
    assert_equal "GR456", reg[:attributes]["vat_number"]
    change = reg[:history].find { _1[:operation] == :updated && _1[:field] == "vat_number" }
    assert_equal %w[GR123 GR456], [change[:from], change[:to]], "the log's ciphertext, opened"
  end

  def test_es_noproj_opens_encrypted_values_too
    use(:es_noproj)
    person = SaPerson.create!(name: "Ann", email: "ann@example.com")
    SaRegistration.create!(sa_person_id: person.id, amount: 5, status: "paid", vat_number: "GR123")

    assert_equal "GR123", record(export(person), "SaRegistration")[:attributes]["vat_number"]
  end

  # 10. Another person's data goes to review.
  def test_a_field_about_the_payer_is_for_review
    person = SaPerson.create!(name: "Ann", email: "ann@example.com")
    SaRegistration.create!(sa_person_id: person.id, amount: 5, status: "paid", payer_name: "Bob Payer")

    reg = record(export(person), "SaRegistration")
    refute reg[:attributes].key?("payer_name")
    assert_equal({ field: "payer_name", about: :payer, value: "Bob Payer" }, reg[:review].first.except(:history))
  end

  # 11. Each record's context from its own policy, field periods included.
  def test_each_model_s_context_comes_from_its_own_policy
    person = SaPerson.create!(name: "Ann", email: "ann@example.com")
    SaRegistration.create!(sa_person_id: person.id, amount: 5, status: "paid", vat_number: "GR1")

    contexts = export(person)[:processing_context]
    account = contexts.find { _1[:purpose] == :account }
    invoicing = contexts.find { _1[:purpose] == :invoicing }
    assert_equal :sa_people, account[:policy]
    assert_equal({ "SaPerson" => %w[email name] }, account[:fields])
    assert_equal({ period: "2 years", fields: { "email" => "1 year" } }, account[:retention]["SaPerson"])
    assert_equal :sa_registrations, invoicing[:policy]
    assert_equal :legal_obligation, invoicing[:legal_basis]
    assert_equal({ period: "10 years", fields: { "vat_number" => "5 years" } }, invoicing[:retention]["SaRegistration"])
    assert_equal "the tax registry", invoicing[:sources]["SaRegistration.vat_number"]
  end

  # 12. Undeclared recipients, transfers and sources are gaps.
  def test_what_the_policies_do_not_declare_is_listed_as_a_gap
    person = SaPerson.create!(name: "Ann", email: "ann@example.com")
    SaRegistration.create!(sa_person_id: person.id, amount: 5, status: "paid", payer_name: "Bob")

    copy = export(person)
    invoicing = copy[:processing_context].find { _1[:purpose] == :invoicing }
    assert_nil invoicing[:recipients]
    assert_includes copy[:gaps], [:invoicing, "Art. 15(1)(c) recipients"]
    assert_includes copy[:gaps], [:invoicing, "Art. 15(2) transfers to third countries"]
    assert_includes copy[:gaps], [nil, "Art. 15(1)(g) source not declared: SaRegistration.payer_name"]
    refute_includes copy[:gaps], [:account, "Art. 15(1)(c) recipients"]
    assert_equal "Registry of Example University, registry@example.edu", copy[:notice][:controller]
  end

  # 13. Role labels by default, ids only when disclosed.
  def test_actors_are_labels_unless_disclosed
    person = SaPerson.create!(name: "Ann", email: "ann@example.com")
    Lyra.config.metadata_proc = ->(_record, _op) { { user_id: person.id, user_type: "SaPerson" } }
    registration = SaRegistration.create!(sa_person_id: person.id, amount: 5, status: "pending")
    Lyra.config.metadata_proc = ->(_record, _op) { { user_id: 99, ip_address: "10.1.2.3" } }
    registration.update!(status: "paid")

    history = record(export(person), "SaRegistration")[:history]
    assert_equal %w[you staff], history.map { _1[:by] }.uniq
    refute history.any? { _1.key?(:actor) }
    refute_includes history.inspect, "10.1.2.3"

    disclosed = record(export(person, disclose_actors: true), "SaRegistration")[:history]
    assert_equal({ user_id: 99, ip_address: "10.1.2.3" }, disclosed.find { _1[:by] == "staff" }[:actor])
  end

  # 14. Each export is recorded in the subject's access stream, without values.
  def test_the_export_is_recorded_and_can_be_turned_off
    person = SaPerson.create!(name: "Ann", email: "ann@example.com")
    export(person, verified_by: "registry desk")

    recorded = exports_of(person)
    assert_equal ["Lyra::Events::SubjectAccessExported"], recorded.map(&:event_type)
    assert_empty Lyra::AccessLog.for("SaPerson$#{person.id}"), "not in the access log, which can be erased"
    data = recorded.first.data
    assert_equal "SaPerson$#{person.id}", data[:subject]
    assert_equal %w[records history processing_context notice], data[:sections]
    assert_equal "registry desk", data[:verified_by]
    refute_includes recorded.first.data.inspect + recorded.first.metadata.inspect, "ann@example.com"

    Lyra.config.record_access_events = true
    accesses = export(person)[:accesses]
    assert_equal "exported", accesses.find { _1[:record] == "SaPerson$#{person.id}" }[:outcome], "an earlier export is in the log"

    Lyra.config.record_subject_access_exports = false
    assert_no_new_events { export(person) }
  end

  # The record that a request was answered outlives the erasure of the
  # subject's access log, by AccessLog.erase! or by Lyra::Erasure.
  def test_the_export_record_survives_access_log_erasure
    Lyra.config.record_access_events = true
    person = SaPerson.create!(name: "Ann", email: "ann@example.com")
    PamDsl.policy(:sa_people).validate_access!([:email], :account, subject: person)
    export(person)

    Lyra::AccessLog.erase!(person, reason: "Art. 17 request", erased_by: "dpo")
    assert_empty Lyra::AccessLog.for(person)
    assert_equal 1, exports_of(person).size

    Lyra::Erasure.erase!(SaPerson, person.id, reason: "Art. 17 request", access_log: true)
    assert_equal 1, exports_of(person).size
    assert_equal ["exported"], export(person, record: false)[:accesses].map { _1[:outcome] }, "still shown in the copy"
  end

  # Only an explicit export answers a request: full_report, a data_export
  # with record: false, and the dashboard's routes record nothing.
  def test_only_an_explicit_export_is_recorded
    person = SaPerson.create!(name: "Ann", email: "ann@example.com")

    assert_no_new_events { compliance(person).full_report }
    assert_no_new_events { export(person, record: false) }
    export(person)
    assert_equal 1, exports_of(person).size
  end

  # 15. The keys data_export always returned are still there, but for the
  # per-event processing_activities, whose purposes were guessed from keywords:
  # from 1.0.0 the purposes are the policy's, in processing_context.
  def test_the_existing_keys_are_unchanged
    person = SaPerson.create!(name: "Ann", email: "ann@example.com")
    copy = export(person)

    %i[subject generated_at events pii_inventory data_lineage processing_context].each { assert copy.key?(_1), _1 }
    refute copy.key?(:processing_activities), "the guessed purposes are gone"
    refute_empty copy[:processing_context]
    assert_equal 1, copy[:events].size
    assert_equal :created, copy[:events].first[:operation].to_sym
  end

  # 16. A subject with no records.
  def test_a_subject_with_nothing_gets_an_empty_copy
    copy = export(4711)

    assert_equal [], copy[:records]
    assert_includes copy[:gaps], [nil, "no records: nothing is held about the subject"]
    assert_equal "Registry of Example University, registry@example.edu", copy[:notice][:controller], "the subject type's policy"
  end

  # The policy of the subject's model and the policy of each related model reach
  # the Art. 30 activities too (it said "Not specified" without policy_name:).
  def test_processing_activities_read_each_model_s_policy
    person = SaPerson.create!(name: "Ann", email: "ann@example.com")
    SaRegistration.create!(sa_person_id: person.id, amount: 5, status: "paid", vat_number: "GR1")

    bases = compliance(person).processing_activities.map { _1[:legal_basis] }.join("; ")
    assert_includes bases, "Contract (Art. 6(1)(b))"
    assert_includes bases, "Legal obligation (Art. 6(1)(c))"
    refute_includes bases, "Not specified"
  end

  # ── Review findings ──────────────────────────────────────────────────────

  # A record whose key moved away is the previous subject's only until the
  # move, even when the move is its last event; and a transition event gives
  # each subject only their side of it.
  %i[monitor hijack es_sync es_noproj].each do |mode|
    define_method(:"test_#{mode}_a_move_as_the_last_event_closes_the_period") do
      use(mode)
      ann = SaPerson.create!(name: "Ann", email: "ann@example.com")
      bob = SaPerson.create!(name: "Bob", email: "bob@example.com")
      registration = SaRegistration.create!(sa_person_id: ann.id, amount: 500, status: "pending", vat_number: "ANNVAT")
      SaRegistration.find(registration.id).update!(sa_person_id: bob.id, vat_number: "BOBVAT", status: "bobs")

      anns = record(export(ann, record: false), "SaRegistration")
      assert_equal :reassigned, anns[:state]
      assert_equal "ANNVAT", anns[:attributes]["vat_number"]
      assert_equal 1, anns[:periods].size
      refute_nil anns[:periods].first[:to]
      refute_includes anns.inspect, "BOBVAT"
      refute_includes anns.inspect, "bobs"
      move = anns[:history].find { _1[:field] == "sa_person_id" && _1[:operation] == :updated }
      assert_equal [ann.id, "moved to another person"], [move[:from], move[:to]]

      bobs = record(export(bob, record: false), "SaRegistration")
      refute_includes bobs.inspect, "ANNVAT"
      refute_includes bobs.inspect, "pending"
      assert_equal "BOBVAT", bobs[:attributes]["vat_number"]
    end
  end

  def test_the_old_keys_carry_neither_the_other_person_s_side_nor_withheld_values_nor_ciphertext
    ann = SaPerson.create!(name: "Ann", email: "ann@example.com", password_digest: "$2a$secret")
    bob = SaPerson.create!(name: "Bob", email: "bob@example.com")
    registration = SaRegistration.create!(sa_person_id: ann.id, amount: 1, status: "x", vat_number: "GR999",
                                          payer_name: "Paul Payer")
    registration.update!(sa_person_id: bob.id, vat_number: "BOBVAT", payer_name: "Bob Payer")

    old = export(ann, record: false).slice(:events, :pii_inventory, :data_lineage).inspect
    refute_includes old, "$2a$secret", "a withheld field"
    refute_includes old, "Paul Payer", "another person's field"
    refute_includes old, "BOBVAT", "the new owner's side of the move"
    refute_includes old, "Bob Payer"
    assert_includes old, "GR999", "the subject's encrypted value, opened"
  end

  def test_accesses_to_a_moved_record_are_the_subject_s_only_within_their_period
    Lyra.config.record_access_events = true
    ann = SaPerson.create!(name: "Ann", email: "ann@example.com")
    bob = SaPerson.create!(name: "Bob", email: "bob@example.com")
    registration = SaRegistration.create!(sa_person_id: ann.id, amount: 1, status: "a", vat_number: "V")
    PamDsl.policy(:sa_registrations).validate_access!([:vat_number], :invoicing, subject: registration)
    sleep 0.01
    registration.update!(sa_person_id: bob.id)
    sleep 0.01
    PamDsl.policy(:sa_registrations).validate_access!([:vat_number], :invoicing, subject: registration)

    record_key = "SaRegistration$#{registration.id}"
    anns = export(ann, record: false)[:accesses].select { _1[:record] == record_key }
    bobs = export(bob, record: false)[:accesses].select { _1[:record] == record_key }
    assert_equal 1, anns.size, "the access before the move"
    assert_equal 1, bobs.size, "the access after it"
  end

  def test_retention_the_policy_does_not_declare_is_a_gap
    PamDsl.define_policy(:sa_people) do
      field :email, type: :email, collected_from: :data_subject
      field :name, type: :name, collected_from: :data_subject
      purpose(:account) { basis :contract; requires :email, :name; recipients "h"; no_transfers! }
    end
    person = SaPerson.create!(name: "Ann", email: "ann@example.com")

    copy = export(person, record: false)
    account = copy[:processing_context].find { _1[:purpose] == :account }
    assert_nil account[:retention]["SaPerson"][:period], "no silent 7-year default"
    assert_includes copy[:gaps], [nil, "Art. 15(1)(d) retention not declared: SaPerson"]
    assert_includes copy[:gaps],
                    [nil, "not declared in the policy (no purpose, basis or retention stated): " \
                          "SaPerson.created_at, SaPerson.password_digest, SaPerson.updated_at"]
  end

  def test_the_writer_s_class_is_recorded_and_decides_you
    person = SaPerson.create!(name: "Ann", email: "ann@example.com")
    with_current(user: person) { SaRegistration.create!(sa_person_id: person.id, amount: 1, status: "a") }
    other = SaStaff.new(person.id) # another class, the same id
    with_current(user: other) { SaRegistration.where(sa_person_id: person.id).first.update!(status: "b") }

    history = record(export(person, record: false), "SaRegistration")[:history]
    stream = Lyra.config.event_store.read.stream(Lyra.stream_name(SaRegistration, SaRegistration.first.id)).to_a
    assert_equal "SaPerson", stream.first.metadata[:user_type]
    assert_equal "SubjectAccessCopyTest::SaStaff", stream.last.metadata[:user_type]
    assert_equal %w[you staff], history.map { _1[:by] }.uniq, "never \"you\" for another class with the subject's id"
  end

  def test_accesses_recorded_under_the_bare_id_are_in_the_copy
    Lyra.config.record_access_events = true
    person = SaPerson.create!(name: "Ann", email: "ann@example.com")
    PamDsl.policy(:sa_people).validate_access!([:email], :account, subject: person.id)

    assert_equal 1, export(person, record: false)[:accesses].count { _1[:record] == person.id.to_s }
  end

  def test_values_set_in_another_person_s_period_are_not_given
    ann = SaPerson.create!(name: "Ann", email: "ann@example.com")
    bob = SaPerson.create!(name: "Bob", email: "bob@example.com")
    registration = SaRegistration.create!(sa_person_id: ann.id, amount: 1, status: "a")
    registration.update!(sa_person_id: bob.id)
    registration.update!(status: "bob-period")
    registration.update!(sa_person_id: ann.id)

    anns = record(export(ann, record: false), "SaRegistration")
    assert_equal :current, anns[:state]
    refute_includes anns.inspect, "bob-period"
    assert_includes anns[:withheld], { field: "status", basis: "set while the record was another person's" }
    assert_equal 1, anns[:attributes]["amount"], "a value the subject's own period set"
    assert_equal 2, anns[:periods].size

    registration.update!(sa_person_id: bob.id)
    again = record(export(ann, record: false), "SaRegistration")
    assert_equal :reassigned, again[:state]
    refute_includes again.inspect, "bob-period", "B's earlier period's values are not replayed into A's"
  end

  def test_records_linked_by_a_named_or_polymorphic_belongs_to_are_found
    connection.create_table("lyra_sa_notes", force: true) do |t|
      t.integer :owner_id
      t.string :about_type
      t.integer :about_id
      t.string :body
      t.timestamps
    end
    Object.send(:remove_const, :SaNote) if Object.const_defined?(:SaNote)
    Object.const_set(:SaNote, Class.new(ActiveRecord::Base) do
      self.table_name = "lyra_sa_notes"
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
      belongs_to :owner, class_name: "SaPerson", optional: true
      belongs_to :about, polymorphic: true, optional: true
    end)
    Lyra.config.monitor_model(SaNote)
    ann = SaPerson.create!(name: "Ann", email: "ann@example.com")
    owned = SaNote.create!(owner_id: ann.id, body: "owned")
    about = SaNote.create!(about_type: "SaPerson", about_id: ann.id, body: "about")
    SaNote.create!(about_type: "SaRegistration", about_id: ann.id, body: "another type, same id")

    found = export(ann, record: false)[:records].select { _1[:model] == "SaNote" }.map { _1[:id] }.sort
    assert_equal [owned.id, about.id].sort, found
  ensure
    connection.drop_table("lyra_sa_notes", if_exists: true)
  end

  # A column an association owns links only to that association's class: the
  # <type>_id convention does not also read owner_id as a link to a model
  # named Owner, nor a polymorphic about_id as one to a model named About.
  def test_a_column_an_association_owns_is_not_also_read_by_the_convention
    connection.create_table("lyra_sa_notes", force: true) do |t|
      t.integer :owner_id
      t.string :about_type
      t.integer :about_id
      t.string :body
      t.timestamps
    end
    %i[SaNote Owner About].each { Object.send(:remove_const, _1) if Object.const_defined?(_1) }
    Object.const_set(:SaNote, Class.new(ActiveRecord::Base) do
      self.table_name = "lyra_sa_notes"
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
      belongs_to :owner, class_name: "SaPerson", optional: true
      belongs_to :about, polymorphic: true, optional: true
    end)
    # Two other monitored models, whose names the convention would match.
    Object.const_set(:Owner, Class.new(ActiveRecord::Base) { self.table_name = PEOPLE })
    Object.const_set(:About, Class.new(ActiveRecord::Base) { self.table_name = PEOPLE })
    [Owner, About].each { Lyra.config.monitor_model(_1) }
    Lyra.config.monitor_model(SaNote)
    ann = SaPerson.create!(name: "Ann", email: "ann@example.com")
    owned = SaNote.create!(owner_id: ann.id, body: "owned")
    about = SaNote.create!(about_type: "SaPerson", about_id: ann.id, body: "about")

    found = ->(type) do
      Lyra::Privacy::GDPRCompliance.new(subject_id: ann.id, subject_type: type).data_export(record: false)[:records]
                                   .select { _1[:model] == "SaNote" }.map { _1[:id] }.sort
    end
    assert_equal [owned.id, about.id].sort, found.call("SaPerson")
    assert_empty found.call("Owner"), "owner_id is SaPerson's, by its belongs_to"
    assert_empty found.call("About"), "about_id is the polymorphic link's, checked by its type column"
  ensure
    connection.drop_table("lyra_sa_notes", if_exists: true)
    %i[Owner About].each { Object.send(:remove_const, _1) if Object.const_defined?(_1) }
  end

  private

  class SaCurrent < ActiveSupport::CurrentAttributes
    attribute :user
  end

  SaStaff = Struct.new(:id)

  def with_current(user:)
    original = Object.send(:remove_const, :Current) if Object.const_defined?(:Current, false)
    Object.const_set(:Current, SaCurrent)
    SaCurrent.user = user
    yield
  ensure
    SaCurrent.reset
    Object.send(:remove_const, :Current) if Object.const_defined?(:Current, false)
    Object.const_set(:Current, original) if original
  end

  def define_policies
    PamDsl.reset!
    PamDsl.define_policy(:sa_people) do
      field :email, type: :email, collected_from: :data_subject
      field :name, type: :name, collected_from: :data_subject
      field :password_digest, type: :credential, withheld_from_access: WITHHOLDING
      purpose(:account) { basis :contract; requires :email, :name; recipients "hosting processor"; no_transfers! }
      retention { for_model("SaPerson") { keep_for 2.years; field :email, duration: 1.year } }
      access_notice controller: "Registry of Example University, registry@example.edu",
                    rights: "rectification, erasure, restriction, objection, portability",
                    complaint: "the supervisory authority of your Member State"
    end
    PamDsl.define_policy(:sa_registrations) do
      field :vat_number, type: :identifier, collected_from: "the tax registry"
      field :payer_name, type: :name, about: :payer
      purpose(:invoicing) { basis :legal_obligation; requires :vat_number }
      purpose(:fees) { basis :contract; requires :payer_name; recipients "bank"; no_transfers! }
      retention { for_model("SaRegistration") { keep_for 10.years; field :vat_number, duration: 5.years } }
      access_notice controller: "Registry of Example University, registry@example.edu"
    end
  end

  def define_models
    %i[SaPerson SaRegistration].each { Object.send(:remove_const, _1) if Object.const_defined?(_1) }
    Object.const_set(:SaPerson, Class.new(ActiveRecord::Base) do
      self.table_name = PEOPLE
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra(privacy_policy: :sa_people)
    end)
    Object.const_set(:SaRegistration, Class.new(ActiveRecord::Base) do
      self.table_name = REGISTRATIONS
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra(privacy_policy: :sa_registrations)
      encrypts :vat_number
    end)
    SaPerson.reset_column_information
    SaRegistration.reset_column_information
  end

  def use(mode)
    LyraConfigIsolation.install_fresh_config
    Lyra.config.monitor_model(SaPerson, privacy_policy: :sa_people)
    Lyra.config.monitor_model(SaRegistration, privacy_policy: :sa_registrations)
    Lyra.config.genesis = false
    case mode
    when :monitor then Lyra.config.enable_monitor!
    when :hijack then Lyra.config.enable_hijack!
    else
      Lyra.config.enable_event_sourcing!
      Lyra.config.projection_mode = { es_sync: :sync, es_noproj: :disabled }.fetch(mode)
    end
  end

  def compliance(subject)
    id = subject.respond_to?(:id) ? subject.id : subject
    Lyra::Privacy::GDPRCompliance.new(subject_id: id, subject_type: "SaPerson")
  end

  def export(subject, **options)
    compliance(subject).data_export(**options)
  end

  def record(copy, model)
    copy[:records].find { _1[:model] == model }
  end

  def exports_of(person)
    Lyra.config.event_store.read.stream("Lyra::SubjectAccessExports$SaPerson$#{person.id}").to_a
  end

  def assert_no_new_events
    before = connection.select_value("SELECT count(*) FROM event_store_events").to_i
    yield
    assert_equal before, connection.select_value("SELECT count(*) FROM event_store_events").to_i
  end

  def connection = ActiveRecord::Base.connection

  def clean
    connection.execute("DELETE FROM event_store_events_in_streams")
    connection.execute("DELETE FROM event_store_events")
  end
end
