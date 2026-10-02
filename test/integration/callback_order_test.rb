# frozen_string_literal: true

require "test_helper"

# Hijack and event-sourcing modes build the event from the record just before
# its row is written. They used to do it in a before_create / before_update
# callback registered on ActiveRecord::Base, i.e. before the model's own
# before_* callbacks, so values those callbacks set never reached the event.
# Solidus generates Order#guest_token and Payment#number that way; under
# ES-Sync, where the row is projected from the event, both were lost from the
# table, and DualView could not tell (table and event agreed).
class CallbackOrderTest < Minitest::Test
  def setup
    skip "Requires Rails and database" unless defined?(ActiveRecord::Base) && ActiveRecord::Base.connection.table_exists?(:articles)

    @event_store = Lyra.config.event_store || RailsEventStore::Client.new(
      repository: RubyEventStore::ActiveRecord::EventRepository.new(serializer: RubyEventStore::Serializers::YAML)
    )
    Object.send(:remove_const, :CallbackArticle) if defined?(CallbackArticle)
    Object.const_set(:CallbackArticle, Class.new(ActiveRecord::Base) do
      self.table_name = "articles"
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
      # The application's own callbacks, defined after Lyra's were registered.
      before_create { self.author_id = 42 }
      before_update { self.body = "#{body} (edited)" if title_changed? }
    end)
    clean
  end

  def teardown
    clean if defined?(CallbackArticle)
    Lyra.reset_config!
    Lyra.config.event_store = @event_store if @event_store
  end

  def test_hijack_events_carry_values_set_by_before_create
    with_mode(:hijack) do
      article = CallbackArticle.create!(title: "T", body: "B")

      assert_equal 42, CallbackArticle.find(article.id).author_id
      assert_equal 42, created_attributes(article)["author_id"]
      assert_consistent(article)
    end
  end

  def test_hijack_events_carry_changes_made_by_before_update
    with_mode(:hijack) do
      article = CallbackArticle.create!(title: "T", body: "B")
      article.update!(title: "T2")

      assert_equal ["B", "B (edited)"], last_changes(article)["body"]
      assert_consistent(article)
    end
  end

  def test_event_sourcing_keeps_values_set_by_before_create_in_the_table
    with_mode(:event_sourcing) do
      article = CallbackArticle.create!(title: "T", body: "B")

      assert_equal 42, CallbackArticle.find(article.id).author_id, "projected row lost a value set by before_create"
      assert_consistent(article)
    end
  end

  def test_event_sourcing_keeps_changes_made_by_before_update_in_the_table
    with_mode(:event_sourcing) do
      article = CallbackArticle.create!(title: "T", body: "B")
      article.update!(title: "T2")

      assert_equal "B (edited)", CallbackArticle.find(article.id).body
      assert_consistent(article)
    end
  end

  def test_a_failed_hijack_command_stops_the_save
    with_mode(:hijack) do
      Lyra::CommandHandler.stubs(:handle).returns(Lyra::CommandResult.failure(error: "rejected"))
      article = CallbackArticle.new(title: "T", body: "B")

      refute article.save
      assert_includes article.errors[:base], "rejected"
      assert_equal 0, CallbackArticle.count
    end
  ensure
    Lyra::CommandHandler.unstub(:handle)
  end

  private

  def with_mode(mode)
    Lyra.reset_config!
    Lyra.config.event_store = @event_store
    case mode
    when :hijack then Lyra.config.enable_hijack!
    when :event_sourcing
      Lyra.config.enable_event_sourcing!
      Lyra.config.projection_mode = :sync
    end
    Lyra.config.monitor_model(CallbackArticle)
    yield
  end

  def events(article) = @event_store.read.stream("CallbackArticle$#{article.id}").to_a

  def created_attributes(article)
    data = events(article).first.data
    (data[:attributes] || data["attributes"]).transform_keys(&:to_s)
  end

  def last_changes(article)
    data = events(article).last.data
    (data[:changes] || data["changes"]).transform_keys(&:to_s)
  end

  def assert_consistent(article)
    assert_equal({ no_differences: true }, Lyra::DualView.new(CallbackArticle, article.id).calculate_differences)
  end

  def clean
    Thread.current[:lyra_bypass_read_override] = true
    CallbackArticle.unscoped.delete_all
    ActiveRecord::Base.connection.execute("DELETE FROM event_store_events_in_streams")
    ActiveRecord::Base.connection.execute("DELETE FROM event_store_events")
  ensure
    Thread.current[:lyra_bypass_read_override] = nil
  end
end
