require "test_helper"

module Lyra
  class EventFlowTest < Minitest::Test
    def setup
      @event_flow = EventFlow.new
    end

    def test_initialization_with_defaults
      flow = EventFlow.new

      assert_nil flow.subject_id
      assert_nil flow.subject_type
      assert flow.time_range.is_a?(Range)
    end

    def test_initialization_with_parameters
      now = Time.current
      yesterday = 1.day.ago

      flow = EventFlow.new(
        subject_id: "user-123",
        subject_type: "User",
        time_range: (yesterday..now)
      )

      assert_equal "user-123", flow.subject_id
      assert_equal "User", flow.subject_type
      assert_equal (yesterday..now), flow.time_range
    end

    def test_build_timeline_with_events
      events = create_test_events(2)

      timeline = @event_flow.send(:build_timeline, events)

      assert_equal 2, timeline.length
      assert timeline.first.key?(:event_id)
      assert timeline.first.key?(:timestamp)
      assert timeline.first.key?(:operation)
      assert timeline.first.key?(:model_class)
      assert timeline.first.key?(:pii_fields)
    end

    def test_calculate_duration_with_empty_events
      duration = @event_flow.send(:calculate_duration, [])

      assert_equal 0, duration
    end

    # Note: Tests for calculate_duration and calculate_statistics with actual events
    # require proper RailsEventStore setup and are better suited for integration tests

    def test_group_by_correlation
      corr_id = "correlation-123"
      events = [
        create_event(correlation_id: corr_id),
        create_event(correlation_id: corr_id),
        create_event(correlation_id: "other")
      ]

      grouped = @event_flow.send(:group_by_correlation, events)

      assert_equal 2, grouped.keys.length
      assert_equal 2, grouped[corr_id].length
    end

    def test_detect_pii
      event = create_event_with_attributes(email: "user@example.com", name: "Alice")

      pii = @event_flow.send(:detect_pii, event)

      if PAM_DSL_AVAILABLE
        assert pii.key?(:email)
        assert pii.key?(:name)
      else
        # Without PAM DSL, detect_pii returns empty hash
        assert_equal({}, pii)
      end
    end

    def test_detect_pii_includes_vat_number
      event = create_event_with_attributes(vat_number: "EL123456789", email: "test@test.com")

      pii = @event_flow.send(:detect_pii, event)

      if PAM_DSL_AVAILABLE
        assert pii.key?(:vat_number), "vat_number should be detected as PII"
        assert_equal :identifier, pii[:vat_number][:type]
      else
        assert_equal({}, pii)
      end
    end

    def test_detect_pii_includes_afm
      event = create_event_with_attributes(afm: "123456789")

      pii = @event_flow.send(:detect_pii, event)

      if PAM_DSL_AVAILABLE
        assert pii.key?(:afm), "afm (Greek tax number) should be detected as PII"
        assert_equal :identifier, pii[:afm][:type]
      else
        assert_equal({}, pii)
      end
    end

    def test_has_pii
      event_with_pii = create_event_with_attributes(email: "user@example.com")
      event_without_pii = create_event_with_attributes(id: 123)

      if PAM_DSL_AVAILABLE
        assert @event_flow.send(:has_pii?, event_with_pii)
        refute @event_flow.send(:has_pii?, event_without_pii)
      else
        # Without PAM DSL, has_pii? always returns false
        refute @event_flow.send(:has_pii?, event_with_pii)
        refute @event_flow.send(:has_pii?, event_without_pii)
      end
    end

    def test_event_summary
      event = create_event(operation: :created)

      summary = @event_flow.send(:event_summary, event)

      assert summary.key?(:event_id)
      assert summary.key?(:timestamp)
      assert_equal :created, summary[:operation]
      assert summary.key?(:has_pii)
    end

    def test_identify_pii_changes
      old_state = { name: "Alice", email: "alice@old.com", count: 5 }
      new_state = { name: "Alice", email: "alice@new.com", count: 10 }

      changes = @event_flow.send(:identify_pii_changes, old_state, new_state)

      if PAM_DSL_AVAILABLE
        assert changes.key?(:email)
        assert_equal "alice@old.com", changes[:email][:from]
        assert_equal "alice@new.com", changes[:email][:to]
        refute changes.key?(:count) # Not PII
      else
        # Without PAM DSL, identify_pii_changes returns empty hash
        assert_equal({}, changes)
      end
    end

    def test_calculate_flow_privacy_impact
      events = [
        create_event_with_attributes(email: "user@example.com"),
        create_event_with_attributes(name: "Bob"),
        create_event_with_attributes(count: 42)
      ]

      impact = @event_flow.send(:calculate_flow_privacy_impact, events)

      if PAM_DSL_AVAILABLE
        assert_equal 2, impact[:events_with_pii]
        assert_equal 66.67, impact[:percentage]
        assert impact[:pii_types].include?(:email)
        assert impact[:pii_types].include?(:name)
      else
        # Without PAM DSL, no PII is detected
        assert_equal 0, impact[:events_with_pii]
        assert_equal 0, impact[:percentage]
        assert_empty impact[:pii_types]
      end
    end

    def test_calculate_overall_risk_low
      risk_factors = []

      risk = @event_flow.send(:calculate_overall_risk, risk_factors)

      assert_equal :low, risk
    end

    def test_calculate_overall_risk_high
      risk_factors = [{ level: :high, reason: "Contains sensitive PII" }]

      risk = @event_flow.send(:calculate_overall_risk, risk_factors)

      assert_equal :high, risk
    end

    def test_calculate_overall_risk_medium
      risk_factors = [{ level: :medium, reason: "Many PII fields" }]

      risk = @event_flow.send(:calculate_overall_risk, risk_factors)

      assert_equal :medium, risk
    end

    def test_generate_recommendations_for_sensitive_data
      risk_factors = [{ level: :high, reason: "Contains sensitive PII" }]

      recommendations = @event_flow.send(:generate_recommendations, risk_factors)

      assert recommendations.any? { |r| r.include?("encryption") }
      assert recommendations.any? { |r| r.include?("audit logging") }
      assert recommendations.any? { |r| r.include?("GDPR") }
    end

    def test_generate_recommendations_for_modifications
      risk_factors = [{ level: :medium, reason: "Frequent modifications detected" }]

      recommendations = @event_flow.send(:generate_recommendations, risk_factors)

      assert recommendations.any? { |r| r.include?("retention") }
      assert recommendations.any? { |r| r.include?("approval workflows") }
    end

    class FlowTestWidget; end

    def test_crud_to_event_mapping_accepts_a_class_or_its_name
      events = [
        create_event(model_class: FlowTestWidget.name, model_id: 5),
        create_event(model_class: FlowTestWidget.name, model_id: 6),
        create_event(model_class: "Other", model_id: 5)
      ]
      @event_flow.stubs(:load_events).returns(events)

      by_class = @event_flow.crud_to_event_mapping(FlowTestWidget, :created)
      by_name = @event_flow.crud_to_event_mapping(FlowTestWidget.name, :created)

      assert_equal 2, by_class[:count]
      assert_equal 2, by_name[:count]
      assert_equal FlowTestWidget.name, by_class[:crud_operation][:model]
      # A request passes the id and operation as strings.
      assert_equal 1, @event_flow.crud_to_event_mapping(FlowTestWidget, "created", "5")[:count]
    end

    def test_data_lineage_accepts_a_class
      event = create_event_with_attributes(email: "a@example.com")
      event.data[:model_class] = FlowTestWidget.name
      @event_flow.stubs(:load_events).returns([event])

      lineage = @event_flow.data_lineage(:email, FlowTestWidget)

      assert_equal 1, lineage[:total_modifications]
      assert_equal FlowTestWidget.name, lineage[:model_class]
    end

    private

    def create_test_events(count)
      count.times.map { |i| create_event(model_id: i) }
    end

    def create_event(operation: :created, model_class: "TestModel", model_id: 1, timestamp: Time.current, correlation_id: nil)
      Event.new(
        data: {
          model_class: model_class,
          model_id: model_id,
          operation: operation,
          attributes: {},
          changes: {},
          timestamp: timestamp
        },
        metadata: {
          correlation_id: correlation_id,
          user_id: "user-123"
        }
      )
    end

    def create_event_with_attributes(attributes)
      Event.new(
        data: {
          model_class: "TestModel",
          model_id: 1,
          operation: :created,
          attributes: attributes,
          changes: {},
          timestamp: Time.current
        },
        metadata: {}
      )
    end
  end
end
