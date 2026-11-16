# frozen_string_literal: true

require "test_helper"

module Lyra
  module Verification
    # The data lifecycle net with its Restricted place (Art. 18), and the
    # objection net (Art. 21): explored by PetriFlow, and matched against
    # the transitions PAM DSL's code allows (PamDsl::Rights.project).
    class RightsWorkflowsTest < Minitest::Test
      def setup
        skip "PetriFlow not available" unless PETRI_FLOW_AVAILABLE
        skip "PAM DSL not available" unless Lyra.pam_dsl_available?
      end

      # ── The data lifecycle with D_R ──

      def test_the_data_lifecycle_net_is_safe_and_ends_in_deleted_or_anonymized
        workflow = DataLifecycleWorkflow.new
        results = workflow.verify!

        assert results[:boundedness][:is_safe]
        assert results[:liveness][:terminates_properly], "no marking is stuck outside Deleted and Anonymized"
        assert workflow.terminal_reachability[:deleted]
        assert workflow.terminal_reachability[:anonymized]
        %i[restricted restricted_retained lift_notified lift_notified_retained].each do |place|
          assert reachable?(workflow, :active, place), "#{place} is reachable"
        end
      end

      # From Restricted, the only way out is the notice and then the lift,
      # back to where the data came from: d2, d3 and d4 are not enabled there.
      def test_deleted_is_unreachable_from_restricted_without_notice_and_lift
        without_lift = DataLifecycleWorkflow.new.net.tap do |net|
          DataLifecycleWorkflow.lift_transitions.each { |id| net.transitions.delete(id) }
        end
        %i[restricted restricted_retained lift_notified lift_notified_retained].each do |place|
          refute reachable_in?(without_lift, place, :deleted), "Deleted from #{place} without a lift"
          refute reachable_in?(without_lift, place, :anonymized), "Anonymized from #{place} without a lift"
        end

        workflow = DataLifecycleWorkflow.new
        assert reachable?(workflow, :restricted, :deleted), "after notice and lift, erasure is possible again"
        assert_equal %i[lift_notified], posts(:restricted), "from Restricted only the notice"
        assert_equal %i[active], posts(:lift_notified), "the lift returns the data to Active"
        assert_equal %i[lift_notified_retained], posts(:restricted_retained)
        assert_equal %i[retained], posts(:lift_notified_retained), "and Retained data to Retained"
      end

      # The restriction's states in the code (active, lift_notified, lifted)
      # and its steps (PamDsl::Rights.project, which refuses any other) are
      # the net's: restrict, notify_lift, lift.
      def test_the_code_s_restriction_transitions_are_the_net_s
        code = explore(:restriction)
        net = DataLifecycleWorkflow.restriction_steps

        assert_equal net, code
      end

      def test_the_code_s_objection_transitions_are_the_net_s
        workflow = ObjectionWorkflow.new
        results = workflow.verify!
        assert results[:boundedness][:is_safe]
        assert results[:liveness][:terminates_properly]
        %i[overridden withdrawn rejected].each { |place| assert workflow.terminal_reachability[place], place }

        assert_equal ObjectionWorkflow.steps, explore(:objection)
      end

      # The objection with its 18(1)(d) restriction: the decision ends the
      # restriction, without a notice when upheld or withdrawn, with one
      # when overridden. The code's steps over both requests are the net's.
      def test_the_code_s_objection_with_its_restriction_is_the_net_s
        workflow = ObjectionRestrictionWorkflow.new
        results = workflow.verify!
        assert results[:boundedness][:is_safe]
        assert results[:liveness][:terminates_properly]

        assert_equal workflow.steps.sort_by(&:to_s), explore_pair.sort_by(&:to_s)
      end

      # And the other direction: what the nets do not allow, the code refuses.
      def test_the_code_refuses_a_step_before_its_request_and_a_request_twice
        key = "Explore$1"
        build = ->(type, data = {}) { PamDsl::Rights::Event.new(type: type, request_id: "x", subject_key: key, data: data, at: Time.now, recorded_at: Time.now, recorded_by: nil) }
        (PamDsl::Rights::EVENT_TYPES - %w[ProcessingRestricted ObjectionReceived]).each do |type|
          assert_raises(PamDsl::RightsTransitionError, "#{type} with nothing recorded") { PamDsl::Rights.project([build.(type)]) }
        end
        restricted = build.("ProcessingRestricted", event_data("ProcessingRestricted"))
        received = build.("ObjectionReceived", event_data("ObjectionReceived"))
        assert_raises(PamDsl::RightsTransitionError) { PamDsl::Rights.project([restricted, restricted]) }
        assert_raises(PamDsl::RightsTransitionError) { PamDsl::Rights.project([received, received]) }
      end

      private

      # Every step the code allows over an objection ("o") and its 18(1)(d)
      # restriction ("r"), from no request, as
      # { [[objection state, restriction state], event type] => states after }.
      def explore_pair
        key = "Explore$1"
        types = %w[ObjectionReceived ProcessingRestricted ObjectionUpheld ObjectionOverridden ObjectionWithdrawn
                   RestrictionLiftNotified RestrictionLifted]
        data = {
          "ObjectionReceived" => { policy: :p, purpose: :u, article: "Art. 21(1)", restriction_id: "r" },
          "ProcessingRestricted" => { ground: :objection_pending, fields: [], policy: :p, purpose: :u, objection_id: "o" }
        }
        id_of = ->(type) { type.start_with?("Objection") ? "o" : "r" }
        state = lambda do |events|
          requests = PamDsl::Rights.project(events)
          %w[o r].map { |id| requests.find { _1.id == id }&.state || :none }
        end
        steps = {}
        frontier = [[]]
        seen = {}
        until frontier.empty?
          events = frontier.shift
          now = state.(events)
          next if seen[now]

          seen[now] = true
          types.each do |type|
            event = PamDsl::Rights::Event.new(type: type, request_id: id_of.(type), subject_key: key,
                                              data: data.fetch(type, {}), at: Time.now, recorded_at: Time.now,
                                              recorded_by: nil)
            after = begin
              state.(events + [event])
            rescue PamDsl::RightsTransitionError
              next
            end
            steps[[now, type]] = after
            frontier << events + [event]
          end
        end
        steps
      end

      def posts(place)
        DataLifecycleWorkflow.defined_transitions.select { _1[:from] == [place] }.flat_map { _1[:to] }
      end

      def reachable?(workflow, from, to)
        reachable_in?(workflow.net, from, to)
      end

      def reachable_in?(net, from, to)
        marking = PetriFlow::Core::Marking.new(net.places.keys.to_h { [_1, _1 == from ? 1 : 0] })
        analyzer = PetriFlow::Verification::ReachabilityAnalyzer.new(net, marking)
        analyzer.analyze
        analyzer.reachable_markings.any? { _1.tokens_at(to).positive? }
      end

      # Every step the code allows from every state it reaches, as
      # { [state, event type] => state }, found by trying each event type
      # in each state and keeping those Rights.project accepts.
      def explore(kind)
        key = "Explore$1"
        id = "r-1"
        types = kind == :restriction ? %w[ProcessingRestricted RestrictionLiftNotified RestrictionLifted] :
                                       PamDsl::Rights::EVENT_TYPES.grep(/Objection/)
        start = kind == :restriction ? "ProcessingRestricted" : "ObjectionReceived"
        steps = {}
        frontier = [[]]
        seen = {}
        until frontier.empty?
          events = frontier.shift
          state = state_after(events, id) || :none
          next if seen[state]

          seen[state] = true
          types.each do |type|
            next if type == start && !events.empty?
            next if type != start && events.empty?

            event = PamDsl::Rights::Event.new(type: type, request_id: id, subject_key: key,
                                              data: event_data(type), at: Time.now, recorded_at: Time.now,
                                              recorded_by: nil)
            after = begin
              state_after(events + [event], id)
            rescue PamDsl::RightsTransitionError
              next
            end
            steps[[state, type]] = after
            frontier << events + [event]
          end
        end
        steps
      end

      def state_after(events, id)
        return nil if events.empty?

        PamDsl::Rights.project(events).find { _1.id == id }&.state
      end

      def event_data(type)
        case type
        when "ProcessingRestricted" then { ground: :accuracy_contested, fields: [] }
        when "ObjectionReceived" then { policy: :p, purpose: :u, article: "Art. 21(1)" }
        else {}
        end
      end
    end
  end
end
