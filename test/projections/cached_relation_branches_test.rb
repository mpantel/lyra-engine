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
      t.integer :owner_id
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
      scope :draft_count, -> { where(status: "draft").count }
      scope :first_by_code, -> { order(:code).first }
      # An Active Record relation of the model (built past Lyra's reads):
      # it is the answer, whatever relation the scope is called on.
      scope :built_on_unscoped, -> { Lyra::ModeTransition.send(:bypass) { CrbItem.unscoped.where(status: "draft") } }
      belongs_to :owner, class_name: "User", optional: true
      belongs_to :buyer, class_name: "User", foreign_key: :owner_id, optional: true
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

  # reverse_order! in place (Active Record's last asks it of the relation it
  # builds); before a window, as reverse_order.
  def test_reverse_order_bang
    assert_same_answer do
      rel = CrbItem.order(:qty, :code)
      rel.reverse_order!
      limited = CrbItem.order(:code).limit(2)
      limited.reverse_order!
      [codes(rel), codes(limited)]
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

  # A window is taken off the relation it was taken from (these were
  # refused): what the relation selected before it is still there.
  def test_unscope_of_a_window
    assert_same_answer do
      [codes(CrbItem.where.not(status: "x").order(:code).limit(2).unscope(:limit)),
       codes(CrbItem.where.not(status: "x").order(:code).offset(1).unscope(:offset)),
       codes(CrbItem.where(status: "active").order(:code).limit(5).unscope(where: :status))]
    end
  end

  # where.not continues the plan: unscope takes it off, as Active Record
  # does (it was refused).
  def test_unscope_of_a_where_not
    assert_same_answer do
      [codes(CrbItem.where.not(status: "active").unscope(where: :status).order(:code)),
       codes(CrbItem.where.not(status: "active").order(:code).limit(2).unscope(where: :status)),
       codes(CrbItem.where.not(status: "active").where(qty: 2).unscope(where: :qty).order(:code))]
    end
  end

  def test_unscope_without_a_plan_refuses_what_it_cannot_take_back
    use(:es_noproj)
    seed

    assert_raises(UnsupportedQuery) { CrbItem.where("qty > ?", 1).where(status: "draft").unscope(where: :status) }
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

  # Not a relation: Active Record's ArgumentError.
  def test_merge_of_what_is_not_a_relation
    assert_same_answer { outcome_any { CrbItem.where(qty: 1).merge(Object.new) } }
  end

  def test_merge_of_another_model_s_relation_is_refused
    use(:es_noproj)
    seed

    other_model = Lyra::ModeTransition.send(:bypass) { User.unscoped.where(name: "x") }
    assert_raises(UnsupportedQuery) { CrbItem.where(qty: 1).merge(other_model) }
  end

  # As Active Record (7 and later): the arguments after the relation are
  # options (merge(r1, r2) ignores r2; rewhere: true changes nothing), and
  # where both name a column, the other relation's conditions replace this
  # one's. ES-NoProj used to intersect with r2, refuse rewhere:, and keep
  # both conditions (status "active" and "draft": nothing).
  def test_merge_takes_the_others_conditions_on_the_columns_both_name
    assert_same_answer do
      [codes(CrbItem.where(qty: 1..2).merge(CrbItem.where(status: %w[active draft]), CrbItem.where(tag: "x")).order(:code)),
       codes(CrbItem.where(status: "active").merge(CrbItem.where(status: "draft"), rewhere: true).order(:code)),
       codes(CrbItem.where(status: "active").merge(CrbItem.where(status: "draft")).order(:code)),
       codes(CrbItem.where(status: %w[active draft], qty: 2).merge(CrbItem.where(status: "draft")).order(:code)),
       codes(CrbItem.where(status: "draft").merge(CrbItem.where(status: "draft", qty: 5))),
       codes(CrbItem.where(qty: 2).merge!(CrbItem.where(qty: 5)))]
    end
  end

  # The same for an Active Record relation of the model (a scope's, an
  # association's).
  def test_merge_of_an_active_record_relation_takes_its_conditions_on_the_columns_both_name
    assert_same_answer do
      other = Lyra::ModeTransition.send(:bypass) { CrbItem.unscoped.where(status: "draft") }
      codes(CrbItem.where(status: "active", qty: 1..).merge(other).order(:code))
    end
  end

  # A condition that cannot be taken off (after a where.not, the relation
  # has no plan to replay) is refused rather than kept.
  # A where.not, an earlier merge and a belongs_to condition are taken off
  # as unscope takes them off (the first two were refused, the last kept).
  def test_merge_replaces_a_where_not_an_earlier_merge_and_a_belongs_to_condition
    assert_same_answer do
      with_owners do
        ann = User.find_by(email: "ann-crb@example.com")
        bob = User.find_by(email: "bob-crb@example.com")
        [codes(CrbItem.where.not(status: "draft").merge(CrbItem.where(status: "draft")).order(:code)),
         codes(CrbItem.where.not(status: "draft").merge(CrbItem.where(qty: 1..2)).order(:code)),
         codes(CrbItem.where(status: "active").merge(CrbItem.where(status: "draft")).merge(CrbItem.where(status: "archived"))),
         codes(CrbItem.where(status: "active").merge(CrbItem.where(qty: 2)).unscope(where: :qty).order(:code)),
         codes(CrbItem.where(owner: ann).merge(CrbItem.where(owner_id: bob.id))),
         codes(CrbItem.where(owner: ann).unscope(where: :owner_id).order(:code)),
         codes(CrbItem.where(qty: 2).or(CrbItem.where(qty: 5)).merge(CrbItem.where(status: "draft")).order(:code))]
      end
    end
  end

  # What the merge would replace and cannot take off is refused: a
  # condition on several columns at once, an or over the one column, a
  # joined table's condition.
  def test_merge_whose_conditions_replace_what_cannot_be_taken_off_is_refused
    assert_equal %w[a3 a4], run_in(:monitor) { codes(CrbItem.where(status: "active").or(CrbItem.where(status: "archived")).merge(CrbItem.where(status: "draft")).order(:code)) }
    run_in(:es_noproj) do
      assert_raises(UnsupportedQuery) do
        CrbItem.where(status: "active").or(CrbItem.where(status: "archived")).merge(CrbItem.where(status: "draft")).to_a
      end
      with_owners do
        assert_raises(UnsupportedQuery) do
          CrbItem.joins(:owner).where(users: { name: "Ann" }).merge(CrbItem.joins(:owner).where(users: { name: "Bob" })).to_a
        end
      end
      assert_raises(UnsupportedQuery) { CrbItem.where(%i[status qty] => [["draft", 5]]).merge(CrbItem.where(qty: 5)).to_a }
      assert_raises(UnsupportedQuery) { CrbItem.where(qty: 5).merge(where: { status: "draft" }) }
    end
  end

  # nil and false are Active Record's ArgumentError (merge(nil) used to
  # return the relation); an Array is the records both have; a Proc runs on
  # the relation.
  def test_merge_of_nil_false_an_array_or_a_proc
    assert_same_answer do
      [outcome_any { codes(CrbItem.where(status: "active").merge(nil)) },
       outcome_any { codes(CrbItem.where(status: "active").merge(false)) },
       codes(CrbItem.where(status: "draft").merge(CrbItem.where(qty: 5..).to_a)),
       codes(CrbItem.where(status: "draft").merge(-> { where(qty: 2) }))]
    end
  end

  # A window on either side: the other's replaces this one's.
  def test_merge_with_a_window
    assert_same_answer do
      [codes(CrbItem.order(:code).merge(CrbItem.limit(2))),
       codes(CrbItem.order(:code).limit(3).merge(CrbItem.where(status: %w[draft archived]))),
       codes(CrbItem.order(:code).limit(3).merge(CrbItem.offset(1)))]
    end
  end

  # Joined on one side, or both to the same association: the rows of the
  # join that both select (it used to be refused). Joined to different
  # associations: refused.
  def test_merge_of_joined_relations
    assert_same_answer do
      with_owners do
        [codes(CrbItem.joins(:owner).merge(CrbItem.where(status: "draft"))).sort,
         codes(CrbItem.where(status: %w[active draft]).merge(CrbItem.joins(:owner))).sort,
         codes(CrbItem.joins(:owner).merge(CrbItem.joins(:owner).where(qty: 2))).sort,
         CrbItem.where(qty: 1..).merge(CrbItem.joins(:owner).where(users: { name: "Ann" })).count,
         codes(CrbItem.joins(:owner).merge(CrbItem.order(qty: :desc, code: :asc)))]
      end
    end
    run_in(:es_noproj) do
      with_owners { assert_raises(UnsupportedQuery) { CrbItem.joins(:owner).merge(CrbItem.joins(:buyer)).to_a } }
    end
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

  # Kaminari's page(n).per(m) is limit(m).offset((n - 1) * m), and page(n)
  # alone limit(25).offset((n - 1) * 25) (no pagination gem is loaded here:
  # Active Record's answer is that of the limit and offset).
  def test_pagination_window
    expected = run_in(:monitor) do
      rel = CrbItem.order(:code)
      [codes(rel.limit(2).offset(2)), codes(rel.limit(2).offset(4)), codes(rel.limit(2).offset(6)),
       codes(rel.limit(25).offset(0)), codes(rel.limit(25).offset(25)), rel.limit_value, rel.offset_value]
    end
    got = run_in(:es_noproj) do
      rel = CrbItem.order(:code)
      page = rel.page(2).per(2)
      assert_equal [2, 2, 2], [page.current_page, page.limit_value, page.offset_value]
      assert_equal 1, rel.page(0).current_page, "pages start at 1"
      assert_equal [1, 1], [rel.total_pages, rel.current_page], "a relation that is not a page is one page"
      first = rel.page(1).per(nil)
      assert_equal [1, 5, 25], [first.total_pages, first.total_count, first.limit_value], "25 a page by default"
      assert_equal [25, 25, 2], [rel.page(2).limit_value, rel.page(2).offset_value, rel.page(2).current_page]
      [codes(page), codes(rel.page("3").per(2)), codes(rel.page(4).per(2)), codes(rel.page(1)), codes(rel.page(2)),
       rel.limit_value, rel.offset_value]
    end
    assert_equal expected, got
  end

  # Kaminari's page methods (no pagination gem is loaded here: the values are
  # Kaminari 1.2.2's formulas). next_page, prev_page, padding and the others
  # were missing; max_paginates_per on a page set the model's maximum.
  def test_page_navigation_padding_and_maximum
    run_in(:es_noproj) do
      rel = CrbItem.order(:code)
      page = rel.page(2).per(2)
      assert_equal [3, 1, false, false, false], [page.next_page, page.prev_page, page.first_page?, page.last_page?, page.out_of_range?]
      last = rel.page(3).per(2)
      assert_equal [nil, 2, true], [last.next_page, last.prev_page, last.last_page?]
      beyond = rel.page(9).per(2)
      assert_equal [[], true, nil], [codes(beyond), beyond.out_of_range?, beyond.next_page]
      padded = rel.page(1).per(2).padding(1)
      assert_equal [%w[a2 a3], 1, 2], [codes(padded), padded.current_page, padded.total_pages]
      assert_equal %w[a1 a2], codes(rel.page(1).per(4).max_paginates_per(2))
      assert_equal %w[a1 a2 a3], codes(rel.page(1).per(5, max_per_page: 3))
      assert_raises(ArgumentError) { rel.page(1).padding(-1) }

      # entry_name (page_entries_info's) and without_count, on a page only.
      assert_equal ["Crb items", "Crb item"], [page.entry_name, page.entry_name(count: 1)]
      assert_equal [true, true, true, false, false, false],
                   [page.respond_to?(:entry_name), page.respond_to?(:without_count), page.respond_to?(:current_per_page),
                    rel.respond_to?(:entry_name), rel.respond_to?(:without_count), rel.respond_to?(:current_per_page)]
      assert_raises(NoMethodError) { rel.entry_name }
      free = rel.page(3).per(2).without_count
      assert_equal [%w[a5], true, false, nil], [codes(free), free.last_page?, free.out_of_range?, free.next_page]
      assert_equal [false, 3], [rel.page(2).per(2).without_count.last_page?, rel.page(2).per(2).without_count.next_page]
      assert rel.page(4).per(2).without_count.out_of_range?
      assert_raises(RuntimeError) { free.total_count }
    end
  end

  # --- windows: limit and offset, as SQL takes them --------------------------

  # A condition, an order or a scope after a limit or offset applies before
  # the window, and a second limit or offset replaces the first. Each used to
  # act on the window's records.
  def test_query_methods_after_a_window_apply_before_it
    assert_same_answer do
      rel = CrbItem.order(:code)
      [codes(rel.limit(2).where(status: "draft")), codes(rel.limit(2).where.not(status: "active")),
       codes(rel.limit(2).reorder(name: :desc)), codes(rel.limit(2).offset(1)), codes(rel.limit(1).limit(3)),
       codes(rel.offset(1).limit(2)), codes(rel.limit(2).offset(1).offset(3)), codes(rel.limit(2).unscope(:limit)),
       codes(rel.offset(3).unscope(:offset)), codes(rel.limit(2).reverse_order), codes(rel.limit(3).active),
       codes(rel.limit(2).select(:code, :qty).where(qty: 2..)), codes(rel.limit(1).limit(nil))]
    end
  end

  # limit_value and offset_value are the values given (limit_value used to
  # be the page size, nil after a limit).
  def test_limit_value_and_offset_value
    assert_same_answer do
      [CrbItem.limit(3).limit_value, CrbItem.all.limit_value, CrbItem.offset(2).offset_value, CrbItem.all.offset_value,
       CrbItem.limit(2).offset(1).limit_value, CrbItem.order(:code).limit(2).where(qty: 1..).limit_value]
    end
  end

  # COUNT, pluck and the records of a window are the window's; SUM, AVG, MIN
  # and MAX are Active Record's one row of the aggregate, which the window
  # keeps (all the records) or leaves out (an offset, a limit of 0). They used
  # to be the window's.
  def test_aggregates_of_a_window
    assert_same_answer do
      rel = CrbItem.order(:code)
      [rel.limit(2).count, rel.limit(2).offset(1).count, rel.limit(2).count(:price), rel.limit(2).pluck(:code),
       rel.limit(2).sum(:qty), rel.limit(2).offset(1).sum(:qty), rel.limit(0).sum(:qty), rel.limit(2).maximum(:qty),
       rel.offset(1).average(:qty), rel.limit(0).minimum(:qty), rel.limit(3).ids.size, rel.limit(2).size]
    end
  end

  # Grouped, a window is of the groups: refused.
  def test_a_grouped_aggregate_of_a_window_is_refused
    run_in(:es_noproj) { assert_raises(UnsupportedQuery) { CrbItem.limit(2).group(:status).count } }
  end

  # find, find_by and exists? with a condition: the condition applies before
  # the window, whose offset still applies (their own limit replaces its).
  def test_finders_of_a_window
    assert_same_answer do
      rel = CrbItem.order(:code)
      a1 = CrbItem.find_by(code: "a1").id
      a3 = CrbItem.find_by(code: "a3").id
      [codes(rel.limit(2).find_by(status: "draft")), codes(rel.offset(1).find_by(status: "active")),
       rel.offset(1).exists?(code: "a1"), rel.offset(1).exists?(code: "a2"), rel.limit(0).exists?,
       rel.limit(2).exists?(status: "archived"), rel.limit(1).exists?(a3), rel.offset(1).exists?(["qty > ?", 4]),
       outcome { codes(rel.offset(1).find(a1)) }, codes(rel.limit(1).find(a3))]
    end
  end

  def test_writes_of_a_window
    assert_same_answer do
      CrbItem.order(:code).limit(2).update_all(tag: "w")
      CrbItem.order(:code).offset(3).where(status: %w[draft archived]).update_all(name: "late")
      state
    end
  end

  # or of two windows: the same window of both conditions; different
  # windows, Active Record's ArgumentError.
  def test_or_of_windows
    assert_same_answer do
      rel = CrbItem.order(:code)
      [codes(rel.limit(2).where(status: "active").or(rel.limit(2).where(status: "draft"))),
       outcome_any { codes(rel.limit(2).or(rel.where(status: "draft"))) },
       outcome_any { codes(rel.where(status: "draft").or(rel.limit(2))) }]
    end
  end

  # --- only, reselect, unscope(:select) ----------------------------------------

  # As Active Record's only: the parts named are kept, the rest taken off.
  # It used to be refused (except only(:joins), which kept everything).
  def test_only
    assert_same_answer do
      rel = CrbItem.where(status: %w[active draft]).order(code: :desc).limit(1)
      [codes(rel.only(:where)).sort, codes(rel.only(:where, :order)), codes(rel.only(:order, :limit)),
       codes(rel.only).sort, codes(rel.only(:joins)).sort, codes(CrbItem.select(:code).where(qty: 2).only(:select)).sort,
       CrbItem.where(qty: 2).select(:code).only(:where).map(&:name).sort,
       codes(CrbItem.where(qty: 2).offset(1).only(:offset, :order).order(:code)),
       CrbItem.where(status: "draft").create_with(tag: "c").only(:where).new.tag]
    end
  end

  # Without its joins, a joined relation's records are not the join's rows:
  # refused.
  def test_only_without_the_joins_of_a_joined_relation_is_refused
    run_in(:es_noproj) { with_owners { assert_raises(UnsupportedQuery) { CrbItem.joins(:owner).only(:order) } } }
  end

  # reselect replaces the columns (it did nothing); a second select adds to
  # the first (it replaced it); unscope(:select) brings every column back.
  def test_reselect_select_and_unscope_select
    assert_same_answer do
      [CrbItem.select(:name).reselect(:qty, :code).order(:code).map { [_1.code, _1.qty] },
       CrbItem.select(:code).select(:qty).order(:code).map { [_1.code, _1.qty] },
       CrbItem.select(:code).unscope(:select).order(:code).map(&:name),
       outcome_any { CrbItem.select(:code).reselect },
       outcome_any { CrbItem.select }]
    end
  end

  # unscope(:where) of an SQL fragment cannot be replayed: refused (it used
  # to keep the fragment's condition).
  def test_unscope_where_of_an_sql_fragment_is_refused
    assert_equal %w[a1 a2 a3 a4 a5], run_in(:monitor) { codes(CrbItem.where("qty > ?", 2).unscope(:where).order(:code)) }
    run_in(:es_noproj) do
      assert_raises(UnsupportedQuery) { CrbItem.where("qty > ?", 2).unscope(:where) }
      assert_raises(UnsupportedQuery) { CrbItem.where("qty > ?", 2).unscope(where: :qty) }
    end
  end

  # --- batches -----------------------------------------------------------------

  # By primary key, the relation's order ignored, as Active Record batches
  # (they used to follow the order): each in_batches batch is the relation
  # narrowed to the batch's records, in the relation's order.
  def test_batches_go_by_primary_key
    assert_same_answer do
      rel = CrbItem.order(name: :desc)
      a2 = CrbItem.find_by(code: "a2").id
      a4 = CrbItem.find_by(code: "a4").id
      batches = []
      rel.in_batches(of: 2) { |batch| batches << batch.pluck(:code) }
      loaded = []
      rel.in_batches(of: 2, load: true) { |batch| loaded << batch.map(&:code) }
      [batches, loaded, rel.find_in_batches(batch_size: 2).map { |b| b.map(&:code) },
       rel.find_each(batch_size: 2).map(&:code), rel.find_each(start: a2, finish: a4).map(&:code),
       rel.find_each(order: :desc, batch_size: 3).map(&:code), rel.limit(3).find_each(batch_size: 2).map(&:code),
       rel.find_in_batches(batch_size: 2).size, rel.find_each.size, rel.find_each { nil },
       rel.find_in_batches(batch_size: 2) { nil }]
    end
  end

  # Without a block, in_batches is Active Record's BatchEnumerator (it raised
  # LocalJumpError).
  def test_in_batches_without_a_block_is_a_batch_enumerator
    assert_same_answer do
      rel = CrbItem.order(name: :desc)
      enum = rel.in_batches(of: 2)
      [enum.class.name, enum.map { |batch| batch.pluck(:code) }, enum.each_record.map(&:code), enum.batch_size,
       CrbItem.where(status: %w[active draft]).in_batches(of: 3).update_all(tag: "b"), state]
    end
  end

  def test_batch_options_active_record_refuses
    assert_same_answer do
      rel = CrbItem.order(:code)
      [outcome_any { rel.find_each(error_on_ignore: true).to_a }, outcome_any { rel.in_batches(order: :up) },
       outcome_any { rel.find_each(cursor: :name).to_a }, outcome_any { rel.find_each(start: [1, 2]).to_a },
       rel.find_each(cursor: :code, order: :desc).map(&:code)]
    end
  end

  # Active Record applies an offset to each batch's query: so does
  # ES-NoProj (it was refused).
  def test_batches_of_a_relation_with_an_offset_skip_it_in_every_batch
    assert_same_answer do
      [CrbItem.offset(1).find_each(batch_size: 2).map(&:code), CrbItem.order(:code).offset(1).in_batches(of: 2).map { codes(_1) }]
    end
  end

  # --- writes by id, counters ----------------------------------------------------

  # relation.update(id, ...) is Active Record's model.update(id, ...): the
  # record is updated even outside the relation (it used to be RecordNotFound).
  def test_update_by_id_outside_the_relation
    assert_same_answer do
      id = CrbItem.find_by(code: "a4").id
      a5 = CrbItem.find_by(code: "a5").id
      [codes(CrbItem.where(status: "active").update(id, name: "never")),
       codes(CrbItem.where(status: "active").update!(a5, tag: "z")), state]
    end
  end

  # Nothing to change is Active Record's ArgumentError (it returned 0);
  # touch alone is a change.
  def test_update_counters_with_nothing_to_change
    assert_same_answer do
      [outcome_any { CrbItem.where(status: "draft").update_counters({}) },
       CrbItem.where(status: "draft").update_counters(touch: true)]
    end
  end

  # --- scopes --------------------------------------------------------------------

  # A scope with an Arel condition answers the same on the model and on a
  # relation (it was refused on the model).
  def test_arel_scopes_on_the_model_and_on_a_relation
    assert_same_answer do
      [codes(CrbItem.arel_eq.order(:code)), codes(CrbItem.arel_in.order(:code)),
       codes(CrbItem.where(qty: 1..).arel_eq.order(:code)), codes(CrbItem.order(:code).arel_in.where(status: "active"))]
    end
  end

  # A scope whose body returns a value returns it, as Active Record's (on
  # the model it returned the relation; on a relation it was refused).
  def test_a_scope_returning_a_value
    assert_same_answer do
      [CrbItem.draft_count, CrbItem.where(qty: 5).draft_count, codes(CrbItem.first_by_code),
       codes(CrbItem.where(status: "draft").first_by_code), codes(CrbItem.where(qty: 1).built_on_unscoped.order(:code))]
    end
  end

  # --- a default scope ------------------------------------------------------------

  # A model with a default scope: unscope, rewhere, only and merge replay the
  # relation's plan from its default scope, taking off what they take off,
  # as Active Record rebuilds its query.
  def test_a_default_scope_replayed
    Object.send(:remove_const, :CrbKept) if Object.const_defined?(:CrbKept)
    Object.const_set(:CrbKept, Class.new(ActiveRecord::Base) do
      self.table_name = TABLE
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
      default_scope { where(status: %w[active draft]).order(:code) }
    end)
    Lyra.config.monitor_model(CrbKept)

    assert_same_answer do
      CrbItem.delete_all
      ROWS.each { |row| CrbKept.unscoped.create!(row) }
      archived = CrbKept.unscope(where: :status).where(status: "archived")
      [codes(CrbKept.where(qty: 2..).unscope(where: :status)), codes(CrbKept.where(qty: 3).rewhere(status: "archived")),
       codes(CrbKept.where(qty: 2..).only(:where)).sort, codes(CrbKept.unscope(where: :status).merge(archived)),
       codes(CrbKept.where(status: "active").merge(archived)), codes(CrbKept.where(qty: 2..).merge(CrbKept.where(qty: 5)))]
    end
  ensure
    Object.send(:remove_const, :CrbKept) if Object.const_defined?(:CrbKept)
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

  # A scope's where.not of a list (a NOT IN) runs on the relation, as a
  # where.not does (built as an Active Record relation, it could not be read,
  # and was refused).
  def test_a_scope_of_a_not_in
    assert_same_answer { [codes(CrbItem.where(status: "draft").not_small), codes(CrbItem.not_small.order(:code))] }
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

  # Any error, by class (UnsupportedQuery is not one Active Record raises).
  def outcome_any
    yield
  rescue StandardError => e
    [:raised, e.class.name]
  end

  # Two owners (users), Ann of a1 and a3, Bob of a4.
  def with_owners
    ann = User.create!(name: "Ann", email: "ann-crb@example.com")
    bob = User.create!(name: "Bob", email: "bob-crb@example.com")
    { "a1" => ann, "a3" => ann, "a4" => bob }.each { |code, user| CrbItem.find_by(code: code).update!(owner_id: user.id) }
    yield
  ensure
    connection.execute("DELETE FROM users WHERE email LIKE '%-crb@example.com'")
  end

  def clean
    connection.execute("DELETE FROM #{TABLE}") if connection.table_exists?(TABLE)
    connection.execute("DELETE FROM event_store_events_in_streams")
    connection.execute("DELETE FROM event_store_events")
    Lyra::Projections::CachedProjection.invalidate_all(CrbItem) if Object.const_defined?(:CrbItem)
  end

  def connection = ActiveRecord::Base.connection
end
