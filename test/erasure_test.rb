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

  private

  def note_class
    Object.send(:remove_const, :EraseNote) if defined?(EraseNote)
    Object.const_set(:EraseNote, Class.new(ActiveRecord::Base) { self.table_name = "articles" })
    EraseNote.include(Lyra::Interceptors::CrudInterceptor)
    EraseNote.monitor_with_lyra
    Lyra.config.monitor_model(EraseNote)
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
