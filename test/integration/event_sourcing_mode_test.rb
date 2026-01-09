# frozen_string_literal: true

require "test_helper"

# Integration tests for event_sourcing mode SQL interception.
# These tests verify the SQL interception and projection mechanisms work correctly.
# NOTE: Requires Rails dummy app with database. Run with: rake test:controllers
class EventSourcingSqlInterceptionTest < Minitest::Test
  def setup
    skip "Requires Rails and database" unless infrastructure_available?

    # Clean up any existing data
    Article.delete_all if defined?(Article) && Article.table_exists?
    clean_event_store

    # Configure Lyra for event_sourcing mode with sync projections
    @original_mode = Lyra.config.mode
    @original_projection_mode = Lyra.config.projection_mode
    @original_event_store = Lyra.config.event_store

    # Ensure event store is available
    Lyra.config.event_store ||= create_event_store
    Lyra.config.mode = :event_sourcing
    Lyra.config.projection_mode = :sync

    # Define Article model with Lyra monitoring
    define_article_model unless defined?(Article) && Article.respond_to?(:lyra_monitored) && Article.lyra_monitored
  end

  def teardown
    return unless defined?(Lyra) && Lyra.config

    # Restore original configuration
    Lyra.config.mode = @original_mode if @original_mode
    Lyra.config.projection_mode = @original_projection_mode if @original_projection_mode
    Lyra.config.event_store = @original_event_store if @original_event_store

    # Clean up
    Article.delete_all if defined?(Article) && Article.respond_to?(:table_exists?) && Article.table_exists?
    clean_event_store
    Thread.current[:lyra_skip_insert] = nil
  rescue StandardError
    # Ignore cleanup errors
  end

  # ==========================================================================
  # CREATE Tests - Verify _insert_record skip via Thread.current flag
  # ==========================================================================

  def test_create_produces_single_insert
    skip "Requires Rails, database, and articles table with sequence" unless infrastructure_available?

    insert_count = count_sql_statements("INSERT INTO \"articles\"") do
      Article.create!(title: "Test Article", body: "Content")
    end

    assert_equal 1, insert_count, "Expected exactly 1 INSERT (from projection), got #{insert_count}"
  end

  def test_create_persists_record_via_projection
    skip "Requires Rails, database, and articles table with sequence" unless infrastructure_available?

    article = Article.create!(title: "Test Article", body: "Content", status: "draft")

    # Verify record exists in database
    assert article.persisted?
    assert article.id.present?

    # Reload to confirm it's actually in the database
    reloaded = Article.find(article.id)
    assert_equal "Test Article", reloaded.title
    assert_equal "Content", reloaded.body
    assert_equal "draft", reloaded.status
  end

  def test_create_stores_event
    skip "Requires Rails, database, and articles table with sequence" unless infrastructure_available?

    article = Article.create!(title: "Test Article", body: "Content")

    # Verify event was stored
    events = Lyra.config.event_store.read.stream("Article$#{article.id}").to_a
    assert_equal 1, events.size
    assert_equal "Lyra::Events::ArticleCreated", events.first.event_type
  end

  def test_create_clears_thread_flag_after_completion
    skip "Requires Rails, database, and articles table with sequence" unless infrastructure_available?

    Article.create!(title: "Test", body: "Content")

    assert_nil Thread.current[:lyra_skip_insert],
               "Thread flag should be cleared after create"
  end

  # ==========================================================================
  # UPDATE Tests - Verify _update_row skip and projection
  # ==========================================================================

  def test_update_produces_single_update
    skip "Requires Rails, database, and articles table with sequence" unless infrastructure_available?

    article = Article.create!(title: "Original", body: "Content")

    update_count = count_sql_statements("UPDATE \"articles\"") do
      article.update!(title: "Updated")
    end

    assert_equal 1, update_count, "Expected exactly 1 UPDATE (from projection), got #{update_count}"
  end

  def test_update_persists_changes_via_projection
    skip "Requires Rails, database, and articles table with sequence" unless infrastructure_available?

    article = Article.create!(title: "Original", body: "Content", status: "draft")
    article.update!(title: "Updated Title", status: "published")

    # Reload to confirm changes are in database
    article.reload
    assert_equal "Updated Title", article.title
    assert_equal "published", article.status
  end

  def test_update_handles_string_keys_in_changes
    skip "Requires Rails, database, and articles table with sequence" unless infrastructure_available?

    # This tests the fix for duplicate column error when changes have string keys
    # and projection adds symbol key for updated_at
    article = Article.create!(title: "Original", body: "Content")

    # Update multiple fields to ensure changes hash has multiple string keys
    article.update!(
      title: "New Title",
      body: "New Body",
      status: "published"
    )

    article.reload
    assert_equal "New Title", article.title
    assert_equal "New Body", article.body
    assert_equal "published", article.status
  end

  def test_update_stores_event_with_changes
    skip "Requires Rails, database, and articles table with sequence" unless infrastructure_available?

    article = Article.create!(title: "Original", body: "Content")
    article.update!(title: "Updated")

    events = Lyra.config.event_store.read.stream("Article$#{article.id}").to_a
    assert_equal 2, events.size

    update_event = events.last
    assert_equal "Lyra::Events::ArticleUpdated", update_event.event_type
    assert update_event.data[:changes].key?(:title) || update_event.data[:changes].key?("title")
  end

  # ==========================================================================
  # DELETE Tests - Verify _delete_row skip and projection
  # ==========================================================================

  def test_destroy_produces_single_delete
    skip "Requires Rails, database, and articles table with sequence" unless infrastructure_available?

    article = Article.create!(title: "Test", body: "Content")
    article_id = article.id

    delete_count = count_sql_statements("DELETE FROM \"articles\"") do
      article.destroy!
    end

    assert_equal 1, delete_count, "Expected exactly 1 DELETE (from projection), got #{delete_count}"
  end

  def test_destroy_removes_record_via_projection
    skip "Requires Rails, database, and articles table with sequence" unless infrastructure_available?

    article = Article.create!(title: "Test", body: "Content")
    article_id = article.id

    article.destroy!

    assert_nil Article.find_by(id: article_id)
  end

  def test_destroy_stores_event
    skip "Requires Rails, database, and articles table with sequence" unless infrastructure_available?

    article = Article.create!(title: "Test", body: "Content")
    article_id = article.id

    article.destroy!

    events = Lyra.config.event_store.read.stream("Article$#{article_id}").to_a
    assert_equal 2, events.size
    assert_equal "Lyra::Events::ArticleDestroyed", events.last.event_type
  end

  # ==========================================================================
  # State Transition Tests - Common pattern in applications
  # ==========================================================================

  def test_state_transition_persists_correctly
    skip "Requires Rails, database, and articles table with sequence" unless infrastructure_available?

    article = Article.create!(title: "Draft Article", status: "draft")
    assert_equal "draft", article.status

    # Simulate a publish action
    article.update!(status: "published", published_at: Time.current)

    article.reload
    assert_equal "published", article.status
    refute_nil article.published_at
  end

  private

  def infrastructure_available?
    return false unless defined?(ActiveRecord::Base)
    return false unless database_available?
    return false unless articles_table_exists?
    return false unless sequence_available?
    true
  rescue StandardError
    false
  end

  def database_available?
    ActiveRecord::Base.connection.active?
  rescue StandardError
    false
  end

  def articles_table_exists?
    ActiveRecord::Base.connection.table_exists?(:articles)
  rescue StandardError
    false
  end

  def sequence_available?
    # Check if PostgreSQL sequence exists for articles table
    result = ActiveRecord::Base.connection.execute(
      "SELECT pg_get_serial_sequence('articles', 'id')"
    )
    result.first&.values&.first.present?
  rescue StandardError
    false
  end

  def clean_event_store
    return unless defined?(RubyEventStore)

    # Clean event store tables directly
    ActiveRecord::Base.connection.execute("DELETE FROM event_store_events_in_streams") rescue nil
    ActiveRecord::Base.connection.execute("DELETE FROM event_store_events") rescue nil
  end

  def create_event_store
    RailsEventStore::Client.new(
      repository: RailsEventStoreActiveRecord::EventRepository.new(
        serializer: RubyEventStore::Serializers::YAML
      )
    )
  end

  def define_article_model
    # Remove existing constant if defined
    Object.send(:remove_const, :Article) if defined?(Article)

    # Define Article model with Lyra monitoring
    Object.const_set(:Article, Class.new(ActiveRecord::Base) do
      self.table_name = "articles"
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
    end)

    # Register with Lyra config for proper event naming
    Lyra.config.monitor_model(Article, event_prefix: "Article")
  end

  def count_sql_statements(pattern)
    count = 0
    callback = ->(*, payload) {
      count += 1 if payload[:sql].include?(pattern)
    }

    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      yield
    end

    count
  end
end
