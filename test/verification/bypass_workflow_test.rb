# frozen_string_literal: true

require "test_helper"

module Lyra
  module Verification
    class BypassWorkflowTest < Minitest::Test
      def self.runnable_methods
        return [] unless defined?(PetriFlow)

        super
      end

      # The model must name exactly the methods Lyra overrides. A new
      # override without a transition (or a transition for a method no
      # longer overridden) fails here, not silently in the thesis.
      def test_model_covers_exactly_the_overridden_methods
        overridden = Lyra::StrictDataAccess.public_instance_methods(false) +
                     Lyra::StrictDataAccessClassMethods.public_instance_methods(false) +
                     Lyra::StrictDataAccessRelation.public_instance_methods(false)

        assert_equal overridden.sort, BypassWorkflow::METHODS.keys.sort
      end

      def test_every_behaviour_class_has_a_request_transition
        requested = BypassWorkflow.defined_transitions.map { |t| t[:name] }
        BypassWorkflow::METHODS.values.uniq.each do |kind|
          assert_includes requested, :"request_#{kind}"
        end
      end

      def test_net_is_safe_terminates_properly_and_has_no_dead_transitions
        workflow = BypassWorkflow.new
        results = workflow.verify!

        assert results[:boundedness][:is_safe]
        assert results[:liveness][:terminates_properly]
        assert_empty results[:liveness][:dead_transitions], "every modelled path can actually be taken"
        assert workflow.terminal_reachability.values.all?
      end

      def test_no_bypass_write_is_silent
        coverage = BypassWorkflow.coverage

        assert coverage[:covered]
        assert_empty coverage[:silent_writes]
      end

      def test_only_upsert_all_writes_without_an_event
        coverage = BypassWorkflow.coverage

        refute_empty coverage[:exceptions]
        coverage[:exceptions].each do |marked|
          assert marked[:unrecorded_write]
          refute marked[:event_logged]
        end
        writers = BypassWorkflow.defined_transitions.select { |t| t[:to].include?(:unrecorded_write) }
        assert_equal [:write_upsert], writers.map { |t| t[:name] }
      end

      # The check is not vacuous: the bulk path as it was before
      # 2026-09-23 (strict mode off: write, no event) is reported.
      class PreFixBulkWorkflow < PetriFlow::Workflow
        workflow_name "Bulk writes before the fix"
        places :idle, :requested, :rejected, :event_logged, :store_changed, :unrecorded_write
        initial_place :idle
        terminal_places :rejected, :store_changed
        transition :request_bulk, from: :idle, to: :requested
        transition :reject_bulk, from: :requested, to: :rejected
        transition :write_bulk, from: :requested, to: :store_changed
      end

      def test_coverage_reports_the_pre_fix_silent_bulk_write
        coverage = BypassWorkflow.coverage(PreFixBulkWorkflow.new)

        refute coverage[:covered]
        assert_equal [{ store_changed: 1 }], coverage[:silent_writes]
      end

      def test_verifier_summary_includes_bypass_coverage
        report = CrudVerifier.new.verify_all

        assert report[:summary][:bypass_covered]
        assert report[:summary][:deadlock_free]
        assert report[:details][:bypass][:coverage][:covered]
      end
    end
  end
end
