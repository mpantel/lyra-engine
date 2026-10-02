# frozen_string_literal: true

require "test_helper"

# Writes that skip ActiveRecord's save callbacks (update_columns, update_column,
# touch) never reach Lyra's interceptors, so Lyra publishes a "bypass" update
# event for them itself. These tests pin that down, because the Olist replay
# through Solidus 4.7 found two holes in it:
# - Solidus assigns a value and then persists it with update_columns
#   (Shipment#persist_amounts: self.cost = ...; update_columns(cost:)). Lyra
#   took the "old" value from the in-memory attribute, already the new value,
#   saw no change, and published nothing.
# - Solidus records order completion with touch(:completed_at). Lyra did not
#   intercept touch at all.
# Either way the table and the event log disagreed.
class BypassEventsTest < Minitest::Test
  def setup
    skip "Requires Rails and database" unless defined?(ActiveRecord::Base) && ActiveRecord::Base.connection.table_exists?(:articles)

    @event_store = Lyra.config.event_store || RailsEventStore::Client.new(
      repository: RubyEventStore::ActiveRecord::EventRepository.new(serializer: RubyEventStore::Serializers::YAML)
    )
    Lyra.reset_config!
    Lyra.config.event_store = @event_store
    Lyra.config.enable_monitor!

    Object.send(:remove_const, :BypassArticle) if defined?(BypassArticle)
    Object.const_set(:BypassArticle, Class.new(ActiveRecord::Base) do
      self.table_name = "articles"
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
    end)
    clean
    @article = BypassArticle.create!(title: "Original", body: "Body")
  end

  def teardown
    clean if defined?(BypassArticle)
    Lyra.reset_config!
    Lyra.config.event_store = @event_store if @event_store
  end

  def test_update_columns_after_assignment_publishes_the_change
    @article.title = "Assigned first"
    @article.update_columns(title: "Assigned first")

    change = bypass_events.last.data.then { |d| d[:changes] || d["changes"] }
    assert_equal ["Original", "Assigned first"], change["title"] || change[:title]
    assert_consistent
  end

  def test_update_columns_without_assignment_publishes_the_change
    @article.update_columns(title: "Direct")

    assert_equal 1, bypass_events.size
    assert_consistent
  end

  def test_update_column_publishes_the_change
    @article.update_column(:status, "published")

    assert_equal 1, bypass_events.size
    assert_consistent
  end

  def test_touch_with_a_column_publishes_the_change
    @article.touch(:published_at)

    event = bypass_events.last
    refute_nil event, "touch(:published_at) must reach the event log"
    attrs = event.data[:attributes] || event.data["attributes"]
    assert attrs.key?("published_at")
    assert_consistent
  end

  def test_touch_without_columns_publishes_updated_at
    @article.touch

    assert_equal 1, bypass_events.size
  end

  def test_a_bypass_that_changes_nothing_publishes_nothing
    @article.update_columns(title: "Original")

    assert_empty bypass_events
  end

  def test_disabled_mode_publishes_no_bypass_events
    Lyra.config.disable!
    @article.update_columns(title: "Quiet")
    @article.touch(:published_at)

    assert_empty bypass_events
  end

  private

  def bypass_events
    @event_store.read.stream("BypassArticle$#{@article.id}").to_a.select { |e| e.metadata[:bypass_source] }
  end

  def assert_consistent
    assert_equal({ no_differences: true }, Lyra::DualView.new(BypassArticle, @article.id).calculate_differences)
  end

  def clean
    BypassArticle.unscoped.delete_all
    ActiveRecord::Base.connection.execute("DELETE FROM event_store_events_in_streams")
    ActiveRecord::Base.connection.execute("DELETE FROM event_store_events")
  end
end
