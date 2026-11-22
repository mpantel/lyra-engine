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
  DEP_JOIN = "lyra_habtm_dep_items_tags"
  PLAIN_JOIN = "lyra_habtm_plain_items_tags"
  MODES = %i[monitor hijack es_sync es_async es_noproj es_lazy].freeze

  # Named, not anonymous: Rails keeps one CurrentAttributes instance per
  # thread under the class's name, so an anonymous class bound to ::Current
  # would share its slot with any other test's ::Current.
  class HabtmLinksCurrent < ActiveSupport::CurrentAttributes
    attribute :user, :request_id
  end

  def setup
    skip "Requires Rails and PostgreSQL" unless defined?(ActiveRecord::Base) && connection.adapter_name.match?(/postgres/i)

    connection.create_table(ITEMS, force: true) { |t| t.string :label; t.timestamps }
    connection.create_table(TAGS, force: true) { |t| t.string :name; t.timestamps }
    [JOIN, DEP_JOIN, PLAIN_JOIN].each do |table|
      connection.create_table(table, id: false, force: true) do |t|
        t.bigint :item_id, null: false
        t.bigint :tag_id, null: false
      end
    end
    define_models
    clean
    Lyra.config.monitor_model(HabtmItem)
    Lyra.config.monitor_model(HabtmTag)
    Lyra.config.monitor_model(HabtmDepItem)
  end

  def teardown
    return unless defined?(HabtmItem)

    Lyra.reset_config!
    Lyra::Genesis.reset!
    clean
    [JOIN, DEP_JOIN, PLAIN_JOIN, ITEMS, TAGS].each { |table| connection.drop_table(table, if_exists: true) }
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

    # Every way Rails deletes join rows is association maintenance: allowed
    # in strict mode, as a dependent: :nullify is, and each records its
    # unlink. No join row goes without its AssociationUnlinked.
    {
      "delete" => ->(item, tags) { item.tags.delete(tags.first) },
      "delete_all" => ->(item, _) { item.tags.delete_all },
      "clear" => ->(item, _) { item.tags.clear },
      "destroy" => ->(item, tags) { item.tags.destroy(tags.first) },
      "destroy_all" => ->(item, _) { item.tags.destroy_all },
      "assigning ids" => ->(item, tags) { item.tag_ids = [tags.last.id] },
      "assigning records" => ->(item, tags) { item.tags = [tags.last] },
      "destroying the owner" => ->(item, _) { item.destroy! }
    }.each do |path, remove|
      define_method("test_#{path.tr(' ', '_')}_unlinks_in_strict_mode_in_#{mode}") do
        use(mode)
        item = HabtmItem.create!(label: "item")
        tags = %w[red blue].map { |name| HabtmTag.create!(name: name) }
        item.tags << tags
        Lyra.config.strict_data_access = true

        remove.call(HabtmItem.find(item.id), tags.map { HabtmTag.find(_1.id) })

        left = join_rows.map(&:last)
        removed = tags.map(&:id) - left
        refute_empty removed, "#{path} removed a link"
        unlinked = links(HabtmItem, item.id).select { _1.first == "unlinked" }.flat_map(&:last)
        assert_equal removed.sort, unlinked.sort, "#{path}: every join row deleted is unlinked in the log"
        tags.each { |tag| assert HabtmTag.find_by(id: tag.id), "#{path} leaves the tag itself" }
        assert_clean(*tags, *(path == "destroying the owner" ? [] : [item]))
      end
    end

    # The application's own delete_all on the join rows, through the join
    # model Rails defines (HabtmItem::HABTM_Tags) or a model of its own on the
    # join table, is a bypass like any other: refused in strict mode, and,
    # where allowed, recorded as the unlink it is.
    define_method("test_an_application_delete_all_of_join_rows_is_refused_in_strict_mode_in_#{mode}") do
      use(mode)
      item = HabtmItem.create!(label: "item")
      red, blue = %w[red blue].map { |name| HabtmTag.create!(name: name) }
      item.tags << [red, blue]
      Lyra.config.strict_data_access = true
      events = event_count

      assert_raises(Lyra::StrictDataAccessViolation) { HabtmItem.const_get(:HABTM_Tags).where(item_id: item.id).delete_all }
      assert_raises(Lyra::StrictDataAccessViolation) { HabtmItemTag.where(item_id: item.id).delete_all }
      assert_equal events, event_count, "nothing recorded"
      assert_equal [red.id, blue.id].sort, join_rows.map(&:last).sort

      Lyra.without_strict_access { HabtmItem.const_get(:HABTM_Tags).where(item_id: item.id, tag_id: red.id).delete_all }
      Lyra.without_strict_access { HabtmItemTag.where(item_id: item.id, tag_id: blue.id).delete_all }

      assert_empty join_rows
      assert_equal [["unlinked", [red.id]], ["unlinked", [blue.id]]], links(HabtmItem, item.id).select { _1.first == "unlinked" }
      assert_clean(item, red, blue)
    end

    # Rails' own writes through the application's model of the join table:
    # removing a tag from a has_many :through over it, and an owner's
    # dependent: :delete_all of it. Association maintenance, allowed in
    # strict mode, recorded as unlinks.
    define_method("test_removing_through_the_application_s_join_model_unlinks_in_strict_mode_in_#{mode}") do
      use(mode)
      item = HabtmItem.create!(label: "item")
      red, blue = %w[red blue].map { |name| HabtmTag.create!(name: name) }
      item.tags << [red, blue]
      Lyra.config.strict_data_access = true

      HabtmItem.find(item.id).tags_via_model.delete(HabtmTag.find(red.id))

      assert_equal [[item.id, blue.id]], join_rows
      assert_includes links(HabtmItem, item.id), ["unlinked", [red.id]]
    end

    define_method("test_dependent_delete_all_through_the_application_s_join_model_unlinks_in_strict_mode_in_#{mode}") do
      use(mode)
      item = HabtmDepItem.create!(label: "item")
      tag = HabtmTag.create!(name: "red")
      item.dep_tags << tag
      Lyra.config.strict_data_access = true

      HabtmDepItem.find(item.id).destroy!

      assert_equal 0, connection.select_value("SELECT COUNT(*) FROM #{DEP_JOIN}").to_i
      assert_includes links(HabtmDepItem, item.id), ["unlinked", [tag.id]]
    end

    # The owner's model is not monitored, the tag's is: the application's
    # delete_all of the join rows is refused in strict mode all the same;
    # Rails' own is not.
    define_method("test_join_rows_of_an_unmonitored_owner_are_guarded_in_#{mode}") do
      use(mode)
      item = HabtmPlainItem.create!(label: "plain")
      red, blue = %w[red blue].map { |name| HabtmTag.create!(name: name) }
      item.ptags << [red, blue]
      Lyra.config.strict_data_access = true

      assert_raises(Lyra::StrictDataAccessViolation) do
        HabtmPlainItem.const_get(:HABTM_Ptags).where(item_id: item.id).delete_all
      end
      HabtmPlainItem.find(item.id).ptags.delete(red)

      assert_equal [blue.id], connection.select_values("SELECT tag_id FROM #{PLAIN_JOIN}").map(&:to_i)
    end

    # Links made and removed from the side Lyra does not monitor are
    # recorded on the monitored side's streams, as a link made from that
    # side is: Rails' link and unlink, and the application's delete_all
    # where it is allowed. They were not recorded at all.
    define_method("test_links_from_an_unmonitored_owner_are_on_the_monitored_side_in_#{mode}") do
      use(mode)
      item = HabtmPlainItem.create!(label: "plain")
      red, blue, green = %w[red blue green].map { |name| HabtmTag.create!(name: name) }

      item.ptags << [red, blue, green]
      HabtmPlainItem.find(item.id).ptags.delete(red)
      Lyra.config.strict_data_access = true
      Lyra.without_strict_access { HabtmPlainItem.const_get(:HABTM_Ptags).where(item_id: item.id, tag_id: blue.id).delete_all }

      assert_equal [green.id], connection.select_values("SELECT tag_id FROM #{PLAIN_JOIN}").map(&:to_i)
      assert_equal [["linked", [red.id]], ["unlinked", [red.id]]], links(HabtmTag, red.id)
      assert_equal [["linked", [blue.id]], ["unlinked", [blue.id]]], links(HabtmTag, blue.id)
      assert_equal [["linked", [green.id]]], links(HabtmTag, green.id)
      HabtmTag.count if @mode == :es_lazy
      [red, blue, green].each do |tag|
        assert_equal({}, Lyra::DualView.new(HabtmTag, tag.id).calculate_differences, tag.name)
      end
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

  def test_a_link_names_the_user_and_the_request
    use(:monitor)
    item = HabtmItem.create!(label: "item")
    tag = HabtmTag.create!(name: "red")
    original = Object.send(:remove_const, :Current) if Object.const_defined?(:Current, false)
    Object.const_set(:Current, HabtmLinksCurrent)
    HabtmLinksCurrent.user = Struct.new(:id).new(7)
    HabtmLinksCurrent.request_id = "req-1"

    item.tags << tag

    event = Lyra.config.event_store.read.of_type([Lyra::Events::AssociationLinked]).to_a.last
    assert_equal 7, event.metadata[:user_id]
    assert_equal "req-1", event.metadata[:request_id]
  ensure
    HabtmLinksCurrent.reset
    Object.send(:remove_const, :Current) if Object.const_defined?(:Current, false)
    Object.const_set(:Current, original) if original
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
    assert_equal({}, Lyra::DualView.new(HabtmItem, item_id).calculate_differences)
    assert_equal({}, Lyra::DualView.new(HabtmTag, tag_id).calculate_differences)
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
    %i[HabtmItem HabtmTag HabtmItemTag HabtmDepItem HabtmDepItemTag HabtmPlainItem].each do |name|
      Object.send(:remove_const, name) if Object.const_defined?(name)
    end
    Object.const_set(:HabtmItem, Class.new(ActiveRecord::Base))
    Object.const_set(:HabtmTag, Class.new(ActiveRecord::Base))
    HabtmItem.class_eval do
      self.table_name = ITEMS
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
      has_and_belongs_to_many :tags, class_name: "HabtmTag", join_table: JOIN,
                                     foreign_key: :item_id, association_foreign_key: :tag_id
      # The same links through the application's model of the join table.
      has_many :item_tags, class_name: "HabtmItemTag", foreign_key: :item_id
      has_many :tags_via_model, through: :item_tags, source: :habtm_tag
    end
    HabtmTag.class_eval do
      self.table_name = TAGS
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
      has_and_belongs_to_many :items, class_name: "HabtmItem", join_table: JOIN,
                                      foreign_key: :tag_id, association_foreign_key: :item_id
      has_and_belongs_to_many :plain_items, class_name: "HabtmPlainItem", join_table: PLAIN_JOIN,
                                            foreign_key: :tag_id, association_foreign_key: :item_id
    end
    # A model of the application's own on the join table, not monitored.
    Object.const_set(:HabtmItemTag, Class.new(ActiveRecord::Base) do
      self.table_name = JOIN
      belongs_to :habtm_tag, class_name: "HabtmTag", foreign_key: :tag_id
    end)
    # An owner whose join rows go with it through the application's model
    # of its join table (dependent: :delete_all).
    Object.const_set(:HabtmDepItemTag, Class.new(ActiveRecord::Base) { self.table_name = DEP_JOIN })
    Object.const_set(:HabtmDepItem, Class.new(ActiveRecord::Base))
    HabtmDepItem.class_eval do
      self.table_name = ITEMS
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
      has_and_belongs_to_many :dep_tags, class_name: "HabtmTag", join_table: DEP_JOIN,
                                         foreign_key: :item_id, association_foreign_key: :tag_id
      has_many :dep_item_tags, class_name: "HabtmDepItemTag", foreign_key: :item_id, dependent: :delete_all
    end
    # An owner Lyra does not monitor, linked to monitored tags.
    Object.const_set(:HabtmPlainItem, Class.new(ActiveRecord::Base))
    HabtmPlainItem.class_eval do
      self.table_name = ITEMS
      has_and_belongs_to_many :ptags, class_name: "HabtmTag", join_table: PLAIN_JOIN,
                                      foreign_key: :item_id, association_foreign_key: :tag_id
    end
    [HabtmItem, HabtmTag, HabtmItemTag, HabtmDepItemTag].each(&:reset_column_information)
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

  def event_count = connection.select_value("SELECT COUNT(*) FROM event_store_events").to_i

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
      assert_equal({}, Lyra::DualView.new(record.class, record.id).calculate_differences,
                   "#{record.class.name} #{record.id}")
    end
  end

  def clean
    [JOIN, DEP_JOIN, PLAIN_JOIN, ITEMS, TAGS].each { |table| connection.execute("DELETE FROM #{table}") if connection.table_exists?(table) }
    connection.execute("DELETE FROM event_store_events_in_streams")
    connection.execute("DELETE FROM event_store_events")
    Lyra::Projections::LazyProjection.reset!
  end
end
