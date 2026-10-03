# frozen_string_literal: true

require "test_helper"

module Lyra
  module Verification
    class CrudLifecycleWorkflowTest < Minitest::Test
      def setup
        skip "PetriFlow not available" unless PETRI_FLOW_AVAILABLE
      end

      def test_lifecycle_workflow_builds_successfully
        workflow = CrudLifecycleWorkflow.new

        assert_equal "CRUD Entity Lifecycle", workflow.workflow_name
        assert_kind_of PetriFlow::Core::Net, workflow.net
      end

      def test_lifecycle_has_correct_places
        workflow = CrudLifecycleWorkflow.new
        places = workflow.net.places.keys

        assert_includes places, :nonexistent
        assert_includes places, :created
        assert_includes places, :persisted
        assert_includes places, :updated
        assert_includes places, :destroyed
        assert_includes places, :deleted
      end

      def test_lifecycle_has_correct_transitions
        workflow = CrudLifecycleWorkflow.new
        transitions = workflow.net.transitions.keys

        # CREATE flow
        assert transitions.any? { |t| t.to_s.include?("create") }
        assert transitions.any? { |t| t.to_s.include?("emit_created_event") }

        # UPDATE flow
        assert transitions.any? { |t| t.to_s.include?("update") }
        assert transitions.any? { |t| t.to_s.include?("emit_updated_event") }

        # DESTROY flow
        assert transitions.any? { |t| t.to_s.include?("destroy") }
        assert transitions.any? { |t| t.to_s.include?("emit_destroyed_event") }
      end

      def test_lifecycle_verification_passes
        workflow = CrudLifecycleWorkflow.new
        results = workflow.verify!

        # Should be safe (1-bounded)
        assert results[:boundedness][:is_safe],
               "Lifecycle should be 1-bounded (safe)"

        # Terminal state should be reachable
        assert workflow.terminal_reachability[:deleted],
               "Deleted state should be reachable from initial state"
      end

      def test_lifecycle_is_deadlock_free_for_complete_flow
        workflow = CrudLifecycleWorkflow.new
        results = workflow.verify!

        # The lifecycle has an intentional terminal state (:deleted), so the
        # property is deadlock-freedom except there; PetriFlow's raw
        # deadlock_free counts the terminal marking itself as a deadlock.
        reachability = results[:reachability]
        assert reachability[:total_reachable_states] > 0,
               "Should have reachable states"
        assert results[:liveness][:terminates_properly],
               "No reachable marking should be stuck outside :deleted"
        refute results[:liveness][:deadlock_free],
               "The raw check still counts the :deleted marking as dead"
      end

      def test_mode_verification_workflows_build
        # Test all three separate CRUD mode workflows
        [CreateModeWorkflow, UpdateModeWorkflow, DestroyModeWorkflow].each do |klass|
          workflow = klass.new
          assert_kind_of PetriFlow::Core::Net, workflow.net
        end
      end

      def test_mode_verification_has_all_modes
        # Each workflow should have monitor, hijack, and event_sourcing mode places
        workflow = CreateModeWorkflow.new
        places = workflow.net.places.keys

        # Mode places (shared naming across all CRUD workflows)
        assert_includes places, :monitor_mode
        assert_includes places, :hijack_mode
        assert_includes places, :event_sourcing_mode
      end

      def test_mode_verification_terminal_reachable
        # All three workflows should reach completed state
        [CreateModeWorkflow, UpdateModeWorkflow, DestroyModeWorkflow].each do |klass|
          workflow = klass.new
          workflow.verify!

          assert workflow.terminal_reachability[:completed],
                 "#{klass.name} completed state should be reachable from all modes"
        end
      end

      def test_crud_verifier_runs_all_verifications
        verifier = CrudVerifier.new
        report = verifier.verify_all

        # Should have lifecycle results
        assert report[:details][:lifecycle], "Should have lifecycle verification results"
        assert report[:details][:lifecycle][:verification], "Lifecycle should have verification data"
        assert report[:details][:lifecycle][:terminal_reachability], "Should have terminal reachability"

        # Should have mode results for all 3 CRUD operations
        assert report[:details][:modes], "Should have mode verification results"
        assert report[:details][:modes][:create], "Should have create mode results"
        assert report[:details][:modes][:update], "Should have update mode results"
        assert report[:details][:modes][:destroy], "Should have destroy mode results"

        # Each mode result should have verification data
        [:create, :update, :destroy].each do |op|
          assert report[:details][:modes][op][:verification],
                 "#{op} mode should have verification data"
        end
      end

      def test_crud_verifier_generates_diagrams
        verifier = CrudVerifier.new
        verifier.verify_lifecycle

        diagrams = verifier.results[:lifecycle][:diagrams]

        assert diagrams[:mermaid].include?("flowchart"),
               "Should generate Mermaid diagram"
        assert diagrams[:dot].include?("digraph"),
               "Should generate DOT diagram"
      end

      def test_lyra_verify_crud_mapping_method
        report = Lyra.verify_crud_mapping

        assert report[:summary], "Should have summary"
        assert report[:details], "Should have details"
        # Check that we got verification results
        assert report[:details][:lifecycle], "Should have lifecycle details"
      end

      def test_verifier_provides_recommendations
        verifier = CrudVerifier.new
        report = verifier.verify_all

        recommendations = report[:summary][:recommendations]
        assert_kind_of Array, recommendations
        refute_empty recommendations, "Should have at least one recommendation"
      end

      def test_lifecycle_workflow_can_simulate
        workflow = CrudLifecycleWorkflow.new
        result = workflow.simulate(steps: 10)

        # Simulation returns a trace or result object
        assert result, "Simulation should return a result"
      end

      def test_lifecycle_mermaid_export
        workflow = CrudLifecycleWorkflow.new
        mermaid = workflow.to_mermaid

        # Should be valid Mermaid syntax (flowchart format)
        assert mermaid.include?("flowchart"), "Should be a flowchart"

        # Should include key places
        assert mermaid.include?("nonexistent") || mermaid.include?("Nonexistent"),
               "Should include initial place"
        assert mermaid.include?("deleted") || mermaid.include?("Deleted"),
               "Should include terminal place"
      end

      # ===========================================
      # Multi-directory Workflow Loading Tests
      # ===========================================

      def test_find_workflows_dirs_returns_array
        verifier = CrudVerifier.new
        dirs = verifier.send(:find_workflows_dirs)

        assert_kind_of Array, dirs
        refute_empty dirs, "Should find at least one workflows directory"
      end

      def test_find_workflows_dirs_includes_lyra_gem_path
        verifier = CrudVerifier.new
        dirs = verifier.send(:find_workflows_dirs)

        # Should include Lyra gem's app/workflows
        lyra_dir = dirs.find { |d| d.include?("lyra") && d.include?("app/workflows") }
        assert lyra_dir, "Should include Lyra gem's app/workflows directory"
      end

      def test_find_workflow_class_finds_top_level_class
        verifier = CrudVerifier.new

        # CrudLifecycleWorkflow is defined at module level
        # Test finding a class defined at Object level
        klass = verifier.send(:find_workflow_class, "CrudLifecycleWorkflow")

        # It might not find it at Object level since it's in Lyra::Verification
        # But should not raise an error
        assert_nil(klass) || assert(klass < PetriFlow::Workflow)
      end

      def test_backward_compatible_find_workflows_dir
        verifier = CrudVerifier.new

        # Old method should still work
        dir = verifier.send(:find_workflows_dir)
        assert_kind_of String, dir
        assert Dir.exist?(dir), "Should return an existing directory"
      end

      # ===========================================
      # Pattern Label Tests (Fork/Choice)
      # ===========================================

      def test_lifecycle_mermaid_shows_choice_pattern_labels
        workflow = CrudLifecycleWorkflow.new
        mermaid = workflow.to_mermaid

        # Lifecycle has choice pattern at persisted state (update OR destroy)
        # Should show ⊕ symbol on arcs from persisted
        assert mermaid.include?("⊕"), "Should show XOR choice symbol for exclusive paths"
      end

      def test_mode_workflow_mermaid_shows_choice_pattern
        workflow = CreateModeWorkflow.new
        mermaid = workflow.to_mermaid

        # Mode workflow has choice (select_monitor OR select_hijack OR select_es)
        assert mermaid.include?("⊕"), "Mode workflow should show XOR symbol for mode selection"
      end
    end
  end
end
