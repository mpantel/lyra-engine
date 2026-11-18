# frozen_string_literal: true

require "test_helper"

# A has_one read under ES-NoProj, from the events, against the same read in
# Monitor (Active Record's query on the table).
#
# - A polymorphic has_one (as:) matches the owner's type as well as its key,
#   as the has_many path does: it used to return a record of another type
#   of owner with the same id.
# - A has_one with a scope of its own (a where, an order) is narrowed by it,
#   the first record in its order: the scope used to be left out.
# - A has_one :through another has_one reaches the target through every
#   intermediate record of the owner, as Active Record's join does, narrowed
#   by both associations' scopes: ordered, the first target in that order;
#   in no order, none or one target, and more than one is refused.
class EsNoprojHasOneTest < Minitest::Test
  TABLES = %w[lyra_ho_owners lyra_ho_others lyra_ho_items lyra_ho_tags].freeze
  UnsupportedQuery = Lyra::Projections::UnsupportedQuery
  MODELS = %i[HoOwner HoOther HoItem HoRankedItem HoTag].freeze

  def setup
    skip "Requires Rails and PostgreSQL" unless defined?(ActiveRecord::Base) && connection.adapter_name.match?(/postgres/i)

    connection.create_table(:lyra_ho_owners, force: true) { |t| t.string :name }
    connection.create_table(:lyra_ho_others, force: true) { |t| t.string :name }
    connection.create_table(:lyra_ho_items, force: true) do |t|
      t.string :label
      t.string :kind
      t.bigint :owner_id
      t.string :owner_type
      t.bigint :ho_owner_id
    end
    connection.create_table(:lyra_ho_tags, force: true) do |t|
      t.string :label
      t.bigint :ho_item_id
    end
    MODELS.each { Object.send(:remove_const, _1) if Object.const_defined?(_1) }
    Object.const_set(:HoItem, Class.new(ActiveRecord::Base) do
      self.table_name = "lyra_ho_items"
      belongs_to :owner, polymorphic: true, optional: true
      has_one :ho_tag, class_name: "HoTag", foreign_key: :ho_item_id
    end)
    Object.const_set(:HoTag, Class.new(ActiveRecord::Base) { self.table_name = "lyra_ho_tags" })
    # The same rows, in an order of the model's own.
    Object.const_set(:HoRankedItem, Class.new(ActiveRecord::Base) do
      self.table_name = "lyra_ho_items"
      default_scope { order(label: :desc) }
      has_one :ho_tag, class_name: "HoTag", foreign_key: :ho_item_id
    end)
    Object.const_set(:HoOwner, Class.new(ActiveRecord::Base) do
      self.table_name = "lyra_ho_owners"
      has_one :item, as: :owner, class_name: "HoItem"
      has_one :own_item, class_name: "HoItem", foreign_key: :ho_owner_id
      has_one :tag, through: :own_item, source: :ho_tag
      has_one :latest_item, -> { order(id: :desc) }, class_name: "HoItem", foreign_key: :ho_owner_id
      has_one :special_item, -> { where(kind: "special") }, class_name: "HoItem", foreign_key: :ho_owner_id
      has_one :lower_special_item, -> { where("lower(kind) = 'special'") }, class_name: "HoItem", foreign_key: :ho_owner_id
      has_one :latest_tag, through: :latest_item, source: :ho_tag
      has_one :special_tag, through: :special_item, source: :ho_tag
      has_one :tag_labelled_second, -> { where(label: "second") }, through: :own_item, source: :ho_tag
      has_one :ranked_item, class_name: "HoRankedItem", foreign_key: :ho_owner_id
      has_one :ranked_tag, through: :ranked_item, source: :ho_tag
    end)
    Object.const_set(:HoOther, Class.new(ActiveRecord::Base) do
      self.table_name = "lyra_ho_others"
      has_one :item, as: :owner, class_name: "HoItem"
    end)
    MODELS.each do |name|
      model = Object.const_get(name)
      model.include(Lyra::Interceptors::CrudInterceptor)
      model.monitor_with_lyra
      Lyra.config.monitor_model(model)
    end
    clean
    Rails.cache.clear
  end

  def teardown
    return unless Object.const_defined?(:HoOwner)

    Lyra.config.enable_monitor!
    Lyra.config.projection_mode = :sync
    clean
    Rails.cache.clear
    TABLES.each { connection.drop_table(_1, if_exists: true) }
  end

  # Owners of two types with the same id: each reads its own item.
  def test_a_polymorphic_has_one_matches_the_owner_s_type
    assert_same_answer do
      owner = HoOwner.create!(id: 7, name: "owner")
      other = HoOther.create!(id: 7, name: "other")
      HoItem.create!(label: "the other's", owner: other)
      HoItem.create!(label: "the owner's", owner: owner)
      lonely = HoOther.create!(id: 8, name: "no item")
      HoItem.create!(label: "an owner's 8", owner_id: 8, owner_type: "HoOwner")
      [HoOwner.find(7).item&.label, HoOther.find(7).item&.label, HoOther.find(lonely.id).item&.label]
    end
  end

  def test_a_has_one_through_a_has_one_with_one_intermediate_record
    assert_same_answer do
      owner = HoOwner.create!(name: "owner")
      item = HoItem.create!(label: "item", ho_owner_id: owner.id)
      HoTag.create!(label: "tag", ho_item_id: item.id)
      HoOwner.find(owner.id).tag&.label
    end
  end

  # Two intermediate records, one of them with a tag: the join reaches that
  # tag whichever intermediate record the has_one would read.
  def test_a_has_one_through_a_has_one_reaches_the_one_target_any_intermediate_has
    assert_same_answer do
      owner = HoOwner.create!(name: "owner")
      HoItem.create!(label: "untagged", ho_owner_id: owner.id)
      tagged = HoItem.create!(label: "tagged", ho_owner_id: owner.id)
      HoTag.create!(label: "tag", ho_item_id: tagged.id)
      HoItem.create!(label: "untagged too", ho_owner_id: owner.id)
      HoOwner.find(owner.id).tag&.label
    end
  end

  # --- a has_one's own scope -------------------------------------------------

  def test_a_has_one_with_a_where_scope_reads_the_record_it_selects
    assert_same_answer do
      owner = HoOwner.create!(name: "owner")
      HoItem.create!(label: "plain", kind: "plain", ho_owner_id: owner.id)
      HoItem.create!(label: "special", kind: "special", ho_owner_id: owner.id)
      none = HoOwner.create!(name: "none")
      HoItem.create!(label: "plain too", kind: "plain", ho_owner_id: none.id)
      [HoOwner.find(owner.id).special_item&.label, HoOwner.find(none.id).special_item&.label]
    end
  end

  def test_a_has_one_with_an_order_scope_reads_the_first_record_in_that_order
    assert_same_answer do
      owner = HoOwner.create!(name: "owner")
      %w[older middle newer].each { |label| HoItem.create!(label: label, ho_owner_id: owner.id) }
      HoOwner.find(owner.id).latest_item&.label
    end
  end

  def test_a_has_one_scope_it_cannot_evaluate_is_refused
    run_in(:monitor) do
      owner = HoOwner.create!(name: "owner")
      HoItem.create!(label: "special", kind: "SPECIAL", ho_owner_id: owner.id)
      assert_equal "special", HoOwner.find(owner.id).lower_special_item&.label
    end
    run_in(:es_noproj) do
      owner = HoOwner.create!(name: "owner")
      HoItem.create!(label: "special", kind: "SPECIAL", ho_owner_id: owner.id)
      assert_raises(UnsupportedQuery) { HoOwner.find(owner.id).lower_special_item }
    end
  end

  # --- has_one :through a has_one, with scopes ---------------------------------

  # Through an ordered has_one: the target of the first intermediate record
  # in that order.
  def test_a_has_one_through_an_ordered_has_one_reaches_the_first_target_in_its_order
    assert_same_answer do
      owner_id = seed_two_intermediates
      HoOwner.find(owner_id).latest_tag&.label
    end
  end

  # Through a has_one whose where selects one intermediate record.
  def test_a_has_one_through_a_scoped_has_one
    assert_same_answer do
      owner = HoOwner.create!(name: "owner")
      %w[plain special].each do |kind|
        item = HoItem.create!(label: kind, kind: kind, ho_owner_id: owner.id)
        HoTag.create!(label: "#{kind} tag", ho_item_id: item.id)
      end
      HoOwner.find(owner.id).special_tag&.label
    end
  end

  # The association's own scope narrows the targets before they are
  # counted: one is left, and it is the answer.
  # Through a has_one whose model's default scope orders: the join orders by
  # it (ORDER BY label DESC LIMIT 1), and so does ES-NoProj; it used to
  # refuse, the scope's order not counted as one.
  def test_a_has_one_through_a_has_one_ordered_by_its_model_s_default_scope
    assert_same_answer do
      owner = HoOwner.create!(name: "owner")
      %w[first second].each do |label|
        item = HoRankedItem.create!(label: label, ho_owner_id: owner.id)
        HoTag.create!(label: label, ho_item_id: item.id)
      end
      HoOwner.find(owner.id).ranked_tag&.label
    end
  end

  def test_the_through_association_s_scope_narrows_the_targets_before_they_are_counted
    assert_same_answer do
      owner_id = seed_two_intermediates
      HoOwner.find(owner_id).tag_labelled_second&.label
    end
  end

  # Two intermediate records: Active Record's join may answer with either
  # one's tag; ES-NoProj would follow only the one its has_one read.
  def test_a_has_one_through_a_has_one_with_several_intermediate_records_is_refused
    owner_id = run_in(:monitor) { seed_two_intermediates }
    assert_includes %w[first second], run_in(:monitor, clean: false) { HoOwner.find(owner_id).tag&.label }

    run_in(:es_noproj) do
      owner_id = seed_two_intermediates
      assert_raises(UnsupportedQuery) { HoOwner.find(owner_id).tag }
    end
  end

  private

  def seed_two_intermediates
    owner = HoOwner.create!(name: "owner")
    %w[first second].each do |label|
      item = HoItem.create!(label: label, ho_owner_id: owner.id)
      HoTag.create!(label: label, ho_item_id: item.id)
    end
    owner.id
  end

  def assert_same_answer(&block)
    expected = run_in(:monitor, &block)
    got = run_in(:es_noproj) do
      result = block.call
      assert_equal 0, Lyra::ModeTransition.send(:bypass) { HoItem.unscoped.count }, "ES-NoProj has no rows"
      result
    end
    assert_equal expected, got
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
