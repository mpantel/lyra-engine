# frozen_string_literal: true

require "test_helper"

# ES-NoProj evaluates hash conditions against cached records. A belongs_to
# association in a condition must become its foreign key, as ActiveRecord
# does it, rather than be loaded record by record.
class AssociationConditionsTest < Minitest::Test
  Rewrite = Lyra::Projections::AssociationConditions

  def setup
    skip "Requires Rails and database" unless defined?(ActiveRecord::Base) && ActiveRecord::Base.connection.table_exists?(:articles)

    %i[AcArticle AcAuthor AcComment].each { |c| Object.send(:remove_const, c) if Object.const_defined?(c) }
    Object.const_set(:AcAuthor, Class.new(ActiveRecord::Base) do
      self.table_name = "users"
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
      has_many :ac_articles, foreign_key: :author_id, class_name: "AcArticle"
    end)
    Object.const_set(:AcArticle, Class.new(ActiveRecord::Base) do
      self.table_name = "articles"
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
      belongs_to :author, class_name: "AcAuthor", optional: true
    end)
    # Polymorphic reflection only: the rewrite needs no columns for it.
    Object.const_set(:AcComment, Class.new(ActiveRecord::Base) do
      self.table_name = "articles"
      belongs_to :subject, polymorphic: true, optional: true
    end)

    clean
    Rails.cache.clear
    Lyra.config.monitor_model(AcAuthor)
    Lyra.config.monitor_model(AcArticle)
    @ann = AcAuthor.create!(name: "Ann", email: "ann@example.com")
    @bob = AcAuthor.create!(name: "Bob", email: "bob@example.com")
    Lyra.config.enable_event_sourcing!
    Lyra.config.projection_mode = :disabled
    AcArticle.create!(title: "A1", body: "x", author_id: @ann.id)
    AcArticle.create!(title: "A2", body: "x", author_id: @ann.id)
    AcArticle.create!(title: "B1", body: "x", author_id: @bob.id)
    AcArticle.create!(title: "N1", body: "x", author_id: nil)
  end

  def teardown
    return unless defined?(AcArticle)

    Lyra.config.projection_mode = :sync
    clean
    Rails.cache.clear
  end

  def test_a_belongs_to_condition_is_its_foreign_key
    assert_equal %w[A1 A2], titles(AcArticle.where(author: @ann))
    assert_equal titles(AcArticle.where(author_id: @ann.id)), titles(AcArticle.where(author: @ann))
    assert_equal 2, AcArticle.where(author: @ann).count
  end

  # The cost must not grow with the number of records: the association was
  # loaded once per record (from the table, or under ES-NoProj through the
  # event-store reader).
  def test_the_query_count_does_not_grow_with_the_records
    AcArticle.where(author: @ann).to_a # warm the cache
    before = capture_sql { AcArticle.where(author: @ann).count }.size

    10.times { |i| AcArticle.create!(title: "M#{i}", body: "x", author_id: @bob.id) }
    AcArticle.where(author: @ann).to_a
    after = capture_sql { AcArticle.where(author: @ann).count }.size

    assert_equal before, after
  end

  def test_find_by_an_association_finds_the_record
    article = AcArticle.find_by(author: @bob)

    refute_nil article, "it compared against a missing \"author\" attribute and found nothing"
    assert_equal "B1", article.title
  end

  def test_a_record_as_a_column_value_is_its_id
    assert_equal %w[A1 A2], titles(AcArticle.where(author_id: @ann))
  end

  def test_several_records_nil_and_negation
    assert_equal %w[A1 A2 B1], titles(AcArticle.where(author: [@ann, @bob]))
    assert_equal %w[N1], titles(AcArticle.where(author: nil))
    assert_equal %w[B1 N1], titles(AcArticle.where.not(author: @ann))
  end

  def test_a_has_many_condition_is_refused_as_activerecord_would_need_a_join
    assert_raises(Lyra::Projections::UnsupportedQuery) { AcAuthor.where(ac_articles: AcArticle.first).to_a }
  end

  def test_a_polymorphic_condition_becomes_type_and_id
    assert_equal({ "subject_type" => "AcAuthor", "subject_id" => @ann.id }, Rewrite.rewrite(AcComment, { subject: @ann }))
    assert_equal({ "subject_type" => "AcAuthor", "subject_id" => [@ann.id, @bob.id] },
                 Rewrite.rewrite(AcComment, { subject: [@ann, @bob] }))
    assert_equal({ "subject_type" => nil, "subject_id" => nil }, Rewrite.rewrite(AcComment, { subject: nil }))
  end

  def test_a_polymorphic_condition_over_several_types_is_refused
    article = AcArticle.instantiate("id" => 1)
    assert_raises(Lyra::Projections::UnsupportedQuery) { Rewrite.rewrite(AcComment, { subject: [@ann, article] }) }
  end

  private

  def titles(relation) = relation.map(&:title).sort

  def capture_sql
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| statements << payload[:sql] }
    yield
    statements
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  def clean
    conn = ActiveRecord::Base.connection
    conn.execute("DELETE FROM articles")
    conn.execute("DELETE FROM users")
    conn.execute("DELETE FROM event_store_events_in_streams")
    conn.execute("DELETE FROM event_store_events")
  end
end
