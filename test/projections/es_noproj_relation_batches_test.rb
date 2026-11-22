# frozen_string_literal: true

require "test_helper"
require "timeout"

# ES-NoProj (CachedRelation) against Monitor (Active Record and
# PostgreSQL) on three groups of relation methods:
#
# - batches of a relation with a limit or an offset (find_each,
#   find_in_batches, in_batches with load true or false, use_ranges, order:
#   :desc, start and finish, each_record, a batch's writes), read as the loop
#   reaches each batch, the limit's remainder and the offset carried as
#   Active Record carries them (the offset skips records of every batch's
#   query), with records inserted, changed and deleted during the loop;
#   and batches of a loaded relation, which Active Record takes from the
#   records loaded;
# - load, reload, reset and loaded? (they were refused);
# - excluding, without and in_order_of as query methods (they were
#   Enumerable's, and returned an Array), their writes selecting at write
#   time.
#
# Each answer must be Active Record's, except those ES-NoProj refuses
# (UnsupportedQuery), listed in REFUSED with what Active Record does.
class EsNoprojRelationBatchesTest < Minitest::Test
  TABLE = "lyra_rb_items"
  UQ = Lyra::Projections::UnsupportedQuery
  # Codes in primary-key order; every query that reads records names an
  # order or batches by key, so the table's physical order (which changes
  # as rows are updated) does not decide an answer.
  ROWS = [
    { code: "a01", status: "active", kind: "small", qty: 2, tag: "x" },
    { code: "a02", status: "draft", kind: "large", qty: 1, tag: nil },
    { code: "a03", status: "active", kind: "huge", qty: 3, tag: "y" },
    { code: "a04", status: nil, kind: "small", qty: 5, tag: nil },
    { code: "a05", status: "draft", kind: nil, qty: 3, tag: "x" },
    { code: "a06", status: "archived", kind: "large", qty: 4, tag: "z" },
    { code: "a07", status: "active", kind: "small", qty: 1, tag: "x" },
    { code: "a08", status: "draft", kind: "huge", qty: 2, tag: nil },
    { code: "a09", status: nil, kind: "large", qty: 6, tag: "y" },
    { code: "a10", status: "active", kind: "small", qty: 7, tag: "z" },
    { code: "a11", status: "archived", kind: "huge", qty: 1, tag: "x" }
  ].freeze

  def setup
    c = connection
    c.create_table(TABLE, force: true) do |t|
      t.string :code
      t.string :status
      t.integer :kind
      t.integer :qty
      t.string :tag
      t.timestamps
    end
    c.add_index TABLE, :code, unique: true
    Object.send(:remove_const, :RbItem) if Object.const_defined?(:RbItem)
    Object.const_set(:RbItem, Class.new(ActiveRecord::Base) do
      self.table_name = TABLE
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
      enum :kind, { small: 0, large: 1, huge: 2 }
      scope :active, -> { where(status: "active") }
    end)
    RbItem.reset_column_information
    clean
    Lyra.config.monitor_model(RbItem)
  end

  def teardown
    Lyra.config.enable_monitor!
    Lyra.config.projection_mode = :sync
    clean
    connection.drop_table(TABLE, if_exists: true)
  end

  # Codes, for records and collections of them.
  def c(value)
    case value
    when nil then nil
    when ActiveRecord::Base then value.code
    when Hash then value
    when Enumerable then value.map { |item| item.is_a?(ActiveRecord::Base) ? item.code : item }
    else value
    end
  end

  def id_of(code) = RbItem.find_by(code: code).id

  def raised
    yield
  rescue UQ
    raise
  rescue StandardError => e
    [:raised, e.class.name, e.message[0, 120]]
  end

  # The batch loop's own answers: each batch's codes.
  def batches(relation, **options)
    relation.in_batches(**options).map { c(_1) }
  end

  def each_batch(relation, **options)
    out = []
    relation.in_batches(**options) { |batch| out << yield(batch) }
    out
  end

  CASES = {
    # 3. Batches of a relation with a limit or offset.
    b_limit_find_each: -> { RbItem.limit(5).find_each(batch_size: 2).map(&:code) },
    b_offset_find_each: -> { RbItem.offset(1).find_each(batch_size: 3).map(&:code) },
    b_offset_limit_find_each: -> { RbItem.offset(2).limit(5).find_each(batch_size: 2).map(&:code) },
    b_offset_limit_small: -> { RbItem.limit(3).offset(1).find_each(batch_size: 10).map(&:code) },
    b_offset_desc: -> { RbItem.offset(1).limit(6).find_each(batch_size: 2, order: :desc).map(&:code) },
    b_offset_start_finish: -> { RbItem.offset(1).limit(4).find_each(batch_size: 2, start: id_of("a03"), finish: id_of("a10")).map(&:code) },
    b_offset_where: -> { RbItem.where(status: %w[active draft]).offset(1).find_each(batch_size: 2).map(&:code) },
    b_offset_cursor_code: -> { RbItem.offset(1).limit(5).find_each(batch_size: 2, cursor: :code, order: :desc).map(&:code) },
    b_offset_fib: -> { RbItem.offset(1).limit(7).find_in_batches(batch_size: 3).map { c(_1) } },
    b_sizes: -> { [RbItem.offset(2).find_each.size, RbItem.offset(2).limit(3).find_in_batches(batch_size: 2).size, RbItem.limit(4).find_each(start: id_of("a09")).size, RbItem.offset(20).find_each.size, RbItem.limit(0).find_in_batches.size] },
    b_limit_zero: -> { [RbItem.limit(0).find_each.map(&:code), batches(RbItem.limit(0), of: 2)] },
    b_offset_past_end: -> { [RbItem.offset(11).find_each.map(&:code), batches(RbItem.order(:code).offset(30), of: 2)] },
    b_in_batches_offset: -> { batches(RbItem.order(:code).offset(1), of: 3) },
    b_in_batches_offset_limit: -> { batches(RbItem.order(:code).offset(1).limit(7), of: 3) },
    b_in_batches_ordered: -> { batches(RbItem.order(:qty, :code).offset(1).limit(8), of: 4) },
    b_in_batches_load: -> { each_batch(RbItem.offset(1).limit(7), of: 3, load: true) { |b| [!!b.loaded?, c(b), c(b.records), b.size, b.ids.size] } },
    b_in_batches_load_count: -> { each_batch(RbItem.order(:code).offset(1).limit(7), of: 3, load: true) { |b| [b.count, c(b.order(:code).where(tag: "x")), b.exists?(tag: "z"), b.sum(:qty)] } },
    b_in_batches_aggregates: -> { each_batch(RbItem.order(:code).offset(1).limit(7), of: 3) { |b| [!!b.loaded?, b.count, b.size, b.ids.size, b.sum(:qty), b.pluck(:code), b.exists?] } },
    b_in_batches_limit_load: -> { each_batch(RbItem.limit(5), of: 2, load: true) { |b| [!!b.loaded?, c(b), b.count] } },
    b_in_batches_desc: -> { batches(RbItem.order(:code).offset(1).limit(6), of: 2, order: :desc) },
    b_in_batches_start: -> { batches(RbItem.order(:code).offset(1).limit(4), of: 2, start: id_of("a04")) },
    b_ranges_limit: -> { batches(RbItem.limit(5), of: 2, use_ranges: true) },
    b_ranges_limit_where: -> { batches(RbItem.where.not(tag: nil).limit(4), of: 3, use_ranges: true) },
    b_ranges_offset: -> { batches(RbItem.offset(1), of: 3, use_ranges: true) },
    b_unordered_offset: -> { batches(RbItem.offset(1), of: 3) },
    b_unordered_offset_load_query: -> { each_batch(RbItem.offset(1), of: 3, load: true) { |b| b.count } },
    b_unordered_offset_load_reads: -> { each_batch(RbItem.offset(1).limit(7), of: 3, load: true) { |b| [c(b), b.size, b.ids.size, !!b.loaded?] } },
    b_unordered_offset_update: -> { reseed!; RbItem.offset(1).in_batches(of: 3).update_all(tag: "e") },
    # An or brings in the other relation's records: each batch takes those
    # after the cursor only (a loop without a limit never ended).
    b_or: -> { r = RbItem.where(status: "draft").or(RbItem.where(tag: "z")); [r.find_each(batch_size: 2).map(&:code), r.find_in_batches(batch_size: 2).map { c(_1) }, batches(r, of: 2)] },
    b_or_window: -> { r = RbItem.where(status: "draft").or(RbItem.where(tag: "z")); [r.limit(5).find_in_batches(batch_size: 2).map { c(_1) }, r.limit(4).find_in_batches(batch_size: 2).map { c(_1) }, r.offset(1).find_in_batches(batch_size: 2).map { c(_1) }, batches(r.order(:code).offset(1).limit(3), of: 2)] },
    b_or_delete_during: -> { reseed!; seen = []; RbItem.where(status: "draft").or(RbItem.where(tag: "z")).limit(5).find_each(batch_size: 2) { |x| seen << x.code; RbItem.find_by(code: "a08").destroy if seen.size == 1 }; seen },
    b_or_insert_during: -> { reseed!; seen = []; RbItem.where(status: "draft").or(RbItem.where(tag: "z")).find_each(batch_size: 2) { |x| seen << x.code; RbItem.create!(code: "b#{seen.size}", status: "draft") if seen.size == 1 }; seen },
    b_or_update: -> { reseed!; RbItem.where(status: "draft").or(RbItem.where(tag: "z")).order(:code).offset(1).limit(3).in_batches(of: 2) { |b| b.update_all(tag: "h") }; state },
    b_each_record: -> { [RbItem.offset(1).limit(6).in_batches(of: 2).each_record.map(&:code), RbItem.limit(3).in_batches(of: 2).each_record.map(&:code)] },
    b_enum_sizes: -> { [RbItem.order(:code).offset(1).in_batches(of: 3).to_a.size, RbItem.limit(5).in_batches(of: 2).map(&:size)] },
    b_batch_where: -> { each_batch(RbItem.order(:code).offset(1).limit(8), of: 3) { |b| c(b.where(status: "active").order(:code)) } },

    # The loop's writes, each batch's and the enumerator's.
    bw_update_all: -> { reseed!; RbItem.order(:code).offset(1).in_batches(of: 3) { |b| b.update_all(tag: "u") }; state },
    bw_update_all_load: -> { reseed!; RbItem.order(:code).offset(1).limit(8).in_batches(of: 3, load: true) { |b| b.update_all(tag: "u") }; state },
    bw_delete_all: -> { reseed!; n = 0; RbItem.order(:code).offset(2).in_batches(of: 3) { |b| n += b.delete_all }; [n, state] },
    bw_destroy_all: -> { reseed!; RbItem.order(:code).offset(1).limit(7).in_batches(of: 3) { |b| b.destroy_all }; state },
    bw_destroy_all_load: -> { reseed!; RbItem.offset(1).limit(7).in_batches(of: 3, load: true) { |b| b.destroy_all }; state },
    bw_enum_update_all: -> { reseed!; [RbItem.order(:code).offset(1).in_batches(of: 2).update_all(tag: "e"), state] },
    bw_enum_delete_all: -> { reseed!; [RbItem.limit(5).in_batches(of: 2).delete_all, state] },
    bw_enum_limit_update: -> { reseed!; [RbItem.where(status: "active").limit(3).in_batches(of: 2).update_all(tag: "l"), state] },
    bw_ordered_offset_update: -> { reseed!; RbItem.order(:qty, :code).offset(1).in_batches(of: 3) { |b| b.update_all(tag: "o") }; state },

    # Changes during the loop, seen as Active Record's per-batch queries see them.
    bl_insert_ahead: -> { reseed!; seen = []; RbItem.offset(1).limit(8).find_each(batch_size: 2) { |r| seen << r.code; RbItem.create!(code: "n#{seen.size}", status: "new") if seen.size == 2 }; [seen, state] },
    bl_delete_ahead: -> { reseed!; seen = []; RbItem.offset(1).limit(6).find_each(batch_size: 2) { |r| seen << r.code; RbItem.find_by(code: "a07").destroy if seen.size == 1 }; seen },
    bl_change_ahead: -> { reseed!; seen = []; RbItem.where(status: "active").offset(1).limit(3).find_each(batch_size: 1) { |r| seen << r.code; RbItem.find_by(code: "a07").update!(status: "draft") if seen.size == 1 }; seen },
    bl_batch_writes_ahead: -> { reseed!; seen = []; RbItem.limit(6).in_batches(of: 2) { |b| seen << c(b.order(:code)); RbItem.where(code: %w[a05 a06]).delete_all if seen.size == 1 }; [seen, state] },
    bl_load_insert: -> { reseed!; seen = []; RbItem.offset(1).in_batches(of: 4, load: true) { |b| seen << c(b); RbItem.create!(code: "n9", status: "new") if seen.size == 1 }; seen },

    # Batches of a loaded relation: the records loaded, sliced; the batch's
    # query (count, where, update_all) is the relation's.
    bd_find_each: -> { reseed!; r = RbItem.order(:code).offset(1).limit(5); r.load; RbItem.create!(code: "a00", status: "new"); r.find_each(batch_size: 2).map(&:code) },
    bd_in_batches: -> { r = RbItem.where(status: %w[active draft]).order(:code).limit(5); r.load; each_batch(r, of: 2, load: false) { |b| [!!b.loaded?, c(b), b.size, b.count, c(b.where(qty: 1))] } },
    bd_update_all: -> { reseed!; r = RbItem.where(status: %w[active draft]).order(:code).limit(4); r.load; n = 0; r.in_batches(of: 2) { |b| n += 1; b.update_all(tag: "L#{n}") }; state },
    # The finders of a batch that holds its records search its query.
    bd_finders: -> { r = RbItem.where(status: %w[active draft]).order(:code).limit(6); r.load; each_batch(r, of: 2) { |b| [b.find_by(code: "a07")&.code, raised { b.find(id_of("a07")).code }, raised { b.find_sole_by(code: "a07").code }, b.find_or_initialize_by(code: "a07").persisted?] } },
    bd_find_or_create: -> { reseed!; r = RbItem.where(status: "draft").order(:code); r.load; out = each_batch(r, of: 2) { |b| raised { b.find_or_create_by!(code: "a05").code } }; [out, state.size] },
    bl_finders_load_true: -> { reseed!; each_batch(RbItem.order(:code).offset(1).limit(6), of: 3, load: true) { |b| RbItem.where(code: b.first.code).update_all(tag: "q"); [b.find_by(tag: "q")&.code, b.find_by(code: "a02")&.code, b.where(tag: "x").pluck(:code), b.find_or_initialize_by(code: "a02").persisted?] } },
    bd_destroy_all: -> { reseed!; r = RbItem.where(status: "draft").order(:code); r.load; r.in_batches(of: 2) { |b| b.destroy_all if b.first.code == "a05" }; state },

    # 5. load, reload, reset, loaded?
    l_load: -> { r = RbItem.where(status: "draft").order(:code); x = r.load; [x.equal?(r), !!r.loaded?, c(r.records), c(r)] },
    l_loaded_before: -> { r = RbItem.where(status: "draft"); [!!r.loaded?, !!r.order(:code).to_a && !!r.loaded?] },
    l_load_block: -> { r = RbItem.where(status: "active").order(:code); seen = []; r.load { |x| seen << x.code }; again = []; r.load { |x| again << x.code }; [seen, again, !!r.loaded?] },
    l_load_window: -> { r = RbItem.order(:code).offset(2).limit(3); r.load; [c(r), r.size, r.count, c(r.first), c(r.last)] },
    l_load_select: -> { r = RbItem.select(:code, :id).order(:code).limit(2).load; r.map { _1.attributes.keys.sort } },
    l_load_no_reread: -> { reseed!; r = RbItem.where(status: "draft").order(:code).load; RbItem.find_by(code: "a02").update!(tag: "changed"); [c(r), r.map(&:tag), r.size, c(r.first)] },
    l_reload: -> { reseed!; r = RbItem.where(status: "draft").order(:code); r.to_a; RbItem.create!(code: "a20", status: "draft"); RbItem.find_by(code: "a05").destroy; RbItem.find_by(code: "a08").update!(tag: "r"); x = r.reload; [x.equal?(r), !!r.loaded?, c(r), r.map(&:tag), r.count] },
    l_reload_window: -> { reseed!; r = RbItem.order(:code).offset(1).limit(3); r.load; RbItem.find_by(code: "a01").destroy; [c(r.reload), r.count] },
    l_reset: -> { reseed!; r = RbItem.where(status: "active").order(:code); r.load; RbItem.create!(code: "a21", status: "active"); x = r.reset; [x.equal?(r), !!r.loaded?, c(r), !!r.loaded?] },
    l_reset_scope: -> { reseed!; r = RbItem.active.order(:code).limit(2); r.load; RbItem.find_by(code: "a01").update!(status: "draft"); r.reset; c(r) },
    l_loaded_initial: -> { [RbItem.all.loaded?, RbItem.where(tag: "x").loaded?, RbItem.where(tag: "x").reset.loaded?] },
    l_destroy_all_resets: -> { reseed!; r = RbItem.where(status: "draft").order(:code); r.load; r.destroy_all; [!!r.loaded?, c(r), r.count] },
    l_destroy_all_batch_resets: -> { reseed!; out = []; RbItem.in_batches(of: 4, load: true) { |b| b.destroy_all; out << [c(b), !!b.loaded?] }; [out, state] },
    l_bang_on_loaded: -> { r = RbItem.where(status: "draft").order(:code); r.load; e = raised { r.where!(tag: "x") }; [e.first(2), c(r)] },
    l_records_then_write: -> { reseed!; r = RbItem.where(status: "draft").order(:code); r.load; RbItem.create!(code: "a22", status: "draft"); [r.update_all(tag: "w"), state] },
    l_delete_all_loaded: -> { reseed!; r = RbItem.where(status: "draft").order(:code); r.load; RbItem.create!(code: "a23", status: "draft"); [r.delete_all, state] },
    l_destroy_all_loaded: -> { reseed!; r = RbItem.where(status: "draft").order(:code); r.load; RbItem.create!(code: "a24", status: "draft"); [c(r.destroy_all), state] },
    l_update_loaded: -> { reseed!; r = RbItem.where(status: "draft").order(:code); r.load; RbItem.create!(code: "a25", status: "draft"); [c(r.update(tag: "v")), state] },

    # 6. excluding, without, in_order_of.
    x_excluding: -> { a1 = RbItem.find_by(code: "a01"); a3 = RbItem.find_by(code: "a03"); [c(RbItem.order(:code).excluding(a1)), c(RbItem.order(:code).excluding(a1, a3)), c(RbItem.order(:code).excluding([a1, a3])), c(RbItem.where(status: "active").order(:code).without(a1))] },
    x_excluding_relation: -> { c RbItem.order(:code).excluding(RbItem.where(status: "draft")) },
    x_excluding_edge: -> { [c(RbItem.order(:code).excluding), c(RbItem.order(:code).excluding(nil)), c(RbItem.order(:code).excluding(RbItem.new)), RbItem.excluding(RbItem.first).count] },
    x_excluding_other: -> { raised { RbItem.order(:code).excluding(User.new) } },
    x_without_other: -> { raised { RbItem.all.without(RbItem.find_by(code: "a01"), User.new) } },
    x_excluding_chain: -> { a2 = RbItem.find_by(code: "a02"); [c(RbItem.excluding(a2).where(status: "draft").order(:code).limit(2)), c(RbItem.order(:code).limit(3).excluding(a2)), RbItem.excluding(a2).pluck(:code).sort] },
    x_in_order_of: -> { c RbItem.in_order_of(:code, %w[a05 a01 a09 zz]) },
    x_in_order_of_nil: -> { c RbItem.in_order_of(:status, ["draft", nil, "active"]).order(:code) },
    x_in_order_of_no_filter: -> { c RbItem.in_order_of(:status, ["archived", nil], filter: false).order(:code) },
    x_in_order_of_enum: -> { [c(RbItem.in_order_of(:kind, %w[huge small]).order(:code)), c(RbItem.in_order_of(:kind, [:large, nil, "nope"]).order(:code)), c(RbItem.in_order_of(:kind, [2, 0]).order(:code))] },
    x_in_order_of_int: -> { c RbItem.in_order_of(:qty, [3, 1, "7"]).order(:code) },
    x_in_order_of_empty: -> { [c(RbItem.in_order_of(:code, [])), c(RbItem.in_order_of(:kind, %w[nope])), RbItem.in_order_of(:code, []).count] },
    x_in_order_of_after_order: -> { c RbItem.order(:tag, :code).in_order_of(:status, %w[draft active archived]) },
    x_in_order_of_chain: -> { [c(RbItem.where.not(tag: nil).in_order_of(:status, %w[archived active]).order(:code).limit(3)), c(RbItem.order(:code).limit(4).in_order_of(:status, %w[draft active])), c(RbItem.in_order_of(:code, %w[a03 a01 a02]).reverse_order), c(RbItem.in_order_of(:code, %w[a03 a01 a02]).first), c(RbItem.in_order_of(:code, %w[a03 a01 a02]).last)] },
    x_in_order_of_aggregates: -> { r = RbItem.in_order_of(:status, ["draft", nil]); [r.count, r.sum(:qty), r.pluck(:code).sort, r.exists?, r.order(:code).pick(:code)] },
    x_in_order_of_raw: -> { raised { RbItem.in_order_of("LOWER(code)", %w[a01]).to_a } },
    x_in_order_of_arel: -> { c RbItem.in_order_of(Arel.sql("code"), %w[a02 a01]) },
    x_in_order_of_scope: -> { c RbItem.active.in_order_of(:code, %w[a10 a03 a01 a02]) },
    # Its filter is a where of the column: rewhere, unscope and except take it off.
    x_in_order_of_rewhere: -> { [c(RbItem.in_order_of(:status, %w[draft]).rewhere(status: "active").order(:code)), c(RbItem.in_order_of(:kind, %w[small]).rewhere(kind: "huge").order(:code)), c(RbItem.where(tag: "x").in_order_of(:status, %w[draft]).rewhere(status: %w[active draft]).order(:code))] },
    x_in_order_of_unscope: -> { [c(RbItem.in_order_of(:status, %w[draft]).unscope(where: :status).order(:code)), c(RbItem.in_order_of(:status, %w[draft]).unscope(:where).order(:code)), c(RbItem.in_order_of(:status, %w[draft]).except(:where).order(:code)), c(RbItem.in_order_of(:code, %w[a03 a01]).unscope(:order).order(:code)), c(RbItem.in_order_of(:code, %w[a03 a01 a02]).reorder(:code))] },
    x_in_order_of_table: -> { c RbItem.in_order_of("lyra_rb_items.code", %w[a02 a01]) },
    x_in_order_of_alias: -> { c RbItem.in_order_of("code", %w[a02 a01]) },

    # Their writes, selected at write time.
    xw_excluding_update_all: -> { reseed!; a1 = RbItem.find_by(code: "a01"); r = RbItem.where(status: "active").excluding(a1); RbItem.create!(code: "a30", status: "active"); [r.update_all(tag: "q"), state] },
    xw_excluding_delete_all: -> { reseed!; r = RbItem.excluding(RbItem.where(status: "draft")).where(tag: "x"); RbItem.find_by(code: "a07").update!(tag: "nx"); [r.delete_all, state] },
    xw_without_destroy_all: -> { reseed!; r = RbItem.where(status: "draft").without(RbItem.find_by(code: "a02")); [c(r.destroy_all).sort, state] },
    xw_in_order_of_update_all: -> { reseed!; r = RbItem.in_order_of(:status, ["draft", nil]); RbItem.create!(code: "a31", status: nil); [r.update_all(tag: "io"), state] },
    xw_in_order_of_limit_update: -> { reseed!; [RbItem.in_order_of(:code, %w[a09 a02 a05 a01]).limit(2).update_all(tag: "lim"), state] },
    xw_in_order_of_delete_all: -> { reseed!; r = RbItem.in_order_of(:kind, %w[huge]); RbItem.find_by(code: "a03").update!(kind: "small"); [r.delete_all, state] },
    xw_in_order_of_destroy_all: -> { reseed!; [c(RbItem.in_order_of(:code, %w[a04 a02]).destroy_all), state] },
    xw_in_order_of_offset_delete: -> { reseed!; [RbItem.in_order_of(:code, %w[a11 a10 a09 a08]).offset(1).limit(2).delete_all, state] },
    xw_in_order_of_rewhere: -> { reseed!; [RbItem.in_order_of(:status, %w[draft]).rewhere(status: "active").update_all(tag: "rw"), RbItem.in_order_of(:status, %w[active]).rewhere(status: "draft").delete_all, state] },
    xw_in_order_of_unscope: -> { reseed!; [c(RbItem.in_order_of(:status, %w[active]).unscope(where: :status).destroy_all).sort, state.size] },
    xw_in_order_of_batches: -> { reseed!; seen = []; RbItem.in_order_of(:status, %w[active draft]).in_batches(of: 2, error_on_ignore: false) { |b| seen << c(b); b.update_all(tag: "ib") }; [seen, state] }
  }.freeze

  # Answered by Active Record, refused by ES-NoProj rather than answered
  # differently.
  REFUSED = {
    b_ranges_offset: "use_ranges: true with an offset (Active Record reads each range with OFFSET and no ORDER BY: " \
                     "which records it skips is the table's physical order)",
    x_in_order_of_arel: "in_order_of of an SQL literal",
    b_unordered_offset: "in_batches of a relation with an offset and no order (Active Record's batch is rewhere(ids).offset(n) " \
                        "with no ORDER BY: which records it skips is the database's plan)",
    b_unordered_offset_load_query: "the same, a query of an in_batches(load: true) batch (its records are read in key order and given)",
    b_unordered_offset_update: "the same, through the BatchEnumerator",
    x_in_order_of_raw: "in_order_of of an SQL expression (Active Record quotes it as a column name, and PostgreSQL " \
                       "rejects it)"
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
          "#{name}: refused expected, got #{es.inspect[0, 200]}" unless refused?(es)
        elsif monitor != es
          "#{name}: Active Record #{monitor.inspect[0, 300]}, ES-NoProj #{es.inspect[0, 300]}"
        end
      end
      assert_empty wrong
    end
  end

  # A batch of a loaded relation, as Active Record's: its update_all is the
  # relation's (each batch writes every record the relation selects), its
  # destroy_all the batch's records.
  def test_a_batch_of_a_loaded_relation_writes_with_the_relations_query
    results = %i[monitor es_noproj].map do |mode|
      clean
      use(mode)
      seed
      r = RbItem.where(status: %w[active draft]).order(:code).limit(4).load
      batches = 0
      r.in_batches(of: 2) { |b| batches += 1; b.update_all(qty: batches * 10) }
      RbItem.unscoped.order(:code).pluck(:code, :qty)
    end
    assert_equal results.first, results.last
    assert_equal [20] * 4, results.last.to_h.values_at("a01", "a02", "a03", "a05"),"every batch wrote the relation's four"
  end

  # The batch loop reads one batch at a time: with a limit, a batch costs
  # about its own records, not the model's size.
  def test_batches_of_a_limited_relation_are_read_as_the_loop_reaches_them
    clean
    use(:es_noproj)
    seed
    Lyra::Projections::Rebuildable.singleton_class.prepend(RebuildCounter)
    seen = []
    reads = RebuildCounter.counting do |counted|
      RbItem.offset(1).limit(6).find_each(batch_size: 2) { |record| seen << [record.code, counted.size] }
    end
    assert_equal %w[a02 a03 a05 a06 a08 a09], seen.map(&:first), "the offset skips a record in every batch's query"
    assert_equal 3, [seen[0][1], seen[2][1], seen[4][1]].uniq.size, "each batch read when the loop reached it"
    assert_equal %w[Keyed], reads.uniq, "each batch read by key"
  end

  # Counts the relations built again (Rebuildable.rebuild) inside counting.
  module RebuildCounter
    def self.counting
      Thread.current[:rb_rebuilds] = []
      yield Thread.current[:rb_rebuilds]
      Thread.current[:rb_rebuilds]
    ensure
      Thread.current[:rb_rebuilds] = nil
    end

    def rebuild(recipe)
      Thread.current[:rb_rebuilds]&.push(recipe.first.class.name.split("::").last)
      super
    end
  end

  private

  def answer(name)
    # A batch loop that never ends (an or relation's did) fails, not hangs.
    Timeout.timeout(60) { instance_exec(&CASES.fetch(name)) }
  rescue UQ => e
    [:REFUSED, e.message[0, 160]]
  rescue StandardError, NotImplementedError => e
    [:ERROR, e.class.name, e.message[0, 160]]
  end

  def refused?(value)
    value.is_a?(Array) && value.first == :REFUSED
  end

  def reseed!
    clean
    seed
  end

  def state = RbItem.unscoped.order(:code).pluck(:code, :status, :kind, :qty, :tag)

  def seed
    ROWS.each { |row| RbItem.create!(row) }
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
    connection.execute("DELETE FROM event_store_events_in_streams")
    connection.execute("DELETE FROM event_store_events")
    Lyra::Projections::CachedProjection.invalidate_all(RbItem) if Object.const_defined?(:RbItem)
    Rails.cache.clear
  end

  def connection = ActiveRecord::Base.connection
end
