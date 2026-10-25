# frozen_string_literal: true

require "test_helper"

# has_and_belongs_to_many links in every mode. The join table has no
# model of its own, so its inserts and deletes went unrecorded: the log never
# learnt that an item was given a tag. They are now AssociationLinked and
# AssociationUnlinked events on the owner's stream, linked into the tag's.
class HabtmLinksTest < Minitest::Test
  ITEMS = "lyra_habtm_items"
  TAGS = "lyra_habtm_tags"
  JOIN = "lyra_habtm_items_tags"
  MODES = %i[monitor hijack es_sync es_async es_noproj es_lazy].freeze

  def setup
    skip "Requires Rails and PostgreSQL" unless defined?(ActiveRecord::Base) && connection.adapter_name.match?(/postgres/i)

    connection.create_table(ITEMS, force: true) { |t| t.string :label; t.timestamps }
    connection.create_table(TAGS, force: true) { |t| t.string :name; t.timestamps }
    connection.create_table(JOIN, id: false, force: true) do |t|
      t.bigint :item_id, null: false
      t.bigint :tag_id, null: false
    end
    define_models
    clean
    Lyra.config.monitor_model(HabtmItem)
    Lyra.config.monitor_model(HabtmTag)
  end

  def teardown
    return unless defined?(HabtmItem)

    Lyra.reset_config!
    Lyra::Genesis.reset!
    clean
    [JOIN, ITEMS, TAGS].each { |table| connection.drop_table(table, if_exists: true) }
  end

  MODES.each do |mode|
    define_method("test_adding_a_tag_records_a_link_on_both_streams_in_#{mode}") do
      use(mode)
      item = HabtmItem.create!(label: "item")
      tag = HabtmTag.create!(name: "red")

      item.tags << tag

      assert_equal [[item.id, tag.id]], join_rows
      assert_equal [["linked", [tag.id]]], links(HabtmItem, item.id)
      assert_equal [["linked", [tag.id]]], links(HabtmTag, tag.id), "the tag's stream has the link too"
      assert_equal %w[red], HabtmItem.find(item.id).tags.map(&:name), "the link reads back"
      assert_equal %w[item], HabtmTag.find(tag.id).items.map(&:label)
      assert_clean(item, tag)
    end

    define_method("test_removing_and_clearing_record_unlinks_in_#{mode}") do
      use(mode)
      item = HabtmItem.create!(label: "item")
      red, blue, green = %w[red blue green].map { |name| HabtmTag.create!(name: name) }
      item.tags << [red, blue, green]

      item.tags.delete(red)
      assert_equal [blue.id, green.id].sort, join_rows.map(&:last).sort
      item.tags.clear

      assert_empty join_rows
      assert_equal [["linked", [red.id]], ["linked", [blue.id]], ["linked", [green.id]],
                    ["unlinked", [red.id]], ["unlinked", [blue.id, green.id].sort]],
                   links(HabtmItem, item.id).map { |op, ids| [op, ids.sort] }
      assert_clean(item, red, blue, green)
    end

    define_method("test_assigning_ids_links_and_unlinks_in_#{mode}") do
      use(mode)
      item = HabtmItem.create!(label: "item")
      red, blue = %w[red blue].map { |name| HabtmTag.create!(name: name) }
      item.tags << red

      item.tag_ids = [blue.id]

      assert_equal [[item.id, blue.id]], join_rows
      assert_includes links(HabtmItem, item.id), ["unlinked", [red.id]]
      assert_includes links(HabtmItem, item.id), ["linked", [blue.id]]
      assert_clean(item, red, blue)
    end

    define_method("test_creating_an_owner_with_tags_records_the_links_in_#{mode}") do
      use(mode)
      tag = HabtmTag.create!(name: "red")

      item = HabtmItem.create!(label: "item", tags: [tag])

      assert_equal [[item.id, tag.id]], join_rows
      assert_equal [["linked", [tag.id]]], links(HabtmItem, item.id)
      assert_clean(item, tag)
    end

    define_method("test_destroying_the_owner_unlinks_its_tags_in_#{mode}") do
      use(mode)
      item = HabtmItem.create!(label: "item")
      tag = HabtmTag.create!(name: "red")
      item.tags << tag

      item.destroy!

      assert_empty join_rows
      assert_equal ["linked", "unlinked"], links(HabtmItem, item.id).map(&:first)
      assert_clean(tag)
    end

    define_method("test_a_link_made_from_the_other_side_is_on_both_streams_in_#{mode}") do
      use(mode)
      item = HabtmItem.create!(label: "item")
      tag = HabtmTag.create!(name: "red")

      tag.items << item

      assert_equal [["linked", [item.id]]], links(HabtmTag, tag.id)
      assert_equal [["linked", [item.id]]], links(HabtmItem, item.id)
      assert_clean(item, tag)
    end
  end

  def test_the_link_events_leave_the_records_state_alone
    use(:es_sync)
    item = HabtmItem.create!(label: "item")
    item.tags << HabtmTag.create!(name: "red")

    state = Lyra::DualView.new(HabtmItem, item.id).event_sourced_state
    assert state[:exists]
    assert_equal "item", state[:state].with_indifferent_access[:label]
  end

  def test_dual_view_reports_a_link_made_behind_lyras_back
    use(:es_sync)
    item = HabtmItem.create!(label: "item")
    tag = HabtmTag.create!(name: "red")
    connection.execute("INSERT INTO #{JOIN} (item_id, tag_id) VALUES (#{item.id}, #{tag.id})")

    assert_equal({ "tags" => { crud: [tag.id.to_s], event_sourced: [] } },
                 Lyra::DualView.new(HabtmItem, item.id).calculate_differences)
  end

  def test_rebuild_restores_the_join_table_from_the_links
    use(:es_sync)
    item = HabtmItem.create!(label: "item")
    red, blue = %w[red blue].map { |name| HabtmTag.create!(name: name) }
    item.tags << [red, blue]
    item.tags.delete(red)
    connection.execute("DELETE FROM #{JOIN}")
    connection.execute("INSERT INTO #{JOIN} (item_id, tag_id) VALUES (#{item.id}, #{red.id})")

    stats = Lyra::Projections::Rebuild.rebuild(HabtmItem)

    assert_equal [[item.id, blue.id]], join_rows
    assert_equal 3, stats[:links]
  end

  def test_genesis_records_the_links_a_row_already_had
    Lyra.config.genesis = true
    use(:monitor)
    item_id = connection.select_value("INSERT INTO #{ITEMS} (label, created_at, updated_at) VALUES ('old', now(), now()) RETURNING id")
    tag_id = connection.select_value("INSERT INTO #{TAGS} (name, created_at, updated_at) VALUES ('old', now(), now()) RETURNING id")
    connection.execute("INSERT INTO #{JOIN} (item_id, tag_id) VALUES (#{item_id}, #{tag_id})")

    Lyra::Genesis.import_all(HabtmItem)
    Lyra::Genesis.import_all(HabtmTag)

    assert_equal [["linked", [tag_id]]], links(HabtmItem, item_id)
    assert_equal({ no_differences: true }, Lyra::DualView.new(HabtmItem, item_id).calculate_differences)
    assert_equal({ no_differences: true }, Lyra::DualView.new(HabtmTag, tag_id).calculate_differences)
  end

  def test_disabled_mode_records_nothing
    Lyra.config.disable!
    item = HabtmItem.create!(label: "item")
    item.tags << HabtmTag.create!(name: "red")
    item.tags.clear

    assert_empty Lyra.config.event_store.read.of_type([Lyra::Events::AssociationLinked, Lyra::Events::AssociationUnlinked]).to_a
  end

  private

  def define_models
    %i[HabtmItem HabtmTag].each { |name| Object.send(:remove_const, name) if Object.const_defined?(name) }
    Object.const_set(:HabtmItem, Class.new(ActiveRecord::Base))
    Object.const_set(:HabtmTag, Class.new(ActiveRecord::Base))
    HabtmItem.class_eval do
      self.table_name = ITEMS
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
      has_and_belongs_to_many :tags, class_name: "HabtmTag", join_table: JOIN,
                                     foreign_key: :item_id, association_foreign_key: :tag_id
    end
    HabtmTag.class_eval do
      self.table_name = TAGS
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
      has_and_belongs_to_many :items, class_name: "HabtmItem", join_table: JOIN,
                                      foreign_key: :tag_id, association_foreign_key: :item_id
    end
    [HabtmItem, HabtmTag].each(&:reset_column_information)
  end

  def use(mode)
    case mode
    when :monitor then Lyra.config.enable_monitor!
    when :hijack then Lyra.config.enable_hijack!
    else
      Lyra.config.enable_event_sourcing!
      Lyra.config.projection_mode = { es_sync: :sync, es_async: :async, es_noproj: :disabled, es_lazy: :lazy }.fetch(mode)
    end
    @mode = mode
  end

  def connection = ActiveRecord::Base.connection

  def join_rows
    connection.select_rows("SELECT item_id, tag_id FROM #{JOIN} ORDER BY item_id, tag_id").map { |row| row.map(&:to_i) }
  end

  # [operation, target ids] of each link event in the record's stream.
  def links(model, id)
    Lyra.config.event_store.read.stream(Lyra.stream_name(model, id)).to_a.filter_map do |event|
      data = event.data.with_indifferent_access
      next unless %w[linked unlinked].include?(data[:operation].to_s)

      [data[:operation].to_s, Array(data[:target_ids]).map(&:to_i)]
    end
  end

  # DualView finds the row and the log in agreement, the links included.
  def assert_clean(*records)
    HabtmItem.count if @mode == :es_lazy # bring the tables up to date first
    records.each do |record|
      assert_equal({ no_differences: true }, Lyra::DualView.new(record.class, record.id).calculate_differences,
                   "#{record.class.name} #{record.id}")
    end
  end

  def clean
    [JOIN, ITEMS, TAGS].each { |table| connection.execute("DELETE FROM #{table}") if connection.table_exists?(table) }
    connection.execute("DELETE FROM event_store_events_in_streams")
    connection.execute("DELETE FROM event_store_events")
    Lyra::Projections::LazyProjection.reset!
  end
end
