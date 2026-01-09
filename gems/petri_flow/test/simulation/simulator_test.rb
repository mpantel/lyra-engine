# frozen_string_literal: true

require "test_helper"

module PetriFlow
  module Simulation
    class SimulatorTest < Minitest::Test
      def setup
        Registry.clear
        @net = create_test_net
        @simulator = Simulator.new(@net)
      end

      def teardown
        Registry.clear
      end

      # ===========================================
      # Helper to create a test Petri net
      # ===========================================

      def create_test_net
        net = Core::Net.new(name: "test_net")

        # Simple sequential net: p1 -> t1 -> p2 -> t2 -> p3
        net.add_place(id: :p1, initial_tokens: 2)
        net.add_place(id: :p2, initial_tokens: 0)
        net.add_place(id: :p3, initial_tokens: 0)

        net.add_transition(id: :t1, name: "step1")
        net.add_transition(id: :t2, name: "step2")

        net.add_arc(source_id: :p1, target_id: :t1)
        net.add_arc(source_id: :t1, target_id: :p2)
        net.add_arc(source_id: :p2, target_id: :t2)
        net.add_arc(source_id: :t2, target_id: :p3)

        net
      end

      # ===========================================
      # Initialization Tests
      # ===========================================

      def test_initialization
        assert_equal @net, @simulator.net
        assert_instance_of Trace, @simulator.trace
        assert_equal 0, @simulator.current_step
      end

      # ===========================================
      # Run Tests
      # ===========================================

      def test_run_executes_transitions
        trace = @simulator.run(steps: 10)

        assert_instance_of Trace, trace
        assert trace.steps > 0
      end

      def test_run_stops_when_no_transitions_enabled
        trace = @simulator.run(steps: 100)

        # With 2 initial tokens, can fire t1 twice, then t2 twice
        # After that, deadlock (no more tokens in p1 or p2)
        assert_equal 4, trace.steps
        assert_equal 2, @net.place(:p3).tokens
      end

      def test_run_respects_max_steps
        trace = @simulator.run(steps: 2)

        assert_equal 2, trace.steps
      end

      def test_run_with_random_strategy
        trace = @simulator.run(steps: 10, strategy: :random)

        assert_instance_of Trace, trace
      end

      def test_run_with_first_strategy
        trace = @simulator.run(steps: 10, strategy: :first)

        assert_instance_of Trace, trace
        assert trace.steps > 0
      end

      def test_run_records_initial_marking
        trace = @simulator.run(steps: 1)

        refute_nil trace.initial_marking
        assert_equal 2, trace.initial_marking.tokens_at(:p1)
      end

      # ===========================================
      # Step Tests
      # ===========================================

      def test_step_fires_one_transition
        initial_p1 = @net.place(:p1).tokens

        transition = @simulator.step

        refute_nil transition
        assert_equal initial_p1 - 1, @net.place(:p1).tokens
      end

      def test_step_increments_current_step
        assert_equal 0, @simulator.current_step

        @simulator.step
        assert_equal 1, @simulator.current_step

        @simulator.step
        assert_equal 2, @simulator.current_step
      end

      def test_step_with_specific_transition
        transition = @simulator.step(:t1)

        assert_equal :t1, transition.id
        assert_equal 1, @net.place(:p1).tokens
        assert_equal 1, @net.place(:p2).tokens
      end

      def test_step_returns_nil_when_no_transitions_enabled
        # Exhaust all transitions
        @simulator.run(steps: 100)

        result = @simulator.step

        assert_nil result
      end

      def test_step_raises_for_unknown_transition
        assert_raises(RuntimeError) do
          @simulator.step(:nonexistent)
        end
      end

      def test_step_raises_for_disabled_transition
        # t2 is not enabled initially (p2 is empty)
        assert_raises(RuntimeError) do
          @simulator.step(:t2)
        end
      end

      # ===========================================
      # Run Until Tests
      # ===========================================

      def test_run_until_condition_met
        trace = @simulator.run_until do |marking, _net|
          marking.tokens_at(:p2) >= 1
        end

        assert trace.steps >= 1
        assert @net.place(:p2).tokens >= 1
      end

      def test_run_until_respects_max_steps
        trace = @simulator.run_until(max_steps: 2) do |_marking, _net|
          false # Never satisfied
        end

        assert_equal 2, trace.steps
      end

      def test_run_until_stops_on_deadlock
        trace = @simulator.run_until(max_steps: 100) do |_marking, _net|
          false # Never satisfied
        end

        # Should stop at 4 steps (deadlock)
        assert_equal 4, trace.steps
      end

      # ===========================================
      # Reset Tests
      # ===========================================

      def test_reset_clears_trace
        @simulator.run(steps: 2)
        assert @simulator.trace.steps > 0

        @simulator.reset

        assert_equal 0, @simulator.current_step
        # Trace is cleared but has initial marking recorded
        assert_equal 0, @simulator.trace.steps
      end

      def test_reset_with_custom_marking
        custom_marking = Core::Marking.new
        custom_marking.set_tokens(:p1, 5)
        custom_marking.set_tokens(:p2, 0)
        custom_marking.set_tokens(:p3, 0)

        @simulator.reset(custom_marking)

        assert_equal 5, @net.place(:p1).tokens
      end

      # ===========================================
      # Run Multiple (Monte Carlo) Tests
      # ===========================================

      def test_run_multiple_returns_analysis
        result = @simulator.run_multiple(runs: 5, steps: 10)

        assert_equal 5, result[:total_runs]
        assert result[:average_steps] > 0
        assert result[:min_steps] > 0
        assert result[:max_steps] > 0
        assert_kind_of Hash, result[:transition_frequencies]
        assert_kind_of Integer, result[:state_coverage]
      end

      def test_run_multiple_resets_between_runs
        # After run_multiple, net should be back to initial state
        initial_tokens = @net.place(:p1).tokens

        @simulator.run_multiple(runs: 3, steps: 10)

        assert_equal initial_tokens, @net.place(:p1).tokens
      end
    end
  end
end
