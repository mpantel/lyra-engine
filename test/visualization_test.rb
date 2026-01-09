require "test_helper"
require "ostruct"
require "json"

module Lyra
  module Visualization
    class TimelineTest < Minitest::Test
      def setup
        @events = create_test_events
        @timeline = Timeline.new(@events)
      end

      def test_to_data_returns_hash_with_events_groups_metadata
        data = @timeline.to_data

        assert data.is_a?(Hash)
        assert data.key?(:events)
        assert data.key?(:groups)
        assert data.key?(:metadata)
      end

      def test_events_contain_required_fields
        data = @timeline.to_data
        event = data[:events].first

        assert event.key?(:id)
        assert event.key?(:start)
        assert event.key?(:content)
        assert event.key?(:group)
        assert event.key?(:className)
        assert event.key?(:title)
      end

      def test_groups_contain_unique_model_classes
        data = @timeline.to_data

        group_ids = data[:groups].map { |g| g[:id] }
        assert_includes group_ids, "User"
        assert_includes group_ids, "Post"
        assert_equal 2, group_ids.uniq.count
      end

      def test_metadata_contains_timeline_bounds
        data = @timeline.to_data
        metadata = data[:metadata]

        assert metadata.key?(:start)
        assert metadata.key?(:end)
        assert metadata.key?(:count)
        assert metadata.key?(:models)
        assert_equal 3, metadata[:count]
      end

      def test_to_mermaid_generates_gantt_chart
        mermaid = @timeline.to_mermaid

        assert mermaid.start_with?("gantt")
        assert_includes mermaid, "title Event Timeline"
        assert_includes mermaid, "dateFormat"
        assert_includes mermaid, "section User"
        assert_includes mermaid, "section Post"
      end

      def test_to_ascii_generates_readable_output
        ascii = @timeline.to_ascii

        assert_includes ascii, "Event Timeline"
        assert_includes ascii, "User#"
        assert_includes ascii, "Post#"
        assert_includes ascii, "CREATED"
      end

      def test_to_ascii_shows_changes
        events = [
          create_event(
            operation: :updated,
            model_class: "User",
            model_id: 1,
            changes: { name: ["Old", "New"] }
          )
        ]
        timeline = Timeline.new(events)

        ascii = timeline.to_ascii

        assert_includes ascii, "name:"
        assert_includes ascii, "Old"
        assert_includes ascii, "New"
      end

      def test_to_ascii_shows_pii_marker
        events = [
          create_event(
            model_class: "User",
            attributes: { email: "test@example.com" }
          )
        ]

        Lyra::Privacy::PIIDetector.stubs(:detect).returns({ email: { type: :email } }) if PAM_DSL_AVAILABLE

        timeline = Timeline.new(events)
        ascii = timeline.to_ascii

        if PAM_DSL_AVAILABLE
          assert_includes ascii, "[PII]"
        else
          # Without PAM DSL, no PII marker is shown
          refute_includes ascii, "[PII]"
        end
      end

      def test_to_d3_json_returns_valid_json
        json = @timeline.to_d3_json

        assert json.is_a?(String)
        parsed = JSON.parse(json)
        assert parsed.key?("nodes")
        assert parsed.key?("links")
      end

      def test_to_d3_json_nodes_contain_required_fields
        json = @timeline.to_d3_json
        parsed = JSON.parse(json)
        node = parsed["nodes"].first

        assert node.key?("id")
        assert node.key?("index")
        assert node.key?("timestamp")
        assert node.key?("label")
        assert node.key?("operation")
        assert node.key?("has_pii")
        assert node.key?("group")
      end

      def test_build_links_by_correlation_id
        events = [
          create_event(correlation_id: "corr-1", timestamp: Time.now - 2),
          create_event(correlation_id: "corr-1", timestamp: Time.now - 1),
          create_event(correlation_id: "corr-2", timestamp: Time.now)
        ]

        timeline = Timeline.new(events)
        json = timeline.to_d3_json
        parsed = JSON.parse(json)

        correlation_links = parsed["links"].select { |l| l["type"] == "correlation" }
        assert_equal 1, correlation_links.count
      end

      def test_build_links_by_same_record
        events = [
          create_event(model_class: "User", model_id: 1, timestamp: Time.now - 2),
          create_event(model_class: "User", model_id: 1, timestamp: Time.now - 1),
          create_event(model_class: "User", model_id: 2, timestamp: Time.now)
        ]

        timeline = Timeline.new(events)
        json = timeline.to_d3_json
        parsed = JSON.parse(json)

        same_record_links = parsed["links"].select { |l| l["type"] == "same_record" }
        assert_equal 1, same_record_links.count
      end

      def test_empty_events_returns_empty_data
        timeline = Timeline.new([])
        data = timeline.to_data

        assert_empty data[:events]
        assert_empty data[:groups]
        assert_nil data[:metadata][:start]
      end

      def test_event_class_includes_operation
        events = [
          create_event(operation: :created),
          create_event(operation: :updated),
          create_event(operation: :destroyed)
        ]

        Lyra::Privacy::PIIDetector.stubs(:detect).returns({}) if PAM_DSL_AVAILABLE

        timeline = Timeline.new(events)
        data = timeline.to_data

        class_names = data[:events].map { |e| e[:className] }
        assert class_names.any? { |c| c.include?("event-created") }
        assert class_names.any? { |c| c.include?("event-updated") }
        assert class_names.any? { |c| c.include?("event-destroyed") }
      end

      def test_event_class_includes_pii_marker
        events = [create_event(attributes: { ssn: "123-45-6789" })]
        Lyra::Privacy::PIIDetector.stubs(:detect).returns({ ssn: { type: :ssn } }) if PAM_DSL_AVAILABLE

        timeline = Timeline.new(events)
        data = timeline.to_data

        if PAM_DSL_AVAILABLE
          assert data[:events].first[:className].include?("event-pii")
        else
          refute data[:events].first[:className].include?("event-pii")
        end
      end

      def test_event_tooltip_contains_details
        events = [create_event(operation: :created, model_class: "User", model_id: 42)]
        Lyra::Privacy::PIIDetector.stubs(:detect).returns({}) if PAM_DSL_AVAILABLE

        timeline = Timeline.new(events)
        data = timeline.to_data

        tooltip = data[:events].first[:title]
        assert_includes tooltip, "Operation: created"
        assert_includes tooltip, "Model: User"
        assert_includes tooltip, "ID: 42"
      end

      def test_event_tooltip_includes_pii_warning
        events = [create_event(attributes: { email: "test@example.com" })]
        Lyra::Privacy::PIIDetector.stubs(:detect).returns({ email: { type: :email } }) if PAM_DSL_AVAILABLE

        timeline = Timeline.new(events)
        data = timeline.to_data

        tooltip = data[:events].first[:title]
        if PAM_DSL_AVAILABLE
          assert_includes tooltip, "Contains PII"
        else
          refute_includes tooltip, "Contains PII"
        end
      end

      def test_events_sorted_by_timestamp
        events = [
          create_event(timestamp: Time.now),
          create_event(timestamp: Time.now - 3600),
          create_event(timestamp: Time.now - 1800)
        ]

        timeline = Timeline.new(events)
        data = timeline.to_data

        timestamps = data[:events].map { |e| e[:start] }
        assert_equal timestamps.sort, timestamps
      end

      private

      def create_test_events
        [
          create_event(operation: :created, model_class: "User", model_id: 1, timestamp: Time.now - 3600),
          create_event(operation: :updated, model_class: "User", model_id: 1, timestamp: Time.now - 1800),
          create_event(operation: :created, model_class: "Post", model_id: 1, timestamp: Time.now)
        ]
      end

      def create_event(attrs = {})
        OpenStruct.new({
          event_id: attrs[:event_id] || SecureRandom.uuid,
          operation: attrs[:operation] || :created,
          model_class: attrs[:model_class] || "TestModel",
          model_id: attrs[:model_id] || rand(1..100),
          timestamp: attrs[:timestamp] || Time.now,
          attributes: attrs[:attributes] || { name: "test" },
          changes: attrs[:changes] || {},
          metadata: {
            correlation_id: attrs[:correlation_id],
            user_id: attrs[:user_id]
          }
        })
      end
    end

    class EventGraphTest < Minitest::Test
      def setup
        @events = create_test_events
        @graph = EventGraph.new(@events)
      end

      def test_to_data_returns_hash_with_nodes_and_links
        data = @graph.to_data

        assert data.is_a?(Hash)
        assert data.key?(:nodes)
        assert data.key?(:links)
        assert data.key?(:metadata)
      end

      def test_nodes_contain_required_fields
        data = @graph.to_data
        node = data[:nodes].first

        assert node.key?(:id)
        assert node.key?(:label)
        assert node.key?(:operation)
        assert node.key?(:model_class)
        assert node.key?(:timestamp)
        assert node.key?(:color)
      end

      def test_links_connect_events_by_correlation_id
        events = [
          create_event(correlation_id: "corr-1", timestamp: Time.now - 2),
          create_event(correlation_id: "corr-1", timestamp: Time.now - 1),
          create_event(correlation_id: "corr-2", timestamp: Time.now)
        ]

        graph = EventGraph.new(events)
        data = graph.to_data

        correlation_links = data[:links].select { |l| l[:type] == "correlation" }
        assert_equal 1, correlation_links.count
      end

      def test_links_connect_events_on_same_record
        events = [
          create_event(model_class: "User", model_id: 1, timestamp: Time.now - 2),
          create_event(model_class: "User", model_id: 1, timestamp: Time.now - 1),
          create_event(model_class: "User", model_id: 2, timestamp: Time.now)
        ]

        graph = EventGraph.new(events)
        data = graph.to_data

        same_record_links = data[:links].select { |l| l[:type] == "same_record" }
        assert_equal 1, same_record_links.count
      end

      def test_metadata_contains_model_classes
        data = @graph.to_data

        assert data[:metadata].key?(:model_classes)
        assert data[:metadata][:model_classes].is_a?(Array)
      end

      def test_to_d3_json_returns_valid_json
        json = @graph.to_d3_json

        assert json.is_a?(String)
        parsed = JSON.parse(json)
        assert parsed.key?("nodes")
        assert parsed.key?("links")
      end

      def test_to_mermaid_generates_flowchart
        mermaid = @graph.to_mermaid

        assert mermaid.start_with?("flowchart TD")
        assert mermaid.include?("CREATE") || mermaid.include?("UPDATE")
      end

      def test_empty_events_returns_empty_data
        graph = EventGraph.new([])
        data = graph.to_data

        assert_equal [], data[:nodes]
        assert_equal [], data[:links]
      end

      def test_nodes_contain_changed_fields
        events = [
          create_event(
            operation: :updated,
            changes: { name: ["Old", "New"], status: ["pending", "active"] }
          )
        ]

        graph = EventGraph.new(events)
        data = graph.to_data
        node = data[:nodes].first

        assert node.key?(:changed_fields)
        assert_includes node[:changed_fields], "name"
        assert_includes node[:changed_fields], "status"
      end

      def test_nodes_contain_changes_with_values
        events = [
          create_event(
            operation: :updated,
            changes: { name: ["Old", "New"] }
          )
        ]

        graph = EventGraph.new(events)
        data = graph.to_data
        node = data[:nodes].first

        assert node.key?(:changes)
        assert node[:changes].is_a?(Array)

        change = node[:changes].find { |c| c[:field] == "name" }
        assert_equal "Old", change[:from]
        assert_equal "New", change[:to]
      end

      def test_changes_exclude_timestamp_fields
        events = [
          create_event(
            operation: :updated,
            changes: { name: ["Old", "New"], updated_at: [Time.now - 1, Time.now] }
          )
        ]

        graph = EventGraph.new(events)
        data = graph.to_data
        node = data[:nodes].first

        field_names = node[:changes].map { |c| c[:field] }
        assert_includes field_names, "name"
        refute_includes field_names, "updated_at"
      end

      def test_changes_include_pii_type_for_pii_fields
        skip "PAM DSL not available" unless PAM_DSL_AVAILABLE

        events = [
          create_event(
            operation: :updated,
            changes: { email: ["old@example.com", "new@example.com"], status: ["a", "b"] }
          )
        ]

        graph = EventGraph.new(events)
        data = graph.to_data
        node = data[:nodes].first

        email_change = node[:changes].find { |c| c[:field] == "email" }
        status_change = node[:changes].find { |c| c[:field] == "status" }

        assert email_change[:pii_type], "email field should have pii_type"
        assert_nil status_change[:pii_type], "status field should not have pii_type"
      end

      def test_mermaid_includes_changed_fields
        events = [
          create_event(
            operation: :updated,
            changes: { name: ["Old", "New"], email: ["a@b.com", "c@d.com"] }
          )
        ]

        graph = EventGraph.new(events)
        mermaid = graph.to_mermaid

        assert_includes mermaid, "📝"
        assert_includes mermaid, "name"
      end

      private

      def create_test_events
        [
          create_event(operation: :created, model_class: "User", model_id: 1),
          create_event(operation: :updated, model_class: "User", model_id: 1),
          create_event(operation: :created, model_class: "Post", model_id: 1)
        ]
      end

      def create_event(attrs = {})
        OpenStruct.new({
          event_id: attrs[:event_id] || SecureRandom.uuid,
          operation: attrs[:operation] || :created,
          model_class: attrs[:model_class] || "TestModel",
          model_id: attrs[:model_id] || rand(1..100),
          timestamp: attrs[:timestamp] || Time.now,
          attributes: attrs[:attributes] || { name: "test" },
          changes: attrs[:changes] || {},
          metadata: {
            correlation_id: attrs[:correlation_id],
            user_id: attrs[:user_id]
          }
        })
      end
    end

    class ActivityHeatmapTest < Minitest::Test
      def setup
        @events = create_test_events
        @heatmap = ActivityHeatmap.new(@events)
      end

      def test_to_data_returns_hash_with_data_and_labels
        data = @heatmap.to_data

        assert data.is_a?(Hash)
        assert data.key?(:data)
        assert data.key?(:x_labels)
        assert data.key?(:y_labels)
        assert data.key?(:metadata)
      end

      def test_data_contains_day_and_hour_entries
        data = @heatmap.to_data
        entry = data[:data].first

        assert entry.key?(:day)
        assert entry.key?(:hour)
        assert entry.key?(:count)
        assert entry.key?(:day_name)
        assert entry.key?(:hour_label)
      end

      def test_heatmap_has_168_cells
        # 7 days x 24 hours = 168 cells
        data = @heatmap.to_data

        assert_equal 168, data[:data].count
      end

      def test_y_labels_are_days_of_week
        data = @heatmap.to_data

        assert_equal 7, data[:y_labels].count
        assert_includes data[:y_labels], "Sunday"
        assert_includes data[:y_labels], "Saturday"
      end

      def test_x_labels_are_hours
        data = @heatmap.to_data

        assert_equal 24, data[:x_labels].count
        assert_includes data[:x_labels], "12 AM"
        assert_includes data[:x_labels], "12 PM"
      end

      def test_hourly_breakdown_returns_24_entries
        breakdown = @heatmap.hourly_breakdown

        assert_equal 24, breakdown.count
        assert breakdown.first.key?(:hour)
        assert breakdown.first.key?(:count)
        assert breakdown.first.key?(:percentage)
      end

      def test_daily_breakdown_returns_7_entries
        breakdown = @heatmap.daily_breakdown

        assert_equal 7, breakdown.count
        assert breakdown.first.key?(:day)
        assert breakdown.first.key?(:count)
      end

      def test_metadata_contains_peak_information
        data = @heatmap.to_data
        metadata = data[:metadata]

        assert metadata.key?(:total_events)
        assert metadata.key?(:peak_hour)
        assert metadata.key?(:peak_day)
      end

      def test_to_d3_json_returns_valid_json
        json = @heatmap.to_d3_json

        assert json.is_a?(String)
        parsed = JSON.parse(json)
        assert parsed.key?("data")
        assert parsed.key?("metadata")
      end

      def test_operation_heatmap_groups_by_operation
        breakdown = @heatmap.operation_heatmap

        assert breakdown.is_a?(Array)
        if breakdown.any?
          assert breakdown.first.key?(:operation)
          assert breakdown.first.key?(:hourly)
          assert breakdown.first.key?(:total)
        end
      end

      def test_empty_events_returns_zero_counts
        heatmap = ActivityHeatmap.new([])
        data = heatmap.to_data

        assert data[:data].all? { |entry| entry[:count] == 0 }
      end

      private

      def create_test_events
        # Create events spread across different times
        [
          create_event(timestamp: Time.new(2024, 1, 15, 9, 0)),   # Monday 9am
          create_event(timestamp: Time.new(2024, 1, 15, 14, 0)),  # Monday 2pm
          create_event(timestamp: Time.new(2024, 1, 16, 10, 0)),  # Tuesday 10am
          create_event(timestamp: Time.new(2024, 1, 17, 16, 0)),  # Wednesday 4pm
          create_event(timestamp: Time.new(2024, 1, 20, 11, 0))   # Saturday 11am
        ]
      end

      def create_event(attrs = {})
        OpenStruct.new({
          event_id: attrs[:event_id] || SecureRandom.uuid,
          operation: attrs[:operation] || :created,
          model_class: attrs[:model_class] || "TestModel",
          model_id: attrs[:model_id] || rand(1..100),
          timestamp: attrs[:timestamp] || Time.now,
          attributes: attrs[:attributes] || { name: "test" },
          changes: attrs[:changes] || {},
          metadata: attrs[:metadata] || {}
        })
      end
    end
  end
end
