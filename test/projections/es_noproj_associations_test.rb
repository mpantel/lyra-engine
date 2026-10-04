# frozen_string_literal: true

require "test_helper"

# What the Solidus Olist replay needed from ES-NoProj: association scopes,
# through and scoped associations, calculations on an association, building
# through one, grouped aggregates and the rest of the relation API that
# Solidus calls on what the event store answers.
class EsNoprojAssociationsTest < Minitest::Test
  def setup
    skip "Requires Rails and database" unless defined?(ActiveRecord::Base) && ActiveRecord::Base.connection.table_exists?(:articles)

    %i[EnArticle EnAuthor].each { |c| Object.send(:remove_const, c) if Object.const_defined?(c) }
    Object.const_set(:EnAuthor, Class.new(ActiveRecord::Base) do
      self.table_name = "users"
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
      has_many :en_articles, foreign_key: :author_id, class_name: "EnArticle"
      has_many :published_articles, -> { where(status: "published") }, foreign_key: :author_id, class_name: "EnArticle"
      has_many :article_authors, through: :en_articles, source: :author
      has_many :nullified_articles, foreign_key: :author_id, class_name: "EnArticle", dependent: :nullify
    end)
    Object.const_set(:EnArticle, Class.new(ActiveRecord::Base) do
      self.table_name = "articles"
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
      class_attribute :flavour, default: "plain"
      belongs_to :author, class_name: "EnAuthor", optional: true
    end)

    clean
    Rails.cache.clear
    Lyra.config.monitor_model(EnAuthor)
    Lyra.config.monitor_model(EnArticle)
    Lyra.config.enable_event_sourcing!
    Lyra.config.projection_mode = :disabled
    @ann = EnAuthor.create!(name: "Ann", email: "ann@example.com")
    @bob = EnAuthor.create!(name: "Bob", email: "bob@example.com")
    EnArticle.create!(title: "A1", body: "x", author_id: @ann.id, status: "published")
    EnArticle.create!(title: "A2", body: "x", author_id: @ann.id, status: "draft")
    EnArticle.create!(title: "B1", body: "x", author_id: @bob.id, status: "published")
  end

  def teardown
    return unless defined?(EnArticle)

    Lyra.config.projection_mode = :sync
    clean
    Rails.cache.clear
  end

  def test_queries_on_an_association_run_on_the_event_store
    ann = EnAuthor.find(@ann.id)

    assert_equal "A2", ann.en_articles.where(status: "draft").first.title
    assert_equal "A1", ann.en_articles.find_by(title: "A1").title
  end

  def test_calculations_on_an_association_read_the_events
    ann = EnAuthor.find(@ann.id)

    assert_equal 2, ann.en_articles.count
    assert_equal %w[A1 A2], ann.en_articles.pluck(:title).sort
    assert ann.en_articles.exists?
    assert_equal ann.en_articles.map(&:id).sum, ann.en_articles.sum(:id)
  end

  def test_a_scoped_association_applies_its_scope
    assert_equal %w[A1], EnAuthor.find(@ann.id).published_articles.map(&:title)
  end

  # The foreign key of a :through association is on the intermediate
  # records; it was looked for on the target and refused.
  def test_a_through_association_reads_through_the_intermediate_records
    assert_equal [@ann.id], EnAuthor.find(@ann.id).article_authors.map(&:id)
  end

  def test_building_through_an_association_sets_the_foreign_key
    article = EnAuthor.find(@ann.id).en_articles.build(title: "A3", body: "x")

    assert_equal @ann.id, article.author_id
    article.save!
    assert_equal %w[A1 A2 A3], EnAuthor.find(@ann.id).en_articles.map(&:title).sort
  end

  def test_find_or_create_by_takes_the_where_conditions
    created = EnArticle.where(author_id: @bob.id, status: "draft").find_or_create_by!(title: "B2", body: "x")

    assert_equal [@bob.id, "draft"], [created.author_id, created.status]
    assert_equal created.id, EnArticle.where(author_id: @bob.id).find_or_create_by!(title: "B2").id
  end

  def test_grouped_aggregates
    assert_equal({ @ann.id => 2, @bob.id => 1 }, EnArticle.group(:author_id).count)
    assert_equal({ "published" => 2, "draft" => 1 }, EnArticle.all.group(:status).count)
  end

  def test_a_record_in_a_condition_is_its_id
    assert_equal %w[A1 A2], EnArticle.where(author_id: [@ann]).map(&:title).sort
  end

  def test_class_attributes_and_extensions_answer_on_the_relation
    relation = EnArticle.where(status: "published")

    assert_equal "plain", relation.flavour
    assert_equal 42, relation.extending { def answer = 42 }.answer
    assert_equal 2, relation.extending { def answer = 42 }.where(status: "published").count
  end

  # dependent: :nullify writes through the association's scope; it must stay
  # the dependent_association bypass Lyra records, not an update_all on the
  # event-backed scope (refused in strict mode).
  def test_dependent_nullify_is_recorded_as_such
    Lyra.config.strict_data_access = true
    article = EnArticle.find_by(title: "B1")

    EnAuthor.find(@bob.id).destroy

    event = Lyra.config.event_store.read.stream("EnArticle$#{article.id}").to_a.last
    assert_equal "dependent_association", event.metadata[:nullify_source]
    assert_nil EnArticle.find(article.id).author_id
  ensure
    Lyra.config.strict_data_access = false
  end

  private

  def clean
    conn = ActiveRecord::Base.connection
    conn.execute("DELETE FROM articles")
    conn.execute("DELETE FROM users")
    conn.execute("DELETE FROM event_store_events_in_streams")
    conn.execute("DELETE FROM event_store_events")
  end
end
