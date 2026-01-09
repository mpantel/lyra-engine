# frozen_string_literal: true

require "test_helper"

module PetriFlow
  module Verification
    class ReachabilityAnalyzerTest < Minitest::Test
      # ===========================================
      # P/T Abstraction Tests
      # ===========================================

      def test_pt_abstraction_ignores_guards
        # Create a net with guards that would block without proper data
        net = PetriFlow.create_net(name: "Guarded Net")

        p_input = net.add_place(id: :input, initial_tokens: 1)
        p_output = net.add_place(id: :output)

        # Add a transition with a guard that checks for :active context
        guard = ->(ctx) { ctx[:active] == true }
        net.add_transition(id: :t_with_guard, guard: guard)

        net.add_arc(source_id: :input, target_id: :t_with_guard)
        net.add_arc(source_id: :t_with_guard, target_id: :output)

        # Without P/T abstraction, guard blocks (no :active in context)
        analyzer_cpn = ReachabilityAnalyzer.new(net, pt_abstraction: false)
        analyzer_cpn.analyze
        assert_equal 1, analyzer_cpn.reachable_markings.size, "CPN mode should have 1 state (guard blocks)"

        # Reset
        net.set_marking(net.current_marking)
        p_input.instance_variable_set(:@tokens, 1)
        p_output.instance_variable_set(:@tokens, 0)

        # With P/T abstraction, guard is ignored
        analyzer_pt = ReachabilityAnalyzer.new(net, pt_abstraction: true)
        analyzer_pt.analyze
        assert_equal 2, analyzer_pt.reachable_markings.size, "P/T mode should have 2 states (initial + after firing)"
      end

      def test_pt_abstraction_attribute_accessible
        net = PetriFlow.create_net(name: "Test Net")

        analyzer_false = ReachabilityAnalyzer.new(net, pt_abstraction: false)
        assert_equal false, analyzer_false.pt_abstraction

        analyzer_true = ReachabilityAnalyzer.new(net, pt_abstraction: true)
        assert_equal true, analyzer_true.pt_abstraction
      end

      def test_report_includes_pt_abstraction_flag
        net = PetriFlow.create_net(name: "Test Net")
        net.add_place(id: :p1, initial_tokens: 1)

        analyzer = ReachabilityAnalyzer.new(net, pt_abstraction: true)
        analyzer.analyze

        report = analyzer.report
        assert_includes report.keys, :pt_abstraction
        assert_equal true, report[:pt_abstraction]
      end

      def test_petriflow_verify_with_pt_abstraction
        net = PetriFlow.create_net(name: "Guarded Net")

        net.add_place(id: :input, initial_tokens: 1)
        net.add_place(id: :output)

        guard = ->(ctx) { ctx[:operation] == :create }
        net.add_transition(id: :t_guarded, guard: guard)

        net.add_arc(source_id: :input, target_id: :t_guarded)
        net.add_arc(source_id: :t_guarded, target_id: :output)

        # Without P/T abstraction - guard blocks
        results_cpn = PetriFlow.verify(net, pt_abstraction: false)
        assert_equal 1, results_cpn[:reachability][:total_reachable_states]
        assert_equal false, results_cpn[:reachability][:pt_abstraction]

        # Reset net
        net.place(:input).instance_variable_set(:@tokens, 1)
        net.place(:output).instance_variable_set(:@tokens, 0)

        # With P/T abstraction - guard ignored
        results_pt = PetriFlow.verify(net, pt_abstraction: true)
        assert_equal 2, results_pt[:reachability][:total_reachable_states]
        assert_equal true, results_pt[:reachability][:pt_abstraction]
      end

      # ===========================================
      # CRUD-to-Event Model Tests (from paper)
      # ===========================================

      def test_crud_event_model_pt_abstraction
        # Recreate the formal model from the paper
        net = PetriFlow.create_colored_net(name: "CRUD_to_Event")

        # Token colors
        net.add_color(:crud_token, attributes: {
          operation: :symbol,
          model_class: :string,
          model_id: :integer,
          attributes: :hash
        })

        net.add_color(:event_token, attributes: {
          event_type: :string,
          event_id: :string,
          data: :hash,
          metadata: :hash
        })

        # Places
        net.add_colored_place(id: :p_crud, color: :crud_token)
        net.add_colored_place(id: :p_event, color: :event_token)
        net.add_colored_place(id: :p_published, color: :event_token)
        net.add_colored_place(id: :p_aggregate, color: :event_token)

        # Guards
        guard_create = PetriFlow::Colored::Guard.new { |ctx| ctx[:operation] == :create }
        guard_update = PetriFlow::Colored::Guard.new { |ctx| ctx[:operation] == :update }
        guard_delete = PetriFlow::Colored::Guard.new { |ctx| ctx[:operation] == :delete }

        # Transitions with guards
        net.add_transition(id: :t_create, guard: guard_create)
        net.add_transition(id: :t_update, guard: guard_update)
        net.add_transition(id: :t_delete, guard: guard_delete)
        net.add_transition(id: :t_publish)
        net.add_transition(id: :t_apply)

        # Arcs
        net.add_arc(source_id: :p_crud, target_id: :t_create)
        net.add_arc(source_id: :p_crud, target_id: :t_update)
        net.add_arc(source_id: :p_crud, target_id: :t_delete)
        net.add_arc(source_id: :t_create, target_id: :p_event)
        net.add_arc(source_id: :t_update, target_id: :p_event)
        net.add_arc(source_id: :t_delete, target_id: :p_event)
        net.add_arc(source_id: :p_event, target_id: :t_publish)
        net.add_arc(source_id: :t_publish, target_id: :p_published)
        net.add_arc(source_id: :p_published, target_id: :t_apply)
        net.add_arc(source_id: :t_apply, target_id: :p_aggregate)

        # Initial token
        net.place(:p_crud).add_tokens(1)

        # Without P/T abstraction: only 1 state (guards block without token data)
        results_cpn = PetriFlow.verify(net, pt_abstraction: false)
        assert_equal 1, results_cpn[:reachability][:total_reachable_states],
                     "CPN mode should have 1 state (guards block)"

        # Reset
        net.place(:p_crud).instance_variable_set(:@tokens, 1)
        net.place(:p_event).instance_variable_set(:@tokens, 0)
        net.place(:p_published).instance_variable_set(:@tokens, 0)
        net.place(:p_aggregate).instance_variable_set(:@tokens, 0)

        # With P/T abstraction: full state space (4 states)
        results_pt = PetriFlow.verify(net, pt_abstraction: true)
        assert_equal 4, results_pt[:reachability][:total_reachable_states],
                     "P/T mode should have 4 states (initial + after each transition in sequence)"
        assert results_pt[:boundedness][:is_bounded]
        assert results_pt[:boundedness][:is_safe]
      end

      # ===========================================
      # Transition#enabled? with ignore_guards
      # ===========================================

      def test_transition_enabled_with_ignore_guards
        net = PetriFlow.create_net(name: "Test")
        net.add_place(id: :p1, initial_tokens: 1)
        net.add_place(id: :p2)

        guard = ->(ctx) { ctx[:approved] == true }
        transition = net.add_transition(id: :t1, guard: guard)

        net.add_arc(source_id: :p1, target_id: :t1)
        net.add_arc(source_id: :t1, target_id: :p2)

        # Without ignore_guards, guard blocks
        refute transition.enabled?({}), "Should not be enabled without context"
        refute transition.enabled?({ approved: false }), "Should not be enabled with wrong context"
        assert transition.enabled?({ approved: true }), "Should be enabled with correct context"

        # With ignore_guards, guard is skipped
        assert transition.enabled?({ ignore_guards: true }), "Should be enabled with ignore_guards"
        assert transition.enabled?({ ignore_guards: true, approved: false }), "ignore_guards should override guard"
      end
    end
  end
end
