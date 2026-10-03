# frozen_string_literal: true

require "test_helper"

# ES-NoProj evaluates joins in memory, from the joined models' streams (or
# table, if the joined model is not monitored). Every query here is checked
# against the same query run as real SQL on the same data: the data is
# written in ES-Sync, so table and streams agree, and the SQL answer is the
# ground truth.
class CachedJoinsTest < Minitest::Test
  UnsupportedQuery = Lyra::Projections::UnsupportedQuery

  def setup
    skip "Requires Rails and database" unless defined?(ActiveRecord::Base) && ActiveRecord::Base.connection.table_exists?(:articles)

    %i[CjArticle CjAuthor CjPlainAuthor].each { |c| Object.send(:remove_const, c) if Object.const_defined?(c) }
    Object.const_set(:CjAuthor, Class.new(ActiveRecord::Base) do
      self.table_name = "users"
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
      has_many :articles, foreign_key: :author_id, class_name: "CjArticle"
      has_many :published, -> { where(status: "published") }, foreign_key: :author_id, class_name: "CjArticle"
    end)
    # The same table, not monitored: joins to it read the table.
    Object.const_set(:CjPlainAuthor, Class.new(ActiveRecord::Base) { self.table_name = "users" })
    Object.const_set(:CjArticle, Class.new(ActiveRecord::Base) do
      self.table_name = "articles"
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
      belongs_to :author, class_name: "CjAuthor", optional: true
      belongs_to :plain_author, class_name: "CjPlainAuthor", foreign_key: :author_id, optional: true
    end)

    clean
    Rails.cache.clear
    Lyra.config.enable_event_sourcing!
    Lyra.config.projection_mode = :sync
    Lyra.config.monitor_model(CjAuthor)
    Lyra.config.monitor_model(CjArticle)

    @ann = CjAuthor.create!(name: "Ann", email: "ann@example.com")
    @bob = CjAuthor.create!(name: "Bob", email: "bob@example.com")
    @cy = CjAuthor.create!(name: "Cy", email: "cy@example.com") # no articles
    CjArticle.create!(title: "A1", body: "x", author_id: @ann.id, status: "published")
    CjArticle.create!(title: "A2", body: "x", author_id: @ann.id, status: "draft")
    CjArticle.create!(title: "B1", body: "x", author_id: @bob.id, status: "published")
    CjArticle.create!(title: "N1", body: "x", author_id: nil, status: "published")

    Lyra.config.projection_mode = :disabled
  end

  def teardown
    return unless defined?(CjArticle)

    Lyra.config.projection_mode = :sync
    clean
    Rails.cache.clear
  end

  def test_inner_join_on_belongs_to_with_a_condition_on_the_joined_table
    same { CjArticle.joins(:author).where(users: { name: "Ann" }) }
    same { CjArticle.joins(:author).where(author: { name: %w[Ann Bob] }) }
  end

  def test_an_inner_join_drops_records_without_a_partner
    same(:count) { CjArticle.joins(:author) }
  end

  def test_a_has_many_join_repeats_the_parent_per_child
    same(:count) { CjAuthor.joins(:articles) }
    same(:count) { CjAuthor.joins(:articles).distinct }
    same { CjAuthor.joins(:articles).where(articles: { status: "published" }) }
  end

  def test_left_joins_keep_records_without_a_partner
    same(:count) { CjAuthor.left_joins(:articles) }
    same { CjAuthor.left_joins(:articles).where(articles: { id: nil }) }
  end

  def test_where_not_on_a_joined_table_follows_sql_null_rules
    same { CjArticle.joins(:author).where.not(users: { name: "Ann" }) }
    same { CjArticle.left_joins(:author).where.not(users: { name: "Ann" }) } # N1 is excluded, as in SQL
  end

  def test_missing_and_associated
    same { CjAuthor.where.missing(:articles) }
    same { CjArticle.where.missing(:author) }
    same(:count) { CjAuthor.where.associated(:articles) }
  end

  def test_own_and_joined_conditions_together
    same { CjArticle.joins(:author).where(status: "published", users: { name: %w[Ann Bob] }) }
    same { CjArticle.joins(:author).where(users: { name: "Ann" }).where(status: "draft") }
  end

  def test_a_joined_model_that_is_not_monitored_is_read_from_its_table
    same { CjArticle.joins(:plain_author).where(users: { name: "Bob" }) }
  end

  def test_what_cannot_be_evaluated_is_refused
    assert_raises(UnsupportedQuery) { CjArticle.joins("INNER JOIN users ON users.id = articles.author_id").to_a }
    assert_raises(UnsupportedQuery) { CjArticle.joins(author: :articles).to_a }
    assert_raises(UnsupportedQuery) { CjAuthor.joins(:published).to_a } # scoped association
    assert_raises(UnsupportedQuery) { CjArticle.where(users: { name: "Ann" }).to_a } # not joined
    assert_raises(UnsupportedQuery) { CjArticle.joins(:author).where(users: { articles: { id: 1 } }).to_a }
  end

  private

  # Run the query in ES-NoProj and as real SQL; the answers must agree.
  def same(what = :titles, &query)
    relation = query.call
    assert_kind_of Lyra::Projections::CachedRelation, relation, "the ES-NoProj side must not run SQL"
    eventsourced = summarise(relation, what)
    sql = with_sql do
      sql_relation = query.call
      assert_kind_of ActiveRecord::Relation, sql_relation
      summarise(sql_relation, what)
    end
    assert_equal sql, eventsourced, "ES-NoProj and SQL disagree"
  end

  def summarise(relation, what)
    case what
    when :count then relation.count
    else relation.to_a.map { _1.respond_to?(:title) ? _1.title : _1.name }.sort
    end
  end

  def with_sql
    previous = Thread.current[:lyra_bypass_read_override]
    Thread.current[:lyra_bypass_read_override] = true
    yield
  ensure
    Thread.current[:lyra_bypass_read_override] = previous
  end

  def clean
    conn = ActiveRecord::Base.connection
    conn.execute("DELETE FROM articles")
    conn.execute("DELETE FROM users")
    conn.execute("DELETE FROM event_store_events_in_streams")
    conn.execute("DELETE FROM event_store_events")
  end
end
