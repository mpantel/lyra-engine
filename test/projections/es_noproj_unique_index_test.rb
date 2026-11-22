# frozen_string_literal: true

require "test_helper"

# insert_all and insert_all! against a unique index other than the primary
# key. Monitor's table decides: insert_all skips a row whose value a record
# holds, insert_all! raises ActiveRecord::RecordNotUnique, and unique_by
# names the one index whose conflicts are skipped (any other raises).
# ES-NoProj decided from its table, which holds no row of a record created
# through callbacks (the duplicate was inserted) and keeps the row of a
# record destroyed there (a free value was skipped). It now decides from the
# event store. Each scenario runs in every mode and ends as in Monitor.
class EsNoprojUniqueIndexTest < Minitest::Test
  TABLE = "lyra_ui_people"
  MODES = %i[monitor hijack es_sync es_async es_noproj es_lazy].freeze

  def setup
    skip "Requires Rails and PostgreSQL" unless defined?(ActiveRecord::Base) && connection.adapter_name.match?(/postgres/i)

    connection.create_table(TABLE, force: true) do |t|
      t.string :email
      t.string :name
      t.integer :shop_id
      t.string :code
      t.timestamps
      t.index :email, unique: true, name: "index_lyra_ui_people_on_email"
      t.index %i[shop_id code], unique: true
    end
    Object.send(:remove_const, :UiPerson) if Object.const_defined?(:UiPerson)
    Object.const_set(:UiPerson, Class.new(ActiveRecord::Base) do
      self.table_name = TABLE
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
    end)
    UiPerson.reset_column_information
    Lyra.config.monitor_model(UiPerson)
    clean
  end

  def teardown
    return unless Object.const_defined?(:UiPerson)

    Lyra.reset_config!
    clean
    connection.drop_table(TABLE, if_exists: true)
  end

  WRITES = {
    "insert_all" => ->(row) { UiPerson.insert_all([row]) },
    "insert_all!" => ->(row) { UiPerson.insert_all!([row]) },
    "insert_all unique_by the email index" => ->(row) { UiPerson.insert_all([row], unique_by: :index_lyra_ui_people_on_email) },
    "insert_all unique_by email" => ->(row) { UiPerson.insert_all([row], unique_by: :email) },
    "insert_all unique_by the primary key" => ->(row) { UiPerson.insert_all([row], unique_by: :id) },
    "insert" => ->(row) { UiPerson.insert(row) }
  }.freeze

  # A value a live record created through callbacks holds.
  def test_a_value_a_live_record_holds
    outcomes = each_mode do
      UiPerson.create!(email: "a@x", name: "first", shop_id: 1, code: "c")
      WRITES.transform_values { |write| attempt { write.call(row(email: "a@x")) } }
    end
    expected = WRITES.keys.to_h { [_1, 0] }.merge("insert_all!" => ActiveRecord::RecordNotUnique,
                                                    "insert_all unique_by the primary key" => ActiveRecord::RecordNotUnique)
    assert_equal expected, outcomes[:monitor][:result]
    assert_same_as_monitor(outcomes)
  end

  # A multi-column index: the pair a record holds conflicts, a NULL in it
  # never does.
  def test_a_multi_column_index
    outcomes = each_mode do
      UiPerson.create!(email: "a@x", shop_id: 1, code: "c")
      [attempt { UiPerson.insert_all([row(shop_id: 1, code: "c")]) },
       attempt { UiPerson.insert_all!([row(shop_id: 1, code: "c")]) },
       attempt { UiPerson.insert_all([row(shop_id: 1, code: "d")]) },
       attempt { UiPerson.insert_all!([row(shop_id: 1, code: nil), row(shop_id: 1, code: nil)]) }]
    end
    assert_equal [0, ActiveRecord::RecordNotUnique, 1, 2], outcomes[:monitor][:result]
    assert_same_as_monitor(outcomes)
  end

  # A destroyed record's value is free, whether it was created through
  # callbacks or inserted (its row left in ES-NoProj's table).
  def test_a_destroyed_record_s_value_is_free
    outcomes = each_mode do
      created = UiPerson.create!(email: "a@x", shop_id: 1, code: "c")
      UiPerson.insert_all([row(email: "b@x", shop_id: 2, code: "c")])
      inserted = UiPerson.find_by!(email: "b@x")
      [created, inserted].each { UiPerson.find(_1.id).destroy! }
      [attempt { UiPerson.insert_all([row(email: "a@x")]) },
       attempt { UiPerson.insert_all!([row(email: "b@x", shop_id: 2, code: "c")]) }]
    end
    assert_equal [1, 1], outcomes[:monitor][:result]
    assert_same_as_monitor(outcomes)
  end

  # A conflict refuses the whole insert_all! before anything is written.
  def test_a_refused_insert_writes_nothing
    use(:es_noproj)
    UiPerson.create!(email: "a@x")
    events = event_count

    assert_raises(ActiveRecord::RecordNotUnique) { UiPerson.insert_all!([row(email: "new@x"), row(email: "a@x")]) }
    assert_equal events, event_count
    assert_nil UiPerson.find_by(email: "new@x")
  end

  # A live record's row an insert left in the table, holding a value its
  # record has since given up (an update through callbacks writes no row
  # there): the value is free, as in Monitor, and the row is brought up to
  # its record's values. It skipped (or refused) the value.
  def test_a_value_a_live_record_gave_up_since_its_insert
    outcomes = each_mode do
      UiPerson.insert_all([row(email: "k1@x")])
      UiPerson.find_by!(email: "k1@x").update!(email: "k2@x")
      [attempt { UiPerson.insert_all([row(email: "k1@x")]) }, attempt { UiPerson.insert_all!([row(email: "k2@x")]) }]
    end
    assert_equal [1, ActiveRecord::RecordNotUnique], outcomes[:monitor][:result]
    assert_same_as_monitor(outcomes)
  end

  # NULLS NOT DISTINCT: a NULL conflicts with a NULL, as Monitor's index
  # has it.
  def test_an_index_whose_nulls_are_not_distinct
    connection.create_table("lyra_ui_badges", force: true) { |t| t.string :badge; t.string :name }
    connection.add_index "lyra_ui_badges", :badge, unique: true, nulls_not_distinct: true
    Object.send(:remove_const, :UiBadge) if Object.const_defined?(:UiBadge)
    Object.const_set(:UiBadge, Class.new(ActiveRecord::Base) do
      self.table_name = "lyra_ui_badges"
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
    end)
    Lyra.config.monitor_model(UiBadge)
    outcomes = %i[monitor es_noproj].to_h do |mode|
      use(mode)
      connection.execute("DELETE FROM lyra_ui_badges")
      UiBadge.create!(name: "no badge")
      [mode, [attempt { UiBadge.insert_all([{ name: "another" }]) }, attempt { UiBadge.insert_all!([{ name: "a third" }]) },
              UiBadge.count]]
    end
    assert_equal [0, ActiveRecord::RecordNotUnique, 1], outcomes[:monitor]
    assert_equal outcomes[:monitor], outcomes[:es_noproj]
  ensure
    connection.drop_table("lyra_ui_badges", if_exists: true)
  end

  # A row from before Lyra that Genesis could not import, left without a
  # stream (genesis_unrepresentable :skip), is a record the table holds:
  # its key and its unique values conflict, as in Monitor. It was taken for
  # a destroyed record's row and deleted, its data lost.
  def test_a_row_genesis_skipped_is_not_deleted
    connection.add_column TABLE, :status, :string
    UiPerson.reset_column_information
    UiPerson.enum :status, { requested: "requested", approved: "approved" }
    previous = Lyra.config.genesis_unrepresentable
    use(:es_noproj)
    Lyra::Genesis.reset!
    Lyra.config.genesis_unrepresentable = :skip
    id = connection.select_value("INSERT INTO #{TABLE} (email, status, created_at, updated_at) " \
                                 "VALUES ('old@x', 'unknown', now(), now()) RETURNING id").to_i

    assert_equal 0, UiPerson.insert_all([row(email: "old@x")]).length
    assert_raises(ActiveRecord::RecordNotUnique) { UiPerson.insert_all!([row(email: "old@x")]) }
    assert_equal 0, UiPerson.insert_all([row(id: id, email: "other@x")]).length
    assert_raises(ActiveRecord::RecordNotUnique) { UiPerson.insert_all!([row(id: id, email: "other@x")]) }
    assert_equal [[id, "old@x", "unknown"]], connection.select_rows("SELECT id, email, status FROM #{TABLE}").map { [_1.to_i, _2, _3] }
  ensure
    Lyra.config.genesis_unrepresentable = previous
    Lyra::Genesis.reset!
  end

  # The values' locks and the keys' locks count together against
  # bulk_write_lock_limit: an email and a key per row, and the shop both
  # rows share (the multi-column index is locked by its first column), are
  # five locks for two rows.
  def test_the_value_and_key_locks_count_together
    use(:es_noproj)
    Lyra.config.bulk_write_lock_limit = 4
    events = event_count

    assert_raises(Lyra::BulkWriteLockLimitError) do
      UiPerson.insert_all([row(id: 1, email: "a@x", shop_id: 1, code: "a"), row(id: 2, email: "b@x", shop_id: 1, code: "b")])
    end
    assert_equal events, event_count
    UiPerson.insert_all([row(id: 1, email: "a@x", shop_id: 1, code: "a")])
    assert_equal events + 1, event_count
  end

  private

  def row(**values)
    { name: "inserted", created_at: Time.current, updated_at: Time.current }.merge(values)
  end

  def attempt
    yield.length
  rescue ActiveRecord::RecordNotUnique => e
    e.class
  end

  # The block's result in each mode, and the records with each email and
  # their events, as the mode reads them.
  def each_mode(&block)
    MODES.to_h do |mode|
      use(mode)
      result = block.call
      UiPerson.count if mode == :es_lazy
      people = UiPerson.order(:email, :code).map { [_1.email, _1.shop_id, _1.code] }
      [mode, { result: result, people: people, events: event_count }]
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

  # The records' events: not the checkpoint of the links ES-NoProj's
  # unique-index check reads (Lyra::Projections::ReferenceLinks).
  def event_count
    connection.select_value("SELECT count(*) FROM event_store_events WHERE event_type <> 'Lyra::Events::ReferenceLinksIndexed'").to_i
  end

  def clean
    connection.execute("DELETE FROM #{TABLE}") if connection.table_exists?(TABLE)
    connection.execute("DELETE FROM event_store_events_in_streams")
    connection.execute("DELETE FROM event_store_events")
    Lyra::Projections::LazyProjection.reset!
    Lyra::Projections::Uniqueness::Snapshot.reset!
    Lyra::Projections::CachedProjection.invalidate_all(UiPerson) if Object.const_defined?(:UiPerson)
    Rails.cache.clear
  end

  def connection = ActiveRecord::Base.connection
end
