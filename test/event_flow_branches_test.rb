# frozen_string_literal: true

require "test_helper"

module Lyra
  # Lyra::EventFlow: a record's state rebuilt from its stream (create, update,
  # destroy), the privacy impact analysis of the events read, and events
  # that are plain RubyEventStore events (no Lyra::Event readers) read from
  # their data as Lyra's own are.
  class EventFlowBranchesTest < Minitest::Test
    def setup
      Lyra.config.event_store = RubyEventStore::Client.new(repository: RubyEventStore::InMemoryRepository.new)
      @flow = EventFlow.new
    end

    # ── reconstruct_state_chain ──

    def test_the_state_chain_follows_create_update_and_destroy
      t0 = 3.hours.ago
      publish("FlowWidget$9", event(:created, attributes: { "name" => "Ann", "email" => "a@example.com" }, at: t0))
      publish("FlowWidget$9", event(:updated, changes: { "email" => ["a@example.com", "b@example.com"] }, at: t0 + 60))
      publish("FlowWidget$9", event(:destroyed, at: t0 + 120))

      chain = @flow.reconstruct_state_chain("FlowWidget", 9)

      assert_equal 3, chain[:events_count]
      assert_equal %i[created updated destroyed], chain[:state_evolution].map { _1[:operation] }
      updated = chain[:state_evolution][1]
      assert_equal "a@example.com", updated[:previous_state]["email"]
      assert_equal "b@example.com", updated[:new_state]["email"]
      if Lyra.privacy_features_available?
        assert_equal({ "email" => { from: "a@example.com", to: "b@example.com" } }, updated[:pii_changed])
      end
      final = chain[:final_state]
      assert_equal ["Ann", "b@example.com", true], final.values_at("name", "email", :_deleted)
      assert_in_delta (t0 + 120).to_f, final[:_deleted_at].to_f, 0.001
    end

    # ── privacy_impact_analysis ──

    def test_privacy_impact_of_events_with_personal_data
      skip "Requires pam_dsl" unless Lyra.privacy_features_available?

      events = [
        event(:created, attributes: { "email" => "a@example.com", "title" => "x" }),
        event(:updated, changes: { "email" => ["a@example.com", "b@example.com"] }),
        event(:updated, changes: { "title" => %w[x y] }),
        event(:destroyed, attributes: { "email" => "b@example.com" })
      ]
      @flow.stubs(:load_events).returns(events)

      impact = @flow.privacy_impact_analysis

      assert_equal 4, impact[:total_events]
      assert_equal 3, impact[:events_with_pii]
      assert_includes impact[:pii_categories], :email
      assert_equal 3, impact[:pii_fields_count]
      assert_equal %i[updated destroyed], impact[:sensitive_operations].map { _1[:operation] }
      assert_equal %i[created updated destroyed], impact[:data_flows][:email].map { _1[:operation] }
      assert_equal "FlowWidget", impact[:data_flows][:email].first[:source_model]
      assert_equal({ overall_risk: :low, factors: [], recommendations: [] }, impact[:risk_assessment])
    end

    def test_the_risk_grows_with_sensitive_data_many_fields_and_frequent_changes
      skip "Requires pam_dsl" unless Lyra.privacy_features_available?

      sensitive = [event(:created, attributes: { "credit_card" => "4111111111111111" })]
      @flow.stubs(:load_events).returns(sensitive)
      high = @flow.privacy_impact_analysis[:risk_assessment]
      assert_equal :high, high[:overall_risk]
      assert_includes high[:recommendations], "Implement field-level encryption for sensitive PII"

      many = Array.new(51) { |i| event(:updated, changes: { "email" => ["#{i}@a.example", "#{i}@b.example"] }) }
      @flow.stubs(:load_events).returns(many)
      medium = @flow.privacy_impact_analysis[:risk_assessment]
      assert_equal :medium, medium[:overall_risk]
      assert_equal ["Large number of PII fields", "Frequent PII modifications"], medium[:factors].map { _1[:reason] }
      assert_includes medium[:recommendations], "Implement change approval workflows"
      assert_includes medium[:recommendations], "Regular GDPR compliance audits recommended"
    end

    # ── Plain RubyEventStore events ──

    # An event without Lyra::Event's readers is read from its data (string
    # keys, as the JSON serializer leaves them, and a string operation and
    # time), with the same answer as the Lyra::Event it stands for.
    def test_plain_events_are_read_from_their_data
      at = 1.hour.ago.change(usec: 0)
      lyra = event(:updated, changes: { "title" => %w[a b] }, at: at)
      plain = RubyEventStore::Event.new(
        event_id: lyra.event_id,
        data: { "model_class" => "FlowWidget", "model_id" => 4, "operation" => "updated",
                "changes" => { "title" => %w[a b] }, "timestamp" => at.iso8601 },
        metadata: {}
      )
      lyra.data[:model_id] = 4

      from_plain = @flow.build_timeline([plain]).first
      from_lyra = @flow.build_timeline([lyra]).first

      %i[operation model_class model_id changes].each do |key|
        assert_equal from_lyra[key], from_plain[key], key
      end
      assert_equal at, Time.zone.parse(from_plain[:timestamp])
      @flow.stubs(:load_events).returns([plain])
      assert_equal 1, @flow.crud_to_event_mapping("FlowWidget", "updated", "4")[:count]
    end

    # A plain event whose time is only in its metadata.
    def test_a_plain_event_s_time_may_be_in_its_metadata
      at = 2.hours.ago
      plain = RubyEventStore::Event.new(data: { "operation" => "created" }, metadata: { timestamp: at })

      assert_equal at, @flow.build_timeline([plain]).first[:timestamp]
    end

    # Events stored with string times are filtered by the time range as
    # times, and the hours counted as theirs.
    def test_string_timestamps_are_read_as_times
      inside = event(:created, at: 2.days.ago)
      inside.data[:timestamp] = inside.data[:timestamp].iso8601
      outside = event(:created, at: 40.days.ago)
      outside.data[:timestamp] = outside.data[:timestamp].iso8601
      Lyra::EventWindow.stubs(:recent).returns([[outside, inside], { limit: 10, returned: 2, truncated: false }])

      data = @flow.flow_data

      assert_equal [inside.event_id], data[:timeline].map { _1[:event_id] }
      assert_equal({ Time.parse(inside.data[:timestamp]).hour => 1 }, data[:statistics][:hourly_distribution])
    end

    # ── Lineage and mapping without matches ──

    def test_a_field_never_written_has_no_lineage
      @flow.stubs(:load_events).returns([event(:created, attributes: { "title" => "x" })])

      lineage = @flow.data_lineage(:email)

      assert_equal 0, lineage[:total_modifications]
      assert_nil lineage[:first_seen]
      assert_nil lineage[:last_modified]
    end

    def test_a_mapping_without_an_operation_matches_nothing
      @flow.stubs(:load_events).returns([event(:created)])

      mapping = @flow.crud_to_event_mapping("FlowWidget", nil)

      assert_equal 0, mapping[:count]
      assert_nil mapping[:crud_operation][:operation]
    end

    private

    def event(operation, attributes: {}, changes: {}, at: Time.current)
      Lyra::Event.new(
        data: { model_class: "FlowWidget", model_id: 9, operation: operation, attributes: attributes,
                changes: changes, timestamp: at },
        metadata: {}
      )
    end

    def publish(stream, event)
      Lyra.config.event_store.publish(event, stream_name: stream)
    end
  end
end
