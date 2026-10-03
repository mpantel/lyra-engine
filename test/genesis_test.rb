# frozen_string_literal: true

require "test_helper"

# Genesis: rows that predate Lyra get one Imported event on the model's first
# use, so that state rebuilt from events -- ES-NoProj reads and their SQL
# aggregates, DualView, Rebuild -- covers them.
class GenesisTest < Minitest::Test
  TABLE = "lyra_genesis_items"

  def setup
    skip "Requires Rails and database" unless defined?(ActiveRecord::Base) && ActiveRecord::Base.connection.adapter_name.match?(/postgres/i)

    connection.create_table(TABLE, force: true) do |t|
      t.string :label
      t.integer :quantity
      t.decimal :amount, precision: 12, scale: 2
      t.float :weight
      t.boolean :active
      t.timestamps
    end
    Object.send(:remove_const, :GenesisItem) if defined?(GenesisItem)
    Object.const_set(:GenesisItem, Class.new(ActiveRecord::Base) do
      self.table_name = TABLE
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
    end)
    GenesisItem.reset_column_information
    clean_events

    # Rows written before Lyra was enabled: no streams.
    connection.execute(<<~SQL)
      INSERT INTO #{TABLE} (label, quantity, amount, weight, active, created_at, updated_at) VALUES
        ('a', 1, 10.10, 1.5, true,  '2020-01-01 10:00:00', '2020-01-02 10:00:00'),
        ('b', 2, 20.20, 2.5, false, '2020-01-01 11:00:00', '2020-01-02 11:00:00'),
        ('c', NULL, 0.01, NULL, NULL, '2020-01-01 12:00:00', '2020-01-02 12:00:00')
    SQL
    @ids = connection.select_values("SELECT id FROM #{TABLE} ORDER BY id").map(&:to_i)
    Lyra.config.monitor_model(GenesisItem)
  end

  def teardown
    return unless defined?(GenesisItem)

    Lyra.config.projection_mode = :sync
    Lyra::Projections::CachedProjection.invalidate_all(GenesisItem)
    clean_events
    connection.drop_table(TABLE, if_exists: true)
  end

  def test_es_noproj_aggregates_cover_rows_that_predate_lyra
    es_noproj!

    assert_equal 3, GenesisItem.count
    assert_equal 2, GenesisItem.count(:quantity), "COUNT(column) skips NULLs only"
    assert_equal 2, GenesisItem.count(:active), "false is a value, not a NULL"
    assert_equal 3, GenesisItem.sum(:quantity)
    assert_equal BigDecimal("30.31"), GenesisItem.sum(:amount)
    assert_kind_of BigDecimal, GenesisItem.sum(:amount), "no rounding through Float"
    assert_equal BigDecimal("1.5"), GenesisItem.average(:quantity)
    assert_kind_of BigDecimal, GenesisItem.average(:quantity)
    assert_in_delta 2.0, GenesisItem.average(:weight)
    assert_kind_of Float, GenesisItem.average(:weight)
    assert_equal BigDecimal("0.01"), GenesisItem.minimum(:amount)
    assert_equal "c", GenesisItem.maximum(:label)
    assert_equal BigDecimal("30.31"), GenesisItem.calculate(:sum, :amount)
    assert_equal BigDecimal("10.10"), GenesisItem.where(active: true).calculate(:sum, :amount)
    assert_equal 1, GenesisItem.where(active: true).count
  end

  # AVG is compared to 12 places: the database rounds a numeric quotient to
  # its own scale (PostgreSQL keeps about 16 significant digits).
  def test_aggregates_match_sql_on_the_same_rows
    expected = sql_aggregates.transform_values { _1.is_a?(BigDecimal) ? _1.round(12) : _1 }
    es_noproj!

    assert_equal expected, {
      count: GenesisItem.count, count_quantity: GenesisItem.count(:quantity),
      sum_quantity: GenesisItem.sum(:quantity), sum_amount: GenesisItem.sum(:amount),
      avg_quantity: GenesisItem.average(:quantity), avg_amount: GenesisItem.average(:amount),
      min_amount: GenesisItem.minimum(:amount), max_weight: GenesisItem.maximum(:weight)
    }.transform_values { _1.is_a?(BigDecimal) ? _1.round(12) : _1 }
  end

  def test_an_aggregate_over_nothing_follows_sql
    es_noproj!

    none = GenesisItem.where(label: "zzz")
    assert_equal 0, none.sum(:amount)
    assert_nil none.average(:amount)
    assert_nil none.minimum(:amount)
    assert_equal 0, none.count(:amount)
  end

  def test_an_sql_expression_is_refused_not_guessed
    es_noproj!

    assert_raises(Lyra::Projections::UnsupportedQuery) { GenesisItem.sum("quantity * amount") }
    assert_raises(Lyra::Projections::UnsupportedQuery) { GenesisItem.all.calculate(:stddev, :amount) }
  end

  def test_the_first_read_imports_each_row_once_and_later_reads_import_nothing
    es_noproj!

    assert_equal 0, imported_events.size, "nothing happens before first use"
    GenesisItem.sum(:amount)
    assert_equal @ids.sort, imported_events.map { _1.data[:model_id] }.sort
    assert imported_events.all? { _1.event_type.end_with?("Imported") && _1.metadata[:genesis] }

    assert Lyra::Genesis.imported?(GenesisItem)
    assert_equal 0, Lyra::Genesis.first_use(GenesisItem)
    GenesisItem.count
    assert_equal 3, imported_events.size
  end

  def test_es_noproj_finds_and_updates_a_row_that_predates_lyra
    es_noproj!

    item = GenesisItem.find(@ids.first)
    assert_equal "a", item.label
    assert_equal BigDecimal("10.10"), item.amount

    item.update!(quantity: 7)
    Lyra::Projections::CachedProjection.invalidate_all(GenesisItem)
    assert_equal 7, GenesisItem.find(@ids.first).quantity
    assert_equal 9, GenesisItem.sum(:quantity)
    assert_equal %w[Imported Updated], stream(@ids.first).map { _1.event_type[/(Imported|Updated)\z/] }
  end

  def test_the_first_write_imports_before_its_own_event
    Lyra.config.enable_event_sourcing!
    Lyra.config.projection_mode = :sync

    GenesisItem.find(@ids.second).update!(label: "b2")

    events = stream(@ids.second)
    assert_equal 2, events.size
    assert events.first.event_type.end_with?("Imported")
    assert_equal "b", events.first.data[:attributes]["label"], "the Imported event holds the row as it was"
    state = Lyra::StateProjection.rebuild_state(GenesisItem, @ids.second)
    assert_equal "b2", (state["label"] || state[:label])
    assert_equal 2, (state["quantity"] || state[:quantity]), "the rebuilt state keeps what only the row knew"
  end

  def test_monitor_mode_imports_only_when_asked
    Lyra.config.enable_monitor!
    GenesisItem.find(@ids.first).update!(label: "a2")
    assert_empty imported_events, "genesis :auto leaves Monitor alone"

    Lyra::Genesis.reset!
    Lyra.config.genesis = true
    GenesisItem.find(@ids.second).update!(label: "b2")
    assert_equal 2, imported_events.size, "the two rows without a stream; the updated one already has one"
    assert_equal "b", stream(@ids.second).first.data[:attributes]["label"]
  end

  def test_genesis_false_never_imports
    Lyra.config.genesis = false
    es_noproj!

    GenesisItem.count
    assert_empty imported_events
  end

  # The import commits on its own connection: the rows existed before the
  # caller's transaction, so its rollback must not undo their history.
  def test_an_import_outlives_the_callers_rollback
    es_noproj!

    ActiveRecord::Base.transaction do
      GenesisItem.count
      raise ActiveRecord::Rollback
    end

    assert Lyra::Genesis.imported?(GenesisItem)
    assert_equal 3, imported_events.size
    assert_equal 3, GenesisItem.count
  end

  # The lock is held only while importing, so a transaction left open after
  # the first use does not block another connection's first use.
  def test_an_open_transaction_does_not_block_another_first_use
    es_noproj!
    opened = Queue.new
    release = Queue.new
    holder = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        ActiveRecord::Base.transaction do
          GenesisItem.count
          opened << true
          release.pop
        end
      end
    end
    opened.pop
    Lyra::Genesis.reset!

    other = Thread.new { ActiveRecord::Base.connection_pool.with_connection { GenesisItem.count } }
    assert other.join(5), "the second first use waited on the open transaction"
    assert_equal 3, other.value
    assert_equal 3, imported_events.size, "each row is imported once"
  ensure
    release << true
    holder&.join
  end

  private

  def connection = ActiveRecord::Base.connection

  def es_noproj!
    Lyra.config.enable_event_sourcing!
    Lyra.config.projection_mode = :disabled
    Lyra::Projections::CachedProjection.invalidate_all(GenesisItem)
  end

  def sql_aggregates
    row = connection.select_one(<<~SQL)
      SELECT COUNT(*) c, COUNT(quantity) cq, SUM(quantity) sq, SUM(amount) sa,
             AVG(quantity) aq, AVG(amount) aa, MIN(amount) mi, MAX(weight) mw
      FROM #{TABLE}
    SQL
    { count: row["c"], count_quantity: row["cq"], sum_quantity: row["sq"], sum_amount: row["sa"],
      avg_quantity: row["aq"], avg_amount: row["aa"], min_amount: row["mi"], max_weight: row["mw"] }
  end

  def stream(id) = Lyra.config.event_store.read.stream("GenesisItem$#{id}").to_a

  def imported_events
    Lyra.config.event_store.read.to_a.select { _1.event_type.end_with?("Imported") }
  end

  def clean_events
    connection.execute("DELETE FROM event_store_events_in_streams")
    connection.execute("DELETE FROM event_store_events")
  end
end
