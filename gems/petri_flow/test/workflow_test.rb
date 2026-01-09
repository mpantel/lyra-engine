# frozen_string_literal: true

require "test_helper"

module PetriFlow
  # Test workflow class for testing DSL
  class TestOrderWorkflow < Workflow
    workflow_name "Test Order Workflow"

    places :pending, :confirmed, :shipped, :delivered, :cancelled
    initial_place :pending
    terminal_places :delivered, :cancelled

    transition :confirm, from: :pending, to: :confirmed
    transition :ship, from: :confirmed, to: :shipped
    transition :deliver, from: :shipped, to: :delivered
    transition :cancel, from: :pending, to: :cancelled
    transition :cancel, from: :confirmed, to: :cancelled
  end

  # Workflow with unreachable state for testing detection
  class TestFlawedWorkflow < Workflow
    workflow_name "Test Flawed Workflow"

    places :start, :middle, :end, :orphan
    initial_place :start
    terminal_places :end, :orphan  # orphan has no incoming transitions

    transition :step1, from: :start, to: :middle
    transition :step2, from: :middle, to: :end
    # Missing: transition to :orphan
  end

  # Workflow with FORK pattern (parallel split)
  class TestForkWorkflow < Workflow
    workflow_name "Test Fork Workflow"

    places :start, :parallel_a, :parallel_b, :end_a, :end_b
    initial_place :start
    terminal_places :end_a, :end_b

    # Fork: one transition produces tokens in TWO places
    transition :fork, from: :start, to: [:parallel_a, :parallel_b]
    transition :complete_a, from: :parallel_a, to: :end_a
    transition :complete_b, from: :parallel_b, to: :end_b
  end

  # Workflow with JOIN pattern (synchronization)
  class TestJoinWorkflow < Workflow
    workflow_name "Test Join Workflow"

    places :start, :parallel_a, :parallel_b, :synchronized, :end
    initial_place :start
    terminal_places :end

    transition :fork, from: :start, to: [:parallel_a, :parallel_b]
    # Join: one transition consumes tokens from TWO places
    transition :join, from: [:parallel_a, :parallel_b], to: :synchronized
    transition :complete, from: :synchronized, to: :end
  end

  class WorkflowTest < Minitest::Test
    def setup
      # Clear registry to avoid test pollution
      Registry.clear
    end

    # ===========================================
    # DSL Class Method Tests
    # ===========================================

    def test_workflow_name_dsl
      assert_equal "Test Order Workflow", TestOrderWorkflow.defined_workflow_name
    end

    def test_places_dsl
      expected = [:pending, :confirmed, :shipped, :delivered, :cancelled]
      assert_equal expected, TestOrderWorkflow.defined_places
    end

    def test_initial_place_dsl
      assert_equal :pending, TestOrderWorkflow.defined_initial_place
    end

    def test_terminal_places_dsl
      expected = [:delivered, :cancelled]
      assert_equal expected, TestOrderWorkflow.defined_terminal_places
    end

    def test_transitions_dsl
      transitions = TestOrderWorkflow.defined_transitions
      assert_equal 5, transitions.size

      # Check first transition structure
      # Note: from/to are now arrays to support fork/join patterns
      confirm_transition = transitions.find { |t| t[:name] == :confirm }
      assert_equal [:pending], confirm_transition[:from]
      assert_equal [:confirmed], confirm_transition[:to]
      assert_equal "confirm!", confirm_transition[:method]
    end

    def test_transition_with_same_name_different_sources
      cancel_transitions = TestOrderWorkflow.defined_transitions.select { |t| t[:name] == :cancel }
      assert_equal 2, cancel_transitions.size

      # from/to are arrays, so extract first element for comparison
      sources = cancel_transitions.map { |t| t[:from].first }
      assert_includes sources, :pending
      assert_includes sources, :confirmed
    end

    # ===========================================
    # Instance Method Tests
    # ===========================================

    def test_workflow_initialization
      workflow = TestOrderWorkflow.new

      assert_instance_of PetriFlow::Core::Net, workflow.net
      assert_equal "Test Order Workflow", workflow.workflow_name
    end

    def test_workflow_id_generation
      workflow = TestOrderWorkflow.new
      assert_equal "test_order_workflow", workflow.workflow_id
    end

    def test_net_has_correct_places
      workflow = TestOrderWorkflow.new

      assert_equal 5, workflow.net.places.size
      assert workflow.net.places.key?(:pending)
      assert workflow.net.places.key?(:delivered)
    end

    def test_net_has_correct_transitions
      workflow = TestOrderWorkflow.new

      assert_equal 5, workflow.net.transitions.size
    end

    def test_initial_marking
      workflow = TestOrderWorkflow.new
      marking = workflow.initial_marking

      assert_equal 1, marking.tokens_at(:pending)
      assert_equal 0, marking.tokens_at(:confirmed)
      assert_equal 0, marking.tokens_at(:delivered)
    end

    def test_reset_to_initial
      workflow = TestOrderWorkflow.new

      # Fire a transition to change state
      workflow.net.fire_transition(:t_confirm_from_pending)

      # Reset
      workflow.reset_to_initial!

      # Should be back to initial state (use place.tokens, not net.tokens_at)
      assert_equal 1, workflow.net.place(:pending).tokens
      assert_equal 0, workflow.net.place(:confirmed).tokens
    end

    # ===========================================
    # Verification Tests
    # ===========================================

    def test_verify_returns_results
      workflow = TestOrderWorkflow.new
      results = workflow.verify!

      assert results.key?(:reachability)
      assert results.key?(:boundedness)
      assert results.key?(:liveness)
    end

    def test_verify_detects_reachable_states
      workflow = TestOrderWorkflow.new
      workflow.verify!

      assert_equal 5, workflow.verification_results[:reachability][:total_reachable_states]
    end

    def test_verify_detects_boundedness
      workflow = TestOrderWorkflow.new
      workflow.verify!

      assert workflow.verification_results[:boundedness][:is_bounded]
      assert workflow.verification_results[:boundedness][:is_safe]
    end

    def test_terminal_reachability_all_reachable
      workflow = TestOrderWorkflow.new
      workflow.verify!

      assert workflow.terminal_reachability[:delivered]
      assert workflow.terminal_reachability[:cancelled]
    end

    def test_terminal_reachability_detects_unreachable
      workflow = TestFlawedWorkflow.new
      workflow.verify!

      assert workflow.terminal_reachability[:end], "end should be reachable"
      refute workflow.terminal_reachability[:orphan], "orphan should be unreachable"
    end

    # ===========================================
    # Fork/Join Pattern Tests
    # ===========================================

    def test_fork_transition_creates_multiple_output_arcs
      workflow = TestForkWorkflow.new

      # The fork transition should have 2 output arcs
      fork_transition = workflow.class.defined_transitions.find { |t| t[:name] == :fork }
      assert_equal [:parallel_a, :parallel_b], fork_transition[:to]
    end

    def test_fork_workflow_both_terminals_reachable
      workflow = TestForkWorkflow.new
      workflow.verify!

      # Both terminal states should be reachable via the fork
      assert workflow.terminal_reachability[:end_a], "end_a should be reachable"
      assert workflow.terminal_reachability[:end_b], "end_b should be reachable"
    end

    def test_fork_mermaid_shows_parallel_arrows
      workflow = TestForkWorkflow.new
      mermaid = workflow.to_mermaid

      # Fork transition should have arrows to both parallel places
      assert_includes mermaid, "t_fork_from_start"
      assert_includes mermaid, "parallel_a"
      assert_includes mermaid, "parallel_b"

      # Count arrows from fork transition (should be 2)
      fork_arrows = mermaid.scan(/t_fork_from_start.*-->.*parallel/).count
      assert_equal 2, fork_arrows, "Fork should have 2 output arrows"
    end

    def test_join_transition_creates_multiple_input_arcs
      workflow = TestJoinWorkflow.new

      # The join transition should have 2 input arcs
      join_transition = workflow.class.defined_transitions.find { |t| t[:name] == :join }
      assert_equal [:parallel_a, :parallel_b], join_transition[:from]
    end

    def test_join_workflow_terminal_reachable
      workflow = TestJoinWorkflow.new
      workflow.verify!

      # Terminal state should be reachable after join
      assert workflow.terminal_reachability[:end], "end should be reachable after join"
    end

    def test_join_mermaid_shows_synchronization_arrows
      workflow = TestJoinWorkflow.new
      mermaid = workflow.to_mermaid

      # Join transition should have arrows from both parallel places
      assert_includes mermaid, "t_join_from_parallel_a"

      # Both parallel places should connect to the join
      assert_includes mermaid, "parallel_a --> t_join"
      assert_includes mermaid, "parallel_b --> t_join"
    end

    # ===========================================
    # Pattern Label Tests (Fork ∥ / Choice ⊕)
    # ===========================================

    def test_fork_mermaid_shows_parallel_symbol
      workflow = TestForkWorkflow.new
      mermaid = workflow.to_mermaid

      # Fork transition should show ∥ symbol on output arcs
      assert_includes mermaid, "∥", "Fork should show parallel symbol ∥"
    end

    def test_fork_dot_shows_parallel_symbol
      workflow = TestForkWorkflow.new
      dot = workflow.to_dot

      # Fork transition should show ∥ symbol on output arcs
      assert_includes dot, "∥", "Fork should show parallel symbol ∥ in DOT"
    end

    def test_choice_mermaid_shows_xor_symbol
      # TestOrderWorkflow has choice at pending (confirm OR cancel)
      # and at confirmed (ship OR cancel)
      workflow = TestOrderWorkflow.new
      mermaid = workflow.to_mermaid

      # Should show ⊕ symbol for choice patterns
      assert_includes mermaid, "⊕", "Choice should show XOR symbol ⊕"
    end

    def test_choice_dot_shows_xor_symbol
      workflow = TestOrderWorkflow.new
      dot = workflow.to_dot

      # Should show ⊕ symbol for choice patterns
      assert_includes dot, "⊕", "Choice should show XOR symbol ⊕ in DOT"
    end

    def test_sequential_workflow_no_pattern_symbols
      # A purely sequential workflow should have no fork or choice symbols
      sequential_workflow = Class.new(Workflow) do
        workflow_name "Sequential Test"
        places :a, :b, :c
        initial_place :a
        terminal_places :c

        transition :step1, from: :a, to: :b
        transition :step2, from: :b, to: :c
      end

      workflow = sequential_workflow.new
      mermaid = workflow.to_mermaid

      # No pattern symbols for purely sequential flow
      refute_includes mermaid, "∥", "Sequential workflow should not have fork symbol"
      refute_includes mermaid, "⊕", "Sequential workflow should not have choice symbol"
    end

    # ===========================================
    # Reload Safety Tests
    # ===========================================

    def test_places_resets_transitions_on_reload
      # Simulates what happens when a file is loaded multiple times
      # (e.g., Rails development mode or using `load` instead of `require`)
      reloadable_workflow = Class.new(Workflow)

      # First "load" - define the workflow
      reloadable_workflow.class_eval do
        workflow_name "Reloadable Test"
        places :a, :b
        initial_place :a
        terminal_places :b
        transition :go, from: :a, to: :b
      end

      assert_equal 1, reloadable_workflow.defined_transitions.size

      # Second "load" - redefine (simulates file reload)
      reloadable_workflow.class_eval do
        places :a, :b  # This should reset transitions
        initial_place :a
        terminal_places :b
        transition :go, from: :a, to: :b
      end

      # Should still be 1, not 2
      assert_equal 1, reloadable_workflow.defined_transitions.size,
        "Transitions should reset when places is called again (file reload safety)"
    end

    def test_multiple_reloads_dont_accumulate_transitions
      reload_test = Class.new(Workflow)

      5.times do
        reload_test.class_eval do
          places :x, :y, :z
          initial_place :x
          terminal_places :z
          transition :step1, from: :x, to: :y
          transition :step2, from: :y, to: :z
        end
      end

      assert_equal 2, reload_test.defined_transitions.size,
        "Should have exactly 2 transitions regardless of reload count"
    end

    # ===========================================
    # Visualization Tests
    # ===========================================

    def test_to_mermaid
      workflow = TestOrderWorkflow.new
      mermaid = workflow.to_mermaid

      assert_includes mermaid, "flowchart"
      assert_includes mermaid, "pending"
      assert_includes mermaid, "delivered"
    end

    def test_to_dot
      workflow = TestOrderWorkflow.new
      dot = workflow.to_dot

      assert_includes dot, "digraph"
      assert_includes dot, "pending"
    end

    # ===========================================
    # Simulation Tests
    # ===========================================

    def test_simulate
      workflow = TestOrderWorkflow.new
      trace = workflow.simulate(steps: 5)

      assert_respond_to trace, :firing_sequence
      assert_respond_to trace, :steps
    end
  end
end
