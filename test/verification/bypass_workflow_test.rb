# frozen_string_literal: true

require "test_helper"

module Lyra
  module Verification
    class BypassWorkflowTest < Minitest::Test
      def self.runnable_methods
        return [] unless defined?(PetriFlow)

        super
      end

      CONFIG = %i[strict_on strict_off table_backed events_only streams_checked].freeze

      def transition_id(name)
        BypassWorkflow.defined_transitions.find { _1[:name] == name }.fetch(:id)
      end

      # The model must name exactly the methods Lyra overrides. A new
      # override without a transition (or a transition for a method no
      # longer overridden) fails here, not silently in the thesis.
      def test_model_covers_exactly_the_overridden_methods
        overridden = Lyra::StrictDataAccess.public_instance_methods(false) +
                     Lyra::StrictDataAccessRelation.public_instance_methods(false)

        assert_equal overridden.sort, BypassWorkflow::METHODS.keys.sort
      end

      # Rails's counters reach update_all; ES-NoProj overrides the
      # class-level ones (CrudInterceptor) to write them as its update_all
      # does. Each is modelled by the method it reaches.
      def test_routed_methods_are_overridden_and_reach_a_modelled_method
        class_level = Lyra::Interceptors::CrudInterceptor::ClassMethods.public_instance_methods(false)

        BypassWorkflow::ROUTED.each do |name, target|
          assert_includes class_level, name
          assert_includes BypassWorkflow::METHODS.keys, target
        end
        assert_equal class_level.select { _1.to_s.match?(/counter/) }.sort, BypassWorkflow::ROUTED.keys.sort
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
        config = CONFIG
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

      # The refusals (Genesis, insert_all's included, the lock limit, a
      # destroyed record's upsert, a duplicate key's insert_all!, a join
      # row's, a unique value's update_column(s), update_all and upsert_all)
      # and the unchanged endings (a
      # destroyed record, insert_all's skipped key, a join row ON CONFLICT
      # skipped) neither change the store nor log an event.
      def test_refusals_and_skips_write_nothing
        transitions = BypassWorkflow.defined_transitions.select { _1[:name].to_s.match?(/\A(refuse_|skip_)/) }

        assert_equal 24, transitions.size
        transitions.each do |t|
          outputs = t[:to] - CONFIG
          expected = t[:name].to_s.start_with?("skip_") ? [:unchanged] : [:rejected]
          assert_equal expected, outputs, t[:name]
        end
      end

      # Each new ending and rejection is reachable, in the configurations
      # whose code takes that path; the net is then dead there.
      def test_each_new_ending_and_rejection_is_reachable
        {
          %i[configure_permissive_lagging request_bulk allow_bulk refuse_lock_limit_bulk] =>
            %i[strict_off table_backed streams_checked rejected],
          %i[configure_permissive_events request_nullify refuse_lock_limit_nullify] =>
            %i[strict_off events_only streams_checked rejected],
          %i[configure_permissive_table request_column allow_column refuse_genesis_column] =>
            %i[strict_off table_backed rejected],
          %i[configure_strict_events request_touch refuse_genesis_touch] =>
            %i[strict_on events_only streams_checked rejected],
          %i[configure_permissive_events request_instance allow_instance refuse_genesis_instance] =>
            %i[strict_off events_only streams_checked rejected],
          %i[configure_permissive_events request_bulk allow_bulk refuse_genesis_bulk] =>
            %i[strict_off events_only streams_checked rejected],
          %i[configure_permissive_lagging request_upsert allow_upsert refuse_genesis_upsert] =>
            %i[strict_off table_backed streams_checked rejected],
          %i[configure_permissive_lagging request_nullify refuse_genesis_nullify] =>
            %i[strict_off table_backed streams_checked rejected],
          %i[configure_permissive_lagging request_instance allow_instance skip_destroyed_instance] =>
            %i[strict_off table_backed streams_checked unchanged],
          %i[configure_permissive_table request_instance allow_instance skip_destroyed_instance] =>
            %i[strict_off table_backed unchanged],
          %i[configure_permissive_lagging request_column allow_column skip_destroyed_column] =>
            %i[strict_off table_backed streams_checked unchanged],
          %i[configure_strict_lagging request_touch skip_destroyed_touch] =>
            %i[strict_on table_backed streams_checked unchanged],
          %i[configure_permissive_events request_bulk allow_bulk skip_destroyed_bulk] =>
            %i[strict_off events_only streams_checked unchanged],
          %i[configure_permissive_lagging request_nullify skip_destroyed_nullify] =>
            %i[strict_off table_backed streams_checked unchanged],
          %i[configure_permissive_events request_insert allow_insert bring_insert_keys_up_to_date write_insert
             publish_insert_events] =>
            %i[strict_off events_only streams_checked event_logged store_changed],
          %i[configure_permissive_lagging request_upsert allow_upsert refuse_lock_limit_upsert] =>
            %i[strict_off table_backed streams_checked rejected],
          %i[configure_strict_lagging request_upsert allow_upsert_in_bypass_block refuse_destroyed_upsert] =>
            %i[strict_on table_backed streams_checked rejected],
          %i[configure_permissive_table request_insert allow_insert insert_as_given skip_conflict_insert] =>
            %i[strict_off table_backed unchanged],
          %i[configure_permissive_events request_insert allow_insert bring_insert_keys_up_to_date refuse_conflict_insert] =>
            %i[strict_off events_only streams_checked rejected],
          # ES-Async: the rows brought up to date, a destroyed record inserted
          # again; the keys over the lock limit; the upsert's rows brought up
          # to date, and a table's as given.
          %i[configure_permissive_lagging request_insert allow_insert bring_insert_keys_up_to_date write_insert
             publish_insert_events] =>
            %i[strict_off table_backed streams_checked event_logged store_changed],
          %i[configure_strict_lagging request_insert allow_insert_in_bypass_block refuse_lock_limit_insert] =>
            %i[strict_on table_backed streams_checked rejected],
          %i[configure_permissive_lagging request_upsert allow_upsert bring_upsert_rows_up_to_date write_upsert
             publish_upsert_events] =>
            %i[strict_off table_backed streams_checked event_logged store_changed],
          %i[configure_permissive_table request_upsert allow_upsert upsert_as_given write_upsert publish_upsert_events] =>
            %i[strict_off table_backed event_logged store_changed],
          # A value a unique index refuses: update_column(s) and update_all
          # write and record nothing, in the events-only store (from the
          # event store) as with a table.
          %i[configure_permissive_events request_column allow_column refuse_unique_column] =>
            %i[strict_off events_only streams_checked rejected],
          %i[configure_strict_table request_column allow_column_in_bypass_block refuse_unique_column] =>
            %i[strict_on table_backed rejected],
          %i[configure_permissive_events request_bulk allow_bulk refuse_unique_bulk] =>
            %i[strict_off events_only streams_checked rejected],
          %i[configure_permissive_lagging request_bulk allow_bulk refuse_unique_bulk] =>
            %i[strict_off table_backed streams_checked rejected],
          # ES-Async and ES-Lazy: an update_column(s) and an upsert_all whose
          # value a record not yet projected holds, found in the event store.
          %i[configure_permissive_lagging request_column allow_column refuse_unique_column] =>
            %i[strict_off table_backed streams_checked rejected],
          %i[configure_permissive_lagging request_upsert allow_upsert bring_upsert_rows_up_to_date refuse_unique_upsert] =>
            %i[strict_off table_backed streams_checked rejected],
          %i[configure_permissive_table request_upsert allow_upsert upsert_as_given refuse_unique_upsert] =>
            %i[strict_off table_backed rejected],
          # ES-Sync: the unique values' locks over the limit (update_all,
          # insert_all(!), upsert_all); a model whose import Genesis refused,
          # read from the event store by insert_all.
          %i[configure_permissive_table request_bulk allow_bulk refuse_lock_limit_bulk] =>
            %i[strict_off table_backed rejected],
          %i[configure_strict_table request_insert allow_insert_in_bypass_block refuse_lock_limit_insert] =>
            %i[strict_on table_backed rejected],
          %i[configure_permissive_table request_upsert allow_upsert refuse_lock_limit_upsert] =>
            %i[strict_off table_backed rejected],
          %i[configure_permissive_events request_insert allow_insert refuse_genesis_insert] =>
            %i[strict_off events_only streams_checked rejected],
          %i[configure_permissive_lagging request_insert allow_insert refuse_genesis_insert] =>
            %i[strict_off table_backed streams_checked rejected]
        }.each do |path, ending|
          workflow = BypassWorkflow.new
          path.each { |name| workflow.net.fire_transition(transition_id(name)) }

          marked = BypassWorkflow.defined_places.select { workflow.net.current_marking.tokens_at(_1).positive? }
          assert_equal ending.sort, marked.sort, path.last
          assert workflow.net.deadlocked?, "#{path.last} ends the write"
        end
      end

      # Rails' association writes (Lyra::Associations::Maintenance) enter
      # past the strict guard, and end as the writes they are; the
      # application's delete_all of join rows is guarded, and logged as an
      # unlink when allowed, in the events-only store too (the join rows are
      # in a table there as well).
      def test_association_writes_and_links_are_reachable
        {
          %i[configure_strict_table request_nullify publish_nullify_events write_nullify] =>
            %i[strict_on table_backed event_logged store_changed],
          %i[configure_strict_events request_association_column write_column publish_column_event] =>
            %i[strict_on events_only streams_checked event_logged store_changed],
          %i[configure_strict_lagging request_through_delete write_bulk publish_bulk_events] =>
            %i[strict_on table_backed streams_checked event_logged store_changed],
          %i[configure_strict_events request_unlink write_unlink publish_unlink] =>
            %i[strict_on events_only streams_checked event_logged store_changed],
          %i[configure_strict_table request_join reject_join] =>
            %i[strict_on table_backed rejected],
          %i[configure_strict_events request_join allow_join_in_bypass_block write_unlink publish_unlink] =>
            %i[strict_on events_only streams_checked event_logged store_changed],
          %i[configure_permissive_lagging request_join allow_join write_unlink publish_unlink] =>
            %i[strict_off table_backed streams_checked event_logged store_changed],
          # The application's inserts of join rows: guarded as its deletes
          # are, written then logged as links; ON CONFLICT skipped, or refused.
          %i[configure_strict_table request_join_insert reject_join_insert] =>
            %i[strict_on table_backed rejected],
          %i[configure_strict_events request_join_insert allow_join_insert_in_bypass_block write_link publish_link] =>
            %i[strict_on events_only streams_checked event_logged store_changed],
          %i[configure_permissive_lagging request_join_insert allow_join_insert write_link publish_link] =>
            %i[strict_off table_backed streams_checked event_logged store_changed],
          %i[configure_permissive_table request_join_insert allow_join_insert skip_conflict_link] =>
            %i[strict_off table_backed unchanged],
          %i[configure_permissive_events request_join_insert allow_join_insert refuse_conflict_link] =>
            %i[strict_off events_only streams_checked rejected]
        }.each do |path, ending|
          workflow = BypassWorkflow.new
          path.each { |name| workflow.net.fire_transition(transition_id(name)) }

          marked = BypassWorkflow.defined_places.select { workflow.net.current_marking.tokens_at(_1).positive? }
          assert_equal ending.sort, marked.sort, path.last
          assert workflow.net.deadlocked?, "#{path.last} ends the write"
        end
      end

      # Rails' own association writes have no strict guard: nothing leads
      # from their requests to a StrictDataAccessViolation. Only the
      # application's (request_join, and request_bulk for update_all(fk: nil))
      # is guarded.
      def test_rails_association_writes_are_never_refused_by_strict_mode
        transitions = BypassWorkflow.defined_transitions
        guards = transitions.select { _1[:trigger].to_s.include?("StrictDataAccessViolation") }.flat_map { _1[:from] }

        %i[nullify_allowed link_allowed column_allowed bulk_allowed].each { refute_includes guards, _1 }
        assert_includes guards, :join_requested
        assert_includes guards, :join_insert_requested
        request = ->(name) { transitions.find { _1[:name] == name } }
        assert_equal [:ready], request.(:request_unlink)[:from]
        assert_equal [:link_allowed], request.(:request_unlink)[:to]
        assert_equal [:column_allowed], request.(:request_association_column)[:to]
        assert_equal [:bulk_allowed], request.(:request_through_delete)[:to]
        # A join row has no stream: no Genesis refusal, stream check or lock
        # limit on the link path.
        assert_empty transitions.select { _1[:from].include?(:link_allowed) && _1[:to].include?(:rejected) }
        assert_empty transitions.select { _1[:from].include?(:link_allowed) && _1[:to].include?(:unchanged) }
        assert_empty transitions.select { _1[:from].include?(:join_insert_allowed) && (_1[:from] & CONFIG).any? },
                     "a join insert's outcome depends on no configuration"
      end

      # The stream checks, a nullify's lock limit and Genesis's refusal of
      # insert_all apply only where the aggregate locks are taken and the
      # event store read: ES-Sync, Hijack and Monitor never reach them, and
      # ES-NoProj rejects upsert_all before. The bulk, insert and upsert lock
      # limits apply in ES-Sync too, to the unique values' locks.
      def test_the_lock_limit_needs_the_stream_check
        %i[refuse_lock_limit_nullify refuse_destroyed_upsert refuse_genesis_insert
           bring_insert_keys_up_to_date bring_upsert_rows_up_to_date].each do |name|
          t = BypassWorkflow.defined_transitions.find { _1[:name] == name }
          assert_includes t[:from], :streams_checked
        end
        %i[refuse_lock_limit_bulk refuse_lock_limit_insert refuse_lock_limit_upsert].each do |name|
          refute_includes BypassWorkflow.defined_transitions.find { _1[:name] == name }[:from], :streams_checked
        end
        %i[refuse_lock_limit_upsert refuse_destroyed_upsert bring_upsert_rows_up_to_date].each do |name|
          assert_includes BypassWorkflow.defined_transitions.find { _1[:name] == name }[:from], :table_backed
        end
      end

      def test_every_dead_marking_is_one_ending_in_every_configuration
        coverage = BypassWorkflow.coverage

        assert_equal 18, coverage[:dead_markings], "six configurations, three endings each"
        assert_equal 6, coverage[:unchanged]
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

      # The unchanged ending does not hide a silent write. A destroyed
      # record's write that still changed the store (the row of a record
      # destroyed in ES-Async, written without the savepoint rolled back), or
      # one that logged an event after the destroy (the record brought back),
      # is reported, as is a write with no event and no ending at all.
      class StaleWriteWorkflow < PetriFlow::Workflow
        workflow_name "Writes to a destroyed record, done wrong"
        places :idle, :requested, :rejected, :event_logged, :store_changed, :unchanged
        initial_place :idle
        terminal_places :rejected, :store_changed, :unchanged
        transition :request_column, from: :idle, to: :requested
        transition :skip_destroyed_column, from: :requested, to: :unchanged
        transition :write_destroyed_row, from: :requested, to: [:unchanged, :store_changed]
        transition :publish_after_destroy, from: :requested, to: [:unchanged, :event_logged]
        transition :write_without_event, from: :requested, to: :store_changed
      end

      def test_coverage_reports_a_store_change_without_an_event_beside_unchanged
        coverage = BypassWorkflow.coverage(StaleWriteWorkflow.new)

        refute coverage[:covered]
        assert_equal 4, coverage[:dead_markings]
        assert_equal 1, coverage[:unchanged]
        assert_equal [{ store_changed: 1 }, { event_logged: 1, unchanged: 1 }, { store_changed: 1, unchanged: 1 }].sort_by(&:to_s),
                     coverage[:silent_writes].sort_by(&:to_s)
      end

      # A rejection counts only alone: a refusal raised after the write (or
      # its event), and not rolled back, is reported.
      class WriteThenRejectWorkflow < PetriFlow::Workflow
        workflow_name "A refusal after the write"
        places :idle, :requested, :rejected, :event_logged, :store_changed, :unchanged
        initial_place :idle
        terminal_places :rejected, :store_changed, :unchanged
        transition :request_bulk, from: :idle, to: :requested
        transition :reject_bulk, from: :requested, to: :rejected
        transition :write_then_reject, from: :requested, to: [:store_changed, :rejected]
        transition :log_then_reject, from: :requested, to: [:event_logged, :rejected]
      end

      def test_coverage_reports_a_rejection_beside_a_write_or_an_event
        coverage = BypassWorkflow.coverage(WriteThenRejectWorkflow.new)

        refute coverage[:covered]
        assert_equal 3, coverage[:dead_markings]
        assert_equal [{ event_logged: 1, rejected: 1 }, { rejected: 1, store_changed: 1 }].sort_by(&:to_s),
                     coverage[:silent_writes].sort_by(&:to_s)
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
