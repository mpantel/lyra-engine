# frozen_string_literal: true

require "test_helper"

# A table's unique indexes on the writes that record one record's change:
# create and update through callbacks, update_columns, update_column and
# update_all. In Monitor (and every mode with a table) PostgreSQL's index
# refuses a duplicate with ActiveRecord::RecordNotUnique from the INSERT or
# UPDATE. ES-NoProj writes no row, so the duplicate was saved. It is now
# checked against the event store (Lyra::Projections::UniqueIndexes). Each
# scenario ends as in Monitor.
#
# Every scenario runs in every mode, ES-Async with its jobs run inline.
# ES-Sync, ES-Async and ES-Lazy, which append the event before their
# projection writes the row, check the same indexes before the event (their
# own scenarios, with the tables lagging, are in
# es_modes_unique_writes_test.rb); before, they compared only in Monitor,
# Hijack and ES-NoProj (CALLBACKS), the other three appending a duplicate.
class EsNoprojUniqueWritesTest < Minitest::Test
  TABLE = "lyra_uw_people"
  MODES = %i[monitor hijack es_sync es_async es_noproj es_lazy].freeze
  CALLBACKS = MODES

  def setup
    skip "Requires Rails and PostgreSQL" unless defined?(ActiveRecord::Base) && connection.adapter_name.match?(/postgres/i)

    connection.create_table(TABLE, force: true) do |t|
      t.string :email
      t.string :name
      t.integer :shop_id
      t.string :code
      t.string :tag
      t.decimal :amount, precision: 10, scale: 2
      t.timestamps
      t.index :email, unique: true, name: "index_lyra_uw_people_on_email"
      t.index %i[shop_id code], unique: true
      t.index :amount, unique: true
      # Neither is enforced in ES-NoProj (nor here: their values never clash).
      t.index :name, unique: true, where: "name = 'only'"
      t.index "lower(code)", name: "index_lyra_uw_people_on_lower_code"
    end
    Object.send(:remove_const, :UwPerson) if Object.const_defined?(:UwPerson)
    Object.const_set(:UwPerson, Class.new(ActiveRecord::Base) do
      self.table_name = TABLE
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra

      cattr_accessor :log, default: []
      cattr_accessor :before_create_hook
      before_save { log << :before_save }
      before_create { log << :before_create; before_create_hook&.call }
      after_create { log << :after_create }
      after_save { log << :after_save }
    end)
    UwPerson.reset_column_information
    Lyra.config.monitor_model(UwPerson)
    clean
  end

  def teardown
    return unless Object.const_defined?(:UwPerson)

    UwPerson.before_create_hook = nil
    Lyra.reset_config!
    clean
    connection.drop_table(TABLE, if_exists: true)
  end

  def test_the_indexes_es_noproj_checks
    indexes = Lyra::Projections::UniqueIndexes.of(UwPerson).map { [_1.columns, _1.nulls_not_distinct] }

    # The partial index on name (name = 'only') is checked from 1.0.1 (its condition compiles).
    assert_equal [[%w[amount], false], [%w[email], false], [%w[name], false], [%w[shop_id code], false]], indexes.sort
  end

  # A create with a value a live record holds raises, after the callbacks
  # that run before the INSERT and before the after_* ones; nothing is
  # recorded.
  def test_a_duplicate_create
    outcomes = each_mode(CALLBACKS) do
      UwPerson.create!(email: "a@x")
      UwPerson.log.clear
      events = event_count
      [attempt { UwPerson.create!(email: "a@x", name: "second") }, UwPerson.log.dup, event_count - events]
    end
    assert_equal [ActiveRecord::RecordNotUnique, %i[before_save before_create], 0], outcomes[:monitor][:result]
    assert_same_as_monitor(outcomes)
  end

  def test_a_duplicate_update
    outcomes = each_mode(CALLBACKS) do
      UwPerson.create!(email: "a@x")
      other = UwPerson.create!(email: "b@x")
      events = event_count
      [attempt { UwPerson.find(other.id).update!(email: "a@x") }, event_count - events, UwPerson.find(other.id).email]
    end
    assert_equal [ActiveRecord::RecordNotUnique, 0, "b@x"], outcomes[:monitor][:result]
    assert_same_as_monitor(outcomes)
  end

  # save returns no false here: the index raises, as in Monitor.
  def test_save_raises_too
    outcomes = each_mode(CALLBACKS) do
      UwPerson.create!(email: "a@x")
      [attempt { UwPerson.new(email: "a@x").save }, attempt { UwPerson.create!(email: "c@x").update(email: "a@x") }]
    end
    assert_equal [ActiveRecord::RecordNotUnique, ActiveRecord::RecordNotUnique], outcomes[:monitor][:result]
    assert_same_as_monitor(outcomes)
  end

  # A multi-column index: the pair a record holds conflicts, a NULL in it
  # never does; changing the other column of the pair conflicts too.
  def test_a_multi_column_index
    outcomes = each_mode(CALLBACKS) do
      UwPerson.create!(shop_id: 1, code: "c")
      moved = UwPerson.create!(shop_id: 2, code: "c")
      [attempt { UwPerson.create!(shop_id: 1, code: "c") },
       attempt { UwPerson.create!(shop_id: 1, code: "d") },
       attempt { UwPerson.create!(shop_id: 1, code: nil) },
       attempt { UwPerson.create!(shop_id: 1, code: nil) },
       attempt { UwPerson.find(moved.id).update!(shop_id: 1) },
       attempt { UwPerson.find(moved.id).update!(shop_id: 3) }]
    end
    assert_equal [ActiveRecord::RecordNotUnique, :saved, :saved, :saved, ActiveRecord::RecordNotUnique, :saved],
                 outcomes[:monitor][:result]
    assert_same_as_monitor(outcomes)
  end

  # NULL conflicts with nothing, unless the index is NULLS NOT DISTINCT.
  def test_nulls
    connection.create_table(:lyra_uw_tags, force: true) do |t|
      t.string :tag
      t.string :label
      t.index :tag, unique: true, nulls_not_distinct: true
      t.index :label, unique: true
    end
    tags = Class.new(ActiveRecord::Base) do
      self.table_name = "lyra_uw_tags"
      def self.name = "UwTag"
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
    end
    Object.const_set(:UwTag, tags)
    Lyra.config.monitor_model(UwTag)
    assert_equal [[%w[label], false], [%w[tag], true]], Lyra::Projections::UniqueIndexes.of(UwTag).map { [_1.columns, _1.nulls_not_distinct] }.sort

    outcomes = each_mode(CALLBACKS) do
      connection.execute("DELETE FROM lyra_uw_tags")
      UwTag.create!(tag: "t", label: nil)
      [attempt { UwTag.create!(tag: nil, label: nil) },
       attempt { UwTag.create!(tag: nil, label: nil) },
       attempt { UwTag.create!(tag: "t", label: "l") },
       attempt { UwTag.create!(tag: "u", label: nil) },
       UwTag.order(:id).pluck(:tag, :label)]
    end
    assert_equal [:saved, ActiveRecord::RecordNotUnique, ActiveRecord::RecordNotUnique, :saved, [["t", nil], [nil, nil], ["u", nil]]],
                 outcomes[:monitor][:result]
    assert_same_as_monitor(outcomes)
  ensure
    Object.send(:remove_const, :UwTag) if Object.const_defined?(:UwTag)
    connection.drop_table(:lyra_uw_tags, if_exists: true)
  end

  # A destroyed record holds no value, nor does a record updated away from it.
  def test_a_destroyed_or_moved_holder
    outcomes = each_mode(CALLBACKS) do
      UwPerson.create!(email: "a@x").destroy!
      UwPerson.create!(email: "b@x").update!(email: "c@x")
      [attempt { UwPerson.create!(email: "a@x") }, attempt { UwPerson.create!(email: "b@x") },
       attempt { UwPerson.create!(email: "c@x") }]
    end
    assert_equal [:saved, :saved, ActiveRecord::RecordNotUnique], outcomes[:monitor][:result]
    assert_same_as_monitor(outcomes)
  end

  # A record keeps its own value, assigned again or not, through every write.
  def test_a_record_s_own_value
    outcomes = each_mode do
      person = UwPerson.create!(email: "a@x", shop_id: 1, code: "c")
      [attempt { UwPerson.find(person.id).update!(email: "a@x", name: "renamed") },
       attempt { UwPerson.find(person.id).update!(code: "c", shop_id: 1, name: "again") },
       attempt { UwPerson.find(person.id).update_columns(email: "a@x", name: "columns") },
       attempt { UwPerson.where(id: person.id).update_all(email: "a@x") },
       UwPerson.find(person.id).name]
    end
    assert_equal [:saved, :saved, :saved, 1, "columns"], outcomes[:monitor][:result]
    assert_same_as_monitor(outcomes)
  end

  # The values compared as the column holds them: 250 and "250.00" on a
  # decimal are one value.
  def test_values_as_the_column_holds_them
    outcomes = each_mode(CALLBACKS) do
      UwPerson.create!(amount: 250)
      [attempt { UwPerson.create!(amount: "250.00") }, attempt { UwPerson.create!(amount: 250.004) },
       attempt { UwPerson.create!(amount: "250.01") }]
    end
    assert_equal [ActiveRecord::RecordNotUnique, ActiveRecord::RecordNotUnique, :saved], outcomes[:monitor][:result]
    assert_same_as_monitor(outcomes)
  end

  # update_columns and update_column skip callbacks, not the index.
  def test_update_columns
    outcomes = each_mode do
      UwPerson.create!(email: "a@x")
      other = UwPerson.create!(email: "b@x")
      events = event_count
      [attempt { UwPerson.find(other.id).update_columns(email: "a@x") },
       attempt { UwPerson.find(other.id).update_column(:email, "a@x") },
       event_count - events,
       attempt { UwPerson.find(other.id).update_columns(email: "d@x") },
       UwPerson.find(other.id).email]
    end
    assert_equal [ActiveRecord::RecordNotUnique, ActiveRecord::RecordNotUnique, 0, :saved, "d@x"], outcomes[:monitor][:result]
    assert_same_as_monitor(outcomes)
  end

  # update_all: two records set to one value conflict with each other; one
  # set to a value another record holds conflicts with it; a record that
  # keeps its value does not.
  def test_update_all
    outcomes = each_mode do
      a = UwPerson.create!(email: "a@x", shop_id: 1, code: "c")
      b = UwPerson.create!(email: "b@x", shop_id: 2, code: "c")
      c = UwPerson.create!(email: "c@x", shop_id: 3, code: "c")
      events = event_count
      [attempt { UwPerson.where(id: [b.id, c.id]).update_all(email: "z@x") },
       attempt { UwPerson.where(id: b.id).update_all(email: "a@x") },
       attempt { UwPerson.where(id: [a.id, b.id]).update_all(code: "d") },
       attempt { UwPerson.where(id: c.id).update_all(shop_id: 1, code: "d") },
       event_count - events,
       attempt { UwPerson.where(id: [a.id, b.id]).update_all(code: "e", name: "moved") },
       attempt { UwPerson.where(id: b.id).update_all(email: "y@x") },
       UwPerson.order(:id).pluck(:email, :code)]
    end
    assert_equal [ActiveRecord::RecordNotUnique, ActiveRecord::RecordNotUnique, 2, ActiveRecord::RecordNotUnique, 2, 2, 1,
                  [["a@x", "e"], ["y@x", "e"], ["c@x", "c"]]], outcomes[:monitor][:result]
    assert_same_as_monitor(outcomes)
  end

  # create_or_find_by's create meets the index (RecordNotUnique, which it
  # rescues) and its find_by finds nothing: RecordNotFound, nothing written;
  # find_or_create_by on a relation the same. Alone and inside a transaction.
  def test_create_or_find_by_and_find_or_create_by_meet_the_index
    outcome = lambda do |write|
      write.call
      :saved
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordNotFound, ActiveRecord::StatementInvalid => e
      e.class
    end
    outcomes = each_mode(CALLBACKS) do
      UwPerson.create!(email: "a01", name: "kept")
      UwPerson.create!(email: "a02", name: "kept")
      writes = [
        -> { UwPerson.create_or_find_by(name: "blk") { _1.email = "a01" } },
        -> { UwPerson.where(name: "zz").find_or_create_by(shop_id: 99) { _1.email = "a02" } }
      ]
      alone = writes.map { |write| outcome.(write) }
      inside = writes.map { |write| outcome.(-> { UwPerson.transaction { write.call } }) }
      [alone, inside, UwPerson.order(:email).pluck(:email, :name)]
    end
    assert_equal [ActiveRecord::RecordNotFound, ActiveRecord::RecordNotFound], outcomes[:monitor][:result].first
    assert_same_as_monitor(outcomes)
  end

  # Inside one transaction the first create's value is taken for the second.
  def test_two_creates_in_one_transaction
    outcomes = each_mode(CALLBACKS) do
      result = attempt do
        UwPerson.transaction do
          UwPerson.create!(email: "a@x")
          UwPerson.create!(email: "a@x")
        end
      end
      [result, UwPerson.where(email: "a@x").count]
    end
    assert_equal [ActiveRecord::RecordNotUnique, 0], outcomes[:monitor][:result]
    assert_same_as_monitor(outcomes)
  end

  # A uniqueness validation still answers first, as before.
  def test_a_uniqueness_validation_still_answers
    UwPerson.validates :email, uniqueness: true, allow_nil: true
    outcomes = each_mode do
      UwPerson.create!(email: "a@x")
      [attempt { UwPerson.create!(email: "a@x") }, UwPerson.new(email: "a@x").valid?, UwPerson.new(email: "b@x").valid?]
    end
    assert_equal [ActiveRecord::RecordInvalid, false, true], outcomes[:monitor][:result]
    assert_same_as_monitor(outcomes)
  end

  # A citext column's unique index compares without case.
  def test_a_citext_column
    begin
      connection.enable_extension("citext")
    rescue ActiveRecord::StatementInvalid
      skip "citext is not available"
    end
    connection.add_column(TABLE, :login, :citext)
    connection.add_index(TABLE, :login, unique: true)
    UwPerson.reset_column_information
    outcomes = each_mode(CALLBACKS) do
      UwPerson.create!(login: "Ann@Example.org")
      [attempt { UwPerson.create!(login: "ann@example.ORG") }, attempt { UwPerson.create!(login: "bob@example.org") }]
    end
    assert_equal [ActiveRecord::RecordNotUnique, :saved], outcomes[:monitor][:result]
    assert_same_as_monitor(outcomes)
  end

  # An enum's value and a deterministically encrypted value (its ciphertext
  # in the log) are compared as the table holds them, through update_column
  # too.
  def test_enum_and_encrypted_columns
    ActiveRecord::Encryption.configure(primary_key: "p" * 32, deterministic_key: "d" * 32, key_derivation_salt: "s" * 32)
    connection.add_column(TABLE, :status, :integer)
    connection.add_column(TABLE, :secret, :string)
    connection.add_index(TABLE, :status, unique: true)
    connection.add_index(TABLE, :secret, unique: true)
    UwPerson.enum :status, { draft: 0, sent: 1 }
    UwPerson.encrypts :secret, deterministic: true
    UwPerson.reset_column_information
    outcomes = each_mode(CALLBACKS) do
      kept = UwPerson.create!(status: :draft, secret: "s1")
      [attempt { UwPerson.create!(status: "draft") }, attempt { UwPerson.create!(secret: "s1") },
       attempt { UwPerson.create!(status: :sent, secret: "s2") },
       attempt { UwPerson.find(kept.id).update_column(:secret, "s2") },
       attempt { UwPerson.find(kept.id).update!(status: 1) }]
    end
    assert_equal [ActiveRecord::RecordNotUnique, ActiveRecord::RecordNotUnique, :saved, ActiveRecord::RecordNotUnique,
                  ActiveRecord::RecordNotUnique], outcomes[:monitor][:result]
    assert_same_as_monitor(outcomes)
  end

  # An erasure rewrites the record's events: the link named by a digest of
  # the erased value goes with them (a NOT NULL column's replacement,
  # "erased:<id>", is linked instead), and the value is free, as in Monitor.
  def test_an_erasure_takes_the_value_s_link_with_it
    connection.change_column_null(TABLE, :code, false, "none")
    UwPerson.reset_column_information
    %i[monitor es_noproj].each do |mode|
      use(mode)
      person = UwPerson.create!(email: "ann@x", shop_id: 1, code: "secret")
      email = Lyra::Projections::UniqueIndexes.stream(UwPerson, "email", "/ann@x")
      code = Lyra::Projections::UniqueIndexes.stream(UwPerson, "code", "/secret")
      replaced = Lyra::Projections::UniqueIndexes.stream(UwPerson, "code", "/erased:#{person.id}")
      assert_equal(mode == :es_noproj ? [1, 1] : [0, 0], [links(email), links(code)], mode)

      Lyra::Erasure.erase!(UwPerson, person.id, reason: "test", fields: %w[email code], any_fields: true)

      assert_equal [0, 0], [links(email), links(code)], mode
      assert_equal(mode == :es_noproj ? 1 : 0, links(replaced), mode)
      assert_equal [nil, "erased:#{person.id}"], UwPerson.find(person.id).then { [_1.email, _1.code] }, mode
      assert UwPerson.create!(email: "ann@x", shop_id: 1, code: "secret"), mode
      assert_raises(ActiveRecord::RecordNotUnique, mode) { UwPerson.create!(shop_id: 1, code: "erased:#{person.id}") }
    end
  end

  def test_the_message_names_the_index_as_postgresql_does
    use(:es_noproj)
    UwPerson.create!(email: "a@x")

    error = assert_raises(ActiveRecord::RecordNotUnique) { UwPerson.create!(email: "a@x") }
    assert_match(/duplicate key value violates unique constraint "index_lyra_uw_people_on_email"/, error.message)
    assert_match(/Key \(email\)=\(a@x\) already exists/, error.message)
  end

  # Two writers of one value, each past its before_create callbacks before
  # either writes: exactly one wins and the other raises, in Monitor (the
  # index makes the second INSERT wait for the first's commit) and in
  # ES-NoProj (the value lock makes the second check wait for it).
  def test_two_concurrent_creates_of_one_value
    %i[monitor es_noproj].each do |mode|
      use(mode)
      results = race { UwPerson.create!(email: "r@x") }

      assert_equal 1, results.count(:saved), "#{mode}: #{results.inspect}"
      assert_equal 1, results.count { _1.is_a?(ActiveRecord::RecordNotUnique) }, "#{mode}: #{results.inspect}"
      assert_equal 1, UwPerson.where(email: "r@x").count, mode
    end
  end

  # Writers of different values do not wait for each other.
  def test_two_concurrent_creates_of_two_values
    use(:es_noproj)
    results = race { |i| UwPerson.create!(email: "r#{i}@x") }

    assert_equal %i[saved saved], results
  end

  # Links written before the value streams existed (or with links off) are
  # completed on first use: the checkpoint names the columns it covers.
  def test_records_linked_before_the_value_streams
    use(:es_noproj)
    Lyra.config.reference_links = false
    UwPerson.create!(email: "old@x")
    # With links off, every record is read.
    assert_raises(ActiveRecord::RecordNotUnique) { UwPerson.create!(email: "old@x") }

    Lyra.config.reference_links = :auto
    Lyra::Projections::ReferenceLinks.reset!
    assert_raises(ActiveRecord::RecordNotUnique) { UwPerson.create!(email: "old@x") }
    assert UwPerson.create!(email: "new@x")
  end

  # The check reads the value's stream, not every record of the model; a
  # model without such an index pays nothing.
  def test_the_check_reads_the_value_not_the_model
    use(:es_noproj)
    3.times { |i| UwPerson.create!(email: "p#{i}@x") }
    sql = statements { UwPerson.create!(email: "fresh@x") }

    refute(sql.any? { _1.include?("MAX(id)") && _1.include?("LIKE") }, "no read of every stream:\n#{sql.join("\n")}")
    assert_equal 1, sql.count { _1.include?("pg_advisory_xact_lock(hashtext('lyra_unique/") }

    plain = Class.new(ActiveRecord::Base) do
      self.table_name = "lyra_uw_plain"
      def self.name = "UwPlain"
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
    end
    connection.create_table(:lyra_uw_plain, force: true) { |t| t.string :email }
    Object.const_set(:UwPlain, plain)
    Lyra.config.monitor_model(UwPlain)
    record = UwPlain.create!(email: "x")
    sql = statements { UwPlain.create!(email: "x") }
    sql += statements { record.update!(email: "y") }
    refute(sql.any? { _1.include?("lyra_unique") || _1.include?("UwPlain!") }, sql.join("\n"))
  ensure
    Object.send(:remove_const, :UwPlain) if Object.const_defined?(:UwPlain)
    connection.drop_table(:lyra_uw_plain, if_exists: true)
  end

  # A copy read before another writer moved the record to shop 2, where
  # (2, "z") is held, changes the other column only: the tuple the row
  # would hold is (2, "z"), taken. The copy's own (1, "z") was claimed.
  def test_a_stale_copy_claims_the_tuple_the_row_would_hold
    {
      "update!" => [CALLBACKS, ->(stale) { stale.update!(code: "z") }],
      "update_columns" => [MODES, ->(stale) { stale.update_columns(code: "z") }]
    }.each do |via, (modes, write)|
      outcomes = each_mode(modes) do
        record = UwPerson.create!(shop_id: 1, code: "a")
        UwPerson.create!(shop_id: 2, code: "z")
        stale = UwPerson.find(record.id)
        UwPerson.find(record.id).update!(shop_id: 2)
        [attempt { write.(stale) }, UwPerson.find(record.id).then { [_1.shop_id, _1.code] }]
      end
      assert_equal [ActiveRecord::RecordNotUnique, [2, "a"]], outcomes[:monitor][:result], via
      assert_same_as_monitor(outcomes)
    end
  end

  # update_columns on a copy read before another writer changed the value
  # it sets back: the old value is the stream's, so the write is recorded
  # (it recorded nothing, and the record kept the other writer's value);
  # with another record holding the value, it is refused.
  def test_a_stale_copy_s_update_columns_writes_from_the_stream
    outcomes = each_mode do
      record = UwPerson.create!(email: "x@x")
      stale = UwPerson.find(record.id)
      UwPerson.find(record.id).update!(email: "y@x")
      first = attempt { stale.update_columns(email: "x@x") }
      other = UwPerson.create!(email: "o@x")
      stale_other = UwPerson.find(other.id)
      UwPerson.find(other.id).update!(email: "p@x")
      UwPerson.create!(email: "o@x")
      [first, UwPerson.find(record.id).email, attempt { stale_other.update_columns(email: "o@x") }]
    end
    assert_equal [:saved, "x@x", ActiveRecord::RecordNotUnique], outcomes[:monitor][:result]
    assert_same_as_monitor(outcomes)
  end

  # update_all of R and R.update!(code:) through callbacks, the first paused
  # after it locked R: both succeed in turn, as in Monitor, where the value
  # locks taken before the record's deadlocked them. And two transactions
  # crossing two records and one value.
  def test_no_deadlock_where_monitor_has_none
    %i[monitor es_noproj].each do |mode|
      use(mode)
      record = UwPerson.create!(email: "r@x", shop_id: 1, code: "a")
      paused = Queue.new
      go = Queue.new
      first = in_transaction do
        UwPerson.where(id: record.id).update_all(code: "b")
        paused << true
        go.pop(timeout: 5)
      end
      paused.pop(timeout: 5)
      second = in_transaction { UwPerson.find(record.id).update!(code: "c") }
      sleep 0.3
      go << true
      assert_equal %i[saved saved], [first.value, second.value], mode

      use(mode)
      r = UwPerson.create!(email: "r@x")
      q = UwPerson.create!(email: "q@x")
      paused = Queue.new
      go = Queue.new
      first = in_transaction do
        UwPerson.find(r.id).update!(name: "n")
        paused << true
        go.pop(timeout: 5)
        UwPerson.find(q.id).update!(email: "x@x")
        raise ActiveRecord::Rollback
      end
      paused.pop(timeout: 5)
      second = in_transaction { UwPerson.find(r.id).update!(email: "x@x") }
      sleep 0.3
      go << true
      assert_equal %i[saved saved], [first.value, second.value], mode
      assert_equal "x@x", UwPerson.find(r.id).email, mode
    end
  end

  # An index added while the process runs: its column's events are linked
  # from the first one, and the index enforced over them.
  def test_an_index_added_in_a_running_process
    use(:es_noproj)
    UwPerson.create!(email: "e1@x", name: "n")
    UwPerson.create!(email: "e2@x", name: "m") # a check ran: the model is linked
    connection.add_index(TABLE, :name, unique: true, name: "lyra_uw_people_name")
    UwPerson.reset_column_information

    assert_includes Lyra::Projections::UniqueIndexes.of(UwPerson).map(&:columns), %w[name]
    assert_raises(ActiveRecord::RecordNotUnique) { UwPerson.create!(email: "e3@x", name: "n") }
    assert UwPerson.create!(email: "e4@x", name: "o")
  end

  # A column with a nondeterministic collation: its equality is the
  # database's alone, so its index is left out (as partial ones are).
  def test_an_index_on_a_nondeterministic_collation_is_left_out
    begin
      connection.execute("CREATE COLLATION IF NOT EXISTS lyra_uw_ci (provider = icu, locale = 'und-u-ks-level2', deterministic = false)")
    rescue ActiveRecord::StatementInvalid
      skip "ICU collations are not available"
    end
    connection.add_column(TABLE, :login, "varchar COLLATE lyra_uw_ci")
    connection.add_index(TABLE, :login, unique: true)
    UwPerson.reset_column_information

    refute_includes Lyra::Projections::UniqueIndexes.of(UwPerson).map(&:columns), %w[login]
  ensure
    connection.remove_column(TABLE, :login) if connection.column_exists?(TABLE, :login)
    connection.execute("DROP COLLATION IF EXISTS lyra_uw_ci")
  end

  # A citext value folds as the database folds it, not as Ruby does.
  def test_citext_folds_as_the_database_does
    begin
      connection.enable_extension("citext")
    rescue ActiveRecord::StatementInvalid
      skip "citext is not available"
    end
    connection.add_column(TABLE, :login, :citext)
    UwPerson.reset_column_information
    %w[İ i i̇ ẞ ß ΣΑΣ σας].combination(2).each do |a, b|
      database = connection.select_value("SELECT #{connection.quote(a)}::citext = #{connection.quote(b)}::citext")
      ours = Lyra::Projections::UniqueIndexes.key(UwPerson, "login", a) == Lyra::Projections::UniqueIndexes.key(UwPerson, "login", b)
      assert_equal database, ours, [a, b].inspect
    end
  end

  # Neither the value streams nor the lock statements hold the value, or a
  # hash of it a dictionary reverses: an HMAC under the installation's key,
  # and a stream linked under another key is linked again under the new one.
  def test_value_streams_and_locks_hold_a_keyed_digest
    use(:es_noproj)
    sql = statements { UwPerson.create!(email: "ann@example.org") }
    refute(sql.any? { _1.include?("ann@example.org") && _1.include?("advisory") }, sql.grep(/advisory/).join("\n"))
    streams = connection.select_values("SELECT stream FROM event_store_events_in_streams WHERE stream LIKE 'UwPerson!email$%'")
    assert_equal 1, streams.size
    refute_includes streams.first, Digest::SHA256.hexdigest("/ann@example.org")[0, 32]

    previous = Lyra.config.value_digest_key
    Lyra.config.value_digest_key = "another key"
    Lyra::Projections::ReferenceLinks.reset!
    assert_raises(ActiveRecord::RecordNotUnique) { UwPerson.create!(email: "ann@example.org") }
    rekeyed = connection.select_values("SELECT stream FROM event_store_events_in_streams WHERE stream LIKE 'UwPerson!email$%'")
    refute_includes rekeyed, streams.first, "the old key's links are deleted"
  ensure
    Lyra.config.value_digest_key = previous
  end

  # insert_all reads the records the values' streams name, not every record
  # of the model.
  def test_insert_all_reads_the_values_streams
    use(:es_noproj)
    3.times { |i| UwPerson.create!(email: "p#{i}@x") }
    Lyra::Projections::Uniqueness::Snapshot.expects(:records).never
    sql = statements { UwPerson.insert_all([{ email: "p1@x", name: "dup" }, { email: "new@x", name: "fresh" }]) }

    assert(sql.any? { _1.include?("WHERE stream IN ('UwPerson!email$") }, sql.join("\n"))
    assert_equal %w[new@x p0@x p1@x p2@x], UwPerson.order(:email).pluck(:email)
  end

  # A model's first use with every connection of the pool taken by its
  # writers, with and without a uniqueness validation: every writer
  # finishes. The writer that caught the links up inline held their lock
  # until it committed and called catch_up again, waiting on a Ruby mutex
  # whose holder waited on that lock: they all hung.
  def test_a_first_use_with_a_full_pool_finishes
    [false, true].each do |validated|
      use(:es_noproj)
      UwPerson.validates :email, uniqueness: true, allow_nil: true if validated
      ActiveRecord::Base.connection_pool.release_connection
      writers = ActiveRecord::Base.connection_pool.size + 1
      threads = Array.new(writers) do |i|
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            3.times { |j| UwPerson.create!(email: "w#{i}-#{j}@x") }
            :ok
          rescue StandardError => e
            e.class
          end
        end
      end
      results = Timeout.timeout(60) { threads.map(&:value) }
      assert_equal [:ok] * writers, results, "validated: #{validated}"
      assert_equal writers * 3, UwPerson.count
    end
  end

  # A validated update locks its record before the validation locks the
  # value, as update_all locks them: the two do not deadlock, as in Monitor,
  # nor two validated transactions crossing two records and one value.
  def test_a_validated_save_and_update_all_do_not_deadlock
    UwPerson.validates :email, uniqueness: true, allow_nil: true
    %i[monitor es_noproj].each do |mode|
      use(mode)
      record = UwPerson.create!(email: "r@x")
      paused = Queue.new
      go = Queue.new
      first = in_transaction do
        UwPerson.where(id: record.id).update_all(email: "v@x")
        paused << true
        go.pop(timeout: 5)
      end
      paused.pop(timeout: 5)
      second = in_transaction { UwPerson.find(record.id).update!(email: "v@x") }
      sleep 0.3
      go << true
      assert_equal %i[saved saved], [first.value, second.value], mode

      use(mode)
      r = UwPerson.create!(email: "r@x")
      q = UwPerson.create!(email: "q@x")
      paused = Queue.new
      go = Queue.new
      first = in_transaction do
        UwPerson.find(r.id).update!(name: "n")
        paused << true
        go.pop(timeout: 5)
        UwPerson.find(q.id).update!(email: "x@x")
        raise ActiveRecord::Rollback
      end
      paused.pop(timeout: 5)
      second = in_transaction { UwPerson.find(r.id).update!(email: "x@x") }
      sleep 0.3
      go << true
      assert_equal %i[saved saved], [first.value, second.value], mode
    end
  end

  # The validated update takes the aggregate lock once, before its
  # validation: the same statements as before, in another order.
  def test_a_validated_update_takes_the_aggregate_lock_once_first
    UwPerson.validates :email, uniqueness: true, allow_nil: true
    use(:es_noproj)
    record = UwPerson.create!(email: "a@x")
    sql = statements { UwPerson.find(record.id).update!(email: "b@x") }.grep(/pg_advisory_xact_lock/)

    assert_equal 1, sql.count { _1.include?("lyra_aggregate/UwPerson$") }, sql.join("\n")
    assert_operator sql.index { _1.include?("lyra_aggregate/") }, :<, sql.index { _1.include?("lyra_unique/") }
  end

  # No key for the digests outside development and test (production,
  # staging): refused at first use; in development and test a fixed key,
  # with a warning.
  def test_a_missing_digest_key_fails_closed_in_production
    previous = Lyra.config.value_digest_key
    Lyra.config.value_digest_key = nil
    Lyra::Projections::ValueDigest.reset!
    Rails.application.stubs(:key_generator).raises(ArgumentError, "Missing secret_key_base")
    Rails.stubs(:env).returns(ActiveSupport::StringInquirer.new("production"))
    error = assert_raises(Lyra::Projections::ValueDigest::KeyMissing) { Lyra::Projections::ValueDigest.hex("x") }
    assert_match(/value_digest_key/, error.message)

    Rails.stubs(:env).returns(ActiveSupport::StringInquirer.new("staging"))
    Lyra::Projections::ValueDigest.reset!
    assert_raises(Lyra::Projections::ValueDigest::KeyMissing) { Lyra::Projections::ValueDigest.hex("x") }

    Rails.stubs(:env).returns(ActiveSupport::StringInquirer.new("test"))
    Lyra::Projections::ValueDigest.reset!
    assert_equal 32, Lyra::Projections::ValueDigest.hex("x").size
  ensure
    Rails.unstub(:env)
    Rails.application.unstub(:key_generator)
    Lyra.config.value_digest_key = previous
    Lyra::Projections::ValueDigest.reset!
  end

  # The unique indexes ES-NoProj does not enforce are named once: here a
  # partial index whose condition Lyra does not evaluate (IN).
  def test_the_indexes_left_out_are_named_once
    use(:es_noproj)
    connection.add_index(TABLE, :code, unique: true, where: "code IN ('x', 'y')", name: "index_lyra_uw_people_code_in")
    logged = StringIO.new
    previous = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(logged)
    Lyra::Projections::UniqueIndexes.reset!
    2.times { Lyra::Projections::UniqueIndexes.of(UwPerson) }
    Lyra::Projections::UniqueIndexes.send(:read_indexes, UwPerson) # read again: not named again

    assert_equal 1, logged.string.scan("does not enforce").size, logged.string
    assert_match(/index_lyra_uw_people_code_in \(partial, a condition Lyra does not evaluate\)/, logged.string)
    refute_match(/index_lyra_uw_people_on_name/, logged.string)
  ensure
    Rails.logger = previous
  end

  # A citext value is lowered by the database as a bound parameter: the
  # statement does not hold it.
  def test_citext_values_are_lowered_as_bound_parameters
    begin
      connection.enable_extension("citext")
    rescue ActiveRecord::StatementInvalid
      skip "citext is not available"
    end
    connection.add_column(TABLE, :login, :citext)
    connection.add_index(TABLE, :login, unique: true)
    UwPerson.reset_column_information
    use(:es_noproj)
    sql = statements { UwPerson.create!(login: "Secret.Login@example.org") }

    refute(sql.any? { _1.include?("Secret.Login") }, sql.join("\n"))
    assert(sql.any? { _1.include?("LOWER(t.x)") })
  end

  private

  def in_transaction(&block)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        ActiveRecord::Base.transaction(&block)
        :saved
      rescue StandardError => e
        e.class
      end
    end
  end

  def attempt
    result = yield
    result.is_a?(ActiveRecord::Base) || result == true ? :saved : result
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
    e.class
  end

  # The block's result in each mode, and the records as the mode reads them.
  def each_mode(modes = MODES, &block)
    modes.to_h do |mode|
      use(mode)
      result = block.call
      UwPerson.count if mode == :es_lazy
      people = UwPerson.order(:id).map { [_1.email, _1.shop_id, _1.code, _1.tag, _1.amount&.to_s] }
      [mode, { result: result, people: people }]
    end
  end

  def assert_same_as_monitor(outcomes)
    outcomes.each { |mode, outcome| assert_equal outcomes[:monitor], outcome, mode }
  end

  def use(mode)
    clean
    case mode
    when :monitor then Lyra.config.enable_monitor!
    when :hijack then Lyra.config.enable_hijack!
    else
      Lyra.config.enable_event_sourcing!
      Lyra.config.projection_mode = { es_sync: :sync, es_async: :async, es_noproj: :disabled, es_lazy: :lazy }.fetch(mode)
    end
  end

  # Runs +block+ in two threads, each in its own transaction on its own
  # connection; each waits in before_create until the other is there too,
  # so that without a lock both check before either writes. :saved or the
  # exception, per thread.
  def race(timeout: 3, &block)
    arrived = Queue.new
    go = [Queue.new, Queue.new]
    UwPerson.before_create_hook = lambda do
      index = Thread.current[:uw_race_index]
      next unless index

      arrived << index
      go[index].pop(timeout: timeout)
    end
    coordinator = Thread.new do
      2.times { arrived.pop(timeout: timeout * 2) }
      go.each { _1 << :go }
    end
    threads = 2.times.map do |i|
      Thread.new do
        Thread.current[:uw_race_index] = i
        ActiveRecord::Base.connection_pool.with_connection do
          ActiveRecord::Base.transaction { block.call(i) }
          :saved
        rescue StandardError => e
          e
        end
      end
    end
    results = threads.map(&:value)
    coordinator.kill
    results
  ensure
    UwPerson.before_create_hook = nil
  end

  def statements(&block)
    sql = []
    callback = ->(*, payload) { sql << payload[:sql] }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record", &block)
    sql
  end

  def event_count = connection.select_value("SELECT count(*) FROM event_store_events").to_i

  def links(stream) = connection.select_value("SELECT count(*) FROM event_store_events_in_streams WHERE stream = #{connection.quote(stream)}").to_i

  def clean
    connection.execute("DELETE FROM #{TABLE}") if connection.table_exists?(TABLE)
    connection.execute("DELETE FROM event_store_events_in_streams")
    connection.execute("DELETE FROM event_store_events")
    UwPerson.log.clear if Object.const_defined?(:UwPerson)
    Lyra::Projections::LazyProjection.reset!
    Lyra::Projections::ReferenceLinks.reset!
    Lyra::Projections::Uniqueness::Snapshot.reset!
    Lyra::Projections::CachedProjection.invalidate_all(UwPerson) if Object.const_defined?(:UwPerson)
    Rails.cache.clear
  end

  def connection = ActiveRecord::Base.connection
end
