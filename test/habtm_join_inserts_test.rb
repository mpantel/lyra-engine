# frozen_string_literal: true

require "test_helper"

# The application's insert_all, insert_all!, upsert_all (insert, insert!,
# upsert) of join rows: through the join model Rails defines
# (HjItem::HABTM_Tags) or a model of its own on the join table. They were
# neither refused in strict mode nor recorded. They are now guarded as its
# delete_all of join rows is, and recorded as the links Rails' own link from
# each side records; rows ON CONFLICT skipped record nothing. Rails' own
# links are inserted through the join model's callbacks, one row at a time,
# and are allowed in strict mode as before.
#
# Also the join table of an owner Lyra does not monitor, linked to records
# it does, whose model has no association back onto the table: a model of
# the application's on that table was not taken for a join model, and its
# deletes went unguarded and unrecorded. And a has_many :through over a
# model Lyra does not monitor, which is no join table: nothing is recorded
# for it, from either side, and nothing is refused.
class HabtmJoinInsertsTest < Minitest::Test
  MODES = %i[monitor hijack es_sync es_async es_noproj es_lazy].freeze
  TABLES = {
    items: "lyra_hj_items", tags: "lyra_hj_tags", items_tags: "lyra_hj_items_tags",
    plain_items_tags: "lyra_hj_plain_items_tags", owners: "lyra_hj_owners", owner_links: "lyra_hj_owner_links",
    item_labels: "lyra_hj_item_labels"
  }.freeze
  MODELS = %i[HjItem HjTag HjItemTag HjPlainItem HjPlainItemTag HjOwner HjOwnerLink HjItemLabel].freeze

  def setup
    skip "Requires Rails and PostgreSQL" unless defined?(ActiveRecord::Base) && connection.adapter_name.match?(/postgres/i)

    %i[items tags owners].each do |name|
      connection.create_table(TABLES[name], force: true) { |t| t.string :name; t.timestamps }
    end
    connection.create_table(TABLES[:items_tags], id: false, force: true) do |t|
      t.bigint :item_id, null: false
      t.bigint :tag_id, null: false
      t.index %i[item_id tag_id], unique: true
    end
    connection.create_table(TABLES[:plain_items_tags], id: false, force: true) do |t|
      t.bigint :item_id, null: false
      t.bigint :tag_id, null: false
      t.index %i[item_id tag_id], unique: true
    end
    connection.create_table(TABLES[:owner_links], force: true) { |t| t.bigint :owner_id; t.bigint :tag_id }
    connection.create_table(TABLES[:item_labels], force: true) { |t| t.bigint :item_id; t.bigint :tag_id }
    define_models
    clean
    %i[HjItem HjTag HjOwner].each { Lyra.config.monitor_model(Object.const_get(_1)) }
  end

  def teardown
    return unless defined?(HjItem)

    Lyra.reset_config!
    Lyra::Genesis.reset!
    clean
    TABLES.each_value { connection.drop_table(_1, if_exists: true) }
  end

  MODES.each do |mode|
    # Every way the application inserts join rows is refused in strict mode,
    # nothing written and nothing recorded; Rails' own link is not.
    define_method("test_application_inserts_of_join_rows_are_refused_in_strict_mode_in_#{mode}") do
      use(mode)
      item = HjItem.create!(name: "item")
      plain = HjPlainItem.create!(name: "plain")
      red = HjTag.create!(name: "red")
      Lyra.config.strict_data_access = true
      events = event_count
      pair = { item_id: item.id, tag_id: red.id }
      plain_pair = { item_id: plain.id, tag_id: red.id }

      {
        "HABTM_Tags.insert_all" => -> { HjItem.const_get(:HABTM_Tags).insert_all([pair]) },
        "HABTM_Tags.insert_all!" => -> { HjItem.const_get(:HABTM_Tags).insert_all!([pair]) },
        "HABTM_Tags.upsert_all" => -> { HjItem.const_get(:HABTM_Tags).upsert_all([pair], unique_by: %i[item_id tag_id]) },
        "HjItemTag.insert" => -> { HjItemTag.insert(pair) },
        "HjItemTag.insert!" => -> { HjItemTag.insert!(pair) },
        "HjItemTag.upsert" => -> { HjItemTag.upsert(pair, unique_by: %i[item_id tag_id]) },
        "item.item_tags.insert_all" => -> { HjItem.find(item.id).item_tags.insert_all([{ tag_id: red.id }]) },
        "HABTM_Ptags.insert_all" => -> { HjPlainItem.const_get(:HABTM_Ptags).insert_all([plain_pair]) },
        "HjPlainItemTag.insert_all" => -> { HjPlainItemTag.insert_all([plain_pair]) }
      }.each do |write, call|
        error = assert_raises(Lyra::StrictDataAccessViolation, write, &call)
        assert_includes %i[insert_all insert_all! upsert_all], error.method_name, write
      end
      assert_equal 0, rows(:items_tags).size + rows(:plain_items_tags).size, "nothing written"
      assert_equal events, event_count, "nothing recorded"

      HjItem.find(item.id).tags << HjTag.find(red.id)
      HjPlainItem.find(plain.id).ptags << HjTag.find(red.id)
      assert_equal [[item.id, red.id]], rows(:items_tags)
      assert_equal [[plain.id, red.id]], rows(:plain_items_tags)
      assert_equal [[item.id, red.id]], linked(HjItem, item.id)
    end

    # Both sides monitored: the application's insert, through its model of
    # the join table, through the join model, and through the owner's
    # association to its model (whose scope sets the owner's key), records
    # on each stream the links Rails' own records there.
    define_method("test_application_inserts_record_the_links_rails_records_in_#{mode}") do
      rails = scenario(mode) { |item, tags| HjItem.find(item.id).tags << tags.map { HjTag.find(_1.id) } }
      expected = { "item" => [%w[item blue], %w[item red]], "red" => [%w[item red]], "blue" => [%w[item blue]] }
      assert_equal expected, rails

      {
        "HjItemTag.insert_all" => ->(item, tags) { HjItemTag.insert_all(tags.map { { item_id: item.id, tag_id: _1.id } }) },
        "HABTM_Tags.insert_all!" => ->(item, tags) { HjItem.const_get(:HABTM_Tags).insert_all!(tags.map { { item_id: item.id, tag_id: _1.id } }) },
        "HjItemTag.upsert_all" => lambda do |item, tags|
          HjItemTag.upsert_all(tags.map { { item_id: item.id, tag_id: _1.id } }, unique_by: %i[item_id tag_id])
        end,
        "item.item_tags.insert_all" => ->(item, tags) { HjItem.find(item.id).item_tags.insert_all(tags.map { { tag_id: _1.id } }) },
        "HjItemTag.insert, inside without_strict_access" => lambda do |item, tags|
          Lyra.config.strict_data_access = true
          Lyra.without_strict_access { tags.each { HjItemTag.insert({ item_id: item.id, tag_id: _1.id }) } }
        end
      }.each do |write, call|
        assert_equal rails, scenario(mode, &call), write
      end
    end

    # A row ON CONFLICT skipped records nothing; insert_all! of a pair there
    # fails and records nothing; an upsert that leaves a pair as it was
    # records nothing for it.
    define_method("test_rows_on_conflict_skipped_record_nothing_in_#{mode}") do
      use(mode)
      item = HjItem.create!(name: "item")
      red, blue = %w[red blue].map { HjTag.create!(name: _1) }
      HjItem.find(item.id).tags << HjTag.find(red.id)
      events = event_count

      result = HjItemTag.insert_all([{ item_id: item.id, tag_id: red.id }], returning: %i[tag_id])
      assert_empty result.rows
      assert_equal events, event_count
      assert_raises(ActiveRecord::RecordNotUnique) { HjItemTag.insert_all!([{ item_id: item.id, tag_id: red.id }]) }
      assert_equal events, event_count

      HjItemTag.upsert_all([{ item_id: item.id, tag_id: red.id }, { item_id: item.id, tag_id: blue.id }],
                           unique_by: %i[item_id tag_id])
      assert_equal [[item.id, red.id], [item.id, blue.id]].sort, rows(:items_tags)
      assert_equal [[item.id, red.id], [item.id, blue.id]].sort, linked(HjItem, item.id)
      assert_equal 2, link_events(HjItem, item.id).size, "Rails' link of red, the upsert's of blue"
      assert_clean(item, red, blue)
    end

    # An upsert by another key (a join table with an id of its own) that
    # moves a row to another pair unlinks the old pair and links the new,
    # on each side, as Rails' unlink and link would; one that leaves the
    # pair as it was records nothing.
    define_method("test_an_upsert_that_changes_a_pair_unlinks_and_links_in_#{mode}") do
      use(mode)
      item = HjItem.create!(name: "item")
      red, blue = %w[red blue].map { HjTag.create!(name: _1) }
      HjItem.find(item.id).labels << HjTag.find(red.id)
      row_id = connection.select_value("SELECT id FROM #{TABLES[:item_labels]}").to_i
      events = event_count

      HjItemLabel.upsert_all([{ id: row_id, item_id: item.id, tag_id: red.id }], unique_by: :id)
      assert_equal events, event_count, "the pair as it was"
      HjItemLabel.upsert_all([{ id: row_id, item_id: item.id, tag_id: blue.id }], unique_by: :id)

      assert_equal [[item.id, blue.id]], linked(HjItem, item.id)
      assert_equal [["linked", [red.id]], ["unlinked", [red.id]], ["linked", [blue.id]]], link_events(HjItem, item.id)
      assert_equal [["linked", [red.id]], ["unlinked", [red.id]]], link_events(HjTag, red.id)
      assert_equal [["linked", [blue.id]]], link_events(HjTag, blue.id)
      assert_clean(item, red, blue)
    end

    # The owner is not monitored, the tags are, and HjTag has no association
    # back onto the table: the application's model of that table is the
    # join model's (join_model_of), guarded, and its inserts and deletes
    # are recorded on the tags' streams as Rails' own link and unlink from
    # the owner's side are.
    define_method("test_a_join_table_whose_monitored_side_has_no_association_back_in_#{mode}") do
      use(mode)
      assert_equal "HABTM_Ptags", Lyra::Associations::HabtmLinks.join_model_of(HjPlainItemTag)&.name
      plain = HjPlainItem.create!(name: "plain")
      red, blue = %w[red blue].map { HjTag.create!(name: _1) }

      HjPlainItem.find(plain.id).ptags << [HjTag.find(red.id)]
      HjPlainItem.find(plain.id).ptags.delete(HjTag.find(red.id))
      rails = [red, blue].to_h { [_1.name, link_events(HjTag, _1.id)] }

      Lyra.config.strict_data_access = true
      assert_raises(Lyra::StrictDataAccessViolation) { HjPlainItemTag.where(item_id: plain.id).delete_all }
      Lyra.without_strict_access do
        HjPlainItemTag.insert_all([{ item_id: plain.id, tag_id: blue.id }])
        HjPlainItemTag.where(item_id: plain.id, tag_id: blue.id).delete_all
      end

      assert_empty rows(:plain_items_tags)
      assert_equal [["linked", [red.id]], ["unlinked", [red.id]]], rails["red"]
      assert_equal [["linked", [blue.id]], ["unlinked", [blue.id]]], link_events(HjTag, blue.id), "as Rails' for red"
      assert_clean(red, blue)
    end

    # A has_many :through over a model Lyra does not monitor: no join
    # table. Neither its links nor its removals are recorded on either
    # side, from Rails or from the application, and nothing is refused.
    define_method("test_a_has_many_through_an_unmonitored_model_records_no_links_in_#{mode}") do
      use(mode)
      assert_nil Lyra::Associations::HabtmLinks.join_model_of(HjOwnerLink)
      owner = HjOwner.create!(name: "owner")
      red, blue = %w[red blue].map { HjTag.create!(name: _1) }
      Lyra.config.strict_data_access = true

      HjOwner.find(owner.id).linked_tags << HjTag.find(red.id)
      HjOwner.find(owner.id).linked_tags.delete(HjTag.find(red.id))
      HjOwnerLink.insert_all([{ owner_id: owner.id, tag_id: blue.id }])
      HjOwnerLink.where(owner_id: owner.id).delete_all

      assert_empty rows(:owner_links)
      assert_empty Lyra.config.event_store.read.of_type([Lyra::Events::AssociationLinked, Lyra::Events::AssociationUnlinked]).to_a
    end
  end

  # The caller gets the result Active Record gives, whatever Lyra added to
  # RETURNING to read the pairs back: the same as with Lyra disabled.
  # A has_and_belongs_to_many declared before Lyra's hook was installed (a
  # model an initializer loaded before Active Record's load hooks ran) is
  # recorded when it is: install! reads the models already loaded.
  def test_declarations_made_before_the_hook_are_recorded
    use(:monitor)
    links = Lyra::Associations::HabtmLinks
    links.instance_variable_set(:@declared, nil)
    links.reset_join_models!
    assert_nil links.join_model_of(HjPlainItemTag), "not known without its declaration"

    links.install!

    assert_equal "HABTM_Ptags", links.join_model_of(HjPlainItemTag)&.name
    assert_operator links.declared_already!, :>=, 3, "HjItem's two and HjPlainItem's"
  end

  def test_the_caller_gets_active_record_s_result
    shapes = %i[monitor disabled].map do |mode|
      clean
      mode == :monitor ? use(:monitor) : Lyra.config.disable!
      item = HjItem.create!(name: "item")
      tags = %w[a b c d e].map { HjTag.create!(name: _1) }
      pair = ->(tag) { { item_id: item.id, tag_id: tag.id } }
      [
        HjItemTag.insert_all([pair.(tags[0])]),
        HjItemTag.insert_all([pair.(tags[1])], returning: :tag_id),
        HjItemTag.insert_all!([pair.(tags[2])], returning: Arel.sql("tag_id * 0 AS zero")),
        HjItemTag.upsert_all([pair.(tags[3])], unique_by: %i[item_id tag_id], returning: false),
        HjItemTag.insert_all([pair.(tags[4])], returning: Arel.sql("*"))
      ].map { |r| [r.columns, r.rows.map { |row| row.map { _1.is_a?(Integer) && _1 > 0 ? :id : _1 } }, r.column_types, r.affected_rows] }
        .tap { assert_equal(mode == :monitor ? 5 : 0, link_events(HjItem, item.id).size) }
    end

    assert_equal shapes.last, shapes.first
  end

  private

  # Links made by the block (+tags+: red and blue), as the pairs each
  # record's stream links, by record name.
  def scenario(mode)
    clean
    use(mode)
    item = HjItem.create!(name: "item")
    tags = %w[red blue].map { HjTag.create!(name: _1) }
    yield item, tags
    assert_clean(item, *tags)
    names = { item.id => "item" }
    tag_names = tags.to_h { [_1.id, _1.name] }
    streams = { "item" => [HjItem, item.id] }.merge(tags.to_h { [_1.name, [HjTag, _1.id]] })
    streams.transform_values do |(model, id)|
      linked(model, id).map { |item_id, tag_id| [names.fetch(item_id), tag_names.fetch(tag_id)] }.sort
    end
  end

  def define_models
    MODELS.each { Object.send(:remove_const, _1) if Object.const_defined?(_1) }
    %i[HjItem HjTag HjPlainItem HjOwner].each { Object.const_set(_1, Class.new(ActiveRecord::Base)) }
    Object.const_set(:HjItemTag, Class.new(ActiveRecord::Base) { self.table_name = TABLES[:items_tags] })
    Object.const_set(:HjPlainItemTag, Class.new(ActiveRecord::Base) { self.table_name = TABLES[:plain_items_tags] })
    Object.const_set(:HjItemLabel, Class.new(ActiveRecord::Base) { self.table_name = TABLES[:item_labels] })
    Object.const_set(:HjOwnerLink, Class.new(ActiveRecord::Base) do
      self.table_name = TABLES[:owner_links]
      belongs_to :tag, class_name: "HjTag"
    end)
    HjItem.class_eval do
      self.table_name = TABLES[:items]
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
      has_and_belongs_to_many :tags, class_name: "HjTag", join_table: TABLES[:items_tags],
                                     foreign_key: :item_id, association_foreign_key: :tag_id
      has_many :item_tags, class_name: "HjItemTag", foreign_key: :item_id
      # A join table with an id of its own.
      has_and_belongs_to_many :labels, class_name: "HjTag", join_table: TABLES[:item_labels],
                                       foreign_key: :item_id, association_foreign_key: :tag_id
    end
    HjTag.class_eval do
      self.table_name = TABLES[:tags]
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
      has_and_belongs_to_many :items, class_name: "HjItem", join_table: TABLES[:items_tags],
                                      foreign_key: :tag_id, association_foreign_key: :item_id
    end
    # Not monitored; HjTag has no association back onto its join table.
    HjPlainItem.class_eval do
      self.table_name = TABLES[:items]
      has_and_belongs_to_many :ptags, class_name: "HjTag", join_table: TABLES[:plain_items_tags],
                                      foreign_key: :item_id, association_foreign_key: :tag_id
    end
    HjOwner.class_eval do
      self.table_name = TABLES[:owners]
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
      has_many :owner_links, class_name: "HjOwnerLink", foreign_key: :owner_id
      has_many :linked_tags, through: :owner_links, source: :tag
    end
    MODELS.each { Object.const_get(_1).reset_column_information }
  end

  def use(mode)
    case mode
    when :monitor then Lyra.config.enable_monitor!
    when :hijack then Lyra.config.enable_hijack!
    else
      Lyra.config.enable_event_sourcing!
      Lyra.config.projection_mode = { es_sync: :sync, es_async: :async, es_noproj: :disabled, es_lazy: :lazy }.fetch(mode)
    end
    Lyra.config.strict_data_access = false
    @mode = mode
  end

  def connection = ActiveRecord::Base.connection

  def event_count = connection.select_value("SELECT COUNT(*) FROM event_store_events").to_i

  def rows(table)
    connection.select_rows("SELECT * FROM #{TABLES[table]}").map { |row| row.map(&:to_i) }.sort
  end

  # [operation, target ids] of each link event in the record's stream.
  def link_events(model, id)
    Lyra.config.event_store.read.stream(Lyra.stream_name(model, id)).to_a.filter_map do |event|
      data = event.data.with_indifferent_access
      next unless %w[linked unlinked].include?(data[:operation].to_s)

      [data[:operation].to_s, Array(data[:target_ids]).map(&:to_i)]
    end
  end

  # The [item_id, tag_id] pairs naming the record that its stream holds
  # linked, after its links and unlinks (as DualView reads them: an event
  # linked into several records' streams carries the rows of them all).
  def linked(model, id)
    column = model == HjTag ? "tag_id" : "item_id"
    pairs = Set.new
    Lyra.config.event_store.read.stream(Lyra.stream_name(model, id)).to_a.each do |event|
      data = event.data.with_indifferent_access
      next unless %w[linked unlinked].include?(data[:operation].to_s)

      Array(data[:rows]).each do |row|
        row = row.to_h.transform_keys(&:to_s)
        next unless row[column].to_i == id

        pair = [row["item_id"].to_i, row["tag_id"].to_i]
        data[:operation].to_s == "linked" ? pairs << pair : pairs.delete(pair)
      end
    end
    pairs.to_a.sort
  end

  # DualView finds the row and the log in agreement, the links included.
  def assert_clean(*records)
    HjItem.count if @mode == :es_lazy # bring the tables up to date first
    records.each do |record|
      assert_equal({}, Lyra::DualView.new(record.class, record.id).calculate_differences,
                   "#{record.class.name} #{record.id}")
    end
  end

  def clean
    TABLES.each_value { |table| connection.execute("DELETE FROM #{table}") if connection.table_exists?(table) }
    connection.execute("DELETE FROM event_store_events_in_streams")
    connection.execute("DELETE FROM event_store_events")
    Lyra::Projections::LazyProjection.reset!
  end
end
