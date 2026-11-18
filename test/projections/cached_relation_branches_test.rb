# frozen_string_literal: true

require "test_helper"

# ES-NoProj's query engine (Lyra::Projections::CachedRelation) against Active
# Record: each query below runs twice on the same rows, first in Monitor,
# where Active Record and PostgreSQL answer from the table, then in ES-NoProj,
# where the rows exist only as events and CachedRelation answers in Ruby. The
# two answers must be equal. Records are named by their code (ids differ
# between the two runs). Writes are compared by the state they leave.
#
# What ES-NoProj refuses (UnsupportedQuery) rather than answer differently
# is asserted as a refusal.
class CachedRelationBranchesTest < Minitest::Test
  TABLE = "lyra_crb_items"
  UnsupportedQuery = Lyra::Projections::UnsupportedQuery

  ROWS = [
    { code: "a1", name: "pear", status: "active", qty: 2, price: BigDecimal("1.50"), tag: "x" },
    { code: "a2", name: "apple", status: "active", qty: 1, price: BigDecimal("2.00"), tag: nil },
    { code: "a3", name: "fig", status: "draft", qty: 2, price: BigDecimal("3.25"), tag: "y" },
    { code: "a4", name: "kiwi", status: "draft", qty: 5, price: nil, tag: nil },
    { code: "a5", name: "date", status: "archived", qty: 3, price: BigDecimal("0.75"), tag: "x" }
  ].freeze

  def setup
    skip "Requires Rails and PostgreSQL" unless defined?(ActiveRecord::Base) && connection.adapter_name.match?(/postgres/i)

    connection.create_table(TABLE, force: true) do |t|
      t.string :code
      t.string :name
      t.string :status
      t.integer :qty
      t.decimal :price, precision: 10, scale: 2
      t.string :tag
      t.integer :hits
      t.datetime :seen_at
      t.timestamps
    end
    connection.add_index TABLE, :code, unique: true
    # Partial: not a conflict create_or_find_by can look for (as ActiveRecord's
    # INSERT would hit it only for archived rows).
    connection.add_index TABLE, :name, unique: true, where: "status = 'archived'", name: "index_crb_archived_names"
    Object.send(:remove_const, :CrbItem) if Object.const_defined?(:CrbItem)
    Object.const_set(:CrbItem, Class.new(ActiveRecord::Base) do
      self.table_name = TABLE
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
      scope :active, -> { where(status: "active") }
      scope :maybe_active, ->(flag) { where(status: "active") if flag }
      scope :arel_in, -> { where(arel_table[:qty].in([1, 2])) }
      scope :arel_eq, -> { where(arel_table[:qty].eq(2)) }
      scope :not_small, -> { where.not(qty: [1, 2]) }
      def self.frob = all.frobnicate
      def self.broken = nil.zzz
    end)
    CrbItem.reset_column_information
    clean
    Rails.cache.clear
    Lyra.config.monitor_model(CrbItem)
  end

  def teardown
    return unless Object.const_defined?(:CrbItem)

    Lyra.config.enable_monitor!
    Lyra.config.projection_mode = :sync
    clean
    Rails.cache.clear
    connection.drop_table(TABLE, if_exists: true)
  end

  # --- finders ---------------------------------------------------------------

  def test_positional_finders
    assert_same_answer do
      rel = CrbItem.order(:name)
      [codes(rel.second), codes(rel.third), codes(rel.take!), codes(rel.first!), codes(rel.last!)]
    end
  end

  def test_bang_finders_raise_record_not_found_on_nothing
    assert_same_answer do
      none = CrbItem.where(status: "gone")
      [:take!, :first!, :last!].map { |finder| outcome { none.public_send(finder) } }
    end
  end

  def test_sole_and_find_sole_by
    assert_same_answer do
      [outcome { codes(CrbItem.where(name: "fig").sole) },
       outcome { CrbItem.where(status: "gone").sole },
       outcome { CrbItem.where(status: "active").sole },
       outcome { codes(CrbItem.where(status: "draft").find_sole_by(qty: 5)) },
       outcome { CrbItem.where(status: "draft").find_sole_by(qty: 9) }]
    end
  end

  def test_exists_by_id_given_as_integer_or_string
    assert_same_answer do
      id = CrbItem.find_by(code: "a3").id
      draft = CrbItem.where(status: "draft")
      [draft.exists?(id), draft.exists?(id.to_s), CrbItem.where(status: "active").exists?(id), CrbItem.none.exists?]
    end
  end

  def test_exists_with_a_condition_it_cannot_read_is_refused
    use(:es_noproj)
    seed

    assert_raises(UnsupportedQuery) { CrbItem.where(status: "draft").exists?(1.5) }
  end

  def test_find_by_with_no_conditions_is_the_first_record
    assert_same_answer { codes(CrbItem.where(code: "a4").find_by({})) }
  end

  def test_find_or_initialize_by
    assert_same_answer do
      found = CrbItem.where(status: "draft").find_or_initialize_by(qty: 5)
      built = CrbItem.where(status: "draft").find_or_initialize_by(qty: 7)
      [codes(found), found.persisted?, built.new_record?, built.status, built.qty]
    end
  end

  # --- loading ---------------------------------------------------------------

  def test_counting_and_testing_for_records
    assert_same_answer do
      rel = CrbItem.where(status: "draft")
      [rel.many?, rel.one?, rel.none?, CrbItem.where(code: "a1").one?, CrbItem.where(code: "a1").many?,
       CrbItem.none.none?, rel.any? { |r| r.qty == 5 }, rel.count { |r| r.qty > 2 }, rel.present?,
       CrbItem.none.blank?, rel.size, rel.length]
    end
  end

  def test_sum_with_a_block_sums_the_loaded_records
    assert_same_answer { CrbItem.where(status: "active").sum { |r| r.qty * 10 } }
  end

  def test_array_conversion_and_indexing
    assert_same_answer do
      first, second = *CrbItem.order(:name).to_ary
      rel = CrbItem.order(qty: :desc, code: :asc)
      [codes(first), codes(second), codes(rel[0]), codes(rel[4]), rel[9]]
    end
  end

  def test_each_without_a_block_is_an_enumerator
    assert_same_answer do
      enum = CrbItem.order(:code).each
      [enum.class, enum.map(&:code)]
    end
  end

  def test_inspect_shows_at_most_ten_records
    use(:es_noproj)
    seed
    7.times { |i| CrbItem.create!(code: "b#{i}", name: "n#{i}", status: "extra", qty: i) }

    shown = CrbItem.order(:code).inspect
    assert_equal 10, shown.scan("#<CrbItem").size
    assert shown.end_with?(", ...]>"), shown
    assert_equal CrbItem.order(:code).first(2).map(&:inspect).join(", "), CrbItem.order(:code).limit(2).to_s[/\[(.*)\]/, 1]
  end

  # --- ordering --------------------------------------------------------------

  def test_reorder_nil_drops_the_order
    # qty has ties: an order by name kept would decide them by name.
    assert_same_answer { codes(CrbItem.order(:name).reorder(nil).order(:qty, :id)) }
  end

  def test_reverse_order
    assert_same_answer do
      [codes(CrbItem.order(:qty, :code).reverse_order), codes(CrbItem.order(qty: :desc, code: :desc).reverse_order)]
    end
  end

  def test_arel_orderings
    assert_same_answer do
      table = CrbItem.arel_table
      [codes(CrbItem.order(table[:qty].asc, table[:code].desc)), codes(CrbItem.order(table[:name].desc))]
    end
  end

  def test_orders_it_cannot_read_are_refused
    use(:es_noproj)
    seed

    assert_raises(UnsupportedQuery) { CrbItem.order(Arel.sql("lower(name)").asc) }
    assert_raises(UnsupportedQuery) { CrbItem.order(1) }
  end

  def test_order_bang_sorts_in_place
    assert_same_answer do
      rel = CrbItem.where(status: %w[active draft])
      rel.order!(:qty)
      rel.order!(code: :desc)
      codes(rel)
    end
  end

  def test_nulls_sort_last_ascending_and_first_descending
    assert_same_answer do
      [codes(CrbItem.order(:tag, :code)), codes(CrbItem.order(tag: :desc, code: :asc)), codes(CrbItem.order(:price, :code))]
    end
  end

  def test_or_with_another_kind_of_relation_is_refused
    use(:es_noproj)
    seed

    assert_raises(UnsupportedQuery) { CrbItem.where(qty: 1).or(User.where(name: "x")) }
  end

  # --- unscope, rewhere, except ------------------------------------------------

  def test_unscope_order_after_a_where
    assert_same_answer { codes(CrbItem.where(qty: 1..).order(:name).unscope(:order).order(:qty, :id)) }
  end

  def test_unscope_where_after_a_reorder_replays_the_reorder
    assert_same_answer { codes(CrbItem.where(status: "active").reorder(:qty, :code).unscope(where: :status)) }
  end

  def test_unscope_of_a_clause_the_relation_does_not_have
    assert_same_answer { codes(CrbItem.where(status: "draft").order(:code).unscope(:select)) }
  end

  def test_unscope_bang_changes_the_relation
    assert_same_answer do
      rel = CrbItem.where(status: "active").order(:code)
      rel.unscope!(where: :status)
      codes(rel)
    end
  end

  def test_except_order
    assert_same_answer { codes(CrbItem.where(status: "draft").order(qty: :desc).except(:order).order(:code)) }
  end

  # Without a plan (after where.not, a limit or an SQL fragment): an order can
  # be dropped (records in key order), the rest only when it changes nothing.
  def test_unscope_order_without_a_plan_keeps_the_records_in_key_order
    expected = run_in(:monitor) { CrbItem.where.not(status: "archived").order(:name).unscope(:order).pluck(:code).sort }
    got = run_in(:es_noproj) { CrbItem.where.not(status: "archived").order(:name).unscope(:order).to_a }

    assert_equal expected, got.map(&:code).sort
    assert_equal got.map(&:id).sort, got.map(&:id), "key order"
  end

  def test_unscope_without_a_plan_of_nothing_it_holds_changes_nothing
    assert_same_answer { codes(CrbItem.where.not(status: "archived").unscope(:limit).unscope(:offset).order(:code)) }
  end

  def test_unscope_without_a_plan_refuses_what_it_cannot_take_back
    use(:es_noproj)
    seed

    assert_raises(UnsupportedQuery) { CrbItem.where.not(status: "x").limit(2).unscope(:limit) }
    assert_raises(UnsupportedQuery) { CrbItem.where.not(status: "x").offset(1).unscope(:offset) }
    assert_raises(UnsupportedQuery) { CrbItem.where(status: "active").limit(5).unscope(where: :status) }
    assert_raises(UnsupportedQuery) { CrbItem.where(status: "active").unscope(order: :name) }
  end

  def test_rewhere
    assert_same_answer do
      [codes(CrbItem.where(status: "active").rewhere(status: "draft").order(:code)),
       codes(CrbItem.where(status: "active").rewhere(qty: 2).order(:code))]
    end
  end

  def test_rewhere_of_an_sql_fragment_is_refused
    use(:es_noproj)
    seed

    assert_raises(UnsupportedQuery) { CrbItem.where(status: "active").rewhere("qty = 1") }
  end

  # --- merge -----------------------------------------------------------------

  def test_merges_in_a_chain
    assert_same_answer do
      codes(CrbItem.where(qty: 1..2).merge(CrbItem.where(status: %w[active draft])).merge(CrbItem.where(tag: "x")))
    end
  end

  def test_merge_takes_the_others_order
    assert_same_answer { codes(CrbItem.where(qty: 1..3).merge(CrbItem.order(qty: :desc, code: :asc))) }
  end

  # An Active Record relation of the model (built past Lyra's reads, as a
  # scope's or an association's is): its conditions, order and create_with.
  def test_merge_of_an_active_record_relation
    assert_same_answer do
      other = Lyra::ModeTransition.send(:bypass) { CrbItem.unscoped.where(status: "draft").order(:code).create_with(tag: "m") }
      merged = CrbItem.where(qty: 2..).merge(other)
      [codes(merged), merged.new.tag, merged.new.status]
    end
  end

  def test_merge_of_an_active_record_relation_that_unscopes
    assert_same_answer do
      other = Lyra::ModeTransition.send(:bypass) { CrbItem.unscoped.unscope(where: :status).where(qty: 2) }
      codes(CrbItem.where(status: "active").merge(other).order(:code))
    end
  end

  def test_merge_bang
    assert_same_answer do
      rel = CrbItem.where(status: %w[active draft])
      rel.merge!(CrbItem.where(qty: 2))
      codes(rel.order(:code))
    end
  end

  # A relation with nothing but create_with: the records stay, the attributes come.
  def test_merge_of_an_active_record_relation_with_create_with_only
    assert_same_answer do
      merged = CrbItem.where(status: "draft").merge(Lyra::ModeTransition.send(:bypass) { CrbItem.unscoped.create_with(tag: "only") })
      [codes(merged.order(:code)), merged.new.tag]
    end
  end

  def test_merge_of_what_it_cannot_evaluate_is_refused
    use(:es_noproj)
    seed

    assert_raises(UnsupportedQuery) { CrbItem.where(qty: 1).merge(Object.new) }
    other_model = Lyra::ModeTransition.send(:bypass) { User.unscoped.where(name: "x") }
    assert_raises(UnsupportedQuery) { CrbItem.where(qty: 1).merge(other_model) }
  end

  # --- building and writing through a relation ---------------------------------

  def test_create_through_a_relation_takes_its_conditions
    assert_same_answer do
      CrbItem.where(status: "new", qty: 7).create(code: "c1", name: "lime")
      CrbItem.where(status: "new").first_or_create(code: "c2", name: "never")
      CrbItem.where(status: "other").first_or_create(code: "c3", name: "plum")
      state
    end
  end

  def test_create_or_find_by_finds_the_record_a_unique_index_would_keep
    assert_same_answer do
      found = CrbItem.where(status: "draft").create_or_find_by(code: "a3")
      elsewhere = outcome { CrbItem.where(status: "active").create_or_find_by(code: "a3") }
      created = CrbItem.create_or_find_by(code: "c9") { |r| r.name = "melon" }
      found_bang = CrbItem.create_or_find_by!(code: "a5")
      # The partial index (archived names) is not one a conflict is looked for in.
      partial = CrbItem.create_or_find_by!(name: "pear", code: "c10")
      [codes(found), elsewhere, codes(created), codes(found_bang), codes(partial), state]
    end
  end

  def test_create_with_bang
    assert_same_answer do
      rel = CrbItem.where(status: "draft")
      rel.create_with!(tag: "cw")
      a = rel.new.tag
      rel.create_with!(nil)
      [a, rel.new.tag]
    end
  end

  def test_update_bang_of_one_record_or_all_selected
    assert_same_answer do
      id = CrbItem.find_by(code: "a2").id
      CrbItem.where(status: "active").update!(id, tag: "one")
      CrbItem.where(status: "draft").update!(qty: 9)
      state
    end
  end

  def test_update_of_one_record_of_the_relation
    assert_same_answer do
      id = CrbItem.find_by(code: "a4").id
      updated = CrbItem.where(status: "draft").update(id, name: "kiwano")
      [codes(updated), state]
    end
  end

  def test_create_with_nil_resets_it
    assert_same_answer do
      rel = CrbItem.where(status: "draft").create_with(tag: "cw")
      [rel.new.tag, rel.create_with(nil).new.tag, rel.create_with(nil).new.status]
    end
  end

  def test_update_counters_of_the_selected_records
    assert_same_answer do
      CrbItem.where(status: "active").update_counters(hits: 2, qty: -1)
      CrbItem.where(status: "gone").update_counters(hits: 2)
      state(:hits)
    end
  end

  def test_update_counters_touches_the_timestamps_asked_for
    assert_same_answer do
      before = CrbItem.where(status: "draft").pluck(:code, :updated_at).to_h
      CrbItem.where(status: "draft").update_counters(hits: 1, touch: true)
      CrbItem.where(status: "active").update_counters(hits: 1, touch: :seen_at)
      after = CrbItem.order(:code).pluck(:code, :updated_at, :seen_at)
      after.map { |code, updated, seen| [code, before.key?(code) ? updated > before[code] : nil, !seen.nil?] }
    end
  end

  def test_update_counters_of_an_unknown_column_is_refused
    use(:es_noproj)
    seed

    assert_raises(UnsupportedQuery) { CrbItem.where(status: "draft").update_counters(nope: 1) }
  end

  def test_destroy_by
    assert_same_answer do
      CrbItem.where(status: %w[active draft]).destroy_by(qty: 2)
      state
    end
  end

  # --- aggregates ------------------------------------------------------------

  def test_aggregates_by_group
    assert_same_answer do
      rel = CrbItem.group(:status)
      [rel.sum(:qty), rel.average(:qty).transform_values(&:to_s), rel.minimum(:price), rel.maximum(:price),
       CrbItem.group(:status, :tag).count]
    end
  end

  def test_calculate_operations
    assert_same_answer do
      rel = CrbItem.where(status: %w[active draft])
      %w[average minimum maximum].map { |op| rel.calculate(op, :price).to_s } + [rel.calculate(:count, :price)]
    end
  end

  def test_pick_several_columns_and_on_nothing
    assert_same_answer do
      [CrbItem.where(code: "a3").pick(:name, :qty), CrbItem.where(code: "zz").pick(:name)]
    end
  end

  # --- batches ---------------------------------------------------------------

  def test_find_in_batches
    assert_same_answer do
      batches = []
      CrbItem.where(status: %w[active draft archived]).find_in_batches(batch_size: 2) { |b| batches << b.map(&:code) }
      enum = CrbItem.find_in_batches(batch_size: 3)
      [batches, enum.map { |b| b.map(&:code) }]
    end
  end

  # --- other relation methods --------------------------------------------------

  def test_none_unscoped_readonly
    assert_same_answer do
      [codes(CrbItem.where(status: "active").none), CrbItem.where(status: "active").none.count,
       codes(CrbItem.where(status: "active").unscoped.order(:code)),
       codes(CrbItem.where(status: "draft").readonly.order(:code))]
    end
  end

  # Kaminari's page(n).per(m): the window, and where it is. (No pagination gem
  # is loaded here, so there is no Active Record answer to compare with.)
  def test_pagination_window
    run_in(:es_noproj) do
      page = CrbItem.order(:code).page(2).per(2)
      assert_equal %w[a3 a4], page.map(&:code)
      assert_equal [2, 2, 2], [page.current_page, page.limit_value, page.offset_value]
      assert_equal %w[a5], CrbItem.order(:code).page("3").per(2).map(&:code)
      assert_equal [], CrbItem.order(:code).page(4).per(2).to_a
      assert_equal 1, CrbItem.order(:code).page(0).current_page, "pages start at 1"

      unpaged = CrbItem.order(:code)
      assert_equal [1, 1, 0, nil], [unpaged.total_pages, unpaged.current_page, unpaged.offset_value, unpaged.limit_value]
      # page(n) alone names no page size: ES-NoProj refuses to read it rather than
      # answer every record; per(nil) keeps the default size, as Kaminari's does.
      assert_raises(Lyra::Projections::UnsupportedQuery) { CrbItem.order(:code).page(1).to_a }
      first = CrbItem.order(:code).page(1).per(nil)
      assert_equal [1, 5, 25], [first.total_pages, first.total_count, first.limit_value], "25 a page by default"
    end
  end

  def test_take_several
    assert_same_answer { [codes(CrbItem.order(:name).take(2)), codes(CrbItem.where(status: "gone").take(2))] }
  end

  # Hints for the database change nothing in the answer.
  def test_hints_and_distinct
    assert_same_answer do
      rel = CrbItem.where(status: %w[active draft]).order(:code)
      [codes(rel.references(:x)), codes(rel.lock), codes(rel.annotate("hint")), codes(rel.optimizer_hints("x")),
       codes(rel.strict_loading), codes(rel.uniq), codes(rel.distinct)]
    end
  end

  # The relation answers what Active Record asks a relation for when it
  # builds on it: the model's table and connection, and no joins.
  def test_relation_internals_mirror_the_model
    assert_same_answer do
      rel = CrbItem.where(status: "draft")
      [rel.table.name, rel.connection.equal?(CrbItem.connection), rel.with_connection { |c| c.select_value("SELECT 7") },
       rel.joins_values, rel.left_outer_joins_values]
    end
  end

  # Inside a scoping block the model's reads answer from that relation; a
  # nested one replaces it until its block ends.
  def test_nested_scoping
    assert_same_answer do
      outer = CrbItem.where(status: "draft")
      inner = CrbItem.where(status: "active")
      outer.scoping { [inner.scoping { codes(CrbItem.order(:code)) }, codes(CrbItem.order(:code))] }
    end
  end

  # --- conditions bound as Active Record binds them (TypedValues) -------------

  # where([:a, :b] => [[x, y], ...]): the record matches one of the tuples; a
  # tuple of the wrong size matches nothing.
  def test_tuple_conditions
    assert_same_answer do
      [codes(CrbItem.where(%i[status qty] => [["draft", 5], ["active", 1], %w[draft 9]]).order(:code)),
       codes(CrbItem.where(%i[status qty] => [["draft", "5"]]))]
    end
  end

  def test_lists_with_ranges_and_empty_lists
    assert_same_answer do
      [codes(CrbItem.where(qty: [1, 3..4]).order(:code)), codes(CrbItem.where(qty: []).order(:code)),
       codes(CrbItem.where.not(qty: []).order(:code)), codes(CrbItem.where(qty: [nil, 4..]).order(:code))]
    end
  end

  # A bound beyond the column's range, or one the type binds as NULL.
  def test_range_bounds_out_of_range_or_unbindable
    assert_same_answer do
      big = 2**70
      [codes(CrbItem.where(qty: ..-big).order(:code)), codes(CrbItem.where(qty: -big..big).order(:code)),
       codes(CrbItem.where(qty: 2..big).order(:code)), codes(CrbItem.where(qty: "abc".."zz").order(:code)),
       codes(CrbItem.where.not(qty: "1".."x").order(:code))]
    end
  end

  def test_a_record_as_a_condition_value_is_its_id
    assert_same_answer do
      fig = CrbItem.find_by(code: "a3")
      codes(CrbItem.where(id: fig))
    end
  end

  def test_where_with_nil_is_no_condition
    assert_same_answer { codes(CrbItem.where(status: "draft").where(nil).order(:code)) }
  end

  def test_where_of_a_hash_with_more_arguments_is_refused
    use(:es_noproj)
    seed

    assert_raises(UnsupportedQuery) { CrbItem.where({ qty: 1 }, 2) }
  end

  def test_where_values_hash
    assert_same_answer do
      rel = CrbItem.where(status: "draft", qty: 5)
      [rel.where_values_hash, rel.where_values_hash(TABLE), rel.where_values_hash("users")]
    end
  end

  def test_model_readers_answer_on_a_relation
    assert_same_answer do
      rel = CrbItem.where(status: "draft")
      [rel.table_name, rel.primary_key, rel.column_names, rel.klass.name, rel.respond_to?(:active), rel.respond_to?(:nope)]
    end
  end

  def test_a_scope_that_returns_nil_is_all
    assert_same_answer do
      [codes(CrbItem.where(qty: 2).maybe_active(false).order(:code)), codes(CrbItem.where(qty: 2).maybe_active(true)),
       codes(CrbItem.maybe_active(false).order(:code))]
    end
  end

  def test_arel_conditions_of_a_scope
    assert_same_answer { [codes(CrbItem.where(qty: 1..).arel_in.order(:code)), codes(CrbItem.where(status: "draft").arel_eq)] }
  end

  # where.not of a list is a NOT IN: not read as a condition, refused.
  def test_a_scope_of_a_not_in_is_refused
    use(:es_noproj)
    seed

    assert_raises(UnsupportedQuery) { CrbItem.where(status: "draft").not_small }
  end

  # A class method that calls what the relation does not have.
  def test_a_class_method_calling_an_unknown_method
    assert_raises(NoMethodError) { run_in(:monitor) { CrbItem.where(qty: 1).frob } }
    assert_raises(UnsupportedQuery) { run_in(:es_noproj) { CrbItem.where(qty: 1).frob } }
    assert_raises(NoMethodError) { run_in(:es_noproj) { CrbItem.where(qty: 1).broken } }
  end

  private

  # The answer in Monitor and in ES-NoProj, each on freshly seeded rows.
  def assert_same_answer(&query)
    expected = run_in(:monitor, &query)
    got = run_in(:es_noproj) do
      assert_equal 0, Lyra::ModeTransition.send(:bypass) { CrbItem.unscoped.count }, "ES-NoProj has no rows"
      query.call
    end
    assert_equal expected, got
  end

  def run_in(mode)
    clean
    use(mode)
    seed
    yield
  end

  def seed
    ROWS.each { |row| CrbItem.create!(row) }
  end

  def use(mode)
    if mode == :es_noproj
      Lyra.config.enable_event_sourcing!
      Lyra.config.projection_mode = :disabled
    else
      Lyra.config.enable_monitor!
      Lyra.config.projection_mode = :sync
    end
  end

  # What a relation or record is, by code.
  def codes(value)
    case value
    when nil then nil
    when ActiveRecord::Base then value.code
    else value.map(&:code)
    end
  end

  def state(*extra)
    CrbItem.order(:code).pluck(:code, :name, :status, :qty, :tag, *extra)
  end

  def outcome
    yield
  rescue ActiveRecord::RecordNotFound, ActiveRecord::SoleRecordExceeded => e
    [:raised, e.class.name]
  end

  def clean
    connection.execute("DELETE FROM #{TABLE}") if connection.table_exists?(TABLE)
    connection.execute("DELETE FROM event_store_events_in_streams")
    connection.execute("DELETE FROM event_store_events")
    Lyra::Projections::CachedProjection.invalidate_all(CrbItem) if Object.const_defined?(:CrbItem)
  end

  def connection = ActiveRecord::Base.connection
end
