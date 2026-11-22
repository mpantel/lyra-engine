# frozen_string_literal: true

require "test_helper"

# A parent's dependent: :delete_all, :nullify and has_one :delete under
# ES-NoProj (event sourcing, projections disabled), where the event log is the
# only store and the tables are empty or stale. Rails writes these through the
# association's table scope; in the events-only store that scope matches no
# row. dependent: :delete_all wrote no event for the children, which stayed
# alive in the log. Each scenario also runs in Monitor, where the table is the
# store, and must behave the same there.
class EsNoprojDependentTest < Minitest::Test
  MODELS = %i[EdArticle EdKeptArticle EdDeletingAuthor EdScopedDeletingAuthor EdNullifyingAuthor
              EdScopedNullifyingAuthor EdHasOneDeletingAuthor EdHasOneNullifyingAuthor EdPlainAuthor
              EdKeptDeletingAuthor EdKeptNullifyingAuthor EdUnscopingAuthor EdSqlDeletingAuthor
              EdSqlNullifyingAuthor].freeze

  def setup
    skip "Requires Rails and database" unless defined?(ActiveRecord::Base) && ActiveRecord::Base.connection.table_exists?(:articles)

    MODELS.each { |c| Object.send(:remove_const, c) if Object.const_defined?(c) }
    define_models
    clean
    Rails.cache.clear
    MODELS.each { |name| Lyra.config.monitor_model(Object.const_get(name)) }
  end

  def teardown
    return unless defined?(EdArticle)

    Lyra.config.strict_data_access = false
    Lyra.config.projection_mode = :sync
    clean
    Rails.cache.clear
  end

  %i[es_noproj monitor].each do |mode|
    define_method(:"test_dependent_delete_all_destroys_each_child_in_#{mode}") do
      use(mode)
      author = EdDeletingAuthor.create!(name: "Ann", email: "ann@example.com")
      children = [article("A1", author), article("A2", author)]
      other = article("B1", nil)

      EdDeletingAuthor.find(author.id).destroy

      assert_equal 0, EdArticle.where(author_id: author.id).count
      children.each do |child|
        assert_nil EdArticle.find_by(id: child.id), "#{child.title} read back"
        last = stream(child).last
        assert_equal "destroyed", operation(last)
        assert_equal "delete_all", last.metadata[:bypass_source]
      end
      assert EdArticle.find_by(id: other.id), "a record of no parent stays"
    end

    define_method(:"test_dependent_delete_all_deletes_only_what_a_scoped_association_selects_in_#{mode}") do
      use(mode)
      author = EdScopedDeletingAuthor.create!(name: "Ann", email: "ann@example.com")
      published = article("A1", author, status: "published")
      draft = article("A2", author, status: "draft")

      EdScopedDeletingAuthor.find(author.id).destroy

      assert_nil EdArticle.find_by(id: published.id)
      assert_equal "destroyed", operation(stream(published).last)
      assert_equal author.id, EdArticle.find(draft.id).author_id
      assert_equal "created", operation(stream(draft).last)
    end

    define_method(:"test_strict_mode_refuses_dependent_delete_all_in_#{mode}") do
      use(mode)
      author = EdDeletingAuthor.create!(name: "Ann", email: "ann@example.com")
      child = article("A1", author)
      Lyra.config.strict_data_access = true

      assert_raises(Lyra::StrictDataAccessViolation) do
        EdDeletingAuthor.transaction { EdDeletingAuthor.find(author.id).destroy }
      end
      assert EdDeletingAuthor.find_by(id: author.id)
      assert EdArticle.find_by(id: child.id)
      assert_equal "created", operation(stream(child).last)
    end

    define_method(:"test_dependent_nullify_clears_each_childs_key_in_#{mode}") do
      use(mode)
      author = EdNullifyingAuthor.create!(name: "Ann", email: "ann@example.com")
      children = [article("A1", author), article("A2", author)]

      EdNullifyingAuthor.find(author.id).destroy

      assert_equal 0, EdArticle.where(author_id: author.id).count
      children.each do |child|
        assert_nil EdArticle.find(child.id).author_id
        last = stream(child).last
        assert_equal "updated", operation(last)
        assert_equal "dependent_association", last.metadata[:nullify_source]
        assert_equal [author.id, nil], changes(last)["author_id"]
      end
    end

    define_method(:"test_dependent_nullify_clears_only_what_a_scoped_association_selects_in_#{mode}") do
      use(mode)
      author = EdScopedNullifyingAuthor.create!(name: "Ann", email: "ann@example.com")
      published = article("A1", author, status: "published")
      draft = article("A2", author, status: "draft")

      EdScopedNullifyingAuthor.find(author.id).destroy

      assert_nil EdArticle.find(published.id).author_id
      assert_equal author.id, EdArticle.find(draft.id).author_id
      assert_equal "created", operation(stream(draft).last)
    end

    define_method(:"test_has_one_dependent_delete_destroys_the_child_in_#{mode}") do
      use(mode)
      author = EdHasOneDeletingAuthor.create!(name: "Ann", email: "ann@example.com")
      child = article("A1", author)

      EdHasOneDeletingAuthor.find(author.id).destroy

      assert_nil EdArticle.find_by(id: child.id)
      assert_equal "destroyed", operation(stream(child).last)
    end

    define_method(:"test_has_one_dependent_nullify_clears_the_childs_key_in_#{mode}") do
      use(mode)
      author = EdHasOneNullifyingAuthor.create!(name: "Ann", email: "ann@example.com")
      child = article("A1", author)

      EdHasOneNullifyingAuthor.find(author.id).destroy

      assert_nil EdArticle.find(child.id).author_id
      last = stream(child).last
      assert_equal "updated", operation(last)
      assert_equal [author.id, nil], changes(last)["author_id"]
    end

    # Clearing a polymorphic key writes two columns. It is Rails' own nullify
    # all the same (Lyra::Associations::Maintenance): the
    # dependent_association bypass, with both columns' changes, in both
    # modes. Before 1.0.0 its shape made it a plain update_all, refused in
    # strict mode.
    define_method(:"test_a_polymorphic_dependent_nullify_clears_each_childs_keys_in_#{mode}") do
      with_notes_table do
        use(mode)
        author = EdNotedAuthor.create!(name: "Ann", email: "ann@example.com")
        note = EdNote.create!(body: "n", notable_type: "EdNotedAuthor", notable_id: author.id)
        other = EdNote.create!(body: "o", notable_type: "Elsewhere", notable_id: author.id)

        EdNotedAuthor.find(author.id).destroy

        assert_equal [nil, nil], EdNote.find(note.id).then { [_1.notable_type, _1.notable_id] }
        last = Lyra.config.event_store.read.stream("EdNote$#{note.id}").to_a.last
        assert_equal "updated", operation(last)
        assert_equal "dependent_association", last.metadata[:nullify_source]
        assert_equal({ "notable_type" => ["EdNotedAuthor", nil], "notable_id" => [author.id, nil] }, changes(last))
        assert_equal ["Elsewhere", author.id], EdNote.find(other.id).then { [_1.notable_type, _1.notable_id] }
      end
    end

    # The children are found as Lyra's own read, as a bulk write's snapshot
    # is, whatever purpose the parent is destroyed for.
    define_method(:"test_dependent_delete_all_under_a_purpose_in_#{mode}") do
      skip "Requires pam_dsl" unless Lyra.pam_dsl_available?

      with_article_policy do
        use(mode)
        author = EdDeletingAuthor.create!(name: "Ann", email: "ann@example.com")
        child = article("A1", author)

        Lyra.with_purpose(:proofreading) do
          assert_raises(PamDsl::PurposeFieldMismatchError) { EdArticle.find(child.id) }
          EdDeletingAuthor.find(author.id).destroy
        end

        assert_nil EdArticle.find_by(id: child.id)
        assert_equal "destroyed", operation(stream(child).last)
      end
    end

    # The association selects through the child's default scope, as Active
    # Record's association scope does: a child the default scope leaves out
    # (soft-deleted, here published) is neither deleted nor nullified.
    define_method(:"test_dependent_delete_all_keeps_children_out_of_the_default_scope_in_#{mode}") do
      use(mode)
      author = EdKeptDeletingAuthor.create!(name: "Ann", email: "ann@example.com")
      kept = kept_article("A1", author)
      published = kept_article("A2", author, published_at: Time.current)

      EdKeptDeletingAuthor.find(author.id).destroy

      assert_equal "destroyed", operation(stream(kept, EdKeptArticle).last)
      assert_equal "created", operation(stream(published, EdKeptArticle).last)
    end

    define_method(:"test_dependent_nullify_keeps_children_out_of_the_default_scope_in_#{mode}") do
      use(mode)
      author = EdKeptNullifyingAuthor.create!(name: "Ann", email: "ann@example.com")
      kept = kept_article("A1", author)
      published = kept_article("A2", author, published_at: Time.current)

      EdKeptNullifyingAuthor.find(author.id).destroy

      assert_equal [author.id, nil], changes(stream(kept, EdKeptArticle).last)["author_id"]
      assert_equal "created", operation(stream(published, EdKeptArticle).last)
    end

    define_method(:"test_an_association_that_unscopes_the_default_scope_deletes_past_it_in_#{mode}") do
      use(mode)
      author = EdUnscopingAuthor.create!(name: "Ann", email: "ann@example.com")
      kept = kept_article("A1", author)
      published = kept_article("A2", author, published_at: Time.current)

      EdUnscopingAuthor.find(author.id).destroy

      [kept, published].each { assert_equal "destroyed", operation(stream(_1, EdKeptArticle).last) }
    end

    # The in-memory counter cache is what the store holds after the delete:
    # 0 in Monitor, and in ES-NoProj, which does not maintain counter caches,
    # what the log holds, never a negative count.
    define_method(:"test_delete_all_leaves_the_counter_cache_as_the_store_has_it_in_#{mode}") do
      with_counted_tables do
        use(mode)
        author = EdCountedAuthor.create!(name: "Ann")
        2.times { |i| EdCountedArticle.create!(title: "A#{i}", body: "x", author_id: author.id) }
        loaded = EdCountedAuthor.find(author.id)

        assert EdCountedAuthor.reflect_on_association(:ed_counted_articles).has_cached_counter?
        assert_equal 2, loaded.ed_counted_articles.delete_all
        assert_equal EdCountedAuthor.find(author.id).ed_counted_articles_count, loaded.ed_counted_articles_count
        assert_operator loaded.ed_counted_articles_count, :>=, 0
      end
    end

    # Removing records from an association (delete, or assigning a new set)
    # deletes or nullifies them as dependent: says, with Monitor's events.
    { EdPlainAuthor: "dependent_association", EdNullifyingAuthor: "dependent_association",
      EdDeletingAuthor: "delete_all" }.each do |parent, source|
      define_method(:"test_#{parent}_association_delete_removes_only_the_given_record_in_#{mode}") do
        use(mode)
        klass = Object.const_get(parent)
        author = klass.create!(name: "Ann", email: "ann@example.com")
        a = article("A1", author)
        b = article("A2", author)
        Lyra.config.strict_data_access = true if source == "dependent_association"

        klass.find(author.id).ed_articles.delete(EdArticle.find(a.id))

        last = stream(a).last
        assert_equal source, last.metadata[:nullify_source] || last.metadata[:bypass_source]
        assert_equal "created", operation(stream(b).last)
        assert_equal [b.id], klass.find(author.id).ed_articles.map(&:id)
      end

      define_method(:"test_#{parent}_association_assignment_removes_the_others_in_#{mode}") do
        use(mode)
        klass = Object.const_get(parent)
        author = klass.create!(name: "Ann", email: "ann@example.com")
        a = article("A1", author)
        b = article("A2", author)

        klass.find(author.id).ed_articles = [EdArticle.find(b.id)]

        last = stream(a).last
        assert_equal source, last.metadata[:nullify_source] || last.metadata[:bypass_source]
        assert_equal "created", operation(stream(b).last)
        assert_equal [b.id], klass.find(author.id).ed_articles.map(&:id)
      end
    end
  end

  # A dependent association whose scope is an SQL string cannot be evaluated
  # against the event store. ES-NoProj refuses the parent's destroy rather
  # than delete or nullify children the scope might not select.
  %i[EdSqlDeletingAuthor EdSqlNullifyingAuthor].each do |parent|
    define_method(:"test_#{parent}_destroy_is_refused_in_es_noproj") do
      use(:es_noproj)
      klass = Object.const_get(parent)
      author = klass.create!(name: "Ann", email: "ann@example.com")
      published = article("A1", author, status: "published")
      draft = article("A2", author)

      error = assert_raises(Lyra::Projections::UnsupportedQuery) { klass.find(author.id).destroy }
      assert_match(/ed_articles/, error.message)
      assert klass.find_by(id: author.id), "the parent stays"
      [published, draft].each { assert_equal "created", operation(stream(_1).last) }
    end

    define_method(:"test_#{parent}_destroy_goes_ahead_in_monitor") do
      use(:monitor)
      klass = Object.const_get(parent)
      author = klass.create!(name: "Ann", email: "ann@example.com")
      published = article("A1", author, status: "published")
      draft = article("A2", author)

      klass.find(author.id).destroy

      assert_nil klass.find_by(id: author.id)
      assert_includes %w[destroyed updated], operation(stream(published).last)
      assert_equal "created", operation(stream(draft).last)
    end
  end

  private

  def kept_article(title, author, published_at: nil)
    EdKeptArticle.create!(title: title, body: "x", author_id: author.id, published_at: published_at)
  end

  def with_counted_tables
    connection = ActiveRecord::Base.connection
    connection.create_table(:lyra_dep_counted_authors, force: true) do |t|
      t.string :name
      t.integer :ed_counted_articles_count, default: 0, null: false
      t.timestamps
    end
    %i[EdCountedArticle EdCountedAuthor].each { |c| Object.send(:remove_const, c) if Object.const_defined?(c) }
    # Named before their bodies run: Rails finds the counter cache by class name.
    Object.const_set(:EdCountedArticle, Class.new(ActiveRecord::Base)).class_eval do
      self.table_name = "articles"
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
      belongs_to :ed_counted_author, foreign_key: :author_id, counter_cache: true, optional: true
    end
    Object.const_set(:EdCountedAuthor, Class.new(ActiveRecord::Base)).class_eval do
      self.table_name = "lyra_dep_counted_authors"
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
      has_many :ed_counted_articles, foreign_key: :author_id, class_name: "EdCountedArticle", dependent: :delete_all
    end
    yield
  ensure
    connection.drop_table(:lyra_dep_counted_authors, if_exists: true)
  end

  def with_notes_table
    connection = ActiveRecord::Base.connection
    connection.create_table(:lyra_dep_notes, force: true) do |t|
      t.string :body
      t.string :notable_type
      t.integer :notable_id
      t.timestamps
    end
    %i[EdNote EdNotedAuthor].each { |c| Object.send(:remove_const, c) if Object.const_defined?(c) }
    Object.const_set(:EdNote, Class.new(ActiveRecord::Base) do
      self.table_name = "lyra_dep_notes"
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
    end)
    Object.const_set(:EdNotedAuthor, Class.new(ActiveRecord::Base) do
      self.table_name = "users"
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
      has_many :ed_notes, as: :notable, class_name: "EdNote", dependent: :nullify
    end)
    yield
  ensure
    connection.drop_table(:lyra_dep_notes, if_exists: true)
  end

  def with_article_policy
    PamDsl.reset!
    PamDsl.logger = Logger.new(nil)
    PamDsl.define_policy(:ed_article_policy) do
      field :title, type: :name
      field :body, type: :name
      purpose :proofreading do
        basis :legitimate_interests
        requires :body
      end
    end
    EdArticle.monitor_with_lyra(privacy_policy: :ed_article_policy)
    yield
  ensure
    PamDsl.reset!
    PamDsl.logger = nil
  end

  def define_models
    Object.const_set(:EdArticle, Class.new(ActiveRecord::Base) do
      self.table_name = "articles"
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
    end)
    # A soft-delete style default scope: a published article is out of it.
    Object.const_set(:EdKeptArticle, Class.new(ActiveRecord::Base) do
      self.table_name = "articles"
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
      default_scope { where(published_at: nil) }
    end)
    kept = { class_name: "EdKeptArticle" }
    sql_scope = -> { where("status = 'published'") }
    parents = {
      EdDeletingAuthor: [:has_many, :ed_articles, { dependent: :delete_all }],
      EdScopedDeletingAuthor: [:has_many, :ed_articles, -> { where(status: "published") }, { dependent: :delete_all }],
      EdNullifyingAuthor: [:has_many, :ed_articles, { dependent: :nullify }],
      EdScopedNullifyingAuthor: [:has_many, :ed_articles, -> { where(status: "published") }, { dependent: :nullify }],
      EdHasOneDeletingAuthor: [:has_one, :ed_article, { dependent: :delete }],
      EdHasOneNullifyingAuthor: [:has_one, :ed_article, { dependent: :nullify }],
      EdPlainAuthor: [:has_many, :ed_articles, {}],
      EdKeptDeletingAuthor: [:has_many, :ed_kept_articles, { dependent: :delete_all, **kept }],
      EdKeptNullifyingAuthor: [:has_many, :ed_kept_articles, { dependent: :nullify, **kept }],
      EdUnscopingAuthor: [:has_many, :ed_kept_articles, -> { unscope(where: :published_at) },
                          { dependent: :delete_all, **kept }],
      EdSqlDeletingAuthor: [:has_many, :ed_articles, sql_scope, { dependent: :delete_all }],
      EdSqlNullifyingAuthor: [:has_many, :ed_articles, sql_scope, { dependent: :nullify }]
    }
    parents.each do |name, (macro, association, *rest)|
      options = { foreign_key: :author_id, class_name: "EdArticle" }.merge(rest.pop)
      Object.const_set(name, Class.new(ActiveRecord::Base) do
        self.table_name = "users"
        include Lyra::Interceptors::CrudInterceptor
        monitor_with_lyra
        public_send(macro, association, *rest, **options)
      end)
    end
  end

  def use(mode)
    if mode == :es_noproj
      Lyra.config.enable_event_sourcing!
      Lyra.config.projection_mode = :disabled
    else
      Lyra.config.enable_monitor!
    end
  end

  def article(title, author, status: "draft")
    EdArticle.create!(title: title, body: "x", author_id: author&.id, status: status)
  end

  def stream(record, klass = EdArticle)
    Lyra.config.event_store.read.stream("#{klass.name}$#{record.id}").to_a
  end

  def operation(event) = (event.data[:operation] || event.data["operation"]).to_s

  def changes(event) = (event.data[:changes] || event.data["changes"]).transform_keys(&:to_s)

  def clean
    conn = ActiveRecord::Base.connection
    conn.execute("DELETE FROM articles")
    conn.execute("DELETE FROM users")
    conn.execute("DELETE FROM event_store_events_in_streams")
    conn.execute("DELETE FROM event_store_events")
  end
end
