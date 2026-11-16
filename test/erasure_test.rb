# frozen_string_literal: true

require "test_helper"

# Lyra::Erasure: one record's personal data erased from its row and from
# every event in its stream, the stream still replaying to the row, and the
# erasure itself recorded.
class ErasureTest < Minitest::Test
  MT = Lyra::ModeTransition

  def setup
    skip "Requires Rails and database" unless defined?(ActiveRecord::Base) && ActiveRecord::Base.connection.table_exists?(:users)
    skip "Requires pam_dsl" unless Lyra.pam_dsl_available?

    PamDsl.reset!
    PamDsl.define_policy(:erase_policy) do
      field :email, type: :email, sensitivity: :confidential
      field :name, type: :name
      purpose :contact do
        basis :contract
        requires :email
      end
    end
    Object.send(:remove_const, :EraseUser) if defined?(EraseUser)
    Object.const_set(:EraseUser, Class.new(ActiveRecord::Base) { self.table_name = "users" })
    EraseUser.include(Lyra::Interceptors::CrudInterceptor)
    monitor(privacy_policy: :erase_policy)
    clean
    Lyra.config.enable_monitor!
  end

  def teardown
    return unless defined?(EraseUser)

    Lyra.config.projection_mode = :sync
    Lyra.config.strict_data_access = false
    Lyra.config.record_access_events = false
    Lyra.config.erase_access_log = false
    Lyra.config.enable_monitor!
    clean
    drop_payments
    drop_subs
    PamDsl.reset!
  end

  def test_the_row_and_every_event_lose_the_personal_values
    user = EraseUser.create!(name: "Ann", email: "ann@example.com")
    user.update!(email: "ann@new.example")
    ids_before = stream(user).map(&:event_id)

    result = Lyra::Erasure.erase!(EraseUser, user.id, reason: "Art. 17 request #12")

    assert_equal %w[email name], result.fields.sort
    assert_equal 0, result.shared_values, "an Integer count even without everywhere"
    assert_equal 2, result.events_rewritten
    assert_equal ["erased:#{user.id}"] * 2, raw("SELECT email, name FROM users WHERE id = #{user.id}", :rows).first
    assert_match(/erased:#{user.id}/, log_text, "the scan reads the stored data")
    refute_match(/ann@|Ann/, log_text, "no value left in the log")
    assert_equal ids_before, stream(user).first(2).map(&:event_id), "overwritten in place"
    assert_nil MT.discrepancy(EraseUser, user.id.to_s), "the stream still replays to the row"
  end

  def test_the_erasure_is_recorded_without_values
    user = EraseUser.create!(name: "Ann", email: "ann@example.com")
    Lyra::Erasure.erase!(EraseUser, user.id, reason: "Art. 17 request #12", erased_by: "dpo")

    event = stream(user).last
    assert_kind_of Lyra::Events::ErasureApplied, event
    assert_equal "Art. 17 request #12", event.data[:reason]
    assert_equal %w[email name], event.data[:fields].sort
    assert_equal ["lyra_erasure", "dpo"], event.metadata.to_h.values_at(:source, :erased_by)
    assert_nil Lyra::Event.operation_of(event), "not replayed"
  end

  def test_only_the_fields_named
    user = EraseUser.create!(name: "Ann", email: "ann@example.com")
    Lyra::Erasure.erase!(EraseUser, user.id, reason: "r", fields: %w[email])

    assert_equal ["Ann", "erased:#{user.id}"], raw("SELECT name, email FROM users WHERE id = #{user.id}", :rows).first
  end

  # A column of the record's own row that is not erased but holds a copy of
  # an erased value (a username that is the email address): its events are
  # rewritten, so the row must be too, or replay and row part.
  def test_a_copy_in_another_column_of_the_row_is_erased_with_its_events
    user = EraseUser.create!(name: "ann@example.com", email: "ann@example.com")

    result = Lyra::Erasure.erase!(EraseUser, user.id, reason: "r", fields: %w[email])

    assert_equal ["erased:#{user.id}"] * 2, raw("SELECT name, email FROM users WHERE id = #{user.id}", :rows).first
    refute_match(/ann@/, log_text)
    assert_nil MT.discrepancy(EraseUser, user.id.to_s), "the stream still replays to the row"
    assert_equal %w[email name], stream(user).last.data[:fields].sort, "the copy is named in the record"
    assert_equal %w[email], result.fields, "the fields asked for"
  end

  # A copy the row no longer holds is left in the row: its later events set
  # the current value, which is not the erased one.
  def test_a_copy_the_row_no_longer_holds_is_left_in_the_row
    user = EraseUser.create!(name: "ann@example.com", email: "ann@example.com")
    user.update!(name: "Ann")

    Lyra::Erasure.erase!(EraseUser, user.id, reason: "r", fields: %w[email])

    assert_equal ["Ann", "erased:#{user.id}"], raw("SELECT name, email FROM users WHERE id = #{user.id}", :rows).first
    refute_match(/ann@/, log_text)
    assert_nil MT.discrepancy(EraseUser, user.id.to_s)
  end

  # From 0.9.3 named fields must be personal: an erasure rewrites history in
  # place, so a column the policy does not declare is refused unless asked.
  def test_a_field_the_policy_does_not_declare_is_refused
    user = EraseUser.create!(name: "Ann", email: "ann@example.com")

    error = assert_raises(Lyra::Erasure::Unsupported) do
      Lyra::Erasure.erase!(EraseUser, user.id, reason: "r", fields: %w[email created_at])
    end
    assert_match(/created_at not declared personal/, error.message)
    assert_equal "ann@example.com", user.reload.email, "nothing erased"
  end

  def test_an_erasure_records_whether_any_fields_was_used_and_what_was_asked
    user = EraseUser.create!(name: "Ann", email: "ann@example.com")
    Lyra::Erasure.erase!(EraseUser, user.id, reason: "r", erased_by: "dpo")

    data = stream(user).last.data
    assert_equal false, data[:any_fields]
    assert_nil data[:requested_fields], "nothing was named: the declared columns"
    assert_empty data[:beyond_policy]
  end

  def test_any_fields_is_recorded_with_the_columns_it_added_beyond_the_policy
    user = EraseUser.create!(name: "Ann", email: "ann@example.com")
    with_policy_without_name do
      Lyra::Erasure.erase!(EraseUser, user.id, reason: "r", fields: %w[name], any_fields: true, erased_by: "anyone")
    end

    event = stream(user).last
    assert_equal true, event.data[:any_fields]
    assert_equal %w[name], event.data[:requested_fields]
    assert_equal %w[name], event.data[:beyond_policy], "name is not declared personal by this policy"
    assert_equal "anyone", event.metadata[:erased_by], "the label is what was claimed"
    assert_equal Etc.getpwuid(Process.uid).name, event.metadata[:os_user]
    assert_equal Socket.gethostname, event.metadata[:host]
    assert_equal Process.pid, event.metadata[:pid]
  end

  def test_any_fields_erases_an_undeclared_column
    user = EraseUser.create!(name: "Ann", email: "ann@example.com")
    with_policy_without_name do
      Lyra::Erasure.erase!(EraseUser, user.id, reason: "r", fields: %w[name], any_fields: true)
    end

    assert_equal "erased:#{user.id}", user.reload.name
  end

  def test_a_domain_event_payload_under_the_attribute_s_name_is_erased_too
    monitor(privacy_policy: :erase_policy,
            domain_events: [{ name: "MemberJoined", on: :create, payload: ->(u, _c) { { email: u.email } } }])
    user = EraseUser.create!(name: "Ann", email: "ann@example.com")

    Lyra::Erasure.erase!(EraseUser, user.id, reason: "r")
    assert_equal "erased:#{user.id}", stream(user).first.data[:payload][:email]
  end

  # A copy under another name is found by its value.
  def test_a_payload_copy_under_another_name_is_erased_too
    monitor(privacy_policy: :erase_policy,
            domain_events: [{ name: "MemberJoined", on: :create, payload: ->(u, _c) { { contact: u.email } } }])
    user = EraseUser.create!(name: "Ann", email: "ann@example.com")

    Lyra::Erasure.erase!(EraseUser, user.id, reason: "r")
    assert_equal "erased:#{user.id}", stream(user).first.data[:payload][:contact]
    refute_match(/ann@example/, log_text)
  end

  # everywhere: another record that copied the value, its row and events.
  def test_everywhere_erases_copies_held_by_other_records
    note_class
    user = EraseUser.create!(name: "Ann", email: "ann@example.com")
    note = EraseNote.create!(title: "Contact", body: "ann@example.com")
    unrelated = EraseNote.create!(title: "Other", body: "bob@example.com")

    result = Lyra::Erasure.erase!(EraseUser, user.id, reason: "r", everywhere: true)

    assert_equal ["EraseNote #{note.id}"], result.copies
    assert_equal 0, result.shared_values, "an Integer count, 0 when none"
    assert_nil raw("SELECT body FROM articles WHERE id = #{note.id}"), "nullable column: nil"
    assert_equal "bob@example.com", raw("SELECT body FROM articles WHERE id = #{unrelated.id}")
    refute_match(/ann@example/, log_text)
    assert_kind_of Lyra::Events::ErasureApplied,
                   Lyra.config.event_store.read.stream("EraseNote$#{note.id}").to_a.last
    assert_nil MT.discrepancy(EraseNote, note.id.to_s), "the copy's stream still replays to its row"
  ensure
    ActiveRecord::Base.connection.execute("DELETE FROM articles")
  end

  # A value held by many other records is shared, not a copy: erasing it
  # everywhere erased everyone's (a replay's placeholder took every address).
  def test_everywhere_leaves_a_value_many_records_share
    note_class
    user = EraseUser.create!(name: "Ann", email: "ann@example.com")
    3.times { |i| EraseNote.create!(title: "Shared #{i}", body: "ann@example.com") }

    result = Lyra::Erasure.erase!(EraseUser, user.id, reason: "r", everywhere: true, max_copies: 2)

    assert_equal 1, result.shared_values, "the email, held by three other records"
    assert_empty result.copies
  ensure
    ActiveRecord::Base.connection.execute("DELETE FROM articles")
  end

  # Another customer can share a name or a postal code by coincidence: only
  # direct identifiers (email, phone, ids, ...) are searched for elsewhere.
  def test_everywhere_does_not_take_a_name_another_record_shares
    user = EraseUser.create!(name: "Ann", email: "ann@example.com")
    other = EraseUser.create!(name: "Ann", email: "other@example.com")

    result = Lyra::Erasure.erase!(EraseUser, user.id, reason: "r", everywhere: true)

    assert_empty result.copies
    assert_equal "Ann", raw("SELECT name FROM users WHERE id = #{other.id}")
    assert_equal "erased:#{user.id}", raw("SELECT name FROM users WHERE id = #{user.id}"), "the person's own is erased"
  end

  # Structured columns (from 1.0.0). The origin's events lose a personal
  # value inside a jsonb column, under the field's name (key rule) and under
  # any other name (value rule); its row kept both, and no longer replayed to
  # its events. The row now gets the rule its events get.
  def test_the_origin_s_jsonb_column_is_erased_as_its_events_are
    payment_class(privacy_policy: :erase_payment_policy)
    payment = ErasePayment.create!(email: "ann@example.com",
                                   payload: { "contact" => "ann@example.com", "email" => "boss@example.com", "amount" => 5 })

    result = Lyra::Erasure.erase!(ErasePayment, payment.id, reason: "r")

    # The email column is nullable: its replacement, under its name and as a copy, is nil.
    assert_equal({ "contact" => nil, "email" => nil, "amount" => 5 }, payload_of(payment))
    assert_equal({ "contact" => nil, "email" => nil, "amount" => 5 },
                 replayed(ErasePayment, payment.id)["payload"], "the events got the same")
    assert_nil MT.discrepancy(ErasePayment, payment.id.to_s), "the stream still replays to the row"
    assert_equal({}, Lyra::DualView.new(ErasePayment, payment.id).compare[:differences])
    refute_match(/ann@example|boss@example/, log_text)
    assert_includes payment_stream(payment).last.data[:fields], "payload", "the column is named in the record"
    assert_equal %w[email], result.fields
  end

  # everywhere: another record holding the email inside its jsonb column.
  # Its events were scrubbed and its row was not, yet it was reported as
  # erased. A third party's email under an "email" key in that record is not
  # the subject's: other records get the value rule only.
  def test_everywhere_erases_a_copy_inside_another_record_s_jsonb_and_keeps_a_third_party_s
    payment_class
    user = EraseUser.create!(name: "Ann", email: "ann@example.com")
    payment = ErasePayment.create!(payload: { "payer_email" => "ann@example.com", "email" => "boss@example.com",
                                              "amount" => 5 })

    result = Lyra::Erasure.erase!(EraseUser, user.id, reason: "r", everywhere: true)

    expected = { "payer_email" => "erased:#{user.id}", "email" => "boss@example.com", "amount" => 5 }
    assert_equal expected, payload_of(payment)
    assert_equal expected, replayed(ErasePayment, payment.id)["payload"]
    assert_nil MT.discrepancy(ErasePayment, payment.id.to_s), "the copy's stream still replays to its row"
    assert_equal ["ErasePayment #{payment.id}"], result.copies
    refute_match(/ann@example/, log_text)
    assert_match(/boss@example/, log_text, "the third party's email is kept in the events too")
    assert_equal %w[payload], payment_stream(payment).last.data[:fields]
  end

  # A PostgreSQL array comes back as a Ruby Array: the same recursion.
  def test_everywhere_erases_a_copy_inside_an_array_column
    payment_class
    user = EraseUser.create!(name: "Ann", email: "ann@example.com")
    payment = ErasePayment.create!(tags: ["vip", "ann@example.com"])

    result = Lyra::Erasure.erase!(EraseUser, user.id, reason: "r", everywhere: true)

    tags = ErasePayment.unscoped.find(payment.id).tags
    assert_equal "vip", tags.first
    refute_includes tags, "ann@example.com"
    assert_equal tags, replayed(ErasePayment, payment.id)["tags"]
    assert_nil MT.discrepancy(ErasePayment, payment.id.to_s)
    assert_equal ["ErasePayment #{payment.id}"], result.copies
    refute_match(/ann@example/, log_text)
  end

  # A text column that holds JSON is a string in its events too: it is
  # compared as a string, in the row as in the events. Parsing it in the row
  # alone would part the row from its replay.
  def test_a_text_column_holding_json_is_compared_as_a_string
    payment_class(privacy_policy: :erase_payment_policy)
    notes = '{"contact":"ann@example.com"}'
    payment = ErasePayment.create!(email: "ann@example.com", notes: notes)

    Lyra::Erasure.erase!(ErasePayment, payment.id, reason: "r")

    assert_equal notes, raw("SELECT notes FROM #{PAYMENTS} WHERE id = #{payment.id}")
    assert_equal notes, replayed(ErasePayment, payment.id)["notes"]
    assert_nil MT.discrepancy(ErasePayment, payment.id.to_s)
  end

  # A jsonb column declared personal is replaced whole by the key rule, in
  # the row and in its events alike (0.9.3 replaced it in the row only).
  def test_a_jsonb_column_declared_personal_is_replaced_whole_in_row_and_events
    PamDsl.define_policy(:erase_address_policy) do
      field :email, type: :email
      field :payload, type: :address
      purpose :contact do
        basis :contract
        requires :email
      end
    end
    payment_class(privacy_policy: :erase_address_policy)
    payment = ErasePayment.create!(email: "ann@example.com", payload: { "street" => "1 Main St" })
    payment.update!(payload: { "street" => "2 Side St" })

    Lyra::Erasure.erase!(ErasePayment, payment.id, reason: "r")

    assert_nil payload_of(payment)
    assert_nil replayed(ErasePayment, payment.id)["payload"]
    assert_nil MT.discrepancy(ErasePayment, payment.id.to_s)
    refute_match(/Main St|Side St/, log_text)
  end

  # A serialized attribute is a hash in its events, so it is recursed into
  # in the row too.
  def test_everywhere_erases_a_copy_inside_a_serialized_column
    payment_class
    ErasePayment.serialize :notes, coder: JSON
    user = EraseUser.create!(name: "Ann", email: "ann@example.com")
    payment = ErasePayment.create!(notes: { "payer_email" => "ann@example.com", "ref" => "A1" })

    result = Lyra::Erasure.erase!(EraseUser, user.id, reason: "r", everywhere: true)

    notes = ErasePayment.unscoped.find(payment.id).notes
    assert_equal({ "payer_email" => "erased:#{user.id}", "ref" => "A1" }, notes)
    assert_nil MT.discrepancy(ErasePayment, payment.id.to_s)
    assert_equal ["ErasePayment #{payment.id}"], result.copies
    refute_match(/ann@example/, log_text)
  end

  # A structured column declared personal is replaced whole, by its own
  # default when it is NOT NULL: an empty array, an empty jsonb. Element by
  # element, an int[] got [[], []] and the erasure failed.
  def test_a_not_null_structured_column_declared_personal_gets_its_own_default
    policy = payment_policy(:erase_nn_policy, nn_tags: :email, nn_nums: :identifier, nn_doc: :address)
    payment_class(privacy_policy: policy, columns: lambda { |t|
      t.string :nn_tags, array: true, null: false, default: []
      t.integer :nn_nums, array: true, null: false, default: []
      t.jsonb :nn_doc, null: false, default: {}
    })
    payment = ErasePayment.create!(email: "ann@example.com", nn_tags: %w[a@b.example c@d.example], nn_nums: [1, 2],
                                   nn_doc: %w[x y])
    payment.update!(nn_tags: %w[e@f.example], nn_nums: [3], nn_doc: { "street" => "1 Main St" })

    Lyra::Erasure.erase!(ErasePayment, payment.id, reason: "r")

    row = ErasePayment.unscoped.find(payment.id)
    assert_equal [[], [], {}], [row.nn_tags, row.nn_nums, row.nn_doc]
    assert_equal [[], [], {}], replayed(ErasePayment, payment.id).values_at("nn_tags", "nn_nums", "nn_doc")
    assert_nil MT.discrepancy(ErasePayment, payment.id.to_s)
    refute_match(/a@b\.example|e@f\.example|Main St/, log_text)
  end

  # A nullable array column declared personal is replaced whole too: nil,
  # not an array of nils.
  def test_an_array_column_declared_personal_is_replaced_whole
    payment_class(privacy_policy: payment_policy(:erase_tags_policy, tags: :email))
    payment = ErasePayment.create!(email: "ann@example.com", tags: %w[a@b.example c@d.example])

    Lyra::Erasure.erase!(ErasePayment, payment.id, reason: "r")

    assert_nil ErasePayment.unscoped.find(payment.id).tags
    assert_nil replayed(ErasePayment, payment.id)["tags"]
    assert_nil MT.discrepancy(ErasePayment, payment.id.to_s)
  end

  # The erasure is a write: it moves lock_version, as any write does, so a
  # copy loaded before it cannot save the erased values back.
  %i[monitor hijack es_sync].each do |mode|
    define_method("test_a_stale_copy_cannot_save_after_the_erasure_in_#{mode}") do
      locking_payment_class
      enter_mode(mode)
      payment = ErasePayment.create!(email: "ann@example.com", payload: { "c" => "ann@example.com" })
      stale = ErasePayment.unscoped.find(payment.id)

      Lyra::Erasure.erase!(ErasePayment, payment.id, reason: "r")

      assert_raises(ActiveRecord::StaleObjectError) { stale.update!(username: "x") }
      assert_nil raw("SELECT email FROM #{PAYMENTS} WHERE id = #{payment.id}")
    end
  end

  # The move is recorded in the record's stream, as an ordinary update of
  # lock_version marked as the erasure's, so the row still equals its replay.
  %i[monitor hijack es_sync].each do |mode|
    define_method("test_the_lock_move_is_in_the_log_in_#{mode}") do
      locking_payment_class
      enter_mode(mode)
      payment = ErasePayment.create!(email: "ann@example.com", payload: { "c" => "ann@example.com" })
      ErasePayment.unscoped.find(payment.id).update!(username: "x")
      before = ErasePayment.unscoped.find(payment.id).lock_version

      Lyra::Erasure.erase!(ErasePayment, payment.id, reason: "r")

      assert_equal before + 1, ErasePayment.unscoped.find(payment.id).lock_version
      assert_equal before + 1, replayed(ErasePayment, payment.id)["lock_version"]
      assert_nil MT.discrepancy(ErasePayment, payment.id.to_s)
      assert_equal({}, Lyra::DualView.new(ErasePayment, payment.id).compare[:differences])
      bump = payment_stream(payment).find { _1.metadata[:source] == Lyra::Erasure::SOURCE && Lyra::Event.operation_of(_1) }
      assert_equal({ "lock_version" => [before, before + 1] }, bump.data[:changes].transform_keys(&:to_s))
      refute_match(/ann@example/, log_text)
    end
  end

  # A copy in another record's row moves that record's lock too.
  def test_everywhere_moves_the_lock_of_a_record_holding_a_copy
    locking_payment_class
    user = EraseUser.create!(name: "Ann", email: "ann@example.com")
    payment = ErasePayment.create!(payload: { "payer_email" => "ann@example.com" })

    Lyra::Erasure.erase!(EraseUser, user.id, reason: "r", everywhere: true)

    assert_equal 1, ErasePayment.unscoped.find(payment.id).lock_version
    assert_nil MT.discrepancy(ErasePayment, payment.id.to_s)
  end

  # A model without optimistic locking gets no lock event.
  def test_a_model_without_optimistic_locking_gets_no_lock_event
    user = EraseUser.create!(name: "Ann", email: "ann@example.com")

    Lyra::Erasure.erase!(EraseUser, user.id, reason: "r")

    assert_equal [Lyra::Events::ErasureApplied],
                 stream(user).select { _1.metadata[:source] == Lyra::Erasure::SOURCE }.map(&:class)
    assert_equal 2, stream(user).size, "the create and the erasure"
  end

  # The person's own row is checked like the others: a value held as a JSON
  # key or inside a longer string is not erased, and is reported.
  def test_what_the_person_s_own_row_still_holds_is_reported
    payment_class(privacy_policy: :erase_payment_policy)
    payment = ErasePayment.create!(email: "ann@example.com", notes: "Write to ann@example.com, not Bob",
                                   payload: { "ann@example.com" => 1 })

    result = Lyra::Erasure.erase!(ErasePayment, payment.id, reason: "r")

    assert_equal [{ record: "ErasePayment #{payment.id}", columns: %w[payload notes] }], result.left_behind
    refute_match(/ann@/, result.left_behind.inspect)
    assert_nil MT.discrepancy(ErasePayment, payment.id.to_s)
  end

  # ES-NoProj has no row: the record's replayed state is checked instead.
  def test_es_noproj_checks_the_replayed_state_of_the_own_record
    payment_class(privacy_policy: :erase_payment_policy)
    Lyra.config.enable_event_sourcing!
    Lyra.config.projection_mode = :disabled
    payment = ErasePayment.create!(email: "ann@example.com", notes: "Write to ann@example.com")

    result = Lyra::Erasure.erase!(ErasePayment, payment.id, reason: "r")

    assert_equal [{ record: "ErasePayment #{payment.id}", columns: %w[notes] }], result.left_behind
  end

  # Inside a personal structure only the strings that are themselves
  # identifying for the field's type are the person's values: an email for
  # :email. Labels ("home", "active") are not, and are not erased elsewhere.
  def test_labels_inside_a_personal_jsonb_are_not_the_person_s_values
    payment_class(privacy_policy: payment_policy(:erase_work_policy, payload: :email))
    payment = ErasePayment.create!(email: "ann@example.com", notes: "active", username: "home",
                                   payload: { "kind" => "home", "address" => "work@ann.example", "status" => "active" })
    other = ErasePayment.create!(username: "home", notes: "active")
    copy = ErasePayment.create!(username: "work@ann.example")

    result = Lyra::Erasure.erase!(ErasePayment, payment.id, reason: "r", everywhere: true)

    own = ErasePayment.unscoped.find(payment.id)
    assert_nil own.payload, "the personal structure is replaced whole"
    assert_equal %w[home active], [own.username, own.notes], "its labels are not erased elsewhere in the record"
    assert_equal %w[home active], ErasePayment.unscoped.find(other.id).attributes.values_at("username", "notes")
    assert_nil ErasePayment.unscoped.find(copy.id).username
    assert_equal ["ErasePayment #{copy.id}"], result.copies
    assert_nil MT.discrepancy(ErasePayment, payment.id.to_s)
    refute_match(/work@ann/, log_text)
  end

  def test_an_identifier_inside_a_personal_structure_is_the_person_s_value
    payment_class(privacy_policy: payment_policy(:erase_passport_policy, payload: :identifier))
    payment = ErasePayment.create!(email: "ann@example.com", payload: { "kind" => "passport", "number" => "AB1234567" })
    copy = ErasePayment.create!(username: "AB1234567", notes: "passport")

    result = Lyra::Erasure.erase!(ErasePayment, payment.id, reason: "r", everywhere: true)

    assert_equal [nil, "passport"], ErasePayment.unscoped.find(copy.id).attributes.values_at("username", "notes")
    assert_equal ["ErasePayment #{copy.id}"], result.copies
  end

  # An earlier erasure's replacement ("erased:<id>") is not the person's
  # value: a second erasure neither reports it nor searches for it.
  def test_a_second_erasure_does_not_take_the_replacement_for_a_value
    payment_class
    user = EraseUser.create!(name: "Ann", email: "ann@example.com")
    note = ErasePayment.create!(notes: "see erased:#{user.id}", username: "erased:#{user.id}")
    Lyra::Erasure.erase!(EraseUser, user.id, reason: "r")

    result = Lyra::Erasure.erase!(EraseUser, user.id, reason: "r", everywhere: true)

    assert_equal [], result.left_behind
    assert_equal [], result.copies
    assert_equal "erased:#{user.id}", ErasePayment.unscoped.find(note.id).username
  end

  # The scrub follows the attribute's type, as the events' does: an hstore
  # column, or a text column the model casts as json, is recursed into.
  def test_an_hstore_copy_is_erased_in_row_and_events_alike
    ActiveRecord::Base.connection.enable_extension("hstore")
    payment_class(columns: ->(t) { t.hstore :extra })
    user = EraseUser.create!(name: "Ann", email: "ann@example.com")
    payment = ErasePayment.create!(extra: { "contact" => "ann@example.com", "kind" => "home" })

    result = Lyra::Erasure.erase!(EraseUser, user.id, reason: "r", everywhere: true)

    assert_equal({ "contact" => "erased:#{user.id}", "kind" => "home" }, ErasePayment.unscoped.find(payment.id).extra)
    assert_nil MT.discrepancy(ErasePayment, payment.id.to_s)
    assert_equal ["ErasePayment #{payment.id}"], result.copies
    assert_equal [], result.left_behind
  end

  def test_a_text_column_cast_as_json_is_erased_in_row_and_events_alike
    payment_class { attribute :notes, :json }
    user = EraseUser.create!(name: "Ann", email: "ann@example.com")
    payment = ErasePayment.create!(notes: { "c" => "ann@example.com" })

    result = Lyra::Erasure.erase!(EraseUser, user.id, reason: "r", everywhere: true)

    assert_equal({ "c" => "erased:#{user.id}" }, ErasePayment.unscoped.find(payment.id).notes)
    assert_nil MT.discrepancy(ErasePayment, payment.id.to_s)
    assert_equal ["ErasePayment #{payment.id}"], result.copies
  end

  # A primary key is never rewritten: the stream is named after it. One
  # that holds the erased value is reported, and never printed.
  def test_a_primary_key_holding_the_person_s_value_is_reported_not_rewritten
    PamDsl.define_policy(:erase_handle_policy) do
      field :handle, type: :email
      purpose(:contact) { basis :contract; requires :handle }
    end
    sub_class(privacy_policy: :erase_handle_policy)
    EraseSub.create!(handle: "ann@example.com", label: "news")

    result = Lyra::Erasure.erase!(EraseSub, "ann@example.com", reason: "r")

    assert_equal ["ann@example.com"], EraseSub.unscoped.pluck(:handle)
    assert_nil MT.discrepancy(EraseSub, "ann@example.com"), "the row and its stream still agree"
    assert_equal [{ record: "EraseSub <key withheld>", columns: %w[handle] }], result.left_behind
    assert result.key_withheld
    refute_match(/ann@/, [result.left_behind, result.copies, result.fields].inspect)
  end

  def test_a_primary_key_reached_by_everywhere_is_reported_not_rewritten
    sub_class
    EraseSub.create!(handle: "ann@example.com", label: "news")
    user = EraseUser.create!(name: "Ann", email: "ann@example.com")

    result = Lyra::Erasure.erase!(EraseUser, user.id, reason: "r", everywhere: true)

    assert_equal ["ann@example.com"], EraseSub.unscoped.pluck(:handle)
    assert_nil MT.discrepancy(EraseSub, "ann@example.com")
    assert_equal [], result.copies
    assert_equal [{ record: "EraseSub <key withheld>", columns: %w[handle] }], result.left_behind
    refute result.key_withheld, "the erased record's own key is not the value"
  end

  # A holder's row and stream are read under its lock: a copy written
  # between the search and the holder's erasure is erased too.
  def test_a_copy_written_during_the_search_is_erased_with_the_rest
    payment_class
    user = EraseUser.create!(name: "Ann", email: "ann@example.com")
    payment = ErasePayment.create!(payload: { "payer" => "ann@example.com" })
    search = Lyra::Erasure.method(:events_mentioning)
    racing = lambda do |values|
      found = search.call(values)
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ErasePayment.unscoped.find(payment.id).update!(username: "ann@example.com")
        end
      end.join
      found
    end

    result = Lyra::Erasure.stub(:events_mentioning, racing) do
      Lyra::Erasure.erase!(EraseUser, user.id, reason: "r", everywhere: true)
    end

    assert_nil ErasePayment.unscoped.find(payment.id).username
    assert_nil MT.discrepancy(ErasePayment, payment.id.to_s)
    refute_match(/ann@example/, log_text)
    assert_equal ["ErasePayment #{payment.id}"], result.copies
  end

  # Copies in other records' encrypted columns cannot be found by a text
  # search of the log: the columns are named as not searched.
  def test_encrypted_columns_of_other_records_are_named_as_not_searched
    ActiveRecord::Encryption.configure(primary_key: "p" * 32, deterministic_key: "d" * 32, key_derivation_salt: "s" * 32)
    payment_class { encrypts :username }
    user = EraseUser.create!(name: "Ann", email: "ann@example.com")
    ErasePayment.create!(username: "ann@example.com")

    assert_equal ["ErasePayment.username"],
                 Lyra::Erasure.erase!(EraseUser, user.id, reason: "r", everywhere: true).not_searched
    assert_equal [], Lyra::Erasure.erase!(EraseUser, user.id, reason: "r").not_searched
  end

  # citext compares without case: a copy differing in case is reported.
  def test_a_citext_copy_differing_in_case_is_reported
    ActiveRecord::Base.connection.enable_extension("citext")
    payment_class(columns: ->(t) { t.citext :alias })
    user = EraseUser.create!(name: "Ann", email: "ann@example.com")
    payment = ErasePayment.create!(alias: "ANN@example.com")

    result = Lyra::Erasure.erase!(EraseUser, user.id, reason: "r", everywhere: true)

    assert_equal [{ record: "ErasePayment #{payment.id}", columns: %w[alias] }], result.left_behind
  end

  # ES-Async: the row trails the log. The lock moves from the version the
  # log recorded, not from the row's.
  def test_es_async_moves_the_lock_from_the_logged_version
    locking_payment_class
    Lyra.config.enable_event_sourcing!
    Lyra.config.projection_mode = :sync
    payment = ErasePayment.create!(email: "ann@example.com")
    Lyra.config.projection_mode = :async
    Lyra.config.async_projections_inline = false
    adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    ErasePayment.unscoped.find(payment.id).update!(username: "a") # logged at 1, row still at 0

    Lyra::Erasure.erase!(ErasePayment, payment.id, reason: "r")

    bump = payment_stream(payment).find { _1.metadata[:lock_moved_by_erasure] }
    assert_equal [1, 2], bump.data[:changes].transform_keys(&:to_s)["lock_version"]
  ensure
    Lyra.config.async_projections_inline = nil
    ActiveJob::Base.queue_adapter = adapter if adapter
  end

  def test_a_clean_erasure_leaves_nothing_behind_in_the_own_row
    payment_class(privacy_policy: :erase_payment_policy)
    payment = ErasePayment.create!(email: "ann@example.com", username: "ann@example.com",
                                   payload: { "c" => "ann@example.com" }, notes: "hello")

    assert_equal [], Lyra::Erasure.erase!(ErasePayment, payment.id, reason: "r").left_behind
  end

  # A value held as a JSON key is not erased (renaming a key changes the
  # document's structure), so the record is not reported as an erased copy:
  # it is reported as left behind, with the columns, never the value.
  def test_a_value_held_as_a_json_key_is_left_and_reported
    payment_class
    user = EraseUser.create!(name: "Ann", email: "ann@example.com")
    both = ErasePayment.create!(payload: { "ann@example.com" => 1 }, username: "ann@example.com")
    key_only = ErasePayment.create!(payload: { "ann@example.com" => 1 })

    result = Lyra::Erasure.erase!(EraseUser, user.id, reason: "r", everywhere: true)

    assert_empty result.copies
    assert_equal [{ record: "ErasePayment #{both.id}", columns: %w[payload] },
                  { record: "ErasePayment #{key_only.id}", columns: %w[payload] }],
                 result.left_behind.sort_by { _1[:record] }
    refute_match(/ann@/, result.left_behind.inspect)
    assert_nil ErasePayment.unscoped.find(both.id).username, "the exact copy is erased"
    assert_nil MT.discrepancy(ErasePayment, both.id.to_s)
  end

  # A text column holding the value inside a longer string is not erased (a
  # value is matched whole), and the record is not reported as erased.
  def test_a_value_inside_a_text_column_is_left_and_reported
    payment_class
    user = EraseUser.create!(name: "Ann", email: "ann@example.com")
    payment = ErasePayment.create!(notes: '{"c":"ann@example.com"}', username: "ann@example.com")

    result = Lyra::Erasure.erase!(EraseUser, user.id, reason: "r", everywhere: true)

    assert_empty result.copies
    assert_equal [{ record: "ErasePayment #{payment.id}", columns: %w[notes] }], result.left_behind
  end

  def test_left_behind_is_empty_when_nothing_is_left
    user = EraseUser.create!(name: "Ann", email: "ann@example.com")

    assert_equal [], Lyra::Erasure.erase!(EraseUser, user.id, reason: "r", everywhere: true).left_behind
  end

  # Monitor's events hold an encrypted attribute's ciphertext, the row its
  # plaintext once read: both are compared in clear, so a copy is erased from
  # both, and the record replays to its row.
  def test_an_encrypted_column_is_erased_in_row_and_events_alike
    ActiveRecord::Encryption.configure(primary_key: "p" * 32, deterministic_key: "d" * 32, key_derivation_salt: "s" * 32)
    payment_class(privacy_policy: :erase_payment_policy) { encrypts :username }
    payment = ErasePayment.create!(email: "ann@example.com", username: "ann@example.com", notes: "hello")
    payment.update!(username: "someone") # change pairs in the log, both ways
    payment.update!(username: "ann@example.com")

    Lyra::Erasure.erase!(ErasePayment, payment.id, reason: "r")

    assert_nil ErasePayment.unscoped.find(payment.id).username
    assert_nil replayed(ErasePayment, payment.id)["username"]
    assert_nil MT.discrepancy(ErasePayment, payment.id.to_s)
    opened = payment_stream(payment).flat_map do |event|
      [Lyra::EncryptedAttributes.open(ErasePayment, event.data[:attributes] || {})["username"],
       *Array((event.data[:changes] || {})["username"]).map { Lyra::EncryptedAttributes.open(ErasePayment, { "username" => _1 })["username"] }]
    end
    refute opened.any? { _1.to_s.include?("ann@") }, "no event decrypts to the email"
  end

  # The strings inside a jsonb column declared personal are this person's
  # values too: copies of them are erased in the record and, with
  # everywhere, in other records.
  def test_values_inside_a_personal_jsonb_are_erased_where_copied
    payment_class(privacy_policy: payment_policy(:erase_work_policy, payload: :email))
    payment = ErasePayment.create!(email: "ann@example.com", payload: { "work" => "work@ann.example" },
                                   username: "work@ann.example")
    other = ErasePayment.create!(username: "work@ann.example")

    result = Lyra::Erasure.erase!(ErasePayment, payment.id, reason: "r", everywhere: true)

    assert_nil ErasePayment.unscoped.find(payment.id).username
    assert_nil ErasePayment.unscoped.find(other.id).username
    assert_equal ["ErasePayment #{other.id}"], result.copies
    assert_nil MT.discrepancy(ErasePayment, payment.id.to_s)
    assert_nil MT.discrepancy(ErasePayment, other.id.to_s)
    refute_match(/work@ann/, log_text)
  end

  # An event that is not a CRUD envelope (an application's own event in the
  # record's stream) gets the key rule at its top level: a hash under a
  # personal field's name is replaced whole there too.
  def test_a_personal_key_at_the_top_of_another_event_is_replaced_whole
    payment_class(privacy_policy: payment_policy(:erase_street_policy, payload: :address))
    payment = ErasePayment.create!(email: "ann@example.com", payload: { "street" => "1 Main St" })
    Object.const_set(:EraseAddressChanged, Class.new(Lyra::Event)) unless defined?(EraseAddressChanged)
    Lyra.config.event_store.publish(EraseAddressChanged.new(data: { payload: { "street" => "1 Main St" } }),
                                    stream_name: "ErasePayment$#{payment.id}")

    Lyra::Erasure.erase!(ErasePayment, payment.id, reason: "r")

    refute_match(/Main St/, log_text)
    assert_nil MT.discrepancy(ErasePayment, payment.id.to_s)
  end

  # A virtual attribute (attribute :x) has no column to write.
  def test_a_virtual_attribute_does_not_stop_the_erasure
    payment_class(privacy_policy: :erase_payment_policy) do
      attribute :contact_hint, :string
      after_initialize { self.contact_hint ||= email }
    end
    payment = ErasePayment.create!(email: "ann@example.com")

    Lyra::Erasure.erase!(ErasePayment, payment.id, reason: "r")

    assert_nil raw("SELECT email FROM #{PAYMENTS} WHERE id = #{payment.id}")
  end

  # Principle 2: a record is reported as erased only if its row no longer
  # holds the value. Here the row could not be written.
  def test_a_holder_whose_row_still_holds_the_value_is_not_reported_as_erased
    payment_class
    user = EraseUser.create!(name: "Ann", email: "ann@example.com")
    ErasePayment.create!(payload: { "payer_email" => "ann@example.com" })
    write = Lyra::Erasure.method(:write_columns)
    skip_payments = ->(model, id, columns) { write.call(model, id, columns) unless model == ErasePayment }

    result = Lyra::Erasure.stub(:write_columns, skip_payments) do
      Lyra::Erasure.erase!(EraseUser, user.id, reason: "r", everywhere: true)
    end

    assert_empty result.copies
  end

  def test_es_noproj_the_events_are_the_record
    Lyra.config.enable_event_sourcing!
    Lyra.config.projection_mode = :disabled
    user = EraseUser.create!(name: "Ann", email: "ann@example.com")
    EraseUser.find(user.id) # cached

    result = Lyra::Erasure.erase!(EraseUser, user.id, reason: "r")
    refute result.row_erased, "no row in ES-NoProj"
    assert_equal "erased:#{user.id}", EraseUser.find(user.id).email, "read after erasure, not from the cache"
  end

  def test_strict_data_access_and_a_purpose_in_scope_do_not_stop_it
    user = EraseUser.create!(name: "Ann", email: "ann@example.com")
    Lyra.config.strict_data_access = true

    Lyra.with_purpose(:contact) { Lyra::Erasure.erase!(EraseUser, user.id, reason: "r") }
    assert_equal "erased:#{user.id}", raw("SELECT email FROM users WHERE id = #{user.id}")
  end

  # Solidus freezes an address once an order uses it; update_columns refused it.
  def test_a_record_the_application_marks_read_only_is_erased_too
    user = EraseUser.create!(name: "Ann", email: "ann@example.com")
    EraseUser.class_eval { def readonly? = persisted? }

    Lyra::Erasure.erase!(EraseUser, user.id, reason: "r")
    assert_equal "erased:#{user.id}", raw("SELECT email FROM users WHERE id = #{user.id}")
  ensure
    EraseUser.class_eval { remove_method :readonly? }
  end

  def test_nothing_to_erase_without_a_policy_or_fields
    monitor
    user = EraseUser.create!(name: "Ann", email: "ann@example.com")

    assert_raises(Lyra::Erasure::Unsupported) { Lyra::Erasure.erase!(EraseUser, user.id, reason: "r") }
  end

  # 0.16 (from 1.0.0): the subject's access stream survived erasure intact,
  # unreported. It is kept by default, and ErasureApplied says so.
  def test_the_access_log_is_kept_by_default_and_the_erasure_says_so
    user, other = two_users_read_twice
    entries = access_event_ids(user)

    result = Lyra::Erasure.erase!(EraseUser, user.id, reason: "r")

    assert_equal ["kept", 2], [result.access_log, result.access_log_entries]
    assert_equal({ access_log: "kept", access_log_entries: 2 },
                 stream(user).last.data.slice(:access_log, :access_log_entries))
    assert_equal entries, access_event_ids(user)
    assert_equal 2, Lyra::AccessLog.for(other).size
  end

  def test_erase_access_log_deletes_the_subject_s_access_events_everywhere
    Lyra.config.erase_access_log = true
    user, other = two_users_read_twice
    entries = access_event_ids(user)
    Lyra.config.event_store.link(entries, stream_name: "AccessAudit$1")
    in_list = entries.map { |event_id| "'#{event_id}'" }.join(", ")

    result = Lyra::Erasure.erase!(EraseUser, user.id, reason: "r")

    assert_equal ["erased", 2], [result.access_log, result.access_log_entries]
    assert_equal({ access_log: "erased", access_log_entries: 2 },
                 stream(user).last.data.slice(:access_log, :access_log_entries))
    assert_empty Lyra::AccessLog.for(user)
    assert_equal 0, raw("SELECT count(*) FROM event_store_events_in_streams WHERE event_id IN (#{in_list})").to_i,
                 "unlinked from every stream"
    assert_equal 0, raw("SELECT count(*) FROM event_store_events WHERE event_id IN (#{in_list})").to_i,
                 "deleted, not only unlinked"
    assert_equal 2, Lyra::AccessLog.for(other).size, "another subject's log is not touched"
    assert_nil MT.discrepancy(EraseUser, user.id.to_s), "the record's stream still replays to the row"
    assert_nil MT.discrepancy(EraseUser, other.id.to_s)
  end

  def test_the_call_overrides_the_configuration
    Lyra.config.erase_access_log = true
    user, = two_users_read_twice
    assert_equal "kept", Lyra::Erasure.erase!(EraseUser, user.id, reason: "r", access_log: false).access_log
    assert_equal 2, Lyra::AccessLog.for(user).size

    Lyra.config.erase_access_log = false
    assert_equal "erased", Lyra::Erasure.erase!(EraseUser, user.id, reason: "r", access_log: true).access_log
    assert_empty Lyra::AccessLog.for(user)
  end

  def test_a_record_never_read_reports_an_empty_log
    user = EraseUser.create!(name: "Ann", email: "ann@example.com")

    result = Lyra::Erasure.erase!(EraseUser, user.id, reason: "r", access_log: true)
    assert_equal ["erased", 0], [result.access_log, result.access_log_entries]
  end

  # The configuration deletes the log only once the record is fully erased:
  # after one field, the rest of the record is still processed, and read.
  def test_the_configuration_keeps_the_log_until_every_personal_field_is_erased
    Lyra.config.erase_access_log = true
    user, = two_users_read_twice

    assert_equal "kept", Lyra::Erasure.erase!(EraseUser, user.id, reason: "r", fields: %w[email]).access_log
    assert_equal 2, Lyra::AccessLog.for(user).size

    result = Lyra::Erasure.erase!(EraseUser, user.id, reason: "r", fields: %w[name])
    assert_equal ["erased", 2], [result.access_log, result.access_log_entries], "email before, name now: complete"
    assert_empty Lyra::AccessLog.for(user)
  end

  # The ids an application passes as this person's subject
  # (validate_access!(…, subject: "user-7")) have logs of their own; they go
  # with the record's when the log is erased, and only then.
  def test_access_log_subjects_are_erased_with_the_record_s_log
    user, = two_users_read_twice
    policy = PamDsl.policy(:erase_policy)
    2.times { policy.validate_access!([:email], :contact, subject: "user-7") }
    policy.validate_access!([:email], :contact, subject: "user-8")

    kept = Lyra::Erasure.erase!(EraseUser, user.id, reason: "r", fields: %w[email], access_log_subjects: ["user-7"])
    assert_equal ["kept", 4], [kept.access_log, kept.access_log_entries], "kept, and counted with the record's"
    assert_equal 2, Lyra::AccessLog.for("user-7").size

    result = Lyra::Erasure.erase!(EraseUser, user.id, reason: "r", access_log: true, access_log_subjects: ["user-7"])
    assert_equal ["erased", 4], [result.access_log, result.access_log_entries]
    assert_equal 1, stream(user).last.data[:access_log_subjects], "how many, never which ids"
    assert_empty Lyra::AccessLog.for("user-7")
    assert_empty Lyra::AccessLog.for(user)
    assert_equal 1, Lyra::AccessLog.for("user-8").size, "another id is not touched"
  end

  def test_a_model_wide_key_is_refused_as_a_subject
    user = EraseUser.create!(name: "Ann", email: "ann@example.com")
    error = assert_raises(Lyra::AccessLog::ModelWideSubject) do
      Lyra::Erasure.erase!(EraseUser, user.id, reason: "r", access_log: true, access_log_subjects: ["EraseUser$*"])
    end
    assert_match(/names no subject/, error.message)
    assert_equal "Ann", raw("SELECT name FROM users WHERE id = #{user.id}"), "refused before anything was erased"
  end

  def test_an_explicit_request_deletes_the_log_after_a_partial_erasure_too
    user, = two_users_read_twice

    assert_equal "erased", Lyra::Erasure.erase!(EraseUser, user.id, reason: "r", fields: %w[email], access_log: true).access_log
    assert_empty Lyra::AccessLog.for(user)
  end

  # Part 2 of 0.8 (from 1.0.0). Finding 8 of part 1's review: a third
  # party's email under a personal key ("email") nested inside the person's
  # own data is erased there, but it is not the person's value, so it is
  # not searched for elsewhere: the third party's own record keeps it.
  def test_a_third_party_s_value_inside_the_person_s_own_data_is_not_searched_for_elsewhere
    payment_class(privacy_policy: :erase_payment_policy)
    boss = ErasePayment.create!(email: "boss@example.com", username: "boss")
    payment = ErasePayment.create!(email: "ann@example.com",
                                   payload: { "manager" => { "email" => "boss@example.com" }, "amount" => 5 })

    result = Lyra::Erasure.erase!(ErasePayment, payment.id, reason: "r", everywhere: true)

    assert_equal "boss@example.com", ErasePayment.unscoped.find(boss.id).email, "the boss's own record is untouched"
    assert_equal "boss@example.com", replayed(ErasePayment, boss.id)["email"], "and so are its events"
    assert_equal({ "manager" => { "email" => nil }, "amount" => 5 }, payload_of(payment), "erased in the person's record")
    assert_nil MT.discrepancy(ErasePayment, payment.id.to_s)
    assert_nil MT.discrepancy(ErasePayment, boss.id.to_s)
    assert_empty result.copies
    refute_match(/ann@example/, log_text)
  end

  # The same value at the top of the person's own field is the person's,
  # and is searched for.
  def test_the_person_s_own_top_level_value_is_still_searched_for
    payment_class(privacy_policy: :erase_payment_policy)
    payment = ErasePayment.create!(email: "ann@example.com", payload: { "manager" => { "email" => "boss@example.com" } })
    copy = ErasePayment.create!(username: "ann@example.com")

    result = Lyra::Erasure.erase!(ErasePayment, payment.id, reason: "r", everywhere: true)

    assert_nil ErasePayment.unscoped.find(copy.id).username
    assert_equal ["ErasePayment #{copy.id}"], result.copies
  end

  # 3.2: a row that holds the value while its events do not (written by
  # raw SQL, or before monitoring) is found by searching the table itself.
  def test_everywhere_finds_rows_that_hold_the_value_without_events
    payment_class(privacy_policy: :erase_payment_policy)
    user = EraseUser.create!(name: "Ann", email: "ann@example.com")
    in_json = ErasePayment.create!(payload: { "amount" => 5 })
    in_text = ErasePayment.create!(username: "someone")
    in_array = ErasePayment.create!(tags: ["vip"])
    untouched = ErasePayment.create!(username: "someone else")
    raw("UPDATE #{PAYMENTS} SET username = 'joann@example.com' WHERE id = #{untouched.id}")
    raw(%(UPDATE #{PAYMENTS} SET payload = '{"amount": 5, "payer_email": "ann@example.com"}' WHERE id = #{in_json.id}))
    raw("UPDATE #{PAYMENTS} SET username = 'ann@example.com' WHERE id = #{in_text.id}")
    raw("UPDATE #{PAYMENTS} SET tags = ARRAY['vip', 'ann@example.com'] WHERE id = #{in_array.id}")

    result = Lyra::Erasure.erase!(EraseUser, user.id, reason: "r", everywhere: true)

    assert_equal({ "amount" => 5, "payer_email" => "erased:#{user.id}" }, payload_of(in_json))
    assert_nil ErasePayment.unscoped.find(in_text.id).username
    assert_equal ["vip", "erased:#{user.id}"], ErasePayment.unscoped.find(in_array.id).tags
    assert_equal "joann@example.com", ErasePayment.unscoped.find(untouched.id).username, "a value is matched whole"
    found = [in_json, in_text, in_array].map { |p| "ErasePayment #{p.id}" }
    assert_equal found.sort, result.rows_without_events.sort
    assert_equal found.sort, result.copies.sort
    [[in_json, %w[payload]], [in_text, %w[username]], [in_array, %w[tags]]].each do |payment, columns|
      erasure = payment_stream(payment).last
      assert_kind_of Lyra::Events::ErasureApplied, erasure
      assert_equal true, erasure.data[:row_only]
      assert_equal columns, erasure.data[:fields]
    end
    assert_equal [], result.left_behind
  end

  # Q6: a row with no stream is erased first and then imported the Genesis
  # way, so its first event holds the replacement, never the value.
  def test_a_row_with_no_stream_is_erased_and_then_imported
    payment_class(privacy_policy: :erase_payment_policy)
    user = EraseUser.create!(name: "Ann", email: "ann@example.com")
    id = raw("INSERT INTO #{PAYMENTS} (username, payload, created_at, updated_at) " \
             "VALUES ('ann@example.com', '{\"payer\": \"ann@example.com\"}', now(), now()) RETURNING id")

    result = Lyra::Erasure.erase!(EraseUser, user.id, reason: "r", everywhere: true)

    events = Lyra.config.event_store.read.stream("ErasePayment$#{id}").to_a
    assert_equal [:imported, nil], events.map { |e| Lyra::Event.operation_of(e) }
    assert_kind_of Lyra::Events::ErasureApplied, events.last
    assert_equal true, events.first.metadata[:genesis]
    assert_nil events.first.data[:attributes]["username"]
    assert_equal({ "payer" => "erased:#{user.id}" }, events.first.data[:attributes]["payload"])
    refute_match(/ann@example/, log_text, "the first event never held the value")
    assert_nil ErasePayment.unscoped.find(id).username
    assert_nil MT.discrepancy(ErasePayment, id.to_s), "the row replays to its import"
    assert_equal ["ErasePayment #{id}"], result.copies
    assert_empty result.rows_without_events, "imported: its row and its stream agree"
    assert_equal 0, Lyra::Genesis.import_all(ErasePayment), "Genesis sees it as imported"
    Lyra.config.enable_event_sourcing!
    Lyra.config.projection_mode = :disabled
    assert_nil ErasePayment.find_by(id: id).username, "ES-NoProj reads it from its stream"
  end

  # Q2: only monitored models with a policy are searched.
  def test_tables_without_a_policy_or_not_monitored_are_not_searched
    payment_class # monitored, no policy
    user = EraseUser.create!(name: "Ann", email: "ann@example.com")
    id = raw("INSERT INTO #{PAYMENTS} (username, created_at, updated_at) VALUES ('ann@example.com', now(), now()) RETURNING id")
    conn = ActiveRecord::Base.connection
    conn.create_table(:lyra_erase_plain, force: true) { |t| t.string :email }
    raw("INSERT INTO lyra_erase_plain (email) VALUES ('ann@example.com')")

    result = Lyra::Erasure.erase!(EraseUser, user.id, reason: "r", everywhere: true)

    assert_equal "ann@example.com", raw("SELECT username FROM #{PAYMENTS} WHERE id = #{id}")
    assert_equal "ann@example.com", raw("SELECT email FROM lyra_erase_plain")
    assert_empty result.rows_without_events
  ensure
    ActiveRecord::Base.connection.drop_table(:lyra_erase_plain, if_exists: true)
  end

  # ES-NoProj has no tables to search (absent or stale).
  def test_es_noproj_skips_the_row_search
    payment_class(privacy_policy: :erase_payment_policy)
    Lyra.config.enable_event_sourcing!
    Lyra.config.projection_mode = :disabled
    user = EraseUser.create!(name: "Ann", email: "ann@example.com")
    never = ->(*) { flunk "no row search in ES-NoProj" }

    result = Lyra::Erasure.stub(:row_candidates, never) do
      Lyra::Erasure.erase!(EraseUser, user.id, reason: "r", everywhere: true)
    end
    assert_empty result.rows_without_events
  end

  # A key column is never rewritten, a row found by the search included.
  def test_a_key_found_by_the_row_search_is_reported_not_rewritten
    sub_class(privacy_policy: payment_policy(:erase_sub_policy, {}))
    raw("INSERT INTO #{SUBS} (handle, label, created_at, updated_at) VALUES ('ann@example.com', 'news', now(), now())")
    user = EraseUser.create!(name: "Ann", email: "ann@example.com")

    result = Lyra::Erasure.erase!(EraseUser, user.id, reason: "r", everywhere: true)

    assert_equal ["ann@example.com"], EraseSub.unscoped.pluck(:handle)
    assert_equal [{ record: "EraseSub <key withheld>", columns: %w[handle] }], result.left_behind
    assert_empty result.copies
    refute_match(/ann@example/, result.to_h.except(:model).inspect)
  end

  # A row found by the search that holds the value only as a JSON key, or
  # only in another case in a citext column, is reported, not erased.
  def test_a_row_found_by_the_search_holding_what_cannot_be_erased_is_reported
    ActiveRecord::Base.connection.enable_extension("citext")
    payment_class(privacy_policy: :erase_payment_policy, columns: ->(t) { t.citext :alias })
    user = EraseUser.create!(name: "Ann", email: "ann@example.com")
    keyed = raw("INSERT INTO #{PAYMENTS} (payload, created_at, updated_at) " \
                "VALUES ('{\"ann@example.com\": 1}', now(), now()) RETURNING id")
    cased = raw("INSERT INTO #{PAYMENTS} (alias, created_at, updated_at) " \
                "VALUES ('ANN@example.com', now(), now()) RETURNING id")

    result = Lyra::Erasure.erase!(EraseUser, user.id, reason: "r", everywhere: true)

    assert_equal [{ record: "ErasePayment #{keyed}", columns: %w[payload] },
                  { record: "ErasePayment #{cased}", columns: %w[alias] }],
                 result.left_behind.sort_by { |entry| entry[:record] }
    assert_empty result.copies
    assert_empty result.rows_without_events
    assert_empty Lyra.config.event_store.read.stream("ErasePayment$#{keyed}").to_a, "nothing erased, nothing imported"
  end

  # 3.2 + 3.3: rows found by the search count toward max_copies, by record.
  # A placeholder held by many rows without events is shared, not erased.
  def test_rows_without_events_count_toward_the_threshold
    payment_class(privacy_policy: :erase_payment_policy)
    user = EraseUser.create!(name: "Ann", email: "ann@example.com")
    3.times { raw("INSERT INTO #{PAYMENTS} (username, created_at, updated_at) VALUES ('ann@example.com', now(), now())") }

    result = Lyra::Erasure.erase!(EraseUser, user.id, reason: "r", everywhere: true, max_copies: 2)

    assert_equal 3, raw("SELECT count(*) FROM #{PAYMENTS} WHERE username = 'ann@example.com'").to_i
    assert_equal [{ field: "email", type: :email, holders: 3 }], result.shared
    assert_equal 1, result.shared_values
    assert_empty result.copies
  end

  # Holders are counted by record, not by stream: a record whose event is
  # also linked to another stream (a reference link) is one holder.
  def test_holders_are_counted_by_record
    note_class
    user = EraseUser.create!(name: "Ann", email: "ann@example.com")
    note = EraseNote.create!(title: "Contact", body: "ann@example.com")
    event = Lyra.config.event_store.read.stream("EraseNote$#{note.id}").to_a.first
    Lyra.config.event_store.link([event.event_id], stream_name: "EraseNote.user_id$#{user.id}")

    result = Lyra::Erasure.erase!(EraseUser, user.id, reason: "r", everywhere: true, max_copies: 1)

    assert_equal ["EraseNote #{note.id}"], result.copies
    assert_empty result.shared
  ensure
    ActiveRecord::Base.connection.execute("DELETE FROM articles")
  end

  # 3.3: records that belong_to the person's record are the person's own,
  # erased and not counted toward max_copies.
  def test_linked_records_are_erased_and_not_counted
    linked_payment_class
    user = EraseUser.create!(name: "Ann", email: "ann@example.com")
    payments = Array.new(12) { ErasePayment.create!(user_id: user.id, username: "ann@example.com") }

    result = Lyra::Erasure.erase!(EraseUser, user.id, reason: "r", everywhere: true)

    assert_equal [nil] * 12, payments.map { |p| ErasePayment.unscoped.find(p.id).username }
    assert_equal 12, result.copies.size
    assert_empty result.shared
    assert_equal 0, result.shared_values
  end

  # Unlinked holders over the threshold: reported by field, type and count,
  # never the value, and left.
  def test_unlinked_holders_over_the_threshold_are_reported
    linked_payment_class
    user = EraseUser.create!(name: "Ann", email: "ann@example.com")
    other = EraseUser.create!(name: "Bob", email: "bob@example.com")
    12.times { ErasePayment.create!(user_id: other.id, username: "ann@example.com") }

    result = Lyra::Erasure.erase!(EraseUser, user.id, reason: "r", everywhere: true)

    assert_equal [{ field: "email", type: :email, holders: 12 }], result.shared
    assert_equal 1, result.shared_values
    assert_equal 12, ErasePayment.unscoped.where(username: "ann@example.com").count
    refute_match(/ann@/, result.shared.inspect)
  end

  # config.erasure_max_copies sets the threshold; max_copies: overrides it.
  def test_the_configured_threshold_applies_unless_the_call_names_one
    note_class
    ann = EraseUser.create!(name: "Ann", email: "ann@example.com")
    bob = EraseUser.create!(name: "Bob", email: "bob@example.com")
    3.times { |i| EraseNote.create!(title: "Shared #{i}", body: "ann@example.com") }
    3.times { |i| EraseNote.create!(title: "Bob #{i}", body: "bob@example.com") }
    Lyra.config.erasure_max_copies = 2

    result = Lyra::Erasure.erase!(EraseUser, ann.id, reason: "r", everywhere: true)
    assert_equal [{ field: "email", type: :email, holders: 3 }], result.shared

    result = Lyra::Erasure.erase!(EraseUser, bob.id, reason: "r", everywhere: true, max_copies: 3)
    assert_equal 3, result.copies.size
    assert_empty result.shared
  ensure
    Lyra.config.erasure_max_copies = 10 if Lyra.config.respond_to?(:erasure_max_copies=)
    ActiveRecord::Base.connection.execute("DELETE FROM articles")
  end

  def test_the_configured_threshold_must_be_a_positive_integer
    assert_equal 10, Lyra::Configuration.new.erasure_max_copies
    [0, -1, "abc", 2.5].each do |bad|
      assert_raises(ArgumentError, bad.inspect) { Lyra::Configuration.new.erasure_max_copies = bad }
    end
  end

  # Lyra's own record streams (rights, access log, exports) are never
  # rewritten by everywhere, even when one names the value.
  def test_lyra_s_own_record_streams_are_not_rewritten
    user = EraseUser.create!(name: "Ann", email: "ann@example.com")
    kept = %w[Lyra::Rights$EraseUser$7 Lyra::Rights Lyra::SubjectAccessExports$x Lyra::DataAccess$ann@example.com]
    kept.each do |name|
      Object.const_set(:EraseRightRecorded, Class.new(Lyra::Event)) unless defined?(EraseRightRecorded)
      Lyra.config.event_store.publish(EraseRightRecorded.new(data: { subject: "ann@example.com" }), stream_name: name)
    end

    result = Lyra::Erasure.erase!(EraseUser, user.id, reason: "r", everywhere: true)

    kept.each do |name|
      assert_equal "ann@example.com", Lyra.config.event_store.read.stream(name).to_a.last.data[:subject], name
    end
    assert_empty result.copies
  end

  # Review of part 2, 1: consent (Lyra::Consent, Lyra::Rights::CONSENT_STREAM)
  # is evidence too. An email used as a consent's subject key is never
  # rewritten, the consent survives a rebuild, and it is not a holder.
  def test_consent_streams_are_never_rewritten_nor_counted
    skip "Requires Lyra::Rights" unless defined?(Lyra::Rights::ConsentStore)
    note_class
    store = Lyra::Rights.consent_store
    store.grant(purpose: :newsletter, subject: "ann@example.com")
    stream = "#{Lyra::Rights::CONSENT_STREAM}$ann@example.com"
    before = Lyra.config.event_store.read.stream(stream).to_a.map { |event| event.data.to_h }
    user = EraseUser.create!(name: "Ann", email: "ann@example.com")
    note = EraseNote.create!(title: "Contact", body: "ann@example.com")

    result = Lyra::Erasure.erase!(EraseUser, user.id, reason: "r", everywhere: true, max_copies: 1)

    assert_equal before, Lyra.config.event_store.read.stream(stream).to_a.map { |event| event.data.to_h }
    assert_equal ["EraseNote #{note.id}"], result.copies, "the consent is not a holder"
    assert_empty result.shared
    store.rebuild!
    store.forget!
    assert store.granted?(:newsletter, "ann@example.com"), "the consent survives a rebuild"
  ensure
    ActiveRecord::Base.connection.execute("DELETE FROM articles")
  end

  # Review 2: a run that leaves a value as shared has erased the person's
  # own values, so a second run cannot find the copies. A dry run reports
  # what would be erased and the shared holders, writing nothing, so the
  # threshold is chosen before erasing.
  def test_a_dry_run_reports_and_writes_nothing
    note_class
    user = EraseUser.create!(name: "Ann", email: "ann@example.com")
    3.times { |i| EraseNote.create!(title: "N#{i}", body: "ann@example.com") }
    log_before = log_text
    events_before = raw("SELECT count(*) FROM event_store_events").to_i

    dry = Lyra::Erasure.erase!(EraseUser, user.id, reason: "r", everywhere: true, max_copies: 2, dry_run: true)

    assert dry.dry_run
    assert_equal [{ field: "email", type: :email, holders: 3 }], dry.shared
    assert_equal log_before, log_text, "no event rewritten"
    assert_equal events_before, raw("SELECT count(*) FROM event_store_events").to_i, "no event appended"
    assert_equal ["ann@example.com", "Ann"], raw("SELECT email, name FROM users WHERE id = #{user.id}", :rows).first
    assert_equal 3, raw("SELECT count(*) FROM articles WHERE body = 'ann@example.com'").to_i

    result = Lyra::Erasure.erase!(EraseUser, user.id, reason: "r", everywhere: true, max_copies: 3)
    refute result.dry_run
    assert_equal 3, result.copies.size
    assert_equal 0, raw("SELECT count(*) FROM articles WHERE body = 'ann@example.com'").to_i
  ensure
    ActiveRecord::Base.connection.execute("DELETE FROM articles")
  end

  def test_a_dry_run_lists_what_would_be_erased
    payment_class(privacy_policy: :erase_payment_policy)
    user = EraseUser.create!(name: "Ann", email: "ann@example.com")
    copy = ErasePayment.create!(username: "ann@example.com")
    bare = ErasePayment.create!(username: "someone")
    raw("UPDATE #{PAYMENTS} SET username = 'ann@example.com' WHERE id = #{bare.id}")

    dry = Lyra::Erasure.erase!(EraseUser, user.id, reason: "r", everywhere: true, dry_run: true)

    assert_equal ["ErasePayment #{bare.id}", "ErasePayment #{copy.id}"].sort, dry.copies.sort
    assert_equal ["ErasePayment #{bare.id}"], dry.rows_without_events
    assert_equal 1, dry.events_rewritten
    assert dry.row_erased
    assert_equal %w[ann@example.com ann@example.com], ErasePayment.unscoped.order(:id).pluck(:username)
    assert_equal "ann@example.com", EraseUser.unscoped.find(user.id).email
  end

  # Review 3: a holder whose events mention the value only inside a longer
  # string, while its row holds it whole (raw SQL), has its row erased.
  def test_a_row_holding_the_value_whole_is_erased_when_its_events_only_mention_it
    payment_class(privacy_policy: :erase_payment_policy)
    user = EraseUser.create!(name: "Ann", email: "ann@example.com")
    payment = ErasePayment.create!(notes: "call ann@example.com after 5")
    raw("UPDATE #{PAYMENTS} SET username = 'ann@example.com' WHERE id = #{payment.id}")

    result = Lyra::Erasure.erase!(EraseUser, user.id, reason: "r", everywhere: true)

    assert_nil ErasePayment.unscoped.find(payment.id).username
    assert_equal ["ErasePayment #{payment.id}"], result.rows_without_events
    assert_equal [{ record: "ErasePayment #{payment.id}", columns: %w[notes] }], result.left_behind
    assert_equal true, payment_stream(payment).last.data[:row_only]
  end

  # Review 4: the Genesis lock is the table's (its stream owner's), so a first
  # use through an STI subclass waits for the erasure instead of importing
  # the row as it was.
  def test_a_subclass_genesis_waits_for_the_erasure_of_a_row_with_no_stream
    sti_payment_class
    user = EraseUser.create!(name: "Ann", email: "ann@example.com")
    id = raw("INSERT INTO #{PAYMENTS} (type, username, created_at, updated_at) " \
             "VALUES ('EraseRefund', 'ann@example.com', now(), now()) RETURNING id")
    original = Lyra::Genesis.method(:import_one)
    racer = nil
    racing = lambda do |model, rid|
      racer = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection { Lyra::Genesis.import_all(EraseRefund) }
      end
      refute racer.join(1), "the subclass's Genesis waits for the erasure's lock"
      original.call(model, rid)
    end

    Lyra::Genesis.stub(:import_one, racing) { Lyra::Erasure.erase!(EraseUser, user.id, reason: "r", everywhere: true) }

    assert_equal 0, racer.value, "after the erasure the row has its stream"
    refute_match(/ann@example/, log_text)
    assert_nil MT.discrepancy(ErasePayment, id.to_s)
  end

  # Review 4: when another process imported the row before the erasure could
  # (its lock not held: a Genesis on its own connection), the import fails:
  # the stream it wrote is read again and rewritten, and no import is claimed.
  def test_when_the_row_was_imported_meanwhile_its_stream_is_rewritten
    payment_class(privacy_policy: :erase_payment_policy)
    user = EraseUser.create!(name: "Ann", email: "ann@example.com")
    id = raw("INSERT INTO #{PAYMENTS} (username, created_at, updated_at) " \
             "VALUES ('ann@example.com', now(), now()) RETURNING id")
    original = Lyra::Genesis.method(:import_one)
    racing = lambda do |model, rid|
      Thread.new { ActiveRecord::Base.connection_pool.with_connection { Lyra::Genesis.import_all(ErasePayment) } }.join
      original.call(model, rid)
    end

    result = Lyra::Genesis.stub(:hold_lock!, nil) do
      Lyra::Genesis.stub(:import_one, racing) { Lyra::Erasure.erase!(EraseUser, user.id, reason: "r", everywhere: true) }
    end

    events = Lyra.config.event_store.read.stream("ErasePayment$#{id}").to_a
    assert_equal [:imported, nil], events.map { |event| Lyra::Event.operation_of(event) }
    assert_nil events.first.data[:attributes]["username"], "the other import's event is rewritten"
    refute events.last.data[:imported], "no import is claimed"
    refute_match(/ann@example/, log_text)
    assert_nil MT.discrepancy(ErasePayment, id.to_s)
    assert_equal ["ErasePayment #{id}"], result.copies
  end

  # Review 5: a third party's value at the top of an event in the person's
  # stream that is not the record's own CRUD event (an invitation) is erased
  # there, but not searched for elsewhere.
  def test_a_third_party_s_value_in_another_event_of_the_person_s_stream_is_not_searched_for
    friend = EraseUser.create!(name: "Fred", email: "fred@example.com")
    user = EraseUser.create!(name: "Ann", email: "ann@example.com")
    Object.const_set(:EraseInvited, Class.new(Lyra::Event)) unless defined?(EraseInvited)
    Lyra.config.event_store.publish(EraseInvited.new(data: { "email" => "fred@example.com" }),
                                    stream_name: "EraseUser$#{user.id}")

    result = Lyra::Erasure.erase!(EraseUser, user.id, reason: "r", everywhere: true)

    assert_equal "fred@example.com", EraseUser.unscoped.find(friend.id).email
    assert_empty result.copies
    refute_includes stream(user).map { |e| e.data.to_h.to_s }.join, "fred@example.com", "erased in the person's stream"
  end

  # Review 6a: max_copies must be a positive Integer, checked before anything is written.
  def test_max_copies_must_be_a_positive_integer
    user = EraseUser.create!(name: "Ann", email: "ann@example.com")
    [0, -1, "2", 2.5].each do |bad|
      assert_raises(ArgumentError, bad.inspect) do
        Lyra::Erasure.erase!(EraseUser, user.id, reason: "r", everywhere: true, max_copies: bad)
      end
    end
    assert_equal "ann@example.com", EraseUser.unscoped.find(user.id).email
  end

  # Review 6c: a belongs_to with its own primary_key links by that column.
  def test_a_link_through_a_named_primary_key_is_the_person_s
    payment_class(privacy_policy: :erase_payment_policy, columns: ->(t) { t.string :owner_name }) do
      belongs_to :owner, class_name: "EraseUser", primary_key: :name, foreign_key: :owner_name, optional: true
    end
    user = EraseUser.create!(name: "Ann Smith", email: "ann@example.com")
    3.times { ErasePayment.create!(owner_name: "Ann Smith", username: "ann@example.com") }

    result = Lyra::Erasure.erase!(EraseUser, user.id, reason: "r", fields: %w[email], everywhere: true, max_copies: 2)

    assert_empty result.shared
    assert_equal 3, result.copies.size
  end

  private

  # Two users, each read twice under the policy with the access log on.
  def two_users_read_twice
    Lyra.config.record_access_events = true
    users = [EraseUser.create!(name: "Ann", email: "ann@example.com"),
             EraseUser.create!(name: "Bob", email: "bob@example.com")]
    users.each { |u| 2.times { PamDsl.policy(:erase_policy).validate_access!([:email], :contact, subject: u) } }
    users
  end

  def access_event_ids(user) = Lyra::AccessLog.for(user).map(&:event_id)

  PAYMENTS = "lyra_erase_payments"

  # A monitored model with jsonb, array and text columns, created here rather
  # than in the dummy schema.
  # +columns+ adds columns to the table; the block runs in the class before
  # Lyra is included (encrypts, serialize, attribute).
  def payment_class(columns: nil, **options, &extra)
    conn = ActiveRecord::Base.connection
    conn.create_table(PAYMENTS, force: true) do |t|
      t.string :email
      t.string :username
      t.jsonb :payload
      t.string :tags, array: true
      t.text :notes
      columns&.call(t)
      t.timestamps
    end
    PamDsl.define_policy(:erase_payment_policy) do
      field :email, type: :email, sensitivity: :confidential
      purpose :contact do
        basis :contract
        requires :email
      end
    end
    Object.send(:remove_const, :ErasePayment) if defined?(ErasePayment)
    Object.const_set(:ErasePayment, Class.new(ActiveRecord::Base) { self.table_name = PAYMENTS })
    ErasePayment.reset_column_information
    ErasePayment.class_eval(&extra) if extra
    ErasePayment.include(Lyra::Interceptors::CrudInterceptor)
    ErasePayment.monitor_with_lyra(**options)
    Lyra.config.monitor_model(ErasePayment, options)
  end

  # A policy with email and the given extra fields ({ name => type }).
  def payment_policy(name, extra)
    PamDsl.define_policy(name) do
      field :email, type: :email, sensitivity: :confidential
      extra.each { |field_name, type| field field_name, type: type }
      purpose :contact do
        basis :contract
        requires :email
      end
    end
    name
  end

  SUBS = "lyra_erase_subs"

  # A monitored model whose primary key is a string column, handle.
  def sub_class(**options)
    conn = ActiveRecord::Base.connection
    conn.create_table(SUBS, id: false, force: true) do |t|
      t.string :handle, null: false
      t.string :label
      t.timestamps
    end
    conn.execute("ALTER TABLE #{SUBS} ADD PRIMARY KEY (handle)")
    Object.send(:remove_const, :EraseSub) if defined?(EraseSub)
    Object.const_set(:EraseSub, Class.new(ActiveRecord::Base) { self.table_name = SUBS })
    EraseSub.primary_key = "handle"
    EraseSub.reset_column_information
    EraseSub.include(Lyra::Interceptors::CrudInterceptor)
    EraseSub.monitor_with_lyra(**options)
    Lyra.config.monitor_model(EraseSub, options)
  end

  def drop_subs
    return unless defined?(EraseSub)

    Lyra.config.monitored_models.delete_if { |m| m.name == "EraseSub" }
    Object.send(:remove_const, :EraseSub)
    ActiveRecord::Base.connection.drop_table(SUBS, if_exists: true)
  end

  # The payments model with optimistic locking.
  def locking_payment_class
    payment_class(privacy_policy: :erase_payment_policy,
                  columns: ->(t) { t.integer :lock_version, default: 0, null: false })
  end

  # The payments model with a user_id and belongs_to EraseUser: a person's own records.
  def linked_payment_class
    payment_class(privacy_policy: :erase_payment_policy, columns: ->(t) { t.integer :user_id }) do
      belongs_to :owner, class_name: "EraseUser", foreign_key: :user_id, optional: true
    end
  end

# The payments model with a type column, and EraseRefund, an STI subclass of it.
def sti_payment_class
  payment_class(privacy_policy: :erase_payment_policy, columns: ->(t) { t.string :type })
  Object.send(:remove_const, :EraseRefund) if defined?(EraseRefund)
  Object.const_set(:EraseRefund, Class.new(ErasePayment))
end

def enter_mode(mode)
    case mode
    when :hijack then Lyra.config.enable_hijack!
    when :es_sync
      Lyra.config.enable_event_sourcing!
      Lyra.config.projection_mode = :sync
    end
  end

  def drop_payments
    return unless defined?(ErasePayment)

    Lyra.config.monitored_models.delete_if { |m| m.name == "ErasePayment" }
    Object.send(:remove_const, :EraseRefund) if defined?(EraseRefund)
    Object.send(:remove_const, :ErasePayment)
    ActiveRecord::Base.connection.drop_table(PAYMENTS, if_exists: true)
  end

  def payload_of(payment) = ErasePayment.unscoped.find(payment.id).payload

  def payment_stream(payment) = Lyra.config.event_store.read.stream("ErasePayment$#{payment.id}").to_a

  # The row's attributes as replay builds them from the stream.
  def replayed(model, id) = Lyra::DualView.new(model, id).compare[:event_sourced_view][:state].transform_keys(&:to_s)

  def note_class
    Object.send(:remove_const, :EraseNote) if defined?(EraseNote)
    Object.const_set(:EraseNote, Class.new(ActiveRecord::Base) { self.table_name = "articles" })
    EraseNote.include(Lyra::Interceptors::CrudInterceptor)
    EraseNote.monitor_with_lyra
    Lyra.config.monitor_model(EraseNote)
  end

  # The test policy with only email declared, so name is an undeclared column.
  def with_policy_without_name
    PamDsl.reset!
    PamDsl.define_policy(:erase_policy) do
      field :email, type: :email, sensitivity: :confidential
      purpose :contact do
        basis :contract
        requires :email
      end
    end
    yield
  end

  def monitor(**options)
    EraseUser.monitor_with_lyra(**options)
    Lyra.config.monitor_model(EraseUser, options)
  end

  def stream(user) = Lyra.config.event_store.read.stream("EraseUser$#{user.id}").to_a

  # The stored events' data as text (the column is bytea).
  def log_text = raw("SELECT string_agg(convert_from(data, 'UTF8'), ' ') FROM event_store_events").to_s

  def raw(sql, kind = :value)
    conn = ActiveRecord::Base.connection
    kind == :rows ? conn.select_rows(sql) : conn.select_value(sql)
  end

  def clean
    conn = ActiveRecord::Base.connection
    conn.execute("DELETE FROM users")
    conn.execute("DELETE FROM event_store_events_in_streams")
    conn.execute("DELETE FROM event_store_events")
  end
end
