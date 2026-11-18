# frozen_string_literal: true

require "test_helper"

module Lyra
  module Visualization
    # Timeline#to_html (TimelineHtmlBuilder), and the timeline read from plain
    # RubyEventStore events (no Lyra::Event readers: string keys, a string
    # operation) and from an event-like object with no data.
    class TimelineHtmlTest < Minitest::Test
      def test_the_html_timeline_shows_each_event_in_time_order
        created = lyra_event(:created, at: 2.hours.ago, attributes: { "email" => "ann@example.com" })
        updated = lyra_event(:updated, at: 1.hour.ago, changes: { "title" => ["Old", "New <i>"], "flag" => true },
                                       user_action: "<b>Approve</b>")

        html = Timeline.new([updated, created]).to_html

        assert_includes html, "<span>2 events</span>"
        assert_includes html, "<span>1 models</span>"
        assert_operator html.index("CREATED"), :<, html.index("UPDATED"), "oldest first"
        assert_includes html, %(<span class="event-model">TlWidget#5</span>)
        assert_includes html, "New &lt;i&gt;", "a change shows its new value, escaped"
        assert_includes html, %(<span class="field">flag</span>), "a change given as its value alone"
        assert_includes html, "User Action: &lt;b&gt;Approve&lt;/b&gt;"
        assert_includes html, created.data[:timestamp].strftime("%Y-%m-%d %H:%M:%S")
        if Lyra.privacy_features_available?
          assert_includes html, %(<div class="timeline-event created with-pii">)
          assert_equal 1, html.scan(%(<span class="pii-badge">PII</span>)).size
        end
      end

      def test_plain_events_and_events_without_data
        at = Time.utc(2026, 3, 1, 9, 30)
        plain = RubyEventStore::Event.new(
          data: { "model_class" => "TlOrder", "model_id" => 8, "operation" => "updated",
                  "changes" => { "state" => %w[cart paid] }, "timestamp" => at },
          metadata: { user_action: "pay" }
        )
        bare = Struct.new(:event_id, :metadata).new("bare-1", {})

        html = TimelineHtmlBuilder.new([plain, bare]).build

        assert_includes html, %(<span class="event-model">TlOrder#8</span>)
        assert_includes html, "UPDATED"
        assert_includes html, "2026-03-01 09:30:00"
        assert_includes html, %(<span class="value">paid</span>)
        assert_includes html, %(<span class="event-model">Unknown#?</span>), "an event with no data"
        assert_includes html, "UNKNOWN"
      end

      def test_the_text_timelines_read_plain_events_from_their_data
        at = Time.utc(2026, 3, 1, 9, 30)
        plain = RubyEventStore::Event.new(
          data: { "model_class" => "TlOrder", "model_id" => 8, "operation" => "updated",
                  "attributes" => {}, "changes" => { "state" => %w[cart paid] } },
          metadata: { timestamp: at }
        )
        timeline = Timeline.new([plain])

        assert_includes timeline.to_ascii, "2026-03-01 09:30:00 | TlOrder#8"
        assert_includes timeline.to_ascii, "└─ UPDATED"
        assert_includes timeline.to_ascii, "• state: cart → paid"
        assert_includes timeline.to_mermaid, "section TlOrder"
        assert_includes timeline.to_mermaid, "updated #8 :2026-03-01 09:30:00, 1s"
        assert_equal "Updated #8", timeline.to_data[:events].first[:content]
      end

      private

      def lyra_event(operation, at:, attributes: {}, changes: {}, user_action: nil)
        Lyra::Event.new(
          data: { model_class: "TlWidget", model_id: 5, operation: operation, attributes: attributes,
                  changes: changes, timestamp: at },
          metadata: { user_action: user_action }.compact
        )
      end
    end
  end
end
