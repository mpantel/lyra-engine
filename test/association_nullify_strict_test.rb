# frozen_string_literal: true

require "test_helper"

# Strict data access lets Rails' own nullify through (a has_many's
# dependent: :nullify, removing children from the collection, a has_one's
# dependent: :nullify, a has_many :through's dependent: :nullify of its
# through records) and refuses the same write made by the application. Before,
# any update_all setting one *_id column to nil was taken for a dependent
# nullify by its shape alone: Model.where(...).update_all(author_id: nil) went
# past strict mode. Rails' association code now marks its write
# (Lyra::Associations::Maintenance). Every scenario runs in every mode.
class AssociationNullifyStrictTest < Minitest::Test
  MODES = %i[monitor hijack es_sync es_async es_noproj es_lazy].freeze
  MODELS = %i[AnsArticle AnsAuthor AnsOneAuthor AnsTag AnsTagging AnsTaggingAuthor AnsPlainTaggingAuthor
              AnsKid AnsKidOwner AnsOneKidOwner AnsSneakyKid AnsSneakyOwner].freeze
  TAGS = "lyra_ans_tags"
  TAGGINGS = "lyra_ans_taggings"
  KIDS = "lyra_ans_kids"

  def setup
    skip "Requires Rails and PostgreSQL" unless defined?(ActiveRecord::Base) && connection.adapter_name.match?(/postgres/i)

    connection.create_table(TAGS, force: true) { |t| t.string :name; t.timestamps }
    connection.create_table(TAGGINGS, force: true) do |t|
      t.bigint :author_id
      t.bigint :ans_tag_id
      t.timestamps
    end
    connection.create_table(KIDS, force: true) do |t|
      t.string :name
      t.bigint :owner_id
      t.string :owner_type
      t.bigint :parent
      t.timestamps
    end
    define_models
    clean
    MODELS.each { Lyra.config.monitor_model(Object.const_get(_1)) }
  end

  def teardown
    return unless defined?(AnsArticle)

    Lyra.config.strict_data_access = false
    Lyra.config.enable_monitor!
    Lyra.config.projection_mode = :sync
    clean
    $ans_sneak = false
    [TAGGINGS, TAGS, KIDS].each { connection.drop_table(_1, if_exists: true) }
  end

  MODES.each do |mode|
    define_method("test_an_application_update_all_clearing_a_foreign_key_is_refused_in_strict_mode_in_#{mode}") do
      use(mode)
      author = AnsAuthor.create!(name: "Ann", email: "ann-ans@example.com")
      child = AnsArticle.create!(title: "A", author_id: author.id)
      Lyra.config.strict_data_access = true
      events = event_count

      assert_raises(Lyra::StrictDataAccessViolation) { AnsArticle.where(author_id: author.id).update_all(author_id: nil) }
      assert_raises(Lyra::StrictDataAccessViolation) { AnsAuthor.find(author.id).ans_articles.update_all(author_id: nil) }

      assert_equal events, event_count, "nothing recorded"
      assert_equal author.id, AnsArticle.find(child.id).author_id
    end

    # Allowed, it is an update_all: its events say so, not
    # dependent_association.
    define_method("test_an_application_update_all_clearing_a_foreign_key_is_an_update_all_in_#{mode}") do
      use(mode)
      author = AnsAuthor.create!(name: "Ann", email: "ann-ans@example.com")
      child = AnsArticle.create!(title: "A", author_id: author.id)
      Lyra.config.strict_data_access = true

      Lyra.without_strict_access { AnsArticle.where(author_id: author.id).update_all(author_id: nil) }

      assert_nil AnsArticle.find(child.id).author_id
      last = stream(AnsArticle, child.id).last
      assert_equal "updated", operation(last)
      assert_equal "update_all", last.metadata[:bypass_source]
      assert_nil last.metadata[:nullify_source]
      assert_equal [author.id, nil], changes(last)["author_id"]
    end

    define_method("test_dependent_nullify_is_allowed_in_strict_mode_and_recorded_as_before_in_#{mode}") do
      use(mode)
      author = AnsAuthor.create!(name: "Ann", email: "ann-ans@example.com")
      children = [AnsArticle.create!(title: "A1", author_id: author.id), AnsArticle.create!(title: "A2", author_id: author.id)]
      Lyra.config.strict_data_access = true

      AnsAuthor.find(author.id).destroy!

      refute AnsAuthor.exists?(author.id)
      children.each do |child|
        assert_nil AnsArticle.find(child.id).author_id
        last = stream(AnsArticle, child.id).last
        assert_equal "updated", operation(last)
        assert_equal "dependent_association", last.metadata[:nullify_source]
        assert_equal [author.id, nil], changes(last)["author_id"]
      end
    end

    # Removing a child from a has_many with no dependent: option nullifies its
    # key: the association's own write, as dependent: :nullify is.
    define_method("test_removing_a_child_from_the_collection_is_allowed_in_strict_mode_in_#{mode}") do
      use(mode)
      author = AnsAuthor.create!(name: "Ann", email: "ann-ans@example.com")
      kept = AnsArticle.create!(title: "K", author_id: author.id)
      removed = AnsArticle.create!(title: "R", author_id: author.id)
      Lyra.config.strict_data_access = true

      AnsAuthor.find(author.id).ans_articles.delete(AnsArticle.find(removed.id))

      assert_nil AnsArticle.find(removed.id).author_id
      assert_equal author.id, AnsArticle.find(kept.id).author_id
      last = stream(AnsArticle, removed.id).last
      assert_equal "dependent_association", last.metadata[:nullify_source]
      assert_equal [author.id, nil], changes(last)["author_id"]
    end

    # has_one dependent: :nullify clears its record's key with
    # update_columns, which strict mode refused: the owner could not be
    # destroyed. Its event is update_columns', as before.
    define_method("test_has_one_dependent_nullify_is_allowed_in_strict_mode_in_#{mode}") do
      use(mode)
      author = AnsOneAuthor.create!(name: "Ann", email: "ann-ans@example.com")
      child = AnsArticle.create!(title: "A", author_id: author.id)
      Lyra.config.strict_data_access = true

      AnsOneAuthor.find(author.id).destroy!

      refute AnsOneAuthor.exists?(author.id)
      assert_nil AnsArticle.find(child.id).author_id
      last = stream(AnsArticle, child.id).last
      assert_equal "updated", operation(last)
      assert_equal "update_columns", last.metadata[:bypass_source]
      assert_equal [author.id, nil], changes(last)["author_id"]

      # The application's own update_columns is still refused.
      assert_raises(Lyra::StrictDataAccessViolation) { AnsArticle.find(child.id).update_columns(author_id: 1) }
    end

    # has_many :through, dependent: :nullify: removing a tag clears the tag
    # key of the author's tagging (the through record), the association's
    # own write.
    define_method("test_has_many_through_dependent_nullify_is_allowed_in_strict_mode_in_#{mode}") do
      use(mode)
      author = AnsTaggingAuthor.create!(name: "Ann", email: "ann-ans@example.com")
      red, blue = %w[red blue].map { AnsTag.create!(name: _1) }
      taggings = [red, blue].map { AnsTagging.create!(author_id: author.id, ans_tag_id: _1.id) }
      Lyra.config.strict_data_access = true

      AnsTaggingAuthor.find(author.id).ans_tags.delete(AnsTag.find(red.id))

      assert_nil AnsTagging.find(taggings.first.id).ans_tag_id
      assert_equal blue.id, AnsTagging.find(taggings.last.id).ans_tag_id
      last = stream(AnsTagging, taggings.first.id).last
      assert_equal "updated", operation(last)
      assert_equal "dependent_association", last.metadata[:nullify_source]
      assert_equal [red.id, nil], changes(last)["ans_tag_id"]

      # The application's own: refused.
      assert_raises(Lyra::StrictDataAccessViolation) do
        AnsTagging.where(author_id: author.id).update_all(ans_tag_id: nil)
      end
      assert_equal blue.id, AnsTagging.find(taggings.last.id).ans_tag_id
    end
  end

  MODES.each do |mode|
    # The mark identifies Rails' write, whatever its shape: a polymorphic
    # key (two columns) and a key not named *_id were refused in strict
    # mode by the shape test.
    define_method("test_polymorphic_has_many_dependent_nullify_is_allowed_in_strict_mode_in_#{mode}") do
      use(mode)
      owner = AnsKidOwner.create!(name: "Ann", email: "ann-ans@example.com")
      kid = AnsKid.create!(name: "k", owner_id: owner.id, owner_type: "AnsKidOwner")
      other = AnsKid.create!(name: "o", owner_id: owner.id, owner_type: "Elsewhere")
      Lyra.config.strict_data_access = true

      AnsKidOwner.find(owner.id).destroy!

      assert_equal [nil, nil], AnsKid.find(kid.id).then { [_1.owner_type, _1.owner_id] }
      assert_equal ["Elsewhere", owner.id], AnsKid.find(other.id).then { [_1.owner_type, _1.owner_id] }
      last = stream(AnsKid, kid.id).last
      assert_equal "dependent_association", last.metadata[:nullify_source]
      assert_equal({ "owner_type" => ["AnsKidOwner", nil], "owner_id" => [owner.id, nil] }, changes(last))
    end

    define_method("test_polymorphic_has_one_dependent_nullify_is_allowed_in_strict_mode_in_#{mode}") do
      use(mode)
      owner = AnsOneKidOwner.create!(name: "Ann", email: "ann-ans@example.com")
      kid = AnsKid.create!(name: "k", owner_id: owner.id, owner_type: "AnsOneKidOwner")
      Lyra.config.strict_data_access = true

      AnsOneKidOwner.find(owner.id).destroy!

      assert_equal [nil, nil], AnsKid.find(kid.id).then { [_1.owner_type, _1.owner_id] }
      last = stream(AnsKid, kid.id).last
      assert_equal "update_columns", last.metadata[:bypass_source]
      assert_equal [owner.id, nil], changes(last)["owner_id"]
    end

    define_method("test_removing_a_child_keyed_by_a_column_not_named_id_is_allowed_in_strict_mode_in_#{mode}") do
      use(mode)
      owner = AnsKidOwner.create!(name: "Ann", email: "ann-ans@example.com")
      kid = AnsKid.create!(name: "k", parent: owner.id)
      Lyra.config.strict_data_access = true

      AnsKidOwner.find(owner.id).fathered.delete(AnsKid.find(kid.id))

      assert_nil AnsKid.find(kid.id).parent
      last = stream(AnsKid, kid.id).last
      assert_equal "dependent_association", last.metadata[:nullify_source]
      assert_equal [owner.id, nil], changes(last)["parent"]
      assert_raises(Lyra::StrictDataAccessViolation) { AnsKid.where(id: kid.id).update_all(parent: nil) }
    end

    # has_many :through: removing a tag deletes the author's tagging (a
    # monitored through model), the association's own write; it was refused
    # in strict mode. Each through record gets its Destroyed.
    define_method("test_removing_a_record_from_a_has_many_through_is_allowed_in_strict_mode_in_#{mode}") do
      use(mode)
      author = AnsPlainTaggingAuthor.create!(name: "Ann", email: "ann-ans@example.com")
      red, blue = %w[red blue].map { AnsTag.create!(name: _1) }
      taggings = [red, blue].map { AnsTagging.create!(author_id: author.id, ans_tag_id: _1.id) }
      Lyra.config.strict_data_access = true

      AnsPlainTaggingAuthor.find(author.id).ans_tags.delete(AnsTag.find(red.id))

      assert_nil AnsTagging.find_by(id: taggings.first.id)
      assert AnsTagging.find_by(id: taggings.last.id)
      last = stream(AnsTagging, taggings.first.id).last
      assert_equal "destroyed", operation(last)
      assert_equal "delete_all", last.metadata[:bypass_source]
      assert AnsTag.find_by(id: red.id), "the tag itself stays"
      assert_raises(Lyra::StrictDataAccessViolation) { AnsTagging.where(id: taggings.last.id).delete_all }
    end

    # The mark is Rails' write's alone: a write the application makes while
    # the association loads its record (after_find) is its own, refused in
    # strict mode, even with the owner's destroy under way.
    define_method("test_an_application_write_during_the_association_s_load_is_not_marked_in_#{mode}") do
      use(mode)
      owner = AnsSneakyOwner.create!(name: "Ann", email: "ann-ans@example.com")
      AnsSneakyKid.create!(name: "k", owner_id: owner.id)
      victim = AnsSneakyKid.create!(name: "victim", parent: 42)
      Lyra.config.strict_data_access = true
      $ans_sneak = true

      assert_raises(Lyra::StrictDataAccessViolation) { AnsSneakyOwner.find(owner.id).destroy! }
      $ans_sneak = false
      assert_equal 42, AnsSneakyKid.find(victim.id).parent
      assert_nil Thread.current[Lyra::Associations::Maintenance::KEY]
    end
  end

  # A nullify that fails leaves no mark behind.
  def test_a_failed_nullify_leaves_no_mark
    use(:monitor)
    author = AnsAuthor.create!(name: "Ann", email: "ann-ans@example.com")
    child = AnsArticle.create!(title: "A", author_id: author.id)
    Lyra.config.strict_data_access = true

    assert_raises(RuntimeError) { Lyra::Associations::Maintenance.marking(:nullify, AnsArticle.where(id: child.id)) { raise "boom" } }

    assert_nil Thread.current[Lyra::Associations::Maintenance::KEY]
    assert_raises(Lyra::StrictDataAccessViolation) { AnsArticle.where(id: child.id).update_all(author_id: nil) }
  end

  private

  def define_models
    MODELS.each { |c| Object.send(:remove_const, c) if Object.const_defined?(c) }
    Object.const_set(:AnsArticle, Class.new(ActiveRecord::Base) do
      self.table_name = "articles"
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
    end)
    Object.const_set(:AnsAuthor, Class.new(ActiveRecord::Base) do
      self.table_name = "users"
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
      has_many :ans_articles, foreign_key: :author_id, class_name: "AnsArticle", dependent: :nullify
    end)
    Object.const_set(:AnsOneAuthor, Class.new(ActiveRecord::Base) do
      self.table_name = "users"
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
      has_one :ans_article, foreign_key: :author_id, class_name: "AnsArticle", dependent: :nullify
    end)
    Object.const_set(:AnsTag, Class.new(ActiveRecord::Base) do
      self.table_name = TAGS
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
    end)
    Object.const_set(:AnsTagging, Class.new(ActiveRecord::Base) do
      self.table_name = TAGGINGS
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
      belongs_to :ans_tag, class_name: "AnsTag", optional: true
    end)
    Object.const_set(:AnsTaggingAuthor, Class.new(ActiveRecord::Base) do
      self.table_name = "users"
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
      has_many :ans_taggings, foreign_key: :author_id, class_name: "AnsTagging"
      has_many :ans_tags, through: :ans_taggings, source: :ans_tag, dependent: :nullify
    end)
    Object.const_set(:AnsPlainTaggingAuthor, Class.new(ActiveRecord::Base) do
      self.table_name = "users"
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
      has_many :ans_taggings, foreign_key: :author_id, class_name: "AnsTagging"
      has_many :ans_tags, through: :ans_taggings, source: :ans_tag
    end)
    Object.const_set(:AnsKid, Class.new(ActiveRecord::Base) do
      self.table_name = KIDS
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
    end)
    # Application code that runs while Rails loads a has_one's record.
    Object.const_set(:AnsSneakyKid, Class.new(ActiveRecord::Base) do
      self.table_name = KIDS
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
      # Once: in ES-NoProj the write reads the records, and finds them again.
      after_find do
        next unless $ans_sneak

        $ans_sneak = false
        AnsSneakyKid.where(name: "victim").update_all(parent: nil)
      end
    end)
    Object.const_set(:AnsKidOwner, Class.new(ActiveRecord::Base) do
      self.table_name = "users"
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
      has_many :ans_kids, as: :owner, class_name: "AnsKid", dependent: :nullify
      has_many :fathered, foreign_key: :parent, class_name: "AnsKid"
    end)
    Object.const_set(:AnsOneKidOwner, Class.new(ActiveRecord::Base) do
      self.table_name = "users"
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
      has_one :ans_kid, as: :owner, class_name: "AnsKid", dependent: :nullify
    end)
    Object.const_set(:AnsSneakyOwner, Class.new(ActiveRecord::Base) do
      self.table_name = "users"
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
      has_one :ans_sneaky_kid, foreign_key: :owner_id, class_name: "AnsSneakyKid", dependent: :nullify
    end)
    [AnsTag, AnsTagging, AnsKid, AnsSneakyKid].each(&:reset_column_information)
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

  def stream(model, id) = Lyra.config.event_store.read.stream(Lyra.stream_name(model, id)).to_a

  def operation(event) = (event.data[:operation] || event.data["operation"]).to_s

  def changes(event)
    (event.data[:changes] || event.data["changes"] || {}).transform_keys(&:to_s)
  end

  def event_count = connection.select_value("SELECT COUNT(*) FROM event_store_events").to_i

  def connection = ActiveRecord::Base.connection

  def clean
    %W[articles users #{TAGGINGS} #{TAGS} #{KIDS}].each { |table| connection.execute("DELETE FROM #{table}") if connection.table_exists?(table) }
    connection.execute("DELETE FROM event_store_events_in_streams")
    connection.execute("DELETE FROM event_store_events")
    Lyra::Projections::LazyProjection.reset!
    Rails.cache.clear
  end
end
