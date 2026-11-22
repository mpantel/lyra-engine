# frozen_string_literal: true

require "test_helper"

# update_all(foreign_key: nil) on an Active Record relation of a monitored
# model, under ES-NoProj (Lyra::StrictDataAccessRelation counts it as a
# dependent nullify and publishes an event for each record it rewrites). The
# table is empty there, so the records come from the event store: those the
# relation's where clause selects, all of it. Its foreign key's equality alone
# used to be read, every other condition skipped: the author's drafts were
# nullified in the log by a write that selected the published articles only.
# A condition it cannot read refuses the write, and no event stays.
#
# Each scenario runs in Monitor (Active Record and PostgreSQL) and in
# ES-NoProj on the same rows; the records' state must be equal, or ES-NoProj
# must refuse and leave the log as it was.
class EsNoprojNullifyRelationTest < Minitest::Test
  UnsupportedQuery = Lyra::Projections::UnsupportedQuery

  def setup
    skip "Requires Rails and database" unless defined?(ActiveRecord::Base) && connection.table_exists?(:articles)

    %i[NrArticle NrAuthor].each { |c| Object.send(:remove_const, c) if Object.const_defined?(c) }
    Object.const_set(:NrArticle, Class.new(ActiveRecord::Base) do
      self.table_name = "articles"
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
    end)
    Object.const_set(:NrAuthor, Class.new(ActiveRecord::Base) do
      self.table_name = "users"
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
      has_many :nr_articles, foreign_key: :author_id, class_name: "NrArticle"
    end)
    clean
    Rails.cache.clear
    [NrArticle, NrAuthor].each { Lyra.config.monitor_model(_1) }
  end

  def teardown
    return unless defined?(NrArticle)

    Lyra.config.enable_monitor!
    Lyra.config.projection_mode = :sync
    clean
    Rails.cache.clear
  end

  def test_a_relation_s_nullify_rewrites_only_what_its_conditions_select
    states = %i[monitor es_noproj].map do |mode|
      scenario(mode) do |author|
        relation = Lyra::ModeTransition.send(:bypass) { NrArticle.unscoped.where(author_id: author.id, status: "published") }
        relation.update_all(author_id: nil)
      end
    end

    assert_equal [%w[D linked], %w[P unlinked]], states.first
    assert_equal states.first, states.last
  end

  def test_a_relation_s_nullify_with_a_condition_it_cannot_read_is_refused
    monitor = scenario(:monitor) do |author|
      Lyra::ModeTransition.send(:bypass) { NrArticle.unscoped.where(author_id: author.id).where("title = 'P'") }
                          .update_all(author_id: nil)
    end
    assert_equal [%w[D linked], %w[P unlinked]], monitor

    scenario(:es_noproj) do |author|
      relation = Lyra::ModeTransition.send(:bypass) { NrArticle.unscoped.where(author_id: author.id).where("title = 'P'") }
      events = event_count
      assert_raises(UnsupportedQuery) { relation.update_all(author_id: nil) }
      assert_equal events, event_count, "no event written"
    end
  end

  # author.nr_articles.update_all(author_id: nil): the association's
  # update_all goes to its event-backed scope under ES-NoProj and nullifies
  # what Monitor nullifies, with one event per record it rewrites. (It was
  # refused before through associations were read from the event store; the
  # events the nullify had published first were then taken back with it.)
  def test_an_association_s_nullify_matches_monitor
    monitor = scenario(:monitor) { |author| NrAuthor.find(author.id).nr_articles.update_all(author_id: nil) }
    assert_equal [%w[D unlinked], %w[P unlinked]], monitor
  
    written = nil
    state = scenario(:es_noproj) do |author|
      events = event_count
      assert_equal 2, NrAuthor.find(author.id).nr_articles.update_all(author_id: nil)
      written = event_count - events
    end
    assert_equal monitor, state
    assert_equal 2, written, "one event per record rewritten"
  end

  private

  # Ann's articles P (published) and D (draft), the block run, and each
  # article's title with whether it still has an author.
  def scenario(mode)
    clean
    use(mode)
    author = NrAuthor.create!(name: "Ann", email: "ann-nr@example.com")
    NrArticle.create!(title: "P", status: "published", author_id: author.id)
    NrArticle.create!(title: "D", status: "draft", author_id: author.id)
    yield author
    NrArticle.order(:title).pluck(:title, :author_id).map { |title, id| [title, id ? "linked" : "unlinked"] }
  end

  def use(mode)
    if mode == :es_noproj
      Lyra.config.enable_event_sourcing!
      Lyra.config.projection_mode = :disabled
    else
      Lyra.config.enable_monitor!
      Lyra.config.projection_mode = :sync
    end
  end

  def event_count = connection.select_value("SELECT COUNT(*) FROM event_store_events").to_i

  def clean
    connection.execute("DELETE FROM articles")
    connection.execute("DELETE FROM users")
    connection.execute("DELETE FROM event_store_events_in_streams")
    connection.execute("DELETE FROM event_store_events")
    [NrArticle, NrAuthor].each { Lyra::Projections::CachedProjection.invalidate_all(_1) } if defined?(NrArticle)
  end

  def connection = ActiveRecord::Base.connection
end
