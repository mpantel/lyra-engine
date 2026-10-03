# frozen_string_literal: true

module Lyra
  module Verification
    # Petri net model of the writes that skip ActiveRecord callbacks.
    #
    # The CRUD nets only cover writes that enter through a callback, so
    # Mapping Completeness says nothing about update_all and friends. This
    # net covers them, as StrictDataAccess and CachedRelation implement them:
    #
    # - configuration, fixed once at the start: strict_data_access on or off,
    #   and a table-backed store or an events-only one (event sourcing with
    #   projections disabled);
    # - instance methods (update_column(s), delete): event, then write;
    # - bulk methods (update_all, delete_all, insert_all(!)): write, then one
    #   event per row; in the events-only store the events are the write;
    # - dependent: :nullify: always allowed, events then write;
    # - touch: always allowed (Rails calls it itself for belongs_to ...
    #   touch: true), write, then event;
    # - upsert_all: write, recorded only as a log warning (the named
    #   exception: inserted and updated rows can't be told apart).
    #
    # With strict mode on, each method is rejected unless it runs inside
    # Lyra.without_strict_access (allow_*_in_bypass_block).
    #
    # The property checked by .coverage is Bypass Coverage: every reachable
    # marking in which nothing can fire is either a rejection, or a store
    # change with an event logged, or a store change on the upsert_all path.
    # A store change with neither is a silent write.
    class BypassWorkflow < PetriFlow::Workflow
      # Every callback-bypassing method Lyra overrides, and the behaviour
      # class that models it. Kept equal to the overrides in
      # StrictDataAccess, StrictDataAccessClassMethods and
      # StrictDataAccessRelation by test/verification/bypass_workflow_test.rb.
      METHODS = {
        update_columns: :instance,
        update_column: :instance,
        delete: :instance,
        update_all: :bulk,
        delete_all: :bulk,
        insert_all: :bulk,
        insert_all!: :bulk,
        upsert_all: :upsert,
        touch: :touch
      }.freeze

      workflow_name "Callback-Bypassing Writes"

      places :idle, :ready,
             :strict_on, :strict_off, :table_backed, :events_only,
             :instance_requested, :instance_allowed, :instance_event_first,
             :bulk_requested, :bulk_allowed, :bulk_event_pending,
             :upsert_requested, :upsert_allowed,
             :nullify_allowed, :nullify_event_first,
             :touch_requested, :touch_event_pending,
             :rejected, :event_logged, :store_changed, :unrecorded_write

      initial_place :idle
      terminal_places :rejected, :store_changed

      # Configuration
      transition :configure_strict_table, from: :idle, to: [:strict_on, :table_backed, :ready],
                 trigger: "strict_data_access = true, projections enabled"
      transition :configure_strict_events, from: :idle, to: [:strict_on, :events_only, :ready],
                 trigger: "strict_data_access = true, event sourcing with projections disabled"
      transition :configure_permissive_table, from: :idle, to: [:strict_off, :table_backed, :ready],
                 trigger: "strict_data_access = false (default), projections enabled"
      transition :configure_permissive_events, from: :idle, to: [:strict_off, :events_only, :ready],
                 trigger: "strict_data_access = false, event sourcing with projections disabled"

      # The strict guard, shared by every overridable method
      %i[instance bulk upsert].each do |kind|
        transition :"request_#{kind}", from: :ready, to: :"#{kind}_requested",
                   trigger: "a #{kind} bypass method is called"
        transition :"reject_#{kind}", from: [:"#{kind}_requested", :strict_on], to: [:rejected, :strict_on],
                   trigger: "raise StrictDataAccessViolation"
        transition :"allow_#{kind}", from: [:"#{kind}_requested", :strict_off], to: [:"#{kind}_allowed", :strict_off],
                   trigger: "strict mode off"
        transition :"allow_#{kind}_in_bypass_block", from: [:"#{kind}_requested", :strict_on],
                   to: [:"#{kind}_allowed", :strict_on],
                   trigger: "inside Lyra.without_strict_access"
      end

      # update_column(s), delete: publish, then write (StrictDataAccess)
      transition :publish_instance_event, from: :instance_allowed, to: [:event_logged, :instance_event_first],
                 trigger: "BypassEvents.publish"
      transition :write_instance, from: :instance_event_first, to: :store_changed,
                 trigger: "super (SQL)"

      # update_all, delete_all, insert_all: write, then an event per row
      # (StrictDataAccessRelation / StrictDataAccessClassMethods)...
      transition :write_bulk, from: [:bulk_allowed, :table_backed], to: [:store_changed, :bulk_event_pending, :table_backed],
                 trigger: "super (SQL), rows snapshotted first"
      transition :publish_bulk_events, from: :bulk_event_pending, to: :event_logged,
                 trigger: "BypassEvents.publish_updates / publish_destroys / publish_creates"
      # ...or, with the stream as the only store, the events are the write
      # (CachedRelation#event_sourced_bulk_mutate)
      transition :publish_bulk_as_write, from: [:bulk_allowed, :events_only], to: [:event_logged, :store_changed, :events_only],
                 trigger: "BypassEvents.publish per record"

      # dependent: :nullify, always allowed (StrictDataAccessRelation#update_all)
      transition :request_nullify, from: :ready, to: :nullify_allowed,
                 trigger: "parent destroyed with dependent: :nullify"
      transition :publish_nullify_events, from: :nullify_allowed, to: [:event_logged, :nullify_event_first],
                 trigger: "publish_nullify_events"
      transition :write_nullify, from: :nullify_event_first, to: :store_changed,
                 trigger: "super (SQL)"

      # touch: never a strict-mode violation; write, then event
      # (StrictDataAccess#touch, via with_bypass_event)
      transition :request_touch, from: :ready, to: :touch_requested,
                 trigger: "touch, or belongs_to ... touch: true"
      transition :write_touch, from: :touch_requested, to: [:store_changed, :touch_event_pending],
                 trigger: "super (SQL)"
      transition :publish_touch_event, from: :touch_event_pending, to: :event_logged,
                 trigger: "publish_bypass_update_event"

      # upsert_all: the named exception
      transition :write_upsert, from: :upsert_allowed, to: [:store_changed, :unrecorded_write],
                 trigger: "super (SQL); Rails.logger.warn"

      # Bypass Coverage over every reachable dead marking of the workflow.
      #
      # @return [Hash] covered: true when there is no silent write;
      #   silent_writes / exceptions: the offending and the upsert_all
      #   dead markings, as place => tokens hashes.
      def self.coverage(workflow = new)
        analyzer = PetriFlow::Verification::ReachabilityAnalyzer.new(workflow.net, workflow.initial_marking)
        analyzer.analyze
        dead = analyzer.reachable_markings.filter_map do |marking|
          workflow.net.set_marking(marking)
          marked_places(marking, workflow) if workflow.net.deadlocked?
        end

        silent = dead.reject do |marked|
          marked[:rejected] || (marked[:store_changed] && (marked[:event_logged] || marked[:unrecorded_write]))
        end
        exceptions = dead.select { |marked| marked[:unrecorded_write] }

        {
          covered: silent.empty?,
          dead_markings: dead.size,
          silent_writes: silent,
          exceptions: exceptions
        }
      ensure
        workflow.reset_to_initial!
      end

      def self.marked_places(marking, workflow)
        workflow.class.defined_places.each_with_object({}) do |place, acc|
          tokens = marking.tokens_at(place)
          acc[place] = tokens if tokens.positive?
        end
      end
      private_class_method :marked_places
    end
  end
end
