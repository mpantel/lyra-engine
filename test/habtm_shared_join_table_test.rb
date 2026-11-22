# frozen_string_literal: true

require "test_helper"

# Join tables several monitored models' has_and_belongs_to_many share: both
# sides of one association, two owners on columns of their own, and a
# self-referential association. A delete_all through the application's model
# of the table (its own, or Rails' through it) records, on the stream of every
# monitored owner the deleted rows name, the AssociationUnlinked Rails' own
# unlink from that side records, linked into the associated records' streams
# that have none of their own. It recorded the first model's side only. Each
# scenario runs in every mode; the rows each record's stream unlinks are
# compared with those Rails' own unlinks record.
class HabtmSharedJoinTableTest < Minitest::Test
  MODES = %i[monitor hijack es_sync es_async es_noproj es_lazy].freeze
  MODELS = %i[ShItem ShTag ShItemTag ShArticle ShNote ShLabel ShLink ShPerson ShFriendship].freeze
  TABLES = {
    items: "lyra_sh_items", tags: "lyra_sh_tags", items_tags: "lyra_sh_items_tags",
    articles: "lyra_sh_articles", notes: "lyra_sh_notes", labels: "lyra_sh_labels", links: "lyra_sh_links",
    people: "lyra_sh_people", friends: "lyra_sh_friends"
  }.freeze

  def setup
    skip "Requires Rails and PostgreSQL" unless defined?(ActiveRecord::Base) && connection.adapter_name.match?(/postgres/i)

    %i[items tags articles notes labels people].each do |name|
      connection.create_table(TABLES[name], force: true) { |t| t.string :name; t.timestamps }
    end
    connection.create_table(TABLES[:items_tags], id: false, force: true) { |t| t.bigint :item_id, null: false; t.bigint :tag_id, null: false }
    connection.create_table(TABLES[:links], id: false, force: true) do |t|
      t.bigint :article_id
      t.bigint :note_id
      t.bigint :label_id, null: false
    end
    connection.create_table(TABLES[:friends], id: false, force: true) { |t| t.bigint :person_id, null: false; t.bigint :friend_id, null: false }
    define_models
    clean
    %i[ShItem ShTag ShArticle ShNote ShLabel ShPerson].each { Lyra.config.monitor_model(Object.const_get(_1)) }
  end

  def teardown
    return unless defined?(ShItem)

    Lyra.reset_config!
    Lyra::Genesis.reset!
    clean
    TABLES.each_value { connection.drop_table(_1, if_exists: true) }
  end

  MODES.each do |mode|
    # Both sides of one association monitored: Rails' unlink from the item's
    # side, and from the tag's, against the application's delete of the
    # same rows (strict mode off, and inside without_strict_access).
    define_method("test_both_sides_of_one_association_in_#{mode}") do
      rails = scenario(mode, :items) do |item, red, blue|
        ShItem.find(item.id).tags.delete(ShTag.find(red.id))
        ShTag.find(blue.id).items.delete(ShItem.find(item.id))
      end
      own = scenario(mode, :items) { |item| ShItemTag.where(item_id: item.id).delete_all }
      bypass = scenario(mode, :items, strict: true) do |item|
        assert_raises(Lyra::StrictDataAccessViolation) { ShItemTag.where(item_id: item.id).delete_all }
        Lyra.without_strict_access { ShItemTag.where(item_id: item.id).delete_all }
      end

      expected = { "item" => [%w[item red], %w[item blue]].sort, "red" => [%w[item red]], "blue" => [%w[item blue]] }
      assert_equal expected, rails[:unlinked]
      assert_equal rails[:unlinked], own[:unlinked]
      assert_equal rails[:unlinked], bypass[:unlinked]
      assert_equal({ "item" => 1, "red" => 1, "blue" => 1 }, own[:events], "one unlink in each stream")
      assert_equal own, bypass
    end

    # Two owners on one table, each on a column of its own; the labels are
    # monitored and have no association back.
    define_method("test_two_owners_on_columns_of_their_own_in_#{mode}") do
      rails = scenario(mode, :links) do |article, note, label|
        ShArticle.find(article.id).labels.delete(ShLabel.find(label.id))
        ShNote.find(note.id).labels.delete(ShLabel.find(label.id))
      end
      own = scenario(mode, :links) { |_, _, label| ShLink.where(label_id: label.id).delete_all }

      expected = { "article" => [%w[article label]], "note" => [%w[note label]],
                   "label" => [%w[article label], %w[note label]].sort }
      assert_equal expected, rails[:unlinked]
      assert_equal rails[:unlinked], own[:unlinked]
      assert_equal({ "article" => 1, "note" => 1, "label" => 2 }, own[:events])
    end

    # One row naming both owners (only the application's code fills both
    # columns): Rails' own unlink from the article's side records the
    # note's unlink too, on the note's stream, as the application's delete
    # of the row does; the note's stream no longer keeps a link whose row
    # is gone. The row's insert recorded both links.
    define_method("test_a_row_naming_two_owners_in_#{mode}") do
      rails = scenario(mode, :shared_row) do |article, _, label|
        ShArticle.find(article.id).labels.delete(ShLabel.find(label.id))
      end
      own = scenario(mode, :shared_row) { |article| ShLink.where(article_id: article.id).delete_all }

      expected = { "article" => [%w[article label]], "note" => [%w[note label]],
                   "label" => [%w[article label], %w[note label]] }
      assert_equal expected, rails[:unlinked]
      assert_equal own, rails
      assert_equal({ "article" => 1, "note" => 1, "label" => 2 }, rails[:events])
      assert_equal({ "article" => 1, "note" => 1, "label" => 2 }, rails[:linked], "the insert's links")
      assert_equal [{}] * 3, rails[:dual_view]
    end

    # A self-referential association: the friend's stream has the
    # person's unlink, as Rails' records it.
    define_method("test_a_self_referential_association_in_#{mode}") do
      rails = scenario(mode, :friends) { |ann, bob| ShPerson.find(ann.id).friends.delete(ShPerson.find(bob.id)) }
      own = scenario(mode, :friends) { |ann| ShFriendship.where(person_id: ann.id).delete_all }

      assert_equal({ "ann" => [%w[ann bob]], "bob" => [%w[ann bob]] }, rails[:unlinked])
      assert_equal rails[:unlinked], own[:unlinked]
      assert_equal rails[:events], own[:events]
    end
  end

  # Which model's table it is, and whether it is guarded, whichever
  # monitored model declared the association first; join_model_of keeps its
  # answer until the monitored models change.
  def test_shared_tables_are_recognised_and_guarded
    use(:monitor)
    [ShItemTag, ShLink, ShFriendship].each do |model|
      join_model = Lyra::Associations::HabtmLinks.join_model_of(model)
      assert join_model, model.name
      assert_equal model.table_name, join_model.table_name
      assert Lyra::Associations::HabtmLinks.guarded?(join_model)
      assert_same join_model, Lyra::Associations::HabtmLinks.join_model_of(model), "kept"
    end
    sides = Lyra::Associations::HabtmLinks.send(:recorded_sides, TABLES[:items_tags]).map(&:left_model)
    assert_equal %w[ShItem ShTag], sides.map(&:name).sort
    assert_equal %w[ShArticle ShNote],
                 Lyra::Associations::HabtmLinks.send(:recorded_sides, TABLES[:links]).map { _1.left_model.name }.sort

    Lyra.reset_config!
    assert_nil Lyra::Associations::HabtmLinks.join_model_of(ShLink), "no monitored model, no join table"
    Lyra.config.monitor_model(ShNote)
    assert_equal "ShNote", Lyra::Associations::HabtmLinks.join_model_of(ShLink).left_model.name
  end

  private

  # Links made, then the block run on them; the rows each record's stream
  # unlinks that name it, by record name, and its unlink events.
  def scenario(mode, kind, strict: false)
    clean
    use(mode)
    records =
      case kind
      when :items
        item = ShItem.create!(name: "item")
        tags = %w[red blue].map { ShTag.create!(name: _1) }
        item.tags << tags
        [item, *tags]
      when :links
        article = ShArticle.create!(name: "article")
        note = ShNote.create!(name: "note")
        label = ShLabel.create!(name: "label")
        article.labels << label
        note.labels << label
        [article, note, label]
      when :friends
        ann, bob = %w[ann bob].map { ShPerson.create!(name: _1) }
        ann.friends << bob
        [ann, bob]
      when :shared_row
        article = ShArticle.create!(name: "article")
        note = ShNote.create!(name: "note")
        label = ShLabel.create!(name: "label")
        ShLink.insert_all([{ article_id: article.id, note_id: note.id, label_id: label.id }])
        [article, note, label]
      end
    Lyra.config.strict_data_access = strict
    yield(*records)
    Lyra.config.strict_data_access = false
    records.first.class.count if mode == :es_lazy
    result = summary(records)
    return result unless kind == :shared_row

    result.merge(
      linked: records.to_h { |r| [r.name, link_events(r, "linked")] }.reject { _2.zero? },
      dual_view: records.map { Lyra::DualView.new(_1.class, _1.id).calculate_differences }
    )
  end

  def link_events(record, operation)
    Lyra.config.event_store.read.stream(Lyra.stream_name(record.class, record.id)).to_a
        .count { (_1.data[:operation] || _1.data["operation"]).to_s == operation }
  end

  # The columns that name a record of each model.
  COLUMNS = {
    "ShItem" => %w[item_id], "ShTag" => %w[tag_id], "ShArticle" => %w[article_id], "ShNote" => %w[note_id],
    "ShLabel" => %w[label_id], "ShPerson" => %w[person_id friend_id]
  }.freeze

  def summary(records)
    names = records.to_h { [[_1.class.name, _1.id], _1.name] }
    by_column = { "item_id" => "ShItem", "tag_id" => "ShTag", "article_id" => "ShArticle", "note_id" => "ShNote",
                  "label_id" => "ShLabel", "person_id" => "ShPerson", "friend_id" => "ShPerson" }
    unlinked = {}
    events = {}
    records.each do |record|
      stream = Lyra.config.event_store.read.stream(Lyra.stream_name(record.class, record.id)).to_a
                   .select { (_1.data[:operation] || _1.data["operation"]).to_s == "unlinked" }
      events[record.name] = stream.size
      rows = stream.flat_map { Array(_1.data[:rows] || _1.data["rows"]) }.map { _1.to_h.transform_keys(&:to_s) }
      rows = rows.select { |row| COLUMNS.fetch(record.class.name).any? { row[_1].to_s == record.id.to_s } }
      unlinked[record.name] = rows.map do |row|
        row.reject { |_, v| v.nil? }.sort_by { |column, _| %w[item_id article_id note_id person_id].include?(column) ? 0 : 1 }
           .map { |column, id| names.fetch([by_column.fetch(column), id.to_i]) }
      end.uniq.sort
    end
    events.reject! { |_, count| count.zero? }
    unlinked.reject! { |_, rows| rows.empty? }
    { unlinked: unlinked, events: events }
  end

  def define_models
    MODELS.each { Object.send(:remove_const, _1) if Object.const_defined?(_1) }
    MODELS.each { Object.const_set(_1, Class.new(ActiveRecord::Base)) }
    monitored = lambda do |table|
      proc do
        self.table_name = table
        include Lyra::Interceptors::CrudInterceptor
        monitor_with_lyra
      end
    end
    ShItem.class_eval(&monitored.(TABLES[:items]))
    ShItem.has_and_belongs_to_many :tags, class_name: "ShTag", join_table: TABLES[:items_tags],
                                          foreign_key: :item_id, association_foreign_key: :tag_id
    ShTag.class_eval(&monitored.(TABLES[:tags]))
    ShTag.has_and_belongs_to_many :items, class_name: "ShItem", join_table: TABLES[:items_tags],
                                          foreign_key: :tag_id, association_foreign_key: :item_id
    ShItemTag.table_name = TABLES[:items_tags]
    ShArticle.class_eval(&monitored.(TABLES[:articles]))
    ShArticle.has_and_belongs_to_many :labels, class_name: "ShLabel", join_table: TABLES[:links],
                                               foreign_key: :article_id, association_foreign_key: :label_id
    ShNote.class_eval(&monitored.(TABLES[:notes]))
    ShNote.has_and_belongs_to_many :labels, class_name: "ShLabel", join_table: TABLES[:links],
                                            foreign_key: :note_id, association_foreign_key: :label_id
    ShLabel.class_eval(&monitored.(TABLES[:labels]))
    ShLink.table_name = TABLES[:links]
    ShPerson.class_eval(&monitored.(TABLES[:people]))
    ShPerson.has_and_belongs_to_many :friends, class_name: "ShPerson", join_table: TABLES[:friends],
                                               foreign_key: :person_id, association_foreign_key: :friend_id
    ShFriendship.table_name = TABLES[:friends]
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
  end

  def connection = ActiveRecord::Base.connection

  def clean
    TABLES.each_value { connection.execute("DELETE FROM #{_1}") if connection.table_exists?(_1) }
    connection.execute("DELETE FROM event_store_events_in_streams")
    connection.execute("DELETE FROM event_store_events")
    Lyra::Projections::LazyProjection.reset!
    Rails.cache.clear
  end
end
