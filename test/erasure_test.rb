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
