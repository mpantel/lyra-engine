# frozen_string_literal: true

require "test_helper"

# A record created in Monitor keeps created_at and updated_at when the log
# becomes authoritative.
#
# Monitor's event used to leave the two columns out of its attributes snapshot.
# Replay and projection read a create's attributes, so after a switch to event
# sourcing an ES-NoProj read raised MissingAttributeError on them and a rebuild
# reset them to the rebuild time. DualView ignored the two columns then, so it
# reported neither.
class MonitorTimestampsTest < Minitest::Test
  TABLE = "lyra_monitor_timestamp_items"

  def setup
    skip "Requires Rails and PostgreSQL" unless defined?(ActiveRecord::Base) && connection.adapter_name.match?(/postgres/i)

    connection.create_table(TABLE, force: true) do |t|
      t.string :label
      t.timestamps
    end
    Object.send(:remove_const, :MonitorTimestampItem) if defined?(MonitorTimestampItem)
    klass = Class.new(ActiveRecord::Base)
    Object.const_set(:MonitorTimestampItem, klass) # named before it is monitored: event names come from the name
    klass.table_name = TABLE
    klass.include Lyra::Interceptors::CrudInterceptor
    klass.monitor_with_lyra
    klass.reset_column_information
    clean
    Lyra.config.monitor_model(klass)
  end

  def teardown
    return unless defined?(MonitorTimestampItem)

    Lyra.reset_config!
    clean
    connection.drop_table(TABLE, if_exists: true)
  end

  def test_the_monitor_event_carries_both_timestamps_in_its_attributes
    Lyra.config.enable_monitor!
    id = MonitorTimestampItem.create!(label: "a").id
    created = Lyra.config.event_store.read.stream(Lyra.stream_name(MonitorTimestampItem, id)).to_a
                  .find { |event| Lyra::Event.operation_of(event) == :created }

    attributes = created.data[:attributes] || created.data["attributes"]
    assert_includes attributes.keys.map(&:to_s), "created_at"
    assert_includes attributes.keys.map(&:to_s), "updated_at"
  end

  def test_a_monitor_created_record_keeps_its_timestamps_in_es_noproj
    id, row = create_in_monitor

    Lyra.config.enable_event_sourcing!
    Lyra.config.projection_mode = :disabled
    record = MonitorTimestampItem.find(id)

    assert_in_delta row["created_at"].to_f, record.created_at.to_f, 0.001
    assert_in_delta row["updated_at"].to_f, record.updated_at.to_f, 0.001
  end

  def test_a_rebuild_does_not_reset_the_timestamps_of_a_monitor_created_record
    id, row = create_in_monitor

    Lyra.config.enable_event_sourcing!
    Lyra.config.projection_mode = :sync
    Lyra::Projections::Rebuild.rebuild(MonitorTimestampItem, truncate: true)
    rebuilt = fetch_row(id)

    assert_in_delta row["created_at"].to_f, rebuilt["created_at"].to_f, 0.001, "created_at is the creation time, not the rebuild time"
    assert_in_delta row["updated_at"].to_f, rebuilt["updated_at"].to_f, 0.001
  end

  # Timestamps are ordinary columns (1.0.0): a projection writes updated_at
  # only when the event changed it. An update that left it alone
  # (update_columns) used to be projected with the projection time, so a
  # rebuilt row differed from its events.
  def test_a_rebuild_keeps_updated_at_that_an_update_did_not_change
    Lyra.config.enable_hijack!
    item = MonitorTimestampItem.create!(label: "a")
    item.update_columns(label: "z")
    before = fetch_row(item.id)["updated_at"]

    Lyra::Projections::Rebuild.rebuild(MonitorTimestampItem, truncate: true)

    assert_equal before, fetch_row(item.id)["updated_at"]
    comparison = Lyra::DualView.new(MonitorTimestampItem, item.id).compare
    assert_equal({}, comparison[:differences], "row and events agree")
  end

  def test_created_attributes_are_the_event_s_attributes
    data = { attributes: { "created_at" => Time.utc(2026, 5, 5) }, changes: { "created_at" => [nil, Time.utc(2020, 1, 1)] } }

    assert_equal({ "created_at" => Time.utc(2026, 5, 5) }, Lyra::Event.created_attributes(data))
    assert_equal({}, Lyra::Event.created_attributes(nil))
  end

  def test_dual_view_reports_a_row_whose_timestamp_differs_from_its_events
    Lyra.config.enable_monitor!
    id = MonitorTimestampItem.create!(label: "a").id
    assert_equal({}, Lyra::DualView.new(MonitorTimestampItem, id).calculate_differences)

    connection.execute("UPDATE #{TABLE} SET updated_at = updated_at + interval '1 day' WHERE id = #{Integer(id)}")

    assert_equal ["updated_at"], Lyra::DualView.new(MonitorTimestampItem, id).calculate_differences.keys
  end

  private

  # A record created in Monitor, then a pause so that a reset would show.
  def create_in_monitor
    Lyra.config.enable_monitor!
    id = MonitorTimestampItem.create!(label: "a").id
    row = fetch_row(id)
    sleep 1.1
    [id, row]
  end

  def fetch_row(id)
    connection.select_one("SELECT created_at, updated_at FROM #{TABLE} WHERE id = #{Integer(id)}")
  end

  def clean
    connection.execute("DELETE FROM event_store_events_in_streams")
    connection.execute("DELETE FROM event_store_events")
  end

  def connection = ActiveRecord::Base.connection
end
