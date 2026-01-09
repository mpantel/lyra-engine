require "test_helper"

module Lyra
  module Integration
    # Integration tests for event flow analysis across complex scenarios
    class EventFlowIntegrationTest < Minitest::Test
      def setup
        @events = create_event_stream
      end

      def create_event_stream
        # Simulate a realistic event stream for a user
        base_time = 7.days.ago

        events = []

        # Day 1: User registration
        events << create_event(
          operation: :created,
          model_id: 1,
          attributes: { name: "Alice", email: "alice@example.com", age: 30 },
          timestamp: base_time
        )

        # Day 2: Profile update
        events << create_event(
          operation: :updated,
          model_id: 1,
          changes: { name: ["Alice", "Alice Smith"] },
          timestamp: base_time + 1.day
        )

        # Day 3: Multiple updates
        3.times do |i|
          events << create_event(
            operation: :updated,
            model_id: 1,
            changes: { age: [30 + i, 30 + i + 1] },
            timestamp: base_time + 3.days + i.hours
          )
        end

        # Day 5: Email change (PII)
        events << create_event(
          operation: :updated,
          model_id: 1,
          changes: { email: ["alice@example.com", "alice.smith@example.com"] },
          timestamp: base_time + 5.days
        )

        # Day 7: Profile completion
        events << create_event(
          operation: :updated,
          model_id: 1,
          changes: { bio: [nil, "Software engineer"], location: [nil, "San Francisco"] },
          timestamp: base_time + 7.days
        )

        events
      end

      def create_event(attrs)
        Event.new(data: {
          model_class: "User",
          model_id: attrs[:model_id],
          operation: attrs[:operation],
          attributes: attrs[:attributes] || {},
          changes: attrs[:changes] || {},
          timestamp: attrs[:timestamp] || Time.current
        })
      end

      def test_event_flow_timeline_analysis
        event_flow = EventAnalyzer.new(@events)
        analysis = event_flow.analyze

        # Timeline checks
        assert analysis[:timeline][:first_event].present?
        assert analysis[:timeline][:last_event].present?
        assert analysis[:timeline][:duration_days] >= 6

        # Verify timeline order
        assert analysis[:timeline][:last_event] > analysis[:timeline][:first_event]
      end

      def test_event_flow_operations_breakdown
        event_flow = EventAnalyzer.new(@events)
        analysis = event_flow.analyze

        # Operation counts
        assert_equal 1, analysis[:operations][:created]
        assert analysis[:operations][:updated] > 0

        # Total events
        assert_equal @events.length, analysis[:metrics][:total_events]
      end

      def test_event_flow_privacy_analysis
        event_flow = EventAnalyzer.new(@events)
        analysis = event_flow.analyze

        if PAM_DSL_AVAILABLE
          # PII detection
          assert analysis[:privacy][:pii_fields].present?
          assert analysis[:privacy][:pii_fields].key?(:email)
          assert analysis[:privacy][:pii_fields].key?(:name)

          # Events with PII
          assert analysis[:privacy][:events_with_pii] > 0
          assert analysis[:privacy][:percentage] > 0
        else
          # Without PAM DSL, no PII is detected
          assert_empty analysis[:privacy][:pii_fields]
          assert_equal 0, analysis[:privacy][:events_with_pii]
          assert_equal 0.0, analysis[:privacy][:percentage]
        end
      end

      def test_event_flow_frequency_metrics
        event_flow = EventAnalyzer.new(@events)
        analysis = event_flow.analyze

        # Operations per day should be calculated
        if analysis[:timeline][:duration_days] && analysis[:timeline][:duration_days] > 0
          assert analysis[:metrics][:operations_per_day].present?
          assert analysis[:metrics][:operations_per_day] > 0
        end
      end

      def test_high_frequency_event_stream
        # Create many events in short time
        high_freq_events = []
        base_time = Time.current

        100.times do |i|
          high_freq_events << create_event(
            operation: :updated,
            model_id: 2,
            changes: { counter: [i, i + 1] },
            timestamp: base_time + i.seconds
          )
        end

        event_flow = EventAnalyzer.new(high_freq_events)
        analysis = event_flow.analyze

        assert_equal 100, analysis[:metrics][:total_events]
        assert_equal 100, analysis[:operations][:updated]

        # High frequency should be detectable
        if analysis[:timeline][:duration_minutes] && analysis[:timeline][:duration_minutes] > 0
          ops_per_minute = 100.0 / analysis[:timeline][:duration_minutes]
          assert ops_per_minute > 1, "Should detect high frequency"
        end
      end

      def test_sparse_event_stream
        # Create events spread over long time
        sparse_events = []
        base_time = 1.year.ago

        4.times do |i|
          sparse_events << create_event(
            operation: :updated,
            model_id: 3,
            changes: { version: [i, i + 1] },
            timestamp: base_time + (i * 3.months)
          )
        end

        event_flow = EventAnalyzer.new(sparse_events)
        analysis = event_flow.analyze

        # Should detect long duration
        assert analysis[:timeline][:duration_days] > 200

        # Low operations per day
        if analysis[:metrics][:operations_per_day]
          assert analysis[:metrics][:operations_per_day] < 1
        end
      end

      def test_mixed_pii_event_stream
        mixed_events = []

        # Some events with PII
        mixed_events << create_event(
          operation: :created,
          model_id: 4,
          attributes: { name: "Bob", email: "bob@example.com" }
        )

        # Some events without PII
        5.times do |i|
          mixed_events << create_event(
            operation: :updated,
            model_id: 4,
            changes: { counter: [i, i + 1], status: ["pending", "active"] }
          )
        end

        # Another event with PII
        mixed_events << create_event(
          operation: :updated,
          model_id: 4,
          changes: { telephone: ["555-0000", "555-1234"] }
        )

        event_flow = EventAnalyzer.new(mixed_events)
        analysis = event_flow.analyze

        if PAM_DSL_AVAILABLE
          # PII percentage should be reasonable
          pii_percentage = analysis[:privacy][:percentage]
          assert pii_percentage > 0, "Should detect some PII"
          assert pii_percentage < 100, "Not all events have PII"

          # Should detect multiple PII types
          assert analysis[:privacy][:pii_fields].keys.length >= 2
        else
          # Without PAM DSL, no PII detection
          assert_equal 0.0, analysis[:privacy][:percentage]
          assert_empty analysis[:privacy][:pii_fields]
        end
      end

      def test_event_flow_with_deletions
        deletion_events = []

        # Create → Update → Delete lifecycle
        deletion_events << create_event(
          operation: :created,
          model_id: 5,
          attributes: { name: "Temp User" },
          timestamp: 3.hours.ago
        )

        deletion_events << create_event(
          operation: :updated,
          model_id: 5,
          changes: { status: ["pending", "active"] },
          timestamp: 2.hours.ago
        )

        deletion_events << create_event(
          operation: :destroyed,
          model_id: 5,
          timestamp: 1.hour.ago
        )

        event_flow = EventAnalyzer.new(deletion_events)
        analysis = event_flow.analyze

        # Should track all operation types
        assert_equal 1, analysis[:operations][:created]
        assert_equal 1, analysis[:operations][:updated]
        assert_equal 1, analysis[:operations][:destroyed]

        # Lifecycle duration
        assert analysis[:timeline][:duration_hours] >= 2
      end

      def test_correlated_event_streams
        correlation_id = "workflow-123"

        # Multiple entities in same workflow
        correlated_events = []

        # User creation
        correlated_events << create_event(
          operation: :created,
          model_id: 10,
          attributes: { name: "Coordinator" }
        ).tap { |e| e.metadata[:correlation_id] = correlation_id }

        # Order creation (related)
        correlated_events << Event.new(data: {
          model_class: "Order",
          model_id: 100,
          operation: :created,
          attributes: { user_id: 10, total: 99.99 }
        }).tap { |e| e.metadata[:correlation_id] = correlation_id }

        # Payment (related)
        correlated_events << Event.new(data: {
          model_class: "Payment",
          model_id: 1000,
          operation: :created,
          attributes: { order_id: 100, amount: 99.99 }
        }).tap { |e| e.metadata[:correlation_id] = correlation_id }

        # All events should share correlation ID
        assert correlated_events.all? { |e| e.metadata[:correlation_id] == correlation_id }

        # Can be grouped by correlation
        grouped = correlated_events.group_by { |e| e.metadata[:correlation_id] }
        assert_equal 3, grouped[correlation_id].length
      end

      def test_event_flow_edge_cases
        # Empty stream
        empty_flow = EventAnalyzer.new([])
        empty_analysis = empty_flow.analyze
        assert_equal 0, empty_analysis[:metrics][:total_events]

        # Single event
        single_event = [create_event(operation: :created, model_id: 99)]
        single_flow = EventAnalyzer.new(single_event)
        single_analysis = single_flow.analyze
        assert_equal 1, single_analysis[:metrics][:total_events]
        assert_equal 1, single_analysis[:operations][:created]
      end

      def test_privacy_percentage_calculation
        # Stream with known PII distribution
        calc_events = []

        # 2 events with PII (email, name)
        2.times do |i|
          calc_events << create_event(
            operation: :created,
            model_id: 20 + i,
            attributes: { name: "User#{i}", email: "user#{i}@example.com" }
          )
        end

        # 2 events without PII
        2.times do |i|
          calc_events << create_event(
            operation: :updated,
            model_id: 20 + i,
            changes: { counter: [0, 1] }
          )
        end

        event_flow = EventAnalyzer.new(calc_events)
        analysis = event_flow.analyze

        if PAM_DSL_AVAILABLE
          # 2 out of 4 events have PII = 50%
          expected_pii_events = 2
          expected_percentage = 50.0

          assert_equal expected_pii_events, analysis[:privacy][:events_with_pii]
          assert_in_delta expected_percentage, analysis[:privacy][:percentage], 0.1
        else
          # Without PAM DSL, no PII detection
          assert_equal 0, analysis[:privacy][:events_with_pii]
          assert_equal 0.0, analysis[:privacy][:percentage]
        end
      end

      def test_event_flow_patterns_detection
        pattern_events = []
        base_time = Time.current

        # Pattern: Regular hourly updates
        24.times do |hour|
          pattern_events << create_event(
            operation: :updated,
            model_id: 30,
            changes: { hour: [hour, hour + 1] },
            timestamp: base_time + hour.hours
          )
        end

        event_flow = EventAnalyzer.new(pattern_events)
        analysis = event_flow.analyze

        # Should span about 24 hours
        assert_in_delta 24, analysis[:timeline][:duration_hours], 1

        # Should have consistent frequency (~ 1 per hour)
        ops_per_hour = 24.0 / analysis[:timeline][:duration_hours]
        assert_in_delta 1.0, ops_per_hour, 0.1
      end

      def test_event_flow_for_audit_trail
        audit_events = []

        # Initial state
        audit_events << create_event(
          operation: :created,
          model_id: 40,
          attributes: { status: "draft", content: "Initial" },
          timestamp: 5.days.ago
        )

        # Review cycle with multiple reviewers
        ["reviewer1", "reviewer2", "reviewer3"].each_with_index do |reviewer, i|
          audit_events << create_event(
            operation: :updated,
            model_id: 40,
            changes: { reviewed_by: [nil, reviewer] },
            timestamp: 5.days.ago + (i + 1).days
          ).tap { |e| e.metadata[:user_id] = reviewer }
        end

        # Final approval
        audit_events << create_event(
          operation: :updated,
          model_id: 40,
          changes: { status: ["draft", "approved"] },
          timestamp: 1.day.ago
        ).tap { |e| e.metadata[:user_id] = "approver" }

        # Should have complete audit trail
        assert_equal 5, audit_events.length

        # Each step should be timestamped
        timestamps = audit_events.map { |e| e.timestamp }
        assert_equal timestamps, timestamps.sort

        # Metadata should track actors
        actors = audit_events.map { |e| e.metadata[:user_id] }.compact
        assert actors.include?("reviewer1")
        assert actors.include?("approver")
      end
    end
  end
end
