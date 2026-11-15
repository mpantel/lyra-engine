# frozen_string_literal: true

require "test_helper"

# touch_all in ES-NoProj (events-only store). It was not among CachedRelation's
# bulk writes, so it went through the scope branch: an unscoped touch_all
# touched every row of the table, publishing an update event for each, and
# then raised UnsupportedQuery. Records the caller never selected changed in
# the log, which ES-NoProj reads as the truth.
class EsNoprojTouchAllTest < Minitest::Test
  TABLE = "lyra_noproj_touch_items"

  def setup
    skip "Requires Rails and PostgreSQL" unless defined?(ActiveRecord::Base) && connection.adapter_name.match?(/postgres/i)

    connection.create_table(TABLE, force: true) do |t|
      t.string :label
      t.timestamps
    end
    Object.send(:remove_const, :NoprojTouchItem) if defined?(NoprojTouchItem)
    klass = Class.new(ActiveRecord::Base)
    Object.const_set(:NoprojTouchItem, klass)
    klass.table_name = TABLE
    klass.include Lyra::Interceptors::CrudInterceptor
    klass.monitor_with_lyra
    klass.reset_column_information
    clean
    Lyra.config.monitor_model(klass)
    Lyra.config.enable_hijack!
    @touched = NoprojTouchItem.create!(label: "i")
    @other = NoprojTouchItem.create!(label: "j")
    Lyra.config.enable_event_sourcing!
    Lyra.config.projection_mode = :disabled
  end

  def teardown
    return unless defined?(NoprojTouchItem)

    Lyra.reset_config!
    clean
    connection.drop_table(TABLE, if_exists: true)
  end

  def test_a_scoped_touch_all_touches_only_the_selected_records
    other_events = stream(@other).size
    before = NoprojTouchItem.find(@touched.id).updated_at
    sleep 0.01

    assert_equal 1, NoprojTouchItem.where(id: @touched.id).touch_all

    last = stream(@touched).last
    assert_equal "touch_all", last.metadata[:bypass_source]
    assert (last.data[:changes] || last.data["changes"]).key?("updated_at")
    assert_operator NoprojTouchItem.find(@touched.id).updated_at, :>, before, "read back from the events"
    assert_equal other_events, stream(@other).size, "an unselected record's stream does not move"
  end

  def test_a_bare_touch_all_touches_every_record_with_one_time
    NoprojTouchItem.all.touch_all

    times = [@touched, @other].map { |r| (stream(r).last.data[:changes] || stream(r).last.data["changes"])["updated_at"].last }
    assert_equal 1, times.uniq.size, "one time for every row, as Rails gives"
  end

  private

  def stream(record) = Lyra.config.event_store.read.stream(Lyra.stream_name(record.class, record.id)).to_a

  def clean
    connection.execute("DELETE FROM event_store_events_in_streams")
    connection.execute("DELETE FROM event_store_events")
  end

  def connection = ActiveRecord::Base.connection
end
