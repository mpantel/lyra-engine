# frozen_string_literal: true

require "test_helper"

# :through associations, and has_ones that unscope, read under ES-NoProj from
# the events, against the same read in Monitor (Active Record's join on the
# tables).
#
# - An association scope that unscopes (-> { unscope(where: :deleted_at) },
#   as -> { with_discarded } does) brings back a target the target's
#   default scope leaves out, on a has_one, a has_one :through and a
#   has_many :through, and so does a source belongs_to's: the source reader
#   used to have removed it already.
# - A has_one :through another has_one :through reaches the target through
#   every candidate, as the join does: it used to follow only the one
#   intermediate record that association read. In no order, more than one
#   target is refused.
# - The intermediate records are read afresh, not taken from the owner's
#   loaded association (which may be stale), and reading the target leaves
#   that association as it was: it used to use and load it.
# - A has_many :through reaching a target through two intermediate records
#   has it twice, as the join does; -> { distinct } keeps one.
#
# Items and tags are soft-deleted (deleted_at, left out by a default scope).
class EsNoprojThroughTest < Minitest::Test
  TABLES = %w[lyra_at_owners lyra_at_items lyra_at_tags lyra_at_notes].freeze
  UnsupportedQuery = Lyra::Projections::UnsupportedQuery
  MODELS = %i[AtOwner AtItem AtTag AtNote].freeze

  def setup
    skip "Requires Rails and PostgreSQL" unless defined?(ActiveRecord::Base) && connection.adapter_name.match?(/postgres/i)

    connection.create_table(:lyra_at_owners, force: true) { |t| t.string :name }
    connection.create_table(:lyra_at_items, force: true) do |t|
      t.string :label
      t.bigint :at_owner_id
      t.datetime :deleted_at
    end
    connection.create_table(:lyra_at_tags, force: true) do |t|
      t.string :label
      t.bigint :at_item_id
      t.bigint :at_owner_id
      t.datetime :deleted_at
    end
    connection.create_table(:lyra_at_notes, force: true) do |t|
      t.string :label
      t.bigint :at_tag_id
    end
    define_models
    clean
    Rails.cache.clear
  end

  def teardown
    return unless Object.const_defined?(:AtOwner)

    Lyra.config.enable_monitor!
    Lyra.config.projection_mode = :sync
    clean
    Rails.cache.clear
    TABLES.each { connection.drop_table(_1, if_exists: true) }
  end

  # --- an association scope that unscopes -----------------------------------

  def test_a_has_one_that_unscopes_reads_a_target_the_default_scope_leaves_out
    assert_same_answer do
      owner = AtOwner.create!(name: "owner")
      AtItem.create!(label: "deleted", at_owner_id: owner.id, deleted_at: Time.utc(2026))
      owner = AtOwner.find(owner.id)
      [owner.item&.label, owner.any_item&.label]
    end
  end

  def test_a_has_one_through_that_unscopes_reads_a_target_the_default_scope_leaves_out
    assert_same_answer do
      owner = AtOwner.create!(name: "owner")
      item = AtItem.create!(label: "item", at_owner_id: owner.id)
      AtTag.create!(label: "deleted tag", at_item_id: item.id, deleted_at: Time.utc(2026))
      owner = AtOwner.find(owner.id)
      [owner.tag&.label, owner.any_tag&.label]
    end
  end

  # The unscoping is the target's: an intermediate record its own default
  # scope leaves out still leads nowhere, in the join as here.
  def test_a_has_one_through_that_unscopes_does_not_follow_a_deleted_intermediate_record
    assert_same_answer do
      owner = AtOwner.create!(name: "owner")
      item = AtItem.create!(label: "deleted item", at_owner_id: owner.id, deleted_at: Time.utc(2026))
      AtTag.create!(label: "tag", at_item_id: item.id)
      AtOwner.find(owner.id).any_tag&.label
    end
  end

  def test_a_has_many_through_that_unscopes_reads_targets_the_default_scope_leaves_out
    assert_same_answer do
      owner = AtOwner.create!(name: "owner")
      item = AtItem.create!(label: "item", at_owner_id: owner.id)
      AtTag.create!(label: "kept", at_item_id: item.id)
      AtTag.create!(label: "deleted", at_item_id: item.id, deleted_at: Time.utc(2026))
      owner = AtOwner.find(owner.id)
      [owner.tags.map(&:label).sort, owner.any_tags.map(&:label).sort, owner.any_tags.count]
    end
  end

  # belongs_to :any_item, -> { unscope(where: :deleted_at) }: the source's
  # scope unscopes the target in the join too (Solidus's with_discarded
  # belongs_to hops). The has_many :through path narrowed by the target's
  # whole default scope again.
  def test_a_source_belongs_to_that_unscopes_brings_the_target_back
    assert_same_answer do
      owner = AtOwner.create!(name: "owner")
      kept = AtItem.create!(label: "kept")
      deleted = AtItem.create!(label: "deleted", deleted_at: Time.utc(2026))
      [kept, deleted].each { |item| AtTag.create!(label: item.label, at_item_id: item.id, at_owner_id: owner.id) }
      owner = AtOwner.find(owner.id)
      [owner.tagged_items.map(&:label).sort, owner.tagged_any_items.map(&:label).sort]
    end
  end

  # An unscope on the collection: Active Record's drops the column's
  # predicate from every table of the join, the intermediate model's default
  # scope included (the soft-deleted tag's item comes back too). ES-NoProj
  # read the intermediate records through that default scope, and refuses.
  def test_unscoping_a_has_many_through_on_a_column_of_an_intermediate_default_scope_is_refused
    seed = lambda do
      owner = AtOwner.create!(name: "owner")
      kept = AtItem.create!(label: "kept")
      deleted = AtItem.create!(label: "deleted", deleted_at: Time.utc(2026))
      [kept, deleted].each { |item| AtTag.create!(label: item.label, at_item_id: item.id, at_owner_id: owner.id) }
      AtTag.create!(label: "deleted tag", at_item_id: kept.id, at_owner_id: owner.id, deleted_at: Time.utc(2026))
      owner.id
    end
    unscoped = ->(id) { AtOwner.find(id).tagged_items.unscope(where: :deleted_at).map(&:label).sort }

    assert_equal %w[deleted kept kept], run_in(:monitor) { unscoped.call(seed.call) }
    run_in(:es_noproj) do
      id = seed.call
      assert_raises(UnsupportedQuery) { unscoped.call(id) }
      assert_equal %w[kept], AtOwner.find(id).tagged_items.map(&:label)
    end
  end

  # --- has_one :through another has_one :through ----------------------------

  def test_a_has_one_through_a_has_one_through_reaches_the_one_target_any_candidate_has
    assert_same_answer do
      owner = AtOwner.create!(name: "owner")
      AtItem.create!(label: "untagged", at_owner_id: owner.id)
      item = AtItem.create!(label: "tagged", at_owner_id: owner.id)
      AtTag.create!(label: "no note", at_item_id: item.id)
      noted = AtItem.create!(label: "noted", at_owner_id: owner.id)
      tag = AtTag.create!(label: "noted", at_item_id: noted.id)
      AtNote.create!(label: "the note", at_tag_id: tag.id)
      AtOwner.find(owner.id).note&.label
    end
  end

  def test_a_has_one_through_an_ordered_has_one_through_reaches_the_first_target_in_its_order
    assert_same_answer do
      owner_id = seed_two_notes
      AtOwner.find(owner_id).latest_note&.label
    end
  end

  # Two candidates in no order: Active Record's join may answer with either
  # note; ES-NoProj followed the one tag its has_one :through read.
  def test_a_has_one_through_a_has_one_through_with_several_targets_in_no_order_is_refused
    owner_id = run_in(:monitor) { seed_two_notes }
    assert_includes %w[first second], run_in(:monitor, clean: false) { AtOwner.find(owner_id).note&.label }

    run_in(:es_noproj) do
      owner_id = seed_two_notes
      assert_raises(UnsupportedQuery) { AtOwner.find(owner_id).note }
    end
  end

  # One intermediate record with two tags: the join reaches both, and the
  # source reader would have answered with the one it read.
  def test_a_has_one_through_a_has_one_source_with_several_candidates_is_refused
    owner_id = run_in(:monitor) { seed_one_item_two_tags }
    assert_includes %w[first second], run_in(:monitor, clean: false) { AtOwner.find(owner_id).tag&.label }

    run_in(:es_noproj) do
      owner_id = seed_one_item_two_tags
      assert_raises(UnsupportedQuery) { AtOwner.find(owner_id).tag }
    end
  end

  # --- a stale intermediate record -------------------------------------------

  # The owner's item is loaded, then moved to another owner through another
  # instance: the join reads the tables, and finds the owner's new item's tag.
  def test_a_has_one_through_does_not_use_a_stale_loaded_intermediate_record
    assert_same_answer do
      owner, other = %w[owner other].map { AtOwner.create!(name: _1) }
      old = AtItem.create!(label: "old", at_owner_id: owner.id)
      AtTag.create!(label: "old tag", at_item_id: old.id)
      owner = AtOwner.find(owner.id)
      loaded = owner.item.label
      AtItem.find(old.id).update!(at_owner_id: other.id)
      current = AtItem.create!(label: "new", at_owner_id: owner.id)
      AtTag.create!(label: "new tag", at_item_id: current.id)
      [loaded, owner.tag&.label, owner.item.label]
    end
  end

  def test_a_has_one_through_a_belongs_to_does_not_use_a_stale_loaded_intermediate_record
    assert_same_answer do
      owner, other = %w[owner other].map { AtOwner.create!(name: _1) }
      item = AtItem.create!(label: "item", at_owner_id: owner.id)
      tag = AtTag.find(AtTag.create!(label: "tag", at_item_id: item.id).id)
      loaded = tag.item.at_owner_id == owner.id
      AtItem.find(item.id).update!(at_owner_id: other.id)
      [loaded, tag.owner&.name]
    end
  end

  def test_a_has_many_through_does_not_use_stale_loaded_intermediate_records
    assert_same_answer do
      owner, other = %w[owner other].map { AtOwner.create!(name: _1) }
      %w[stays moves].each do |label|
        item = AtItem.create!(label: label, at_owner_id: owner.id)
        AtTag.create!(label: label, at_item_id: item.id)
      end
      owner = AtOwner.find(owner.id)
      loaded = owner.items.map(&:label).sort
      AtItem.find_by(label: "moves").update!(at_owner_id: other.id)
      [loaded, owner.tags.map(&:label).sort]
    end
  end

  # Reading through leaves the intermediate association unloaded, as the
  # join does.
  def test_reading_through_leaves_the_intermediate_association_unloaded
    assert_same_answer do
      owner = AtOwner.create!(name: "owner")
      item = AtItem.create!(label: "item", at_owner_id: owner.id)
      tag = AtTag.create!(label: "tag", at_item_id: item.id)
      AtNote.create!(label: "note", at_tag_id: tag.id)
      owner = AtOwner.find(owner.id)
      tag = AtTag.find(tag.id)
      answers = [owner.tag&.label, owner.note&.label, owner.tags.map(&:label), tag.owner&.name]
      answers + [owner.association(:item).loaded?, owner.association(:items).loaded?,
                 owner.association(:tag).loaded?, tag.association(:item).loaded?]
    end
  end

  # --- a target reached twice ------------------------------------------------

  def test_a_has_many_through_has_a_target_reached_twice_twice
    assert_same_answer do
      owner = AtOwner.create!(name: "owner")
      2.times { |i| AtItem.create!(label: "item #{i}", at_owner_id: owner.id) }
      owner = AtOwner.find(owner.id)
      [owner.item_owners.map(&:name), owner.item_owners.count, owner.distinct_item_owners.map(&:name)]
    end
  end

  private

  def define_models
    MODELS.each { Object.send(:remove_const, _1) if Object.const_defined?(_1) }
    Object.const_set(:AtNote, Class.new(ActiveRecord::Base) { self.table_name = "lyra_at_notes" })
    Object.const_set(:AtTag, Class.new(ActiveRecord::Base) do
      self.table_name = "lyra_at_tags"
      default_scope { where(deleted_at: nil) }
      belongs_to :item, class_name: "AtItem", foreign_key: :at_item_id, optional: true
      belongs_to :any_item, -> { unscope(where: :deleted_at) }, class_name: "AtItem", foreign_key: :at_item_id, optional: true
      has_one :note, class_name: "AtNote", foreign_key: :at_tag_id
      has_one :owner, through: :item, source: :at_owner
    end)
    Object.const_set(:AtItem, Class.new(ActiveRecord::Base) do
      self.table_name = "lyra_at_items"
      default_scope { where(deleted_at: nil) }
      belongs_to :at_owner, class_name: "AtOwner", optional: true
      has_one :tag, class_name: "AtTag", foreign_key: :at_item_id
      has_many :tags, class_name: "AtTag", foreign_key: :at_item_id
    end)
    Object.const_set(:AtOwner, Class.new(ActiveRecord::Base) do
      self.table_name = "lyra_at_owners"
      has_one :item, class_name: "AtItem", foreign_key: :at_owner_id
      has_one :any_item, -> { unscope(where: :deleted_at) }, class_name: "AtItem", foreign_key: :at_owner_id
      has_one :latest_item, -> { order(id: :desc) }, class_name: "AtItem", foreign_key: :at_owner_id
      has_one :tag, through: :item
      has_one :any_tag, -> { unscope(where: :deleted_at) }, through: :item, source: :tag
      has_one :latest_tag, through: :latest_item, source: :tag
      has_one :note, through: :tag
      has_one :latest_note, through: :latest_tag, source: :note
      has_many :items, class_name: "AtItem", foreign_key: :at_owner_id
      has_many :tags, through: :items, source: :tags
      has_many :any_tags, -> { unscope(where: :deleted_at) }, through: :items, source: :tags
      has_many :item_owners, through: :items, source: :at_owner
      has_many :distinct_item_owners, -> { distinct }, through: :items, source: :at_owner
      has_many :own_tags, class_name: "AtTag", foreign_key: :at_owner_id
      has_many :tagged_items, through: :own_tags, source: :item
      has_many :tagged_any_items, through: :own_tags, source: :any_item
    end)
    MODELS.each do |name|
      model = Object.const_get(name)
      model.include(Lyra::Interceptors::CrudInterceptor)
      model.monitor_with_lyra
      Lyra.config.monitor_model(model)
    end
  end

  # An owner with two items, each with a tag with a note.
  def seed_two_notes
    owner = AtOwner.create!(name: "owner")
    %w[first second].each do |label|
      item = AtItem.create!(label: label, at_owner_id: owner.id)
      tag = AtTag.create!(label: label, at_item_id: item.id)
      AtNote.create!(label: label, at_tag_id: tag.id)
    end
    owner.id
  end

  def seed_one_item_two_tags
    owner = AtOwner.create!(name: "owner")
    item = AtItem.create!(label: "item", at_owner_id: owner.id)
    %w[first second].each { |label| AtTag.create!(label: label, at_item_id: item.id) }
    owner.id
  end

  def assert_same_answer(&block)
    expected = run_in(:monitor, &block)
    got = run_in(:es_noproj) do
      result = block.call
      assert_equal 0, Lyra::ModeTransition.send(:bypass) { AtItem.unscoped.count + AtTag.unscoped.count }, "ES-NoProj has no rows"
      result
    end
    expected.nil? ? assert_nil(got) : assert_equal(expected, got)
  end

  def run_in(mode, clean: true)
    self.clean if clean
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
    MODELS.each do |name|
      Lyra::Projections::CachedProjection.invalidate_all(Object.const_get(name)) if Object.const_defined?(name)
    end
  end

  def connection = ActiveRecord::Base.connection
end
