# frozen_string_literal: true

require "test_helper"

module Lyra
  class EventAnalyzerTest < Minitest::Test
    # Mock event class for testing
    MockEvent = Struct.new(:timestamp, :operation, :model_class, :model_id, :attributes, :changes, :metadata, keyword_init: true) do
      def data
        { operation: operation, attributes: attributes, changes: changes, timestamp: timestamp }
      end
    end

    def setup
      @base_time = Time.now
      @events = [
        MockEvent.new(
          timestamp: @base_time,
          operation: :created,
          model_class: "User",
          model_id: 1,
          attributes: { email: "test@example.com", name: "Test User" },
          changes: {},
          metadata: {}
        ),
        MockEvent.new(
          timestamp: @base_time + 3600,
          operation: :updated,
          model_class: "User",
          model_id: 1,
          attributes: { email: "test@example.com", name: "Updated User" },
          changes: { name: ["Test User", "Updated User"] },
          metadata: {}
        ),
        MockEvent.new(
          timestamp: @base_time + 7200,
          operation: :destroyed,
          model_class: "User",
          model_id: 1,
          attributes: {},
          changes: {},
          metadata: {}
        )
      ]
    end

    def test_analyze_returns_comprehensive_metrics
      analyzer = EventAnalyzer.new(@events)
      result = analyzer.analyze

      assert result.key?(:timeline)
      assert result.key?(:operations)
      assert result.key?(:metrics)
      assert result.key?(:privacy)
    end

    def test_calculate_timeline_with_events
      analyzer = EventAnalyzer.new(@events)
      result = analyzer.analyze

      timeline = result[:timeline]
      assert_equal @base_time, timeline[:first_event]
      assert_equal @base_time + 7200, timeline[:last_event]
      assert_equal 7200, timeline[:duration_seconds]
      assert_equal 120.0, timeline[:duration_minutes]
      assert_equal 2.0, timeline[:duration_hours]
    end

    def test_calculate_timeline_with_empty_events
      analyzer = EventAnalyzer.new([])
      result = analyzer.analyze

      assert_empty result[:timeline]
    end

    def test_calculate_operations_counts
      analyzer = EventAnalyzer.new(@events)
      result = analyzer.analyze

      operations = result[:operations]
      assert_equal 1, operations[:created]
      assert_equal 1, operations[:updated]
      assert_equal 1, operations[:destroyed]
    end

    def test_calculate_metrics
      analyzer = EventAnalyzer.new(@events)
      result = analyzer.analyze

      metrics = result[:metrics]
      assert_equal 3, metrics[:total_events]
      assert metrics[:operations_per_day] > 0
      assert_equal 3600, metrics[:average_time_between_events]
    end

    def test_calculate_metrics_with_single_event
      single_event = [MockEvent.new(timestamp: @base_time, operation: :created, attributes: {}, changes: {}, metadata: {})]
      analyzer = EventAnalyzer.new(single_event)
      result = analyzer.analyze

      metrics = result[:metrics]
      assert_equal 1, metrics[:total_events]
      assert_equal 0, metrics[:average_time_between_events]
    end

    def test_analyze_privacy_detects_pii
      # Only stub when PAM DSL is available
      Lyra::Privacy::PIIDetector.stubs(:detect).returns({ email: { type: :email, confidence: 0.9 } }) if PAM_DSL_AVAILABLE

      analyzer = EventAnalyzer.new(@events)
      result = analyzer.analyze

      privacy = result[:privacy]
      if PAM_DSL_AVAILABLE
        assert privacy[:pii_fields].key?(:email)
        assert privacy[:events_with_pii] > 0
        assert privacy[:percentage] > 0
      else
        # Without PAM DSL, no PII is detected
        assert_empty privacy[:pii_fields]
        assert_equal 0, privacy[:events_with_pii]
        assert_equal 0.0, privacy[:percentage]
      end
    end

    def test_analyze_privacy_with_no_pii
      # Only stub when PAM DSL is available
      Lyra::Privacy::PIIDetector.stubs(:detect).returns({}) if PAM_DSL_AVAILABLE

      analyzer = EventAnalyzer.new(@events)
      result = analyzer.analyze

      privacy = result[:privacy]
      assert_empty privacy[:pii_fields]
      assert_equal 0, privacy[:events_with_pii]
      assert_equal 0.0, privacy[:percentage]
    end

    def test_analyze_privacy_with_empty_events
      analyzer = EventAnalyzer.new([])
      result = analyzer.analyze

      privacy = result[:privacy]
      assert_empty privacy[:pii_fields]
      assert_equal 0, privacy[:events_with_pii]
      assert_equal 0.0, privacy[:percentage]
    end

    def test_extract_timestamp_from_event_timestamp_method
      event = MockEvent.new(timestamp: @base_time, operation: :created, attributes: {}, changes: {}, metadata: {})
      analyzer = EventAnalyzer.new([event])
      result = analyzer.analyze

      assert_equal @base_time, result[:timeline][:first_event]
    end

    def test_extract_timestamp_from_event_data
      # Event without timestamp method but with data[:timestamp]
      event = Struct.new(:data, :operation).new(
        { timestamp: @base_time, operation: :created, attributes: {} },
        :created
      )

      analyzer = EventAnalyzer.new([event])
      result = analyzer.analyze

      assert_equal @base_time, result[:timeline][:first_event]
    end

    def test_extract_timestamp_from_metadata
      # Event with timestamp in metadata
      event = Struct.new(:metadata, :data, :operation).new(
        { timestamp: @base_time },
        { operation: :created, attributes: {} },
        :created
      )

      # Need to remove respond_to?(:timestamp) returning true
      event.define_singleton_method(:timestamp) { nil }

      analyzer = EventAnalyzer.new([event])
      result = analyzer.analyze

      assert_equal @base_time, result[:timeline][:first_event]
    end

    def test_handles_events_without_timestamp
      event = Struct.new(:operation, :data).new(:created, { operation: :created, attributes: {} })

      analyzer = EventAnalyzer.new([event])
      result = analyzer.analyze

      assert_empty result[:timeline]
    end

    def test_operations_from_data_when_no_operation_method
      event = Struct.new(:data, :timestamp).new(
        { operation: :created, attributes: {} },
        @base_time
      )

      analyzer = EventAnalyzer.new([event])
      result = analyzer.analyze

      assert_equal 1, result[:operations][:created]
    end

    def test_detect_event_pii_from_attributes
      event = MockEvent.new(
        timestamp: @base_time,
        operation: :created,
        attributes: { email: "test@example.com" },
        changes: {},
        metadata: {}
      )

      Lyra::Privacy::PIIDetector.stubs(:detect).with { |arg| arg[:email] == "test@example.com" }.returns({ email: { type: :email } }) if PAM_DSL_AVAILABLE

      analyzer = EventAnalyzer.new([event])
      result = analyzer.analyze

      if PAM_DSL_AVAILABLE
        assert result[:privacy][:pii_fields].key?(:email)
      else
        assert_empty result[:privacy][:pii_fields]
      end
    end

    def test_detect_event_pii_from_changes
      event = MockEvent.new(
        timestamp: @base_time,
        operation: :updated,
        attributes: {},
        changes: { ssn: ["old", "new-ssn"] },
        metadata: {}
      )

      Lyra::Privacy::PIIDetector.stubs(:detect).returns({ ssn: { type: :ssn } }) if PAM_DSL_AVAILABLE

      analyzer = EventAnalyzer.new([event])
      result = analyzer.analyze

      if PAM_DSL_AVAILABLE
        assert result[:privacy][:pii_fields].key?(:ssn)
      else
        assert_empty result[:privacy][:pii_fields]
      end
    end

    def test_detect_event_pii_from_data_attributes
      event = Struct.new(:data, :timestamp, :operation).new(
        { attributes: { phone: "555-1234" }, changes: {} },
        @base_time,
        :created
      )

      Lyra::Privacy::PIIDetector.stubs(:detect).returns({ phone: { type: :phone } }) if PAM_DSL_AVAILABLE

      analyzer = EventAnalyzer.new([event])
      result = analyzer.analyze

      if PAM_DSL_AVAILABLE
        assert result[:privacy][:pii_fields].key?(:phone)
      else
        assert_empty result[:privacy][:pii_fields]
      end
    end

    def test_events_accessor
      analyzer = EventAnalyzer.new(@events)
      assert_equal @events, analyzer.events
    end

    def test_handles_duration_days_zero
      # Two events at the exact same time
      same_time_events = [
        MockEvent.new(timestamp: @base_time, operation: :created, attributes: {}, changes: {}, metadata: {}),
        MockEvent.new(timestamp: @base_time, operation: :updated, attributes: {}, changes: {}, metadata: {})
      ]

      analyzer = EventAnalyzer.new(same_time_events)
      result = analyzer.analyze

      # operations_per_day should be 0 when duration_days is 0
      assert_equal 0, result[:metrics][:operations_per_day]
    end
  end
end
