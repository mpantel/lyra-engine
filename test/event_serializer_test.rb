# frozen_string_literal: true

require "test_helper"

class EventSerializerTest < ActiveSupport::TestCase
  test "keeps sub-second precision that serializer: JSON drops" do
    before = Time.utc(2016, 1, 1, 9, 51, 15.304r)
    after = Time.utc(2016, 1, 1, 9, 51, 15.352r)
    data = { "changes" => { "status_changed_at" => [before, after] } }

    lossy = JSON.parse(JSON.dump(data))["changes"]["status_changed_at"]
    assert_equal lossy.first, lossy.last, "precondition: plain JSON makes the change vanish"

    kept = Lyra::EventSerializer.load(Lyra::EventSerializer.dump(data))["changes"]["status_changed_at"]
    assert_equal "2016-01-01T09:51:15.304000Z", kept.first
    assert_equal "2016-01-01T09:51:15.352000Z", kept.last
  end

  test "keeps microseconds, the resolution of a PostgreSQL timestamp" do
    t = Time.utc(2026, 10, 2, 7, 10, 55, 123_456)
    assert_equal t, Time.iso8601(Lyra::EventSerializer.load(Lyra::EventSerializer.dump("t" => t))["t"])
  end

  test "encodes TimeWithZone, BigDecimal and nested structures" do
    tz = Time.utc(2016, 1, 2, 3, 4, 5.678r).in_time_zone("Athens")
    out = Lyra::EventSerializer.load(
      Lyra::EventSerializer.dump(attributes: { at: tz, amount: BigDecimal("20000.50"), tags: [tz] })
    )
    assert_equal "2016-01-02T03:04:05.678000Z", out["attributes"]["at"]
    assert_equal "20000.5", out["attributes"]["amount"]
    assert_equal ["2016-01-02T03:04:05.678000Z"], out["attributes"]["tags"]
  end

  test "round-trips through a RailsEventStore repository" do
    client = RailsEventStore::Client.new(
      repository: RailsEventStoreActiveRecord::EventRepository.new(serializer: Lyra::EventSerializer)
    )
    at = Time.utc(2016, 1, 1, 9, 51, 15.304r)
    event = RubyEventStore::Event.new(data: { "attributes" => { "status_changed_at" => at } })
    client.publish(event, stream_name: "EventSerializerTest$#{SecureRandom.hex(4)}")

    stored = client.read.event(event.event_id)
    assert_equal "2016-01-01T09:51:15.304000Z", stored.data["attributes"]["status_changed_at"]
  end
end
