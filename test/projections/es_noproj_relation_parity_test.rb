# frozen_string_literal: true

require "test_helper"

# ES-NoProj (CachedRelation) against Active Record on about two hundred
# relation queries: windows (limit, offset, pages), merge, only, unscope,
# select, batches, scopes, or, writes through a relation, belongs_to and
# joined conditions. Each group runs its queries on the same rows in
# Monitor (Active Record and PostgreSQL) and in ES-NoProj; every answer must
# be equal, except those ES-NoProj refuses (UnsupportedQuery), listed in
# REFUSED with what Active Record does there. These came from an
# independent review's probe of the relation work for 1.0.0; each was a
# silent difference or a refusal before it.
class EsNoprojRelationParityTest < Minitest::Test
  TABLE = "lyra_pr_items"
  UQ = Lyra::Projections::UnsupportedQuery
  ROWS = [
    { code: "a1", name: "pear", status: "active", qty: 2, price: BigDecimal("1.50"), tag: "x" },
    { code: "a2", name: "apple", status: "active", qty: 1, price: BigDecimal("2.00"), tag: nil },
    { code: "a3", name: "fig", status: "draft", qty: 2, price: BigDecimal("3.25"), tag: "y" },
    { code: "a4", name: "kiwi", status: "draft", qty: 5, price: nil, tag: nil },
    { code: "a5", name: "date", status: "archived", qty: 3, price: BigDecimal("0.75"), tag: "x" },
    { code: "a6", name: "lime", status: "active", qty: 4, price: BigDecimal("1.00"), tag: "z" },
    { code: "a7", name: "plum", status: "draft", qty: 1, price: BigDecimal("4.00"), tag: "x" }
  ].freeze

  def setup
    c = connection
    c.create_table(TABLE, force: true) do |t|
      t.string :code
      t.string :name
      t.string :status
      t.integer :qty
      t.decimal :price, precision: 10, scale: 2
      t.string :tag
      t.integer :owner_id
      t.timestamps
    end
    c.add_index TABLE, :code, unique: true
    Object.send(:remove_const, :PrItem) if Object.const_defined?(:PrItem)
    Object.const_set(:PrItem, Class.new(ActiveRecord::Base) do
      self.table_name = TABLE
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
      scope :active, -> { where(status: "active") }
      scope :explicit_drafts, -> { PrItem.where(status: "draft") }
      scope :bang_limit, -> { limit!(1) }
      scope :arel_q2, -> { where(arel_table[:qty].eq(2)) }
      scope :cnt, -> { count }
      belongs_to :owner, class_name: "User", optional: true
    end)
    PrItem.reset_column_information
    clean
    Lyra.config.monitor_model(PrItem)
  end

  def teardown
    Lyra.config.enable_monitor!
    Lyra.config.projection_mode = :sync
    clean
    connection.drop_table(TABLE, if_exists: true)
  end

  def c(v)
    case v
    when nil then nil
    when ActiveRecord::Base then v.code
    when Hash then v
    when Enumerable then v.map { |x| x.is_a?(ActiveRecord::Base) ? x.code : x }
    else v
    end
  end


  def id_of(code)
    PrItem.find_by(code: code).id
  end

  CASES = {
    w_where: -> { c PrItem.order(:code).limit(2).where(status: "draft") },
    w_where_not: -> { c PrItem.order(:code).limit(2).where.not(status: "active") },
    w_offset_limit: -> { c PrItem.order(:code).offset(1).limit(2) },
    w_limit_limit: -> { c PrItem.order(:code).limit(1).limit(3) },
    w_limit_offset: -> { c PrItem.order(:code).limit(2).offset(1) },
    w_order_after: -> { c PrItem.order(:qty).limit(3).order(:code) },
    w_reorder_after: -> { c PrItem.order(:code).limit(3).reorder(:name) },
    w_reverse: -> { c PrItem.order(:code).limit(3).reverse_order },
    w_count: -> { [PrItem.order(:code).limit(3).count, PrItem.limit(3).offset(5).count, PrItem.limit(0).count, PrItem.offset(5).count] },
    w_count_col: -> { PrItem.order(:code).limit(4).count(:tag) },
    w_size: -> { [PrItem.limit(3).size, PrItem.limit(3).empty?, PrItem.limit(0).empty?, PrItem.limit(1).any?, PrItem.limit(1).many?, PrItem.limit(2).many?, PrItem.limit(1).one?] },
    w_exists: -> { [PrItem.limit(0).exists?, PrItem.offset(7).exists?, PrItem.offset(6).exists?, PrItem.order(:code).limit(2).exists?(code: "a5"), PrItem.order(:code).offset(4).exists?(status: "active"), PrItem.order(:code).offset(1).exists?(status: "archived")] },
    w_exists_id: -> { [PrItem.order(:code).limit(1).exists?(PrItem.find_by(code: "a5").id), PrItem.order(:code).offset(1).exists?(PrItem.find_by(code: "a5").id)] },
    w_pluck: -> { [PrItem.order(:code).limit(2).pluck(:code), PrItem.order(:code).offset(5).pick(:code), PrItem.order(:code).limit(2).ids.size] },
    w_finders: -> { r = PrItem.order(:code).limit(3); [c(r.first), c(r.last), c(r.second), c(r.third), c(r.take), c(r.first(2)), c(r.last(2)), c(r.offset(1).first), c(r.offset(1).last)] },
    w_finders_unordered: -> { r = PrItem.order(:qty, :code).limit(4).offset(1); [c(r.first), c(r.last), c(r.second)] },
    w_find: -> { r = PrItem.order(:code).limit(2); [c(r.find(PrItem.find_by(code: "a5").id)), c(r.find_by(code: "a6")), c(r.offset(1).find_by(code: "a1")), c(r.find_by(status: "draft"))] },
    w_find_offset_raise: -> { begin; c PrItem.order(:code).offset(1).find(PrItem.find_by(code: "a1").id); rescue ActiveRecord::RecordNotFound => e; [:raised, e.class.name]; end },
    w_find_many: -> { begin; c PrItem.order(:code).limit(1).find(PrItem.find_by(code: "a1").id, PrItem.find_by(code: "a2").id); rescue => e; [:raised, e.class.name]; end },
    w_sum: -> { [PrItem.order(:code).limit(2).sum(:qty), PrItem.offset(1).sum(:qty), PrItem.limit(0).sum(:qty)] },
    w_aggs: -> { r = PrItem.order(:code).limit(2); [r.average(:qty)&.to_f, r.minimum(:qty), r.maximum(:qty), PrItem.offset(1).maximum(:qty), PrItem.limit(0).minimum(:qty)] },
    w_calc: -> { [PrItem.order(:code).limit(2).calculate(:sum, :qty), PrItem.order(:code).limit(2).calculate(:count, :all)] },
    w_nested: -> { c PrItem.order(:code).limit(4).offset(1).limit(2) },
    w_nested2: -> { c PrItem.order(:code).offset(2).offset(1) },
    w_or_same: -> { c PrItem.order(:code).limit(2).where(status: "archived").or(PrItem.order(:code).limit(2).where(status: "draft")) },
    w_or_diff: -> { begin; c PrItem.limit(2).or(PrItem.limit(3)); rescue ArgumentError => e; [:raised, e.class.name]; end },
    w_or_one: -> { begin; c PrItem.where(status: "active").or(PrItem.where(status: "draft").limit(2)); rescue ArgumentError => e; [:raised, e.class.name]; end },
    w_unscope_limit: -> { c PrItem.order(:code).where(status: "active").limit(1).unscope(:limit) },
    w_unscope_offset: -> { c PrItem.order(:code).offset(5).unscope(:offset) },
    w_unscope_where: -> { c PrItem.order(:code).where(status: "draft").limit(2).unscope(:where) },
    w_unscope_where_col: -> { c PrItem.order(:code).where(status: "draft").limit(2).unscope(where: :status) },
    w_scope: -> { c PrItem.order(:code).limit(2).active },
    w_merge: -> { c PrItem.order(:code).limit(2).merge(PrItem.where(status: "draft")) },
    w_merge_window: -> { c PrItem.order(:code).limit(2).merge(PrItem.offset(1)) },
    w_merge_window2: -> { c PrItem.order(:code).limit(2).offset(1).merge(PrItem.limit(3)) },
    w_string: -> { c PrItem.order(:code).limit("2") },
    w_limit_nil: -> { c PrItem.order(:code).limit(2).limit(nil) },
    w_values: -> { r = PrItem.order(:code).limit(2).offset(1); [r.limit_value, r.offset_value, PrItem.limit(3).offset_value, PrItem.offset(2).limit_value, r.where(qty: 1).limit_value] },
    w_distinct: -> { c PrItem.order(:code).limit(3).distinct },
    w_select: -> { r = PrItem.order(:code).limit(2).select(:code, :id); [r.map { _1.attributes.keys.sort }, c(r)] },
    w_group_count: -> { begin; PrItem.order(:status).limit(2).group(:status).count; rescue UQ; [:refused]; end },
    w_includes_where: -> { c PrItem.order(:code).limit(2).includes(:owner).where(status: "draft") },
    w_preload_where: -> { c PrItem.order(:code).limit(2).preload(:owner).where(status: "draft") },
    w_eager_where: -> { c PrItem.order(:code).limit(2).references(:owner).where(status: "draft") },
    w_readonly_where: -> { c PrItem.order(:code).limit(2).readonly.where(status: "draft") },
    w_none: -> { c PrItem.limit(2).none.where(status: "draft") },
    w_all_where: -> { c PrItem.order(:code).limit(2).all.where(status: "draft") },
    w_extending_where: -> { c PrItem.order(:code).limit(2).extending(Module.new).where(status: "draft") },
    w_rewhere: -> { c PrItem.order(:code).where(status: "draft").limit(1).rewhere(status: "active") },
    w_find_each: -> { PrItem.order(:code).limit(3).find_each.map(&:code) },
    w_in_batches_limit: -> { PrItem.limit(5).in_batches(of: 2).map { |b| c(b) } },
    w_where_missing: -> { c PrItem.order(:code).limit(2).where.missing(:owner) },
    w_lazy_bang: -> { r = PrItem.order(:code).limit(2); r2 = r.where(status: "draft"); [c(r), c(r2)] },
    m_replace: -> { c PrItem.order(:code).where(status: "active").merge(PrItem.where(status: "draft")) },
    m_replace_keep_other: -> { c PrItem.order(:code).where(status: "active", qty: 2).merge(PrItem.where(status: "draft")) },
    m_intersect: -> { c PrItem.order(:code).where(qty: 2).merge(PrItem.where(status: "draft")) },
    m_not_self: -> { c PrItem.order(:code).where.not(status: "active").merge(PrItem.where(status: "draft")) },
    m_not_other: -> { c PrItem.order(:code).where(status: "draft").merge(PrItem.where.not(status: "draft")) },
    m_fragment_self: -> { c PrItem.order(:code).where("qty > 1").merge(PrItem.where(qty: 2)) },
    m_fragment_other: -> { c PrItem.order(:code).where(qty: 2).merge(PrItem.where("qty > ?", 1)) },
    m_or_self: -> { c PrItem.order(:code).where(status: "active").or(PrItem.where(qty: 5)).merge(PrItem.where(status: "draft")) },
    m_or_same_col: -> { c PrItem.order(:code).where(status: "active").or(PrItem.where(status: "archived")).merge(PrItem.where(status: "draft")) },
    m_order: -> { c PrItem.order(:status).merge(PrItem.order(:code)) },
    m_reorder: -> { c PrItem.order(:status).merge(PrItem.reorder(:code)) },
    m_limit_other: -> { c PrItem.order(:code).where(status: "active").merge(PrItem.limit(1)) },
    m_where_limit_other: -> { c PrItem.order(:code).merge(PrItem.where(status: "draft").limit(1)) },
    m_group: -> { PrItem.where(status: "active").merge(PrItem.group(:status)).count },
    m_select: -> { PrItem.where(status: "active").merge(PrItem.select(:code)).map { _1.attributes.keys.sort } },
    m_distinct_count: -> { PrItem.where(status: "active").merge(PrItem.select(:status).distinct).to_a.size },
    m_array: -> { c PrItem.order(:code).where(status: "active").merge(PrItem.where(qty: 2).to_a) },
    m_proc: -> { c PrItem.order(:code).where(qty: 2).merge(-> { where(status: "draft") }) },
    m_nil: -> { begin; PrItem.all.merge(nil); rescue ArgumentError => e; [:raised, e.class.name]; end },
    m_rest: -> { c PrItem.order(:code).where(status: "active").merge(PrItem.where(status: "draft"), PrItem.where(qty: 5)) },
    m_rewhere_opt: -> { c PrItem.order(:code).where(status: "active").merge(PrItem.where(status: "draft"), rewhere: true) },
    m_list: -> { c PrItem.order(:code).where(status: %w[active draft]).merge(PrItem.where(status: "active")) },
    m_same: -> { c PrItem.order(:code).where(status: "active").merge(PrItem.where(status: "active").where(qty: 1)) },
    m_range: -> { c PrItem.order(:code).where(qty: 1..3).merge(PrItem.where(qty: 5)) },
    m_table_key: -> { c PrItem.order(:code).where("lyra_pr_items.status" => "active").merge(PrItem.where(status: "draft")) },
    m_string_key: -> { c PrItem.order(:code).where("status" => "active").merge(PrItem.where(status: "draft")) },
    m_twice_same_col: -> { c PrItem.order(:code).where(status: %w[active draft]).where(status: "draft").merge(PrItem.where(status: "active")) },
    m_scope_other: -> { c PrItem.order(:code).where(status: "draft").merge(PrItem.active) },
    m_none: -> { c PrItem.where(status: "active").merge(PrItem.none) },
    m_create_with: -> { PrItem.where(status: "active").merge(PrItem.create_with(tag: "q")).new.tag },
    m_unscope_other: -> { c PrItem.order(:code).where(status: "active").merge(PrItem.where(qty: 2).unscope(where: :qty)) },
    m_bang: -> { r = PrItem.order(:code).where(status: "active"); r.merge!(PrItem.where(status: "draft")); c r },
    m_ar_rel: -> { c PrItem.order(:code).where(status: "active").merge(Lyra::ModeTransition.send(:bypass) { PrItem.unscoped.where(status: "draft") }) },
    m_window_of_merged_with_where: -> { c PrItem.order(:code).merge(PrItem.limit(2)).where(status: "draft") },
    o_only_where: -> { c(PrItem.where(status: "draft").order(:code).limit(1).only(:where)).sort },
    o_only_order: -> { c PrItem.where(status: "draft").order(:code).only(:order) },
    o_only_both: -> { c PrItem.where(status: "draft").order(:name).limit(1).only(:order, :where) },
    o_only_limit: -> { c(PrItem.where(status: "draft").order(:name).limit(1).only(:limit)).size },
    o_only_none: -> { c(PrItem.where(status: "draft").order(:name).only).size },
    o_only_limit_order: -> { c PrItem.where(status: "draft").order(:name).limit(2).offset(1).only(:limit, :order, :offset) },
    o_select2: -> { PrItem.select(:code).select(:name).first.attributes.keys.sort },
    o_reselect: -> { PrItem.select(:code).reselect(:name).first.attributes.keys.sort },
    o_unscope_select: -> { PrItem.select(:code).unscope(:select).first.attributes.keys.sort },
    o_unscope_group: -> { PrItem.group(:status).unscope(:group).count },
    o_unscope_frag: -> { begin; c(PrItem.where("qty > ?", 2).unscope(:where)).size; rescue UQ; [:refused]; end },
    o_unscope_frag_col: -> { begin; c(PrItem.where("qty > ?", 2).where(status: "draft").unscope(where: :status)).sort; rescue UQ; [:refused]; end },
    o_unscope_frag_other_col: -> { begin; c(PrItem.where("tag = 'x'").where(status: "draft").unscope(where: :status)).sort; rescue UQ; [:refused]; end },
    o_unscope_where: -> { c(PrItem.where(status: "draft").unscope(:where)).size },
    o_unscope_where_col: -> { c PrItem.order(:code).where(status: "draft").where(qty: 5).unscope(where: :qty) },
    o_select_empty: -> { begin; PrItem.select; rescue ArgumentError => e; [:raised, e.class.name]; end },
    o_select_where: -> { PrItem.select(:code).where(status: "draft").order(:code).map { _1.attributes.keys.sort } },
    o_select_group: -> { PrItem.select(:status).group(:status).unscope(:where).count },
    o_except_order: -> { c PrItem.where(status: "draft").order(:name).limit(2).except(:limit).order(:code) },
    o_reselect_where_unscope: -> { begin; c PrItem.order(:code).select(:code).where(status: "draft").reselect(:code, :name).unscope(where: :status).limit(2); rescue UQ; [:refused]; end },
    b_find_each: -> { PrItem.order(:name).find_each.map(&:code) },
    b_fib: -> { PrItem.order(:name).find_in_batches(batch_size: 3).map { |b| c(b) } },
    b_in_batches: -> { PrItem.order(:name).in_batches(of: 3).map { |b| c(b) } },
    b_in_batches_load: -> { PrItem.where(status: "draft").order(:name).in_batches(of: 2, load: true).map { |b| c(b) } },
    b_start_finish: -> { PrItem.find_each(start: PrItem.find_by(code: "a2").id, finish: PrItem.find_by(code: "a5").id).map(&:code) },
    b_desc: -> { PrItem.find_each(order: :desc, batch_size: 2).map(&:code) },
    b_desc_start: -> { PrItem.find_each(order: :desc, start: PrItem.find_by(code: "a5").id).map(&:code) },
    b_sizes: -> { [PrItem.find_each(batch_size: 3).size, PrItem.find_in_batches(batch_size: 3).size, PrItem.where(status: "draft").find_each.size] },
    b_err: -> { begin; PrItem.order(:name).find_each(error_on_ignore: true) { }; :none; rescue ArgumentError => e; [:raised, e.class.name]; end },
    b_cursor: -> { PrItem.find_each(cursor: :code, order: :desc).map(&:code) },
    b_cursor_bad: -> { begin; PrItem.find_each(cursor: :name) { }; :ok; rescue ArgumentError => e; [:raised, e.message]; end },
    b_each_record: -> { PrItem.where(status: "active").in_batches(of: 2).each_record.map(&:code) },
    b_enum_each: -> { PrItem.in_batches(of: 3).each.map { |r| r.size } },
    b_batch_count: -> { PrItem.in_batches(of: 3).map(&:count) },
    b_batch_where: -> { PrItem.in_batches(of: 3).map { |r| c(r.where(status: "draft")) } },
    b_where_fib: -> { PrItem.where(status: %w[active draft]).find_in_batches(batch_size: 2, start: PrItem.find_by(code: "a2").id).map { c(_1) } },
    b_limit_start: -> { PrItem.limit(2).find_each(start: PrItem.find_by(code: "a3").id).map(&:code) },
    b_enum_lazy: -> { PrItem.find_each.with_index.map { |r, n| "#{r.code}#{n}" } },
    b_in_batches_enum_size: -> { PrItem.in_batches(of: 3).to_a.size },
    s_class: -> { [c(PrItem.active), c(PrItem.where(qty: 2).active), c(PrItem.arel_q2), c(PrItem.where(status: "draft").arel_q2), PrItem.cnt, PrItem.where(status: "draft").cnt] },
    s_explicit: -> { c PrItem.where(status: "active").explicit_drafts.order(:code) },
    s_bang: -> { r = PrItem.order(:code).where(status: "active"); r.bang_limit; c r },
    s_scoping: -> { r = PrItem.where(status: "draft"); [c(r.scoping { PrItem.active.to_a }), c(r.scoping { PrItem.where(qty: 5) })] },
    s_scoping_exc: -> { begin; PrItem.where(status: "draft").scoping { raise "boom" }; rescue StandardError; nil; end; PrItem.count },
    s_scoping_thread: -> { r = PrItem.where(status: "draft"); r.scoping { Thread.new { PrItem.count }.value } },
    s_scoping_fiber: -> { r = PrItem.where(status: "draft"); r.scoping { Fiber.new { PrItem.count }.resume } },
    s_scoping_enum: -> { r = PrItem.where(status: "draft"); r.scoping { e = Enumerator.new { |y| y << PrItem.count }; e.next } },
    or_order_unwindowed: -> { c PrItem.order(:code).where(status: "archived").or(PrItem.order(:code).where(status: "draft")) },
    or_order_plain: -> { c PrItem.order(:name).where(status: "archived").or(PrItem.where(status: "draft")) },
    or_window_then: -> { c PrItem.order(:code).where(status: "archived").or(PrItem.order(:code).where(status: "draft")).limit(2) },
    j_merge_replace: -> { c PrItem.joins(:owner).where(users: { name: "Ann" }).merge(PrItem.joins(:owner).where(users: { name: "Bob" })).order(:code) },
    j_merge_one_side: -> { c PrItem.where(status: "draft").merge(PrItem.joins(:owner)).order(:code) },
    j_merge_other_side: -> { c PrItem.joins(:owner).merge(PrItem.where(status: "draft")).order(:code) },
    j_merge_both_where: -> { c PrItem.joins(:owner).where(status: "active").merge(PrItem.joins(:owner).where(status: "draft")).order(:code) },
    j_merge_user_rel: -> { begin; c PrItem.joins(:owner).merge(User.where(name: "Ann")).order(:code); rescue => e; [:raised, e.class.name]; end },
    m_belongs_to: -> { ann = User.find_by(name: "Ann"); bob = User.find_by(name: "Bob"); c PrItem.where(owner: ann).merge(PrItem.where(owner_id: bob.id)).order(:code) },
    m_belongs_to2: -> { ann = User.find_by(name: "Ann"); bob = User.find_by(name: "Bob"); c PrItem.where(owner_id: ann.id).merge(PrItem.where(owner: bob)).order(:code) },
    m_not_self_other_col: -> { c PrItem.order(:code).where.not(status: "active").merge(PrItem.where(qty: 2)) },
    m_window_then_merge_where: -> { c PrItem.order(:code).limit(3).merge(PrItem.where(status: "active")) },
    m_merge_page_like: -> { c PrItem.where(status: "active").merge(PrItem.order(:code).limit(1).offset(1)) },
    m_count_after_merge_limit: -> { PrItem.where(status: "active").merge(PrItem.limit(2)).count },
    s_scope_on_window: -> { c PrItem.order(:code).limit(3).active },
    s_scope_count_on_rel: -> { PrItem.where(qty: 2).cnt },
    s_arel_on_window: -> { c PrItem.order(:code).limit(2).arel_q2 },
    s_chain_scopes: -> { c PrItem.active.arel_q2 },
    u_relation_update_outside: -> { reseed!; id = PrItem.find_by(code: "a4").id; r = PrItem.where(status: "active").update(id, name: "zz"); [c(r), state] },
    u_relation_update_ids: -> { reseed!; ids = %w[a1 a4].map { PrItem.find_by(code: _1).id }; r = PrItem.where(status: "active").update(ids, [{ name: "q1" }, { name: "q4" }]); [c(r), state] },
    u_relation_update_missing: -> { reseed!; begin; PrItem.where(status: "active").update(999_999, name: "zz"); rescue ActiveRecord::RecordNotFound => e; [:raised, e.class.name]; end },
    u_update_bang: -> { reseed!; id = PrItem.find_by(code: "a5").id; PrItem.none.update!(id, tag: "w"); state },
    u_counters_empty: -> { begin; PrItem.where(status: "active").update_counters({}); rescue ArgumentError => e; [:raised, e.message]; end },
    wr_window_update_all: -> { reseed!; PrItem.order(:code).limit(2).where(status: "draft").update_all(tag: "z"); state },
    wr_window_delete_all: -> { reseed!; begin; PrItem.order(:code).offset(5).delete_all; rescue => e; [:raised, e.class.name]; end; state },
    wr_window_destroy_all: -> { reseed!; PrItem.order(:code).limit(2).where(status: "draft").destroy_all; state },
    wr_merge_update_all: -> { reseed!; PrItem.where(status: "active").merge(PrItem.where(status: "draft")).update_all(tag: "m"); state },
    wr_in_batches_update: -> { reseed!; PrItem.where(status: "active").in_batches(of: 2).update_all(tag: "b"); state },
    wr_in_batches_delete: -> { reseed!; PrItem.where(status: "draft").in_batches(of: 2).delete_all; state },
    wr_batch_rel_update: -> { reseed!; PrItem.order(:name).in_batches(of: 3) { |b| b.where(status: "draft").update_all(tag: "c") }; state },
    wr_only_update: -> { reseed!; PrItem.where(status: "draft").order(:code).limit(1).only(:where).update_all(tag: "o"); state },
    wr_page_update: -> { reseed!; r = begin; PrItem.order(:code).limit(2).offset(2).update_all(tag: "p"); rescue => e; [:raised, e.class.name, e.message[0,150]]; end; [r, state.map { _1[4] }] },
    wr_offset_delete: -> { reseed!; r = begin; PrItem.order(:code).offset(5).delete_all; rescue => e; [:raised, e.class.name, e.message[0,150]]; end; [r, state.map(&:first)] },
    wr_limit_update: -> { reseed!; r = begin; PrItem.order(:code).limit(2).update_all(tag: "p"); rescue => e; [:raised, e.class.name, e.message[0,150]]; end; [r, state.map { _1[4] }] },
    bt_unscope: -> { ann = User.find_by(name: "Ann"); c PrItem.order(:code).where(owner: ann).unscope(where: :owner_id) },
    bt_merge_same: -> { ann = User.find_by(name: "Ann"); c PrItem.order(:code).where(owner: ann).merge(PrItem.where(owner_id: ann.id)) },
    bt_merge_other: -> { ann = User.find_by(name: "Ann"); bob = User.find_by(name: "Bob"); c PrItem.order(:code).where(owner: ann).merge(PrItem.where(owner_id: bob.id)) },
    bt_merge_other_sym: -> { ann = User.find_by(name: "Ann"); bob = User.find_by(name: "Bob"); c PrItem.order(:code).where(owner: ann).merge(PrItem.where(owner: bob)) },
    j_merge_replace_str: -> { c PrItem.joins(:owner).where("users.name" => "Ann").merge(PrItem.joins(:owner).where("users.name" => "Bob")).order(:code) },
    j_merge_replace_one: -> { c PrItem.joins(:owner).where(users: { name: "Ann" }).merge(PrItem.where(status: "draft")).merge(PrItem.joins(:owner).where(users: { name: "Bob" })).order(:code) },
    j_merge_ar_other: -> { begin; c PrItem.joins(:owner).where(users: { name: "Ann" }).merge(Lyra::ModeTransition.send(:bypass) { PrItem.unscoped.joins(:owner).where(users: { name: "Bob" }) }).order(:code); rescue => e; [:raised, e.class.name]; end },
    m_not_list: -> { c PrItem.order(:code).where.not(status: %w[active draft]).merge(PrItem.where(status: "draft")) },
    m_scope_or: -> { c PrItem.order(:code).where(qty: 2).or(PrItem.where(qty: 5)).merge(PrItem.where(qty: 1)) },
    m_twice_merge: -> { c PrItem.order(:code).where(status: "active").merge(PrItem.where(status: "draft")).merge(PrItem.where(status: "archived")) },
    m_merge_then_unscope: -> { c PrItem.order(:code).where(status: "active").merge(PrItem.where(qty: 2)).unscope(where: :qty) },
    m_merge_then_rewhere: -> { c PrItem.order(:code).where(status: "active").merge(PrItem.where(status: "draft")).rewhere(status: "archived") },
    m_window_merge_ar_limit: -> { c PrItem.order(:code).limit(2).merge(Lyra::ModeTransition.send(:bypass) { PrItem.unscoped.limit(5) }) },
    m_window_merge_ar_where_limit: -> { c PrItem.order(:code).limit(1).merge(Lyra::ModeTransition.send(:bypass) { PrItem.unscoped.where(status: "draft").limit(3) }) },
    m_merge_ar_limit_plain: -> { c PrItem.order(:code).merge(Lyra::ModeTransition.send(:bypass) { PrItem.unscoped.limit(3) }) },
    s_scope_limit_on_window: -> { c PrItem.order(:code).limit(2).bang_limit }
  }.freeze

  # Answered by Active Record, refused by ES-NoProj rather than answered
  # differently.
  REFUSED = {
    w_group_count: "a grouped aggregate of a window (Active Record limits the groups)",
    m_fragment_self: "an SQL fragment without binds",
    m_or_same_col: "merge replacing an OR over one column",
    m_scope_or: "merge replacing an OR over one column",
    m_distinct_count: "SELECT DISTINCT of selected columns",
    m_table_key: "a condition keyed by the model's own table name",
    o_unscope_frag: "unscope of an SQL fragment (the relation keeps no plan)",
    o_unscope_frag_col: "unscope of a column after an SQL fragment",
    o_unscope_frag_other_col: "unscope of a column after an SQL fragment",
    j_merge_replace: "merge replacing a joined table's condition",
    j_merge_replace_one: "merge replacing a joined table's condition",
    j_merge_replace_str: "a condition keyed by a joined table's column name",
    j_merge_both_where: "merge replacing a condition of a joined relation (no plan)",
    j_merge_user_rel: "merge of another model's relation",
    j_merge_ar_other: "merge of an Active Record relation with joins"
  }.freeze

  CASES.keys.group_by { _1.to_s[/\A[a-z]+/] }.each do |group, names|
    define_method(:"test_#{group}_cases_answer_as_active_record_or_are_refused") do
      results = %i[monitor es_noproj].to_h do |mode|
        clean
        use(mode)
        seed
        [mode, names.to_h { |name| [name, answer(name)] }]
      end
      wrong = names.filter_map do |name|
        monitor = results[:monitor][name]
        es = results[:es_noproj][name]
        if REFUSED.key?(name)
          "#{name}: refused expected, got #{es.inspect[0, 160]}" unless refused?(es)
        elsif monitor != es
          "#{name}: Active Record #{monitor.inspect[0, 160]}, ES-NoProj #{es.inspect[0, 160]}"
        end
      end
      assert_empty wrong
    end
  end

  private

  def answer(name)
    instance_exec(&CASES.fetch(name))
  rescue UQ => e
    [:REFUSED, e.message[0, 160]]
  rescue StandardError, NotImplementedError => e
    [:ERROR, e.class.name, e.message[0, 160]]
  end

  def refused?(value)
    value.is_a?(Array) && (value.first == :REFUSED || value == [:refused] || value == [:raised, UQ.name])
  end

  def reseed!
    clean
    seed
  end

  def state = PrItem.unscoped.order(:code).pluck(:code, :name, :status, :qty, :tag, :owner_id).map { |r| r[0..4] + [r[5] ? User.find(r[5]).name : nil] }

  def events = connection.select_value("SELECT COUNT(*) FROM event_store_events").to_i

  private

  def seed
    ann = User.create!(name: "Ann", email: "ann-pr@example.com")
    bob = User.create!(name: "Bob", email: "bob-pr@example.com")
    owners = { "a1" => ann.id, "a3" => ann.id, "a4" => bob.id }
    ROWS.each { |row| PrItem.create!(row.merge(owner_id: owners[row[:code]])) }
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

  def clean
    connection.execute("DELETE FROM #{TABLE}") if connection.table_exists?(TABLE)
    connection.execute("DELETE FROM users WHERE email LIKE '%-pr@example.com'")
    connection.execute("DELETE FROM event_store_events_in_streams")
    connection.execute("DELETE FROM event_store_events")
    Lyra::Projections::CachedProjection.invalidate_all(PrItem) if Object.const_defined?(:PrItem)
    Lyra::Projections::CachedProjection.invalidate_all(User) if defined?(User)
    Rails.cache.clear
  end

  def connection = ActiveRecord::Base.connection
end
