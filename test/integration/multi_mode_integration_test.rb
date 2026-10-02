# frozen_string_literal: true

require "test_helper"

# Integration tests for Lyra's multi-mode CRUD behavior.
# These tests verify that CRUD operations work correctly in all modes.
# NOTE: Requires Rails dummy app with database. Run with: rake test
class MultiModeIntegrationTest < Minitest::Test
  MODES = [:disabled, :monitor, :hijack, :event_sourcing].freeze
  EVENT_CAPTURING_MODES = [:monitor, :hijack, :event_sourcing].freeze
  PROJECTION_MODES = [:sync, :async, :disabled].freeze

  def setup
    skip "Requires Rails and database" unless infrastructure_available?

    # Clean up any existing data
    Article.delete_all if defined?(Article) && Article.table_exists?
    clean_event_store

    # Store original configuration
    @original_mode = Lyra.config.mode
    @original_projection_mode = Lyra.config.projection_mode

    # Define Article model with Lyra monitoring
    define_article_model unless article_model_ready?
  end

  def teardown
    return unless defined?(Lyra) && Lyra.config

    # Restore original configuration
    Lyra.config.mode = @original_mode if @original_mode
    Lyra.config.projection_mode = @original_projection_mode if @original_projection_mode

    # Clean up
    Article.delete_all if defined?(Article) && Article.respond_to?(:table_exists?) && Article.table_exists?
    clean_event_store
    Thread.current[:lyra_skip_insert] = nil
  rescue StandardError
    # Ignore cleanup errors
  end

  # ===========================================================================
  # CREATE Tests - All Modes
  # ===========================================================================

  MODES.each do |mode|
    define_method("test_create_persists_record_in_#{mode}_mode") do
      skip "Requires Rails and database" unless infrastructure_available?

      with_mode(mode) do
        article = Article.create!(title: "Test Article", body: "Content", status: "draft")

        assert article.persisted?, "Record should be persisted in #{mode} mode"
        assert article.id.present?, "Record should have an ID in #{mode} mode"

        # Verify it's actually in the database
        reloaded = Article.find(article.id)
        assert_equal "Test Article", reloaded.title
        assert_equal "Content", reloaded.body
      end
    end
  end

  # ===========================================================================
  # UPDATE Tests - All Modes
  # ===========================================================================

  MODES.each do |mode|
    define_method("test_update_modifies_record_in_#{mode}_mode") do
      skip "Requires Rails and database" unless infrastructure_available?

      with_mode(mode) do
        article = Article.create!(title: "Original", body: "Content", status: "draft")
        original_id = article.id

        article.update!(title: "Updated Title", status: "published")

        # Verify changes persisted
        article.reload
        assert_equal original_id, article.id, "ID should not change on update"
        assert_equal "Updated Title", article.title
        assert_equal "published", article.status
      end
    end
  end

  # ===========================================================================
  # DESTROY Tests - All Modes
  # ===========================================================================

  MODES.each do |mode|
    define_method("test_destroy_removes_record_in_#{mode}_mode") do
      skip "Requires Rails and database" unless infrastructure_available?

      with_mode(mode) do
        article = Article.create!(title: "To Delete", body: "Content")
        article_id = article.id

        article.destroy!

        assert_nil Article.find_by(id: article_id),
          "Record should be removed from database in #{mode} mode"
      end
    end
  end

  # ===========================================================================
  # Event Capture Tests
  # ===========================================================================

  def test_disabled_mode_captures_no_events
    skip "Requires Rails and database" unless infrastructure_available?

    with_mode(:disabled) do
      article = Article.create!(title: "Test", body: "Content")
      article.update!(title: "Updated")
      article.destroy!

      events = events_for("Article", article.id)
      assert_empty events, "Disabled mode should not capture any events"
    end
  end

  # Regression: a *monitored* model kept emitting events after Lyra was disabled.
  # The monitor callbacks were gated on lyra_monitored? alone -- a class attribute
  # with no mode check -- so :disabled was not a true ORM baseline.
  #
  # test_disabled_mode_captures_no_events above cannot catch this: with_mode(:disabled)
  # redefines Article *without* the interceptor, so it asserts the desired behavior by
  # construction. Here the model stays monitored and only the mode changes -- which is
  # exactly the situation a team migrating with Lyra is in, and the one the benchmark's
  # "plain ORM" baseline assumed.
  def test_disabled_mode_writes_no_events_for_a_monitored_model
    skip "Requires Rails and database" unless infrastructure_available?

    event_store = Lyra.config.event_store || create_event_store
    Lyra.reset_config!
    Lyra.config.event_store = event_store

    define_article_model # includes the interceptor and calls monitor_with_lyra
    Lyra.config.monitor_model(Article, event_prefix: "Article")
    Lyra.config.disable!

    assert Article.lyra_monitored, "model must stay monitored for this to test anything"
    assert Lyra.disabled_mode?

    before = event_store_row_count

    article = Article.create!(title: "Test", body: "Content")
    article.update!(title: "Updated")
    article.destroy!

    assert_equal before, event_store_row_count,
                 "Disabled mode must be a true ORM baseline: a monitored model wrote " \
                 "events to the store while Lyra was disabled"
  end

  # Monitor and event_sourcing modes capture events with the correct ID
  [:monitor, :event_sourcing].each do |mode|
    define_method("test_#{mode}_mode_captures_create_event") do
      skip "Requires Rails and database" unless infrastructure_available?

      with_mode(mode) do
        article = Article.create!(title: "Test", body: "Content")

        events = events_for("Article", article.id)
        assert_equal 1, events.size, "#{mode} mode should capture create event"

        event = events.first
        assert_match(/Created$/, event.event_type)
      end
    end

    define_method("test_#{mode}_mode_captures_update_event") do
      skip "Requires Rails and database" unless infrastructure_available?

      with_mode(mode) do
        article = Article.create!(title: "Original", body: "Content")
        article.update!(title: "Updated")

        events = events_for("Article", article.id)
        assert_equal 2, events.size, "#{mode} mode should capture create + update events"

        update_event = events.last
        assert_match(/Updated$/, update_event.event_type)
      end
    end

    define_method("test_#{mode}_mode_captures_destroy_event") do
      skip "Requires Rails and database" unless infrastructure_available?

      with_mode(mode) do
        article = Article.create!(title: "Test", body: "Content")
        article_id = article.id
        article.destroy!

        events = events_for("Article", article_id)
        assert_equal 2, events.size, "#{mode} mode should capture create + destroy events"

        destroy_event = events.last
        assert_match(/Destroyed$/, destroy_event.event_type)
      end
    end
  end

  # Hijack mode must file every event, including Created, under the record's
  # own stream, so the record's history can be rebuilt from it.
  def test_hijack_mode_files_created_event_under_the_record_stream
    skip "Requires Rails and database" unless infrastructure_available?

    with_mode(:hijack) do
      article = Article.create!(title: "Test", body: "Content")
      article.update!(title: "Updated")

      types = events_for("Article", article.id).map { |e| e.data[:operation] || e.data["operation"] }.map(&:to_s)
      assert_equal %w[created updated], types
      pending = Lyra.config.event_store.read.to_a.select { |e| (e.data[:model_id] || e.data["model_id"]).to_s.start_with?("pending-") }
      assert_empty pending, "no event should carry a pending- placeholder ID"
    end
  end

  def test_hijack_mode_captures_events
    skip "Requires Rails and database" unless infrastructure_available?

    with_mode(:hijack) do
      # Get event count before
      all_events_before = all_article_events.size

      article = Article.create!(title: "Test", body: "Content")
      article.update!(title: "Updated")
      article.destroy!

      # Get event count after
      all_events_after = all_article_events.size

      # Hijack mode should capture 3 events (create, update, destroy)
      # They may be under a pending-xxx stream for the create
      assert_operator all_events_after, :>, all_events_before,
        "Hijack mode should capture events (may use pending ID streams)"
    end
  end

  # ===========================================================================
  # Event Data Correctness Tests
  # ===========================================================================

  # Test event data for every event-producing mode. Hijack belongs here too:
  # it used to file the Created event under a "pending-" stream for integer keys,
  # which is why it was once left out of this list.
  [:monitor, :hijack, :event_sourcing].each do |mode|
    define_method("test_#{mode}_mode_event_contains_correct_data") do
      skip "Requires Rails and database" unless infrastructure_available?

      with_mode(mode) do
        article = Article.create!(title: "Test Title", body: "Test Body", status: "draft")

        events = events_for("Article", article.id)
        assert_equal 1, events.size

        event = events.first
        assert_equal article.id, event.data[:model_id] || event.data["model_id"]
        assert_equal "Article", event.data[:model_class] || event.data["model_class"]

        # Verify attributes captured
        attrs = event.data[:attributes] || event.data["attributes"] || {}
        assert_equal "Test Title", attrs[:title] || attrs["title"]
      end
    end

    define_method("test_#{mode}_mode_update_event_contains_changes") do
      skip "Requires Rails and database" unless infrastructure_available?

      with_mode(mode) do
        article = Article.create!(title: "Original", body: "Content")
        article.update!(title: "Updated")

        events = events_for("Article", article.id)
        update_event = events.last

        changes = update_event.data[:changes] || update_event.data["changes"] || {}
        title_change = changes[:title] || changes["title"]

        assert title_change.present?, "Update event should contain title change"
      end
    end
  end

  # Hijack mode test - events are captured but may have different stream IDs
  def test_hijack_mode_update_event_contains_changes
    skip "Requires Rails and database" unless infrastructure_available?

    with_mode(:hijack) do
      article = Article.create!(title: "Original", body: "Content")
      article.update!(title: "Updated")

      # For update events in hijack mode, they use the real ID
      events = events_for("Article", article.id)

      # Should have at least the update event
      assert events.any? { |e| e.event_type.include?("Updated") },
        "Hijack mode should capture update events"
    end
  end

  # ===========================================================================
  # Full Lifecycle Test
  # ===========================================================================

  # Test lifecycle for modes with predictable event IDs
  [:disabled, :monitor, :event_sourcing].each do |mode|
    define_method("test_full_crud_lifecycle_in_#{mode}_mode") do
      skip "Requires Rails and database" unless infrastructure_available?

      with_mode(mode) do
        # Create
        article = Article.create!(title: "New Article", body: "Initial content", status: "draft")
        assert article.persisted?
        article_id = article.id

        # Read
        found = Article.find(article_id)
        assert_equal "New Article", found.title

        # Update
        found.update!(title: "Edited Article", status: "published")
        found.reload
        assert_equal "Edited Article", found.title
        assert_equal "published", found.status

        # Delete
        found.destroy!
        assert_nil Article.find_by(id: article_id)

        # Verify event count
        events = events_for("Article", article_id)
        if mode == :disabled
          assert_empty events
        else
          assert_equal 3, events.size, "Should have create + update + destroy events"
        end
      end
    end
  end

  # Hijack mode lifecycle test - CRUD works, events captured (may use pending IDs)
  def test_full_crud_lifecycle_in_hijack_mode
    skip "Requires Rails and database" unless infrastructure_available?

    with_mode(:hijack) do
      events_before = all_article_events.size

      # Create
      article = Article.create!(title: "New Article", body: "Initial content", status: "draft")
      assert article.persisted?
      article_id = article.id

      # Read
      found = Article.find(article_id)
      assert_equal "New Article", found.title

      # Update
      found.update!(title: "Edited Article", status: "published")
      found.reload
      assert_equal "Edited Article", found.title
      assert_equal "published", found.status

      # Delete
      found.destroy!
      assert_nil Article.find_by(id: article_id)

      # Verify events were captured (at least update/destroy use real IDs)
      events_after = all_article_events.size
      assert_operator events_after, :>, events_before,
        "Hijack mode should capture events during lifecycle"
    end
  end

  # ===========================================================================
  # Projection Mode Tests (Event Sourcing only)
  # ===========================================================================

  PROJECTION_MODES.each do |proj_mode|
    define_method("test_event_sourcing_with_#{proj_mode}_projection_creates_record") do
      skip "Requires Rails and database" unless infrastructure_available?
      skip "Async projection requires ActiveJob" if proj_mode == :async && !defined?(ActiveJob)

      with_event_sourcing_projection(proj_mode) do
        article = Article.create!(title: "Test", body: "Content", status: "draft")

        assert article.persisted?, "Record should be persisted with #{proj_mode} projection"
        assert article.id.present?, "Record should have an ID"

        # For sync and async (inline), record should be in DB
        # For disabled projection, record may only be in event store
        if proj_mode != :disabled
          reloaded = Article.find_by(id: article.id)
          assert_equal "Test", reloaded&.title
        end
      end
    end

    define_method("test_event_sourcing_with_#{proj_mode}_projection_captures_events") do
      skip "Requires Rails and database" unless infrastructure_available?
      skip "Async projection requires ActiveJob" if proj_mode == :async && !defined?(ActiveJob)

      with_event_sourcing_projection(proj_mode) do
        article = Article.create!(title: "Test", body: "Content")

        events = events_for("Article", article.id)
        assert_equal 1, events.size, "Should capture create event with #{proj_mode} projection"
        assert_match(/Created$/, events.first.event_type)
      end
    end

    define_method("test_event_sourcing_with_#{proj_mode}_projection_updates_record") do
      skip "Requires Rails and database" unless infrastructure_available?
      skip "Async projection requires ActiveJob" if proj_mode == :async && !defined?(ActiveJob)

      with_event_sourcing_projection(proj_mode) do
        article = Article.create!(title: "Original", body: "Content")
        article.update!(title: "Updated")

        events = events_for("Article", article.id)
        assert_equal 2, events.size, "Should capture create + update events"

        # For sync projection, verify DB state
        if proj_mode == :sync
          article.reload
          assert_equal "Updated", article.title
        end
      end
    end

    define_method("test_event_sourcing_with_#{proj_mode}_projection_destroys_record") do
      skip "Requires Rails and database" unless infrastructure_available?
      skip "Async projection requires ActiveJob" if proj_mode == :async && !defined?(ActiveJob)

      with_event_sourcing_projection(proj_mode) do
        article = Article.create!(title: "Test", body: "Content")
        article_id = article.id
        article.destroy!

        events = events_for("Article", article_id)
        assert_equal 2, events.size, "Should capture create + destroy events"

        # For sync projection, verify record removed from DB
        if proj_mode == :sync
          assert_nil Article.find_by(id: article_id)
        end
      end
    end
  end

  def test_event_sourcing_projection_modes_all_capture_same_events
    skip "Requires Rails and database" unless infrastructure_available?

    event_counts = {}

    # Test sync and disabled (skip async as it may require job processing)
    [:sync, :disabled].each do |proj_mode|
      with_event_sourcing_projection(proj_mode) do
        article = Article.create!(title: "Test", body: "Content")
        article.update!(title: "Updated")
        article_id = article.id
        article.destroy!

        event_counts[proj_mode] = events_for("Article", article_id).size
        Article.delete_all rescue nil
      end
    end

    # All projection modes should capture the same events
    assert_equal event_counts[:sync], event_counts[:disabled],
      "All projection modes should capture the same number of events"
  end

  # ===========================================================================
  # Mode Comparison Tests
  # ===========================================================================

  def test_all_modes_produce_same_database_state_after_create
    skip "Requires Rails and database" unless infrastructure_available?

    results = {}

    MODES.each do |mode|
      with_mode(mode) do
        article = Article.create!(title: "Same Title", body: "Same Body", status: "published")
        results[mode] = {
          title: article.reload.title,
          body: article.body,
          status: article.status
        }
        Article.delete_all
      end
    end

    # All modes should produce the same database state
    reference = results[:monitor]
    MODES.each do |mode|
      assert_equal reference, results[mode],
        "#{mode} mode should produce same DB state as monitor mode"
    end
  end

  def test_all_modes_produce_same_database_state_after_update
    skip "Requires Rails and database" unless infrastructure_available?

    results = {}

    MODES.each do |mode|
      with_mode(mode) do
        article = Article.create!(title: "Original", body: "Content", status: "draft")
        article.update!(title: "Updated", status: "published")
        results[mode] = {
          title: article.reload.title,
          body: article.body,
          status: article.status
        }
        Article.delete_all
      end
    end

    reference = results[:monitor]
    MODES.each do |mode|
      assert_equal reference, results[mode],
        "#{mode} mode should produce same DB state as monitor mode after update"
    end
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
    result = ActiveRecord::Base.connection.execute(
      "SELECT pg_get_serial_sequence('articles', 'id')"
    )
    result.first&.values&.first.present?
  rescue StandardError
    false
  end

  def article_model_ready?
    defined?(Article) &&
      Article.respond_to?(:lyra_monitored) &&
      Article.lyra_monitored
  rescue StandardError
    false
  end

  def clean_event_store
    return unless defined?(RubyEventStore)

    ActiveRecord::Base.connection.execute("DELETE FROM event_store_events_in_streams") rescue nil
    ActiveRecord::Base.connection.execute("DELETE FROM event_store_events") rescue nil
  end

  def create_event_store
    RailsEventStore::Client.new(
      repository: RubyEventStore::ActiveRecord::EventRepository.new(
        serializer: RubyEventStore::Serializers::YAML
      )
    )
  end

  def define_article_model
    Object.send(:remove_const, :Article) if defined?(Article)

    Object.const_set(:Article, Class.new(ActiveRecord::Base) do
      self.table_name = "articles"
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
    end)
  end

  def define_article_model_without_lyra
    Object.send(:remove_const, :Article) if defined?(Article)

    Object.const_set(:Article, Class.new(ActiveRecord::Base) do
      self.table_name = "articles"
    end)
  end

  def with_mode(mode)
    # Save or create event store before reset
    event_store = Lyra.config.event_store || create_event_store

    Lyra.reset_config!
    Lyra.config.event_store = event_store

    case mode
    when :disabled
      Lyra.config.disable!
      # For disabled mode, define model WITHOUT Lyra monitoring
      define_article_model_without_lyra
    when :monitor
      Lyra.config.enable_monitor!
      define_article_model
      Lyra.config.monitor_model(Article, event_prefix: "Article")
    when :hijack
      Lyra.config.enable_hijack!
      define_article_model
      Lyra.config.monitor_model(Article, event_prefix: "Article")
    when :event_sourcing
      Lyra.config.enable_event_sourcing!
      Lyra.config.projection_mode = :sync
      define_article_model
      Lyra.config.monitor_model(Article, event_prefix: "Article")
    end

    yield
  ensure
    Lyra.reset_config!
    Lyra.config.event_store = event_store
  end

  def with_event_sourcing_projection(projection_mode)
    # Save or create event store before reset
    event_store = Lyra.config.event_store || create_event_store

    Lyra.reset_config!
    Lyra.config.event_store = event_store
    Lyra.config.enable_event_sourcing!
    Lyra.config.projection_mode = projection_mode

    # For async mode in tests, run projections inline
    if projection_mode == :async
      Lyra.config.async_projections_inline = true
    end

    # Re-apply model monitoring after mode change
    define_article_model

    # Register the model for monitoring
    Lyra.config.monitor_model(Article, event_prefix: "Article")

    yield
  ensure
    Lyra.reset_config!
    Lyra.config.event_store = event_store
  end

  # Raw row count in the event store. Deliberately does not rescue: a failure to
  # read must fail the test, not silently look like "no events".
  def event_store_row_count
    ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM event_store_events").to_i
  end

  def events_for(model_class, id)
    stream_name = "#{model_class}$#{id}"
    Lyra.config.event_store.read.stream(stream_name).to_a
  rescue StandardError
    []
  end

  def all_article_events
    # Read all events and filter for Article-related ones
    Lyra.config.event_store.read.to_a.select do |event|
      event_type = event.event_type.to_s
      event_type.include?("Article") || event_type.include?("Created") ||
        event_type.include?("Updated") || event_type.include?("Destroyed")
    end
  rescue StandardError
    []
  end
end
