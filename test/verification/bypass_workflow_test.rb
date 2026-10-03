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

      # upsert_all used to be the one write without an event. Every path
      # that changes the store now logs one, upsert_all's included.
      # Structurally: each transition that changes the store either logs the
      # event itself, is only reachable after the event was logged (event
      # first: instance methods, nullify), or leaves a place whose only way
      # out logs it (write first: bulk methods, upsert_all).
      def test_every_store_change_is_paired_with_an_event
        transitions = BypassWorkflow.defined_transitions
        config = %i[strict_on strict_off table_backed events_only]
        logs = ->(t) { t[:to].include?(:event_logged) }

        transitions.select { |t| t[:to].include?(:store_changed) }.each do |t|
          next if logs.(t)

          logged_before = (t[:from] - config).all? do |input|
            transitions.select { |p| p[:to].include?(input) }.all?(&logs)
          end
          logged_after = (t[:to] - config - [:store_changed]).any? do |output|
            exits = transitions.select { |p| p[:from].include?(output) }
            exits.any? && exits.all?(&logs)
          end
          assert logged_before || logged_after, "#{t[:name]} changes the store without an event"
        end
        refute_includes BypassWorkflow.defined_places, :unrecorded_write
      end

      def test_upsert_all_is_rejected_in_the_events_only_store
        rejector = BypassWorkflow.defined_transitions.find { |t| t[:name] == :reject_upsert_events_only }
        assert_equal %i[upsert_allowed events_only], rejector[:from]
        assert_includes rejector[:to], :rejected
      end

      # The check is not vacuous: the bulk path as it was before
      # 2026-09-23 (strict mode off: write, no event) is reported.
      class PreFixBulkWorkflow < PetriFlow::Workflow
        workflow_name "Bulk writes before the fix"
        places :idle, :requested, :rejected, :event_logged, :store_changed
        initial_place :idle
        terminal_places :rejected, :store_changed
        transition :request_bulk, from: :idle, to: :requested
        transition :reject_bulk, from: :requested, to: :rejected
        transition :write_bulk, from: :requested, to: :store_changed
      end

      # upsert_all before it was closed: write, log a warning, no event.
      class PreFixUpsertWorkflow < PetriFlow::Workflow
        workflow_name "upsert_all before it was closed"
        places :idle, :allowed, :rejected, :event_logged, :store_changed, :unrecorded_write
        initial_place :idle
        terminal_places :rejected, :store_changed
        transition :request_upsert, from: :idle, to: :allowed
        transition :write_upsert, from: :allowed, to: [:store_changed, :unrecorded_write]
      end

      def test_coverage_reports_the_pre_fix_upsert_as_silent
        coverage = BypassWorkflow.coverage(PreFixUpsertWorkflow.new)

        refute coverage[:covered]
        assert_equal [{ store_changed: 1, unrecorded_write: 1 }], coverage[:silent_writes]
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
