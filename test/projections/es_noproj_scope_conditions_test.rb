# frozen_string_literal: true

require "test_helper"

# What ES-NoProj reads of an Active Record relation it is narrowed by (a
# named scope called on a relation, a relation merged in, a default scope):
# its where clause as hash conditions on the model's own columns, and its
# order. A predicate it cannot read as such must refuse the query
# (UnsupportedQuery), never be skipped. An equality or IN whose left side was
# not a column (where(Arel.sql("lower(name)").eq("pear"))) used to be
# skipped, and the scope answered with every record its other conditions
# selected; a column named twice kept only the last condition.
#
# Each query runs on the same rows in Monitor (Active Record and PostgreSQL
# answer from the table) and in ES-NoProj (the rows exist only as events):
# the answers must be equal, or ES-NoProj must refuse.
class EsNoprojScopeConditionsTest < Minitest::Test
  TABLE = "lyra_scond_items"
  UnsupportedQuery = Lyra::Projections::UnsupportedQuery

  ROWS = [
    { code: "a1", name: "pear", status: "active", qty: 2, other: 1 },
    { code: "a2", name: "apple", status: "active", qty: 1, other: 1 },
    { code: "a3", name: "fig", status: "draft", qty: 2, other: 2 },
    { code: "a4", name: "kiwi", status: "draft", qty: 5, other: 9 }
  ].freeze

  def setup
    skip "Requires Rails and PostgreSQL" unless defined?(ActiveRecord::Base) && connection.adapter_name.match?(/postgres/i)

    connection.create_table(TABLE, force: true) do |t|
      t.string :code
      t.string :name
      t.string :status
      t.integer :qty
      t.integer :other
      t.timestamps
    end
    Object.send(:remove_const, :ScondItem) if Object.const_defined?(:ScondItem)
    Object.const_set(:ScondItem, Class.new(ActiveRecord::Base) do
      self.table_name = TABLE
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
      scope :literal_eq, -> { where(Arel.sql("lower(name)").eq("pear")) }
      scope :literal_in, -> { where(Arel.sql("lower(name)").in(%w[pear fig])) }
      scope :function_eq, -> { where(Arel::Nodes::NamedFunction.new("LOWER", [arel_table[:name]]).eq("pear")) }
      scope :other_table_eq, -> { where(Arel::Table.new(:lyra_scond_others)[:name].eq("pear")) }
      scope :column_eq_column, -> { where(arel_table[:qty].eq(arel_table[:other])) }
      scope :column_eq_literal, -> { where(arel_table[:name].eq(Arel.sql("'pear'"))) }
      scope :in_subquery, -> { where(arel_table[:qty].in(Arel.sql("SELECT 2"))) }
      scope :arel_eq, -> { where(arel_table[:qty].eq(2)) }
      scope :arel_in, -> { where(arel_table[:qty].in([1, 5])) }
      scope :qty_twice, -> { where(qty: 2).where(qty: 5) }
      scope :qty_list_and_value, -> { where(qty: [1, 2]).where(qty: 2) }
      scope :by_other_table_column, -> { order(Arel::Table.new(:lyra_scond_others)[:name].asc) }
      scope :by_other_table_string, -> { order(Arel.sql("lyra_scond_others.name")) }
    end)
    ScondItem.reset_column_information
    clean
    Rails.cache.clear
    Lyra.config.monitor_model(ScondItem)
  end

  def teardown
    return unless Object.const_defined?(:ScondItem)

    Lyra.config.enable_monitor!
    Lyra.config.projection_mode = :sync
    clean
    Rails.cache.clear
    connection.drop_table(TABLE, if_exists: true)
  end

  # --- refused: not a condition on one of the model's columns --------------

  %i[literal_eq literal_in function_eq column_eq_column column_eq_literal in_subquery].each do |scope|
    define_method(:"test_a_scope_#{scope}_answers_in_monitor_and_is_refused_in_es_noproj") do
      answered = run_in(:monitor) { codes(ScondItem.where(qty: 1..).public_send(scope).order(:code)) }
      refute_equal codes(ScondItem.order(:code)), answered, "the scope selects some of the records"

      run_in(:es_noproj) do
        assert_raises(UnsupportedQuery) { ScondItem.where(qty: 1..).public_send(scope).to_a }
      end
    end
  end

  # A condition on a table the query did not join: an error in Active Record,
  # refused in ES-NoProj (it used to be read as this model's own column).
  def test_a_condition_on_another_table_s_column_is_refused
    assert_raises(ActiveRecord::StatementInvalid) { run_in(:monitor) { ScondItem.where(qty: 1..).other_table_eq.to_a } }
    run_in(:es_noproj) { assert_raises(UnsupportedQuery) { ScondItem.where(qty: 1..).other_table_eq.to_a } }
  end

  # The same through merge of an Active Record relation.
  def test_a_merged_relation_with_an_sql_literal_condition_is_refused
    run_in(:es_noproj) do
      merged = Lyra::ModeTransition.send(:bypass) { ScondItem.unscoped.where(Arel.sql("lower(name)").eq("pear")) }
      assert_raises(UnsupportedQuery) { ScondItem.where(status: "active").merge(merged).to_a }
    end
  end

  # --- answered, as Active Record answers ---------------------------------

  def test_arel_conditions_on_the_model_s_columns_are_answered
    assert_same_answer do
      [codes(ScondItem.where(qty: 1..).arel_eq.order(:code)), codes(ScondItem.where(qty: 1..).arel_in.order(:code))]
    end
  end

  # Both conditions hold (AND); the second used to replace the first.
  def test_a_column_named_twice_keeps_both_conditions
    assert_same_answer do
      [codes(ScondItem.where(qty: 1..).qty_twice), codes(ScondItem.where(qty: 1..).qty_list_and_value.order(:code))]
    end
  end

  # --- orders --------------------------------------------------------------

  def test_an_order_on_another_table_s_column_is_refused
    run_in(:es_noproj) do
      assert_raises(UnsupportedQuery) { ScondItem.where(qty: 1..).by_other_table_column.to_a }
      assert_raises(UnsupportedQuery) { ScondItem.where(qty: 1..).by_other_table_string.to_a }
      assert_raises(UnsupportedQuery) { ScondItem.order("lyra_scond_others.name").to_a }
      assert_raises(UnsupportedQuery) { ScondItem.order(Arel::Table.new(:lyra_scond_others)[:name].desc).to_a }
    end
  end

  def test_an_order_direction_other_than_asc_or_desc_is_refused
    run_in(:es_noproj) { assert_raises(UnsupportedQuery) { ScondItem.order(qty: "desc nulls last").to_a } }
  end

  def test_orders_on_the_model_s_own_columns_are_answered
    assert_same_answer do
      table = ScondItem.arel_table
      [codes(ScondItem.order("#{TABLE}.qty DESC, code")), codes(ScondItem.order(%("#{TABLE}"."name"))),
       codes(ScondItem.order(table[:qty].asc, table[:code].desc)), codes(ScondItem.order(qty: "DESC", code: :asc))]
    end
  end

  # --- default scopes ------------------------------------------------------

  # A default scope with a condition ES-NoProj cannot read is one it cannot
  # evaluate: named at the switch and refused on read, never applied in part.
  def test_a_default_scope_with_an_sql_literal_condition_is_unevaluable
    Object.send(:remove_const, :ScondLiteralDefault) if Object.const_defined?(:ScondLiteralDefault)
    Object.const_set(:ScondLiteralDefault, Class.new(ActiveRecord::Base) do
      self.table_name = TABLE
      default_scope { where(Arel.sql("lower(status)").eq("active")).where(status: %w[active draft]) }
    end)

    unevaluable = Lyra::Projections::DefaultScopes.unevaluable([ScondLiteralDefault, ScondItem])

    assert_equal [ScondLiteralDefault], unevaluable.map(&:first)
  ensure
    Object.send(:remove_const, :ScondLiteralDefault) if Object.const_defined?(:ScondLiteralDefault)
  end

  # --- bang methods, only ----------------------------------------------------

  # limit! changes the relation it is called on, as Active Record's; it used
  # to return a limited copy and leave the relation whole.
  def test_limit_bang_limits_the_relation_in_place
    assert_same_answer do
      rel = ScondItem.order(:code)
      rel.limit!(2)
      codes(rel)
    end
  end

  # Bang query methods it does not implement are refused, not run on a copy.
  def test_other_bang_query_methods_are_refused
    run_in(:es_noproj) do
      %i[offset! reorder! distinct! group! none!].each do |bang|
        args = bang == :offset! ? [1] : bang == :reorder! || bang == :group! ? [:code] : []
        assert_raises(UnsupportedQuery, bang.to_s) { ScondItem.order(:code).public_send(bang, *args) }
      end
    end
  end

  # only(:where) answers in Active Record (the order and limit dropped);
  # ES-NoProj refuses it (it used to keep them, silently).
  def test_only_is_refused
    assert_equal %w[a1 a2 a3 a4], run_in(:monitor) { codes(ScondItem.order(code: :desc).limit(1).only(:where)).sort }
    run_in(:es_noproj) do
      assert_raises(UnsupportedQuery) { ScondItem.order(code: :desc).limit(1).only(:where) }
      assert_equal %w[a4], codes(ScondItem.order(code: :desc).limit(1).only(:joins)), "only the joins: kept"
    end
  end

  # --- pagination (Kaminari's page and per) ------------------------------------

  # page(n).per(m): the window SQL's LIMIT m OFFSET (n - 1) * m gives, and
  # the totals of the records before the window (they counted the page's).
  def test_a_page_is_the_window_and_its_totals_count_every_record
    expected = run_in(:monitor) do
      rel = ScondItem.where(qty: 1..).order(:code)
      [codes(rel.limit(3).offset(3)), rel.count, (rel.count / 3.0).ceil]
    end
    got = run_in(:es_noproj) do
      page = ScondItem.where(qty: 1..).order(:code).page(2).per(3)
      [codes(page), page.total_count, page.total_pages]
    end
    assert_equal expected, got
    assert_equal [%w[a4], 4, 2], got
  end

  # A where after page applies before the window, as in SQL.
  def test_a_condition_after_page_applies_before_the_window
    run_in(:es_noproj) do
      page = ScondItem.order(:code).page(1).where(status: "draft").per(1)
      assert_equal [%w[a3], 2, 2], [codes(page), page.total_count, page.total_pages]
    end
  end

  # page(n) read before per(m) would be every record (Kaminari gives page n
  # of its default size): refused. page no longer changes the relation it is
  # called on.
  # As Kaminari 1.2's per: nil, a negative or a non-numeric size keeps the
  # default page size (25 here); 0 is an empty page.
  def test_per_without_a_usable_size_keeps_the_default_page_size
    run_in(:es_noproj) do
      rel = ScondItem.order(:code)
      [nil, -1, "abc"].each do |size|
        assert_equal [%w[a1 a2 a3 a4], 25], [codes(rel.page(1).per(size)), rel.page(1).per(size).limit_value], size.inspect
        assert_equal [], rel.page(2).per(size).to_a, size.inspect
      end
      assert_equal [], rel.page(1).per(0).to_a
      assert_equal %w[a3 a4], codes(rel.page(2).per("2"))
    end
  end

  def test_page_without_per_is_refused
    run_in(:es_noproj) do
      rel = ScondItem.order(:code)
      paged = rel.page(2)
      %i[to_a count first exists? total_count].each do |read|
        assert_raises(UnsupportedQuery, read.to_s) { paged.public_send(read) }
      end
      assert_raises(UnsupportedQuery) { paged.where(status: "draft").to_a }
      assert_raises(UnsupportedQuery) { paged.update_all(name: "x") }
      assert_equal 4, rel.count, "the relation page was called on"
    end
  end

  # --- exists? -------------------------------------------------------------

  # As Active Record: exists?(false) and exists?(nil) are false.
  def test_exists_of_false_or_nil_is_false
    assert_same_answer do
      rel = ScondItem.where(status: "draft")
      [rel.exists?, rel.exists?(false), rel.exists?(nil), ScondItem.exists?(false), ScondItem.exists?(nil),
       ScondItem.where(status: "gone").exists?]
    end
  end

  private

  def assert_same_answer(&query)
    expected = run_in(:monitor, &query)
    got = run_in(:es_noproj) do
      assert_equal 0, Lyra::ModeTransition.send(:bypass) { ScondItem.unscoped.count }, "ES-NoProj has no rows"
      query.call
    end
    assert_equal expected, got
  end

  def run_in(mode)
    clean
    if mode == :es_noproj
      Lyra.config.enable_event_sourcing!
      Lyra.config.projection_mode = :disabled
    else
      Lyra.config.enable_monitor!
      Lyra.config.projection_mode = :sync
    end
    ROWS.each { |row| ScondItem.create!(row) }
    yield
  end

  def codes(value) = value.map(&:code)

  def clean
    connection.execute("DELETE FROM #{TABLE}") if connection.table_exists?(TABLE)
    connection.execute("DELETE FROM event_store_events_in_streams")
    connection.execute("DELETE FROM event_store_events")
    Lyra::Projections::CachedProjection.invalidate_all(ScondItem) if Object.const_defined?(:ScondItem)
  end

  def connection = ActiveRecord::Base.connection
end
