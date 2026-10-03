# frozen_string_literal: true

require "test_helper"

# ES-Lazy (projection_mode :lazy): writes store events only; before a read,
# the tables are brought up to date from the log, and the read runs as real
# SQL. These tests check each rule LazyProjection rests on.
class LazyProjectionTest < Minitest::Test
  LazyProjection = Lyra::Projections::LazyProjection

  def setup
    skip "Requires Rails and database" unless defined?(ActiveRecord::Base) && ActiveRecord::Base.connection.table_exists?(:articles)

    Object.send(:remove_const, :LazyArticle) if defined?(LazyArticle)
    Object.send(:remove_const, :LazyAuthor) if defined?(LazyAuthor)
    Object.const_set(:LazyAuthor, Class.new(ActiveRecord::Base) do
      self.table_name = "users"
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
      has_many :lazy_articles, foreign_key: :author_id, class_name: "LazyArticle"
      scope :named, ->(name) { where(name: name) }
    end)
    Object.const_set(:LazyArticle, Class.new(ActiveRecord::Base) do
      self.table_name = "articles"
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
      belongs_to :author, class_name: "LazyAuthor", optional: true
    end)

    @event_store = Lyra.config.event_store
    clean
    Lyra.config.enable_event_sourcing!
    Lyra.config.projection_mode = :lazy
    Lyra.config.monitor_model(LazyAuthor)
    Lyra.config.monitor_model(LazyArticle)
  end

  def teardown
    return unless defined?(LazyArticle)

    Lyra.config.projection_mode = :sync
    clean
  end

  def test_writes_leave_the_table_alone_until_a_read
    author = LazyAuthor.create!(name: "Ann", email: "ann@example.com")

    assert_nil raw("SELECT id FROM users WHERE id = #{author.id}"), "a write stores events only"
    assert_equal "Ann", LazyAuthor.find(author.id).name
    refute_nil raw("SELECT id FROM users WHERE id = #{author.id}")
  end

  def test_a_read_sees_the_latest_state_of_every_record
    kept = LazyAuthor.create!(name: "Kept", email: "k@example.com")
    kept.update!(name: "Kept, renamed")
    gone = LazyAuthor.create!(name: "Gone", email: "g@example.com")
    gone.destroy!

    assert_equal ["Kept, renamed"], LazyAuthor.order(:id).pluck(:name)
  end

  def test_queries_es_noproj_refuses_work_with_real_sql
    ann = LazyAuthor.create!(name: "Ann", email: "ann@example.com")
    bob = LazyAuthor.create!(name: "Bob", email: "bob@example.com")
    LazyArticle.create!(title: "One", body: "x", author_id: ann.id, status: "published")
    LazyArticle.create!(title: "Two", body: "x", author_id: ann.id, status: "draft")
    LazyArticle.create!(title: "Three", body: "x", author_id: bob.id, status: "published")

    assert_equal %w[Ann], LazyAuthor.where("name LIKE ?", "A%").pluck(:name)
    assert_equal %w[One Three], LazyArticle.joins(:author).where(users: { name: %w[Ann Bob] }, status: "published").order(:title).pluck(:title).sort
    assert_equal %w[One Two], LazyArticle.joins(:author).merge(LazyAuthor.named("Ann")).order(:title).pluck(:title)
    assert_equal 2, LazyArticle.where(author_id: ann.id).count
    assert LazyArticle.where.not(status: "draft").exists?
    assert_equal({ ann.id => 2, bob.id => 1 }, LazyArticle.group(:author_id).count)
  end

  def test_associations_load_through_the_same_catch_up
    ann = LazyAuthor.create!(name: "Ann", email: "ann@example.com")
    LazyArticle.create!(title: "One", body: "x", author_id: ann.id)

    assert_equal %w[One], LazyAuthor.find(ann.id).lazy_articles.map(&:title)
  end

  def test_once_caught_up_a_read_applies_nothing
    LazyAuthor.create!(name: "Ann", email: "ann@example.com")
    LazyAuthor.count

    assert_equal 0, LazyProjection.catch_up!
    position, gaps = LazyProjection.checkpoint
    assert_equal raw("SELECT MAX(id) FROM event_store_events").to_i, position
    assert_empty gaps.keys & event_ids, "no gap may refer to an event that exists"
  end

  def test_a_rolled_back_write_leaves_nothing_behind
    ActiveRecord::Base.transaction do
      LazyAuthor.create!(name: "Ghost", email: "ghost@example.com")
      raise ActiveRecord::Rollback
    end

    assert_equal 0, LazyAuthor.count
  end

  # Event ids are assigned before commit. A write still in flight in another
  # connection leaves a gap below a later, committed event; the gap must be
  # filled when that write commits, not skipped for good.
  def test_an_event_committed_late_is_not_skipped
    started = Queue.new
    proceed = Queue.new
    late = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        ActiveRecord::Base.transaction do
          LazyAuthor.create!(name: "Late", email: "late@example.com")
          started << true
          proceed.pop
        end
      end
    end
    started.pop

    LazyAuthor.create!(name: "Early", email: "early@example.com")
    assert_equal %w[Early], LazyAuthor.order(:name).pluck(:name), "the in-flight write is not visible yet"
    refute_empty LazyProjection.checkpoint.last, "its event id is watched as a gap"

    proceed << true
    late.join
    sleep LazyProjection::GAP_RECHECK + 0.1 # gaps are re-checked at most this often

    assert_equal %w[Early Late], LazyAuthor.order(:name).pluck(:name)
    assert_empty LazyProjection.checkpoint.last.keys & event_ids, "the late event is applied, not left as a gap"
  end

  def test_lazy_mode_needs_event_sourcing_mode
    Lyra.config.enable_monitor!
    author = LazyAuthor.create!(name: "Ann", email: "ann@example.com")

    refute LazyProjection.active?
    refute_nil raw("SELECT id FROM users WHERE id = #{author.id}"), "outside ES mode the row is written as usual"
  end

  private

  def raw(sql) = ActiveRecord::Base.connection.select_value(sql)

  def event_ids = ActiveRecord::Base.connection.select_values("SELECT id FROM event_store_events").map(&:to_i)

  def clean
    conn = ActiveRecord::Base.connection
    conn.execute("DELETE FROM articles")
    conn.execute("DELETE FROM users")
    conn.execute("DELETE FROM event_store_events_in_streams")
    conn.execute("DELETE FROM event_store_events")
    LazyProjection.reset!
  end
end
