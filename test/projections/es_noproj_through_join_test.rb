# frozen_string_literal: true

require "test_helper"

# :through associations read under ES-NoProj against Active Record's join
# (Monitor), over many shapes: has_many and has_one :through, nested chains,
# source scopes and own scopes, STI, source_type, an unmonitored step,
# default scopes (soft-deleted items and tags), orders at every step, purpose
# checks and restrictions, and bulk writes on a collection. Each answer is
# compared as is; an error is compared by its class.
#
# Owners have items (position, soft-deleted), items have tags (active,
# soft-deleted, STI TjHotTag), tags have notes; comments point at items or
# tags (polymorphic); links (not monitored) join owners and tags.
class EsNoprojThroughJoinTest < Minitest::Test
  TABLES = %w[lyra_tj_owners lyra_tj_items lyra_tj_tags lyra_tj_notes lyra_tj_comments lyra_tj_links
              lyra_tj_boxes lyra_tj_slots lyra_tj_pins lyra_tj_marks].freeze
  MODELS = %i[TjOwner TjItem TjSpecialItem TjTag TjHotTag TjNote TjComment TjLink TjBox TjSlot TjPin TjMark].freeze
  MONITORED = %i[TjOwner TjItem TjSpecialItem TjTag TjHotTag TjNote TjComment TjBox TjSlot TjPin TjMark].freeze
  UnsupportedQuery = Lyra::Projections::UnsupportedQuery

  def setup
    skip "Requires Rails and PostgreSQL" unless defined?(ActiveRecord::Base) && connection.adapter_name.match?(/postgres/i)

    c = connection
    c.create_table(:lyra_tj_owners, force: true) { |t| t.string :name }
    c.create_table(:lyra_tj_items, force: true) do |t|
      t.string :label
      t.string :type
      t.bigint :tj_owner_id
      t.datetime :deleted_at
      t.integer :position
      t.bigint :parent_id
    end
    c.create_table(:lyra_tj_tags, force: true) do |t|
      t.string :label
      t.string :type
      t.bigint :tj_item_id
      t.bigint :tj_owner_id
      t.datetime :deleted_at
      t.boolean :active, default: true
    end
    c.create_table(:lyra_tj_notes, force: true) do |t|
      t.string :label
      t.bigint :tj_tag_id
    end
    c.create_table(:lyra_tj_comments, force: true) do |t|
      t.string :label
      t.string :commentable_type
      t.bigint :commentable_id
      t.bigint :tj_owner_id
    end
    c.create_table(:lyra_tj_boxes, force: true) { |t| t.string :name }
    c.create_table(:lyra_tj_slots, force: true) do |t|
      t.bigint :tj_box_id
      t.integer :position
    end
    c.create_table(:lyra_tj_pins, force: true) do |t|
      t.string :label
      t.integer :rank
      t.bigint :tj_slot_id
    end
    c.create_table(:lyra_tj_marks, force: true) do |t|
      t.string :label
      t.bigint :tj_pin_id
    end
    c.create_table(:lyra_tj_links, force: true) do |t|
      t.bigint :tj_owner_id
      t.bigint :tj_tag_id
    end
    PamDsl.reset!
    PamDsl.logger = Logger.new(nil)
    define_models
    clean
    Rails.cache.clear
  end

  def teardown
    return unless Object.const_defined?(:TjOwner)

    Lyra.config.enable_monitor!
    Lyra.config.projection_mode = :sync
    clean
    Rails.cache.clear
    TABLES.each { connection.drop_table(_1, if_exists: true) }
    PamDsl.reset!
    PamDsl.logger = nil
  end

  # --- reads on the owner ------------------------------------------------------

  OWNER_READS = {
    "tags" => ->(o) { o.tags.map(&:label).sort },
    "tags.count" => ->(o) { o.tags.count },
    "tags.size" => ->(o) { o.tags.size },
    "tags.pluck" => ->(o) { o.tags.pluck(:label).sort },
    "tags.where" => ->(o) { o.tags.where(active: true).map(&:label).sort },
    "tags.order.first" => ->(o) { o.tags.order(:label).first&.label },
    "tag_ids" => ->(o) { o.tag_ids.size },
    "notes (three steps)" => ->(o) { o.notes.map(&:label).sort },
    "notes.count" => ->(o) { o.notes.count },
    "notes via items (a :through source)" => ->(o) { o.notes_via_items.map(&:label).sort },
    "active tags (a source scope)" => ->(o) { o.active_tags.map(&:label).sort },
    "scoped tags (its own scope)" => ->(o) { o.scoped_tags.map(&:label).sort },
    "ordered tags" => ->(o) { o.ordered_tags.map(&:label) },
    "ordered tags first" => ->(o) { o.ordered_tags.first&.label },
    "limited tags" => ->(o) { o.limited_tags.map(&:label) },
    "hot tags (STI source)" => ->(o) { o.hot_tags.map(&:label) },
    "special item tags (STI step)" => ->(o) { o.special_item_tags.map(&:label).sort },
    "commented items (source_type)" => ->(o) { o.commented_items.map(&:label).sort },
    "commented items distinct count" => ->(o) { o.commented_items.distinct.count },
    "commented tags (source_type)" => ->(o) { o.commented_tags.map(&:label).sort },
    "linked tags (an unmonitored step)" => ->(o) { o.linked_tags.map(&:label).sort },
    "latest tags (a has_one source)" => ->(o) { o.latest_tags.map(&:label).sort },
    "latest tags first" => ->(o) { o.latest_tags.first&.label },
    "first tag (through an ordered has_one)" => ->(o) { o.first_tag&.label },
    "first latest tag (orders at two steps)" => ->(o) { o.first_latest_tag&.label },
    "any tags (a source that unscopes)" => ->(o) { o.any_tags.map(&:label).sort },
    "tag items, twice where reached twice" => ->(o) { o.tag_items.map(&:label).sort },
    "tag items count" => ->(o) { o.tag_items.count },
    "tag items exists?" => ->(o) { o.tag_items.exists? },
    "tag items ids" => ->(o) { o.tag_items.ids.size },
    "tag items distinct count" => ->(o) { o.tag_items.distinct.count },
    "distinct tag items" => ->(o) { o.distinct_tag_items.map(&:label).sort },
    "position tags (an ordered step)" => ->(o) { o.position_tags.map(&:label) },
    "position tags first" => ->(o) { o.position_tags.first&.label },
    "position latest tags" => ->(o) { o.position_latest_tags.map(&:label) },
    "first link tag" => ->(o) { o.first_link_tag&.label }
  }.freeze

  OWNER_READS.each do |name, read|
    define_method("test_owner_#{name.gsub(/\W+/, '_')}") do
      assert_same_answer { |ids| read.call(TjOwner.find(ids[:owner])) }
    end
  end

  # Item i2 last by position: the first item is i1, whose latest tag is t2,
  # while the join orders by the tag's label first and answers t3.
  def test_the_join_orders_by_the_source_s_scope_before_the_intermediate_step_s
    assert_same_answer do |ids|
      TjItem.find(ids[:i2]).update!(position: 9)
      owner = TjOwner.find(ids[:owner])
      [owner.first_item.label, owner.first_latest_tag&.label, owner.first_tag&.label]
    end
  end

  # --- reads from the other end ------------------------------------------------

  OTHER_READS = {
    "tag owner (through a belongs_to)" => ->(ids) { TjTag.find(ids[:t1]).owner&.name },
    "note owner (three steps)" => ->(ids) { TjNote.find_by(label: "n1").owner&.name },
    "note item" => ->(ids) { TjNote.find_by(label: "n3").item&.label },
    "sibling tags" => ->(ids) { TjTag.find(ids[:t1]).sibling_tags.map(&:label).sort },
    "a tag with no item" => ->(_ids) { TjTag.find(TjTag.create!(label: "orphan").id).owner },
    "another owner's tags" => ->(ids) { TjOwner.find(ids[:other]).tags.to_a },
    "another owner's first tag" => ->(ids) { TjOwner.find(ids[:other]).first_tag },
    "a new owner's tags" => ->(_ids) { TjOwner.new.tags.to_a },
    "a new owner with a built item" => ->(_ids) { TjOwner.new.tap { _1.items.build(label: "x") }.tags.to_a },
    "an unsaved tag's owner" => ->(ids) { TjTag.new(tj_item_id: ids[:i1]).owner&.name },
    "an unsaved note's owner" => ->(ids) { TjNote.new(tj_tag_id: ids[:t1]).owner&.name },
    "a key changed in memory" => ->(ids) { TjTag.find(ids[:t1]).tap { _1.tj_item_id = ids[:i2] }.owner&.name },
    "includes" => ->(ids) { TjOwner.where(id: ids[:owner]).includes(:tags).first.tags.map(&:label).sort },
    "preload" => ->(ids) { TjOwner.where(id: ids[:owner]).preload(:notes).first.notes.map(&:label).sort },
    "items left unloaded" => ->(ids) { TjOwner.find(ids[:owner]).then { _1.tags.to_a && _1.association(:items).loaded? } },
    "tags read again" => lambda do |ids|
      owner = TjOwner.find(ids[:owner])
      before = owner.tags.map(&:label).sort
      TjTag.create!(label: "new", tj_item_id: ids[:i1])
      [before, owner.tags.map(&:label).sort, owner.tags.reload.map(&:label).sort]
    end
  }.freeze

  OTHER_READS.each do |name, read|
    define_method("test_other_#{name.gsub(/\W+/, '_')}") { assert_same_answer(&read) }
  end

  # An unmonitored has_one step with two candidates: the first link's tag is
  # soft-deleted; the join reaches the other link's.
  def test_an_unmonitored_has_one_step_counts_every_candidate
    assert_same_answer do
      owner = TjOwner.create!(name: "o2")
      dead = TjTag.create!(label: "dead", deleted_at: Time.utc(2026))
      live = TjTag.create!(label: "live")
      TjLink.create!(tj_owner_id: owner.id, tj_tag_id: dead.id)
      TjLink.create!(tj_owner_id: owner.id, tj_tag_id: live.id)
      owner = TjOwner.find(owner.id)
      [owner.first_link_tag&.label, owner.link_tag&.label]
    end
  end

  # Two links with a live tag each and no order: the join chooses.
  def test_an_unmonitored_has_one_step_with_two_targets_in_no_order_is_refused
    seed = lambda do
      owner = TjOwner.create!(name: "o2")
      %w[a b].each { |label| TjLink.create!(tj_owner_id: owner.id, tj_tag_id: TjTag.create!(label: label).id) }
      owner.id
    end
    assert_includes %w[a b], run_in(:monitor) { TjOwner.find(seed.call).link_tag&.label }
    run_in(:es_noproj) do
      id = seed.call
      assert_raises(UnsupportedQuery) { TjOwner.find(id).link_tag }
    end
  end

  def test_an_ordered_has_one_step_whose_first_record_has_no_target
    assert_same_answer do
      owner = TjOwner.create!(name: "o2")
      TjItem.create!(label: "a", tj_owner_id: owner.id, position: 1)
      tagged = TjItem.create!(label: "b", tj_owner_id: owner.id, position: 2)
      TjTag.create!(label: "tb", tj_item_id: tagged.id)
      TjOwner.find(owner.id).first_tag&.label
    end
  end

  # unscope(where: :deleted_at) on the association drops the column from the
  # intermediate items' default scope too in the join: a soft-deleted item's
  # tag comes back. ES-NoProj read the items through that scope: refused.
  def test_unscoping_a_column_of_an_intermediate_default_scope_is_refused
    unscoped = ->(ids) { TjOwner.find(ids[:owner]).tags.unscope(where: :deleted_at).map(&:label).sort }

    assert_equal %w[t1 t2 t3 tdel tgone], run_in(:monitor) { unscoped.call(seed) }
    run_in(:es_noproj) do
      ids = seed
      assert_raises(UnsupportedQuery) { unscoped.call(ids) }
    end
  end

  # cat.grandchildren: the join aliases the intermediate step on the target's
  # own table and applies no default scope to it.
  def test_an_intermediate_step_on_the_target_s_table_has_no_default_scope
    assert_same_answer do
      top = TjItem.create!(label: "top")
      deleted = TjItem.create!(label: "deleted child", parent_id: top.id, deleted_at: Time.utc(2026))
      TjItem.create!(label: "under the deleted child", parent_id: deleted.id)
      live = TjItem.create!(label: "child", parent_id: top.id)
      TjItem.create!(label: "grandchild", parent_id: live.id)
      TjItem.find(top.id).grandchildren.map(&:label).sort
    end
  end

  # --- purpose checks ----------------------------------------------------------

  # Items bound to a policy whose purpose does not allow their label: the
  # join loads no item, so reading tags through items is allowed; reading an
  # item's label is not.
  def test_intermediate_records_are_not_checked_as_loaded_rows
    bind_policies(items: true)
    assert_same_answer(purpose: true) { |ids| TjItem.find(ids[:i1]).label }
    assert_same_answer(purpose: true) { |ids| TjOwner.find(ids[:owner]).tags.map(&:label).sort }
    assert_same_answer(purpose: true) { |ids| TjTag.find(ids[:t1]).owner&.name }
    assert_same_answer(purpose: true) { |ids| TjOwner.find(ids[:owner]).first_tag&.label }
    assert_same_answer(purpose: true) { |ids| TjOwner.find(ids[:owner]).tag_items.map(&:label) }
  end

  RESTRICTED_READS = {
    "scoped tags, the inactive tag restricted" => [:t2, ->(o) { o.scoped_tags.map(&:label).sort }],
    "limited tags, a tag past the limit restricted" => [:t3, ->(o) { o.limited_tags.map(&:label) }],
    "first latest tag, another candidate restricted" => [:t1, ->(o) { o.first_latest_tag&.label }],
    "first tag, the answer restricted" => [:t1, ->(o) { o.first_tag&.label }],
    "tags.where, a tag it leaves out restricted" => [:t2, ->(o) { o.tags.where(active: true).map(&:label).sort }],
    "tags.count, a tag restricted" => [:t1, ->(o) { o.tags.count }],
    "tags, a tag restricted" => [:t1, ->(o) { o.tags.map(&:label).sort }],
    "own tags count" => [:t1, ->(o) { o.own_tags.count }],
    "own tags" => [:t1, ->(o) { o.own_tags.map(&:label) }],
    "tags.exists?, another tag restricted" => [:t1, ->(o) { o.tags.exists?(label: "t3") }],
    "tag items, an intermediate tag restricted" => [:t1, ->(o) { o.tag_items.map(&:label).sort }],
    "notes, an intermediate tag restricted" => [:t1, ->(o) { o.notes.map(&:label).sort }]
  }.freeze

  RESTRICTED_READS.each do |name, (restricted, read)|
    define_method("test_restricted_#{name.gsub(/\W+/, '_')}") do
      bind_policies
      assert_same_answer do |ids|
        TjItem.find(ids[:i2]).update!(position: 9)
        PamDsl.rights.restrict!(subject: "TjTag$#{ids[restricted]}", ground: :accuracy_contested)
        Lyra::Rights.refresh!
        Lyra.with_purpose(:tagging) { read.call(TjOwner.find(ids[:owner])) }
      end
    end
  end

  # destroy_all loads its records, as Active Record's does: a restricted
  # one raises RestrictedProcessingError before any is destroyed. ES-NoProj
  # destroyed it.
  def test_destroy_all_over_a_restricted_record_raises_as_its_load_does
    bind_policies
    answers = %i[monitor es_noproj].map do |mode|
      run_in(mode) do
        ids = seed
        PamDsl.rights.restrict!(subject: "TjTag$#{ids[:t1]}", ground: :accuracy_contested)
        Lyra::Rights.refresh!
        result = begin
          Lyra.with_purpose(:tagging) { TjTag.where(tj_item_id: ids[:i1]).destroy_all.size }
        rescue StandardError => e
          e.class.name
        end
        [result, TjTag.unscoped.order(:label).pluck(:label)]
      end
    end
    assert_equal answers.first, answers.last
    assert_equal "PamDsl::RestrictedProcessingError", answers.last.first
    assert_includes answers.last.last, "t1"
  end

  # --- default orders at both ends ---------------------------------------------

  # Pins order by rank (desc) by default, slots by position. Two pins of
  # rank 3: "a" in the second slot, "b" in the first. The join orders by
  # rank, then the slot's position, then the association's own order:
  # ORDER BY pins.rank DESC, slots.position, pins.label gives b before a.
  BOX_READS = {
    "pins" => ->(box) { box.pins.map(&:label) },
    "labeled pins" => ->(box) { box.labeled_pins.map(&:label) },
    "labeled pins first" => ->(box) { box.labeled_pins.first&.label },
    "labeled pins count" => ->(box) { box.labeled_pins.count },
    "labeled pins size" => ->(box) { box.labeled_pins.size },
    "labeled pins empty?" => ->(box) { box.labeled_pins.empty? },
    "labeled pins exists?" => ->(box) { box.labeled_pins.exists? },
    "labeled pins sum" => ->(box) { box.labeled_pins.sum(:rank) },
    "labeled pins where count" => ->(box) { box.labeled_pins.where(rank: 3).count },
    "labeled pins pluck" => ->(box) { box.labeled_pins.pluck(:label) },
    "plain pins (a source that unscopes the order)" => ->(box) { box.plain_pins.map(&:label).sort },
    "slot-ordered pins (an order on the step's table)" => ->(box) { box.slot_ordered_pins.map(&:label) },
    "marks count" => ->(box) { box.labeled_marks.count },
    "marks exists?" => ->(box) { box.labeled_marks.exists? }
  }.freeze

  BOX_READS.each do |name, read|
    define_method("test_box_#{name.gsub(/\W+/, '_')}") do
      assert_same_answer { |ids| read.call(TjBox.find(ids[:box])) }
    end
  end

  # Marks through pins through slots, ordered by their label: the join
  # orders by the pins' default scope (a step past the first) before it,
  # which ES-NoProj cannot reproduce. What lists the records in that order
  # (loading, first, pluck, ids) is refused; counting answers, and so does a
  # pluck in an order of its own.
  def test_an_order_the_join_cannot_be_matched_in_is_refused_only_where_it_is_used
    monitor = run_in(:monitor) { TjBox.find(seed[:box]).labeled_marks.map(&:label) }
    assert_equal 3, monitor.size
    run_in(:es_noproj) do
      marks = TjBox.find(seed[:box]).labeled_marks
      assert_equal [3, 3, 3, true], [marks.count, marks.size, marks.length, marks.exists?]
      %i[to_a first ids].each { |read| assert_raises(UnsupportedQuery, read.to_s) { marks.public_send(read) } }
      assert_raises(UnsupportedQuery) { marks.pluck(:label) }
      assert_raises(UnsupportedQuery) { marks.pluck(:id, :label) }
      assert_equal monitor.sort, marks.reorder(:label).pluck(:label)
    end
  end

  # A three-step chain ordered by a column two steps away (the item's
  # position, through tags): ES-NoProj cannot order by it, and refuses what
  # lists the notes in that order; counts and length answer as Monitor's.
  def test_an_order_two_steps_away_is_refused_where_it_lists
    monitor = run_in(:monitor) do
      notes = TjOwner.find(seed[:owner]).item_ordered_notes
      [notes.count, notes.length, notes.pluck(:label)]
    end
    run_in(:es_noproj) do
      notes = TjOwner.find(seed[:owner]).item_ordered_notes
      assert_equal monitor.first(2), [notes.count, notes.length]
      assert_raises(UnsupportedQuery) { notes.pluck(:label) }
      assert_raises(UnsupportedQuery) { notes.ids }
      assert_equal monitor.last.sort, notes.reorder(:label).pluck(:label)
    end
  end

  # owner.tag_items reaches i1 through t1 and t2: SQL updates its row once.
  def test_update_all_writes_a_record_reached_twice_once
    assert_same_answer do |ids|
      updated = ->(events) { events.count { _1.is_a?(Lyra::Event) && _1.data[:model_class] == "TjItem" && _1.data[:operation].to_s == "updated" } }
      before = Lyra.config.event_store.read.to_a
      count = TjOwner.find(ids[:owner]).tag_items.update_all(position: 7)
      [count, updated.call(Lyra.config.event_store.read.to_a - before), TjItem.order(:label).pluck(:label, :position)]
    end
  end

  # --- bulk writes on a collection ---------------------------------------------

  BULK_WRITES = {
    "update_all on a has_many" => ->(o) { o.own_tags.update_all(active: false) },
    "update_all nullifying a has_many's key" => ->(o) { o.own_tags.update_all(tj_owner_id: nil) },
    "update_all on a has_many :through" => ->(o) { o.tags.update_all(active: false) },
    "delete_all on a has_many" => ->(o) { o.own_tags.delete_all },
    "delete_all with :delete_all" => ->(o) { o.own_tags.delete_all(:delete_all) },
    "destroy_all on a has_many" => ->(o) { o.own_tags.destroy_all.size }
  }.freeze

  BULK_WRITES.each do |name, write|
    define_method("test_bulk_#{name.gsub(/\W+/, '_')}") do
      assert_same_answer do |ids|
        result = write.call(TjOwner.find(ids[:owner]))
        state = TjTag.unscoped.order(:label).map { [_1.label, _1.active, _1.tj_owner_id == ids[:owner]] }
        [result.is_a?(Integer) ? result : nil, state, TjOwner.find(ids[:owner]).own_tags.count]
      end
    end
  end

  private

  def seed
    owner = TjOwner.create!(name: "owner")
    other = TjOwner.create!(name: "other")
    i1 = TjItem.create!(label: "i1", tj_owner_id: owner.id, position: 2)
    i2 = TjSpecialItem.create!(label: "i2", tj_owner_id: owner.id, position: 1)
    gone = TjItem.create!(label: "gone", tj_owner_id: owner.id, position: 0, deleted_at: Time.utc(2026))
    t1 = TjTag.create!(label: "t1", tj_item_id: i1.id, tj_owner_id: owner.id)
    t2 = TjHotTag.create!(label: "t2", tj_item_id: i1.id, active: false)
    t3 = TjTag.create!(label: "t3", tj_item_id: i2.id)
    TjTag.create!(label: "tdel", tj_item_id: i2.id, deleted_at: Time.utc(2026))
    TjTag.create!(label: "tgone", tj_item_id: gone.id)
    TjNote.create!(label: "n1", tj_tag_id: t1.id)
    TjNote.create!(label: "n3", tj_tag_id: t3.id)
    TjNote.create!(label: "n3b", tj_tag_id: t3.id)
    TjComment.create!(label: "c1", commentable: i1, tj_owner_id: owner.id)
    TjComment.create!(label: "c2", commentable: t3, tj_owner_id: owner.id)
    TjComment.create!(label: "c3", commentable: i1, tj_owner_id: owner.id)
    TjLink.create!(tj_owner_id: owner.id, tj_tag_id: t1.id)
    TjLink.create!(tj_owner_id: owner.id, tj_tag_id: t3.id)
    box = TjBox.create!(name: "box")
    first = TjSlot.create!(tj_box_id: box.id, position: 1)
    second = TjSlot.create!(tj_box_id: box.id, position: 2)
    [["a", 3, second], ["b", 3, first], ["c", 1, first], ["d", 2, second]].each do |label, rank, slot|
      pin = TjPin.create!(label: label, rank: rank, tj_slot_id: slot.id)
      TjMark.create!(label: "m#{label}", tj_pin_id: pin.id) unless label == "c"
    end
    { owner: owner.id, other: other.id, i1: i1.id, i2: i2.id, t1: t1.id, t2: t2.id, t3: t3.id, box: box.id }
  end

  # Items' label is not for :tagging (items: true); tags' is.
  def bind_policies(items: false)
    PamDsl.define_policy(:tj_item_policy) do
      field :label, type: :custom
      field :position, type: :custom
      purpose(:tagging) do
        basis :contract
        requires :position
      end
    end
    PamDsl.define_policy(:tj_tag_policy) do
      field :label, type: :custom
      purpose(:tagging) do
        basis :contract
        requires :label
      end
    end
    bound = { TjTag => :tj_tag_policy, TjHotTag => :tj_tag_policy }
    bound.merge!(TjItem => :tj_item_policy, TjSpecialItem => :tj_item_policy) if items
    bound.each do |model, policy|
      model.monitor_with_lyra(privacy_policy: policy)
      Lyra.config.monitor_model(model, privacy_policy: policy)
    end
  end

  # The block's answer (or the class of what it raised) in Monitor and in
  # ES-NoProj, from the same seed; with +purpose+, under :tagging.
  def assert_same_answer(purpose: false, &block)
    answers = %i[monitor es_noproj].map do |mode|
      run_in(mode) do
        ids = seed
        purpose ? Lyra.with_purpose(:tagging) { block.call(ids) } : block.call(ids)
      rescue StandardError => e
        e.class.name
      end
    end
    refute_equal UnsupportedQuery.name, answers.first
    answers.first.nil? ? assert_nil(answers.last) : assert_equal(answers.first, answers.last)
  end

  def define_models
    MODELS.each { Object.send(:remove_const, _1) if Object.const_defined?(_1) }
    Object.const_set(:TjLink, Class.new(ActiveRecord::Base) do
      self.table_name = "lyra_tj_links"
      belongs_to :tag, class_name: "TjTag", foreign_key: :tj_tag_id
    end)
    Object.const_set(:TjComment, Class.new(ActiveRecord::Base) do
      self.table_name = "lyra_tj_comments"
      belongs_to :commentable, polymorphic: true
    end)
    Object.const_set(:TjNote, Class.new(ActiveRecord::Base) do
      self.table_name = "lyra_tj_notes"
      belongs_to :tag, class_name: "TjTag", foreign_key: :tj_tag_id, optional: true
      has_one :item, through: :tag
      has_one :owner, through: :tag
    end)
    Object.const_set(:TjTag, Class.new(ActiveRecord::Base) do
      self.table_name = "lyra_tj_tags"
      default_scope { where(deleted_at: nil) }
      belongs_to :item, class_name: "TjItem", foreign_key: :tj_item_id, optional: true
      has_many :notes, class_name: "TjNote", foreign_key: :tj_tag_id
      has_one :owner, through: :item, source: :tj_owner
      has_many :sibling_tags, through: :item, source: :tags
    end)
    Object.const_set(:TjHotTag, Class.new(TjTag))
    Object.const_set(:TjItem, Class.new(ActiveRecord::Base) do
      self.table_name = "lyra_tj_items"
      default_scope { where(deleted_at: nil) }
      belongs_to :tj_owner, class_name: "TjOwner", optional: true
      has_many :tags, class_name: "TjTag", foreign_key: :tj_item_id
      has_one :tag, class_name: "TjTag", foreign_key: :tj_item_id
      has_one :latest_tag, -> { order(label: :desc) }, class_name: "TjTag", foreign_key: :tj_item_id
      has_many :active_tags, -> { where(active: true) }, class_name: "TjTag", foreign_key: :tj_item_id
      has_many :hot_tags, class_name: "TjHotTag", foreign_key: :tj_item_id
      has_many :any_tags, -> { unscope(where: :deleted_at) }, class_name: "TjTag", foreign_key: :tj_item_id
      has_many :notes, through: :tags, source: :notes
      has_many :children, class_name: "TjItem", foreign_key: :parent_id
      has_many :grandchildren, through: :children, source: :children
    end)
    Object.const_set(:TjSpecialItem, Class.new(TjItem))
    Object.const_set(:TjOwner, Class.new(ActiveRecord::Base) do
      self.table_name = "lyra_tj_owners"
      has_many :items, class_name: "TjItem", foreign_key: :tj_owner_id
      has_many :special_items, class_name: "TjSpecialItem", foreign_key: :tj_owner_id
      has_one :first_item, -> { order(:position) }, class_name: "TjItem", foreign_key: :tj_owner_id
      has_many :tags, through: :items, source: :tags
      has_many :notes, through: :tags, source: :notes
      has_many :notes_via_items, through: :items, source: :notes
      has_many :active_tags, through: :items, source: :active_tags
      has_many :scoped_tags, -> { where(active: true) }, through: :items, source: :tags
      has_many :ordered_tags, -> { order(label: :desc) }, through: :items, source: :tags
      has_many :limited_tags, -> { order(:label).limit(2) }, through: :items, source: :tags
      has_many :hot_tags, through: :items, source: :hot_tags
      has_many :special_item_tags, through: :special_items, source: :tags
      has_many :comments, class_name: "TjComment", foreign_key: :tj_owner_id
      has_many :commented_items, through: :comments, source: :commentable, source_type: "TjItem"
      has_many :commented_tags, through: :comments, source: :commentable, source_type: "TjTag"
      has_many :links, class_name: "TjLink", foreign_key: :tj_owner_id
      has_many :linked_tags, through: :links, source: :tag
      has_one :link, class_name: "TjLink", foreign_key: :tj_owner_id
      has_one :link_tag, through: :link, source: :tag
      has_one :first_link, -> { order(:tj_tag_id) }, class_name: "TjLink", foreign_key: :tj_owner_id
      has_one :first_link_tag, through: :first_link, source: :tag
      has_many :latest_tags, through: :items, source: :latest_tag
      has_one :first_tag, through: :first_item, source: :tag
      has_one :first_latest_tag, through: :first_item, source: :latest_tag
      has_many :any_tags, through: :items, source: :any_tags
      has_many :own_tags, class_name: "TjTag", foreign_key: :tj_owner_id
      has_many :tag_items, through: :tags, source: :item
      has_many :distinct_tag_items, -> { distinct }, through: :tags, source: :item
      has_many :position_items, -> { order(:position) }, class_name: "TjItem", foreign_key: :tj_owner_id
      has_many :position_tags, through: :position_items, source: :tags
      has_many :position_latest_tags, through: :position_items, source: :latest_tag
      has_many :item_ordered_notes, -> { order(TjItem.arel_table[:position].desc) }, through: :tags, source: :notes
    end)
    Object.const_set(:TjMark, Class.new(ActiveRecord::Base) { self.table_name = "lyra_tj_marks" })
    Object.const_set(:TjPin, Class.new(ActiveRecord::Base) do
      self.table_name = "lyra_tj_pins"
      default_scope { order(rank: :desc) }
      has_many :marks, class_name: "TjMark", foreign_key: :tj_pin_id
    end)
    Object.const_set(:TjSlot, Class.new(ActiveRecord::Base) do
      self.table_name = "lyra_tj_slots"
      default_scope { order(:position) }
      has_many :pins, class_name: "TjPin", foreign_key: :tj_slot_id
      has_many :plain_pins, -> { unscope(:order) }, class_name: "TjPin", foreign_key: :tj_slot_id
    end)
    Object.const_set(:TjBox, Class.new(ActiveRecord::Base) do
      self.table_name = "lyra_tj_boxes"
      has_many :slots, class_name: "TjSlot", foreign_key: :tj_box_id
      has_many :pins, through: :slots
      has_many :labeled_pins, -> { order(:label) }, through: :slots, source: :pins
      has_many :plain_pins, through: :slots, source: :plain_pins
      has_many :slot_ordered_pins, -> { order(TjSlot.arel_table[:position].desc) }, through: :slots, source: :pins
      has_many :labeled_marks, -> { order(:label) }, through: :pins, source: :marks
    end)
    MONITORED.each do |name|
      model = Object.const_get(name)
      model.include(Lyra::Interceptors::CrudInterceptor)
      model.monitor_with_lyra
      Lyra.config.monitor_model(model)
    end
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
    yield
  end

  def clean
    TABLES.each { connection.execute("DELETE FROM #{_1}") if connection.table_exists?(_1) }
    connection.execute("DELETE FROM event_store_events_in_streams")
    connection.execute("DELETE FROM event_store_events")
    LyraRightsIsolation.purge! if defined?(LyraRightsIsolation)
    MONITORED.each do |name|
      Lyra::Projections::CachedProjection.invalidate_all(Object.const_get(name)) if Object.const_defined?(name)
    end
  end

  def connection = ActiveRecord::Base.connection
end
