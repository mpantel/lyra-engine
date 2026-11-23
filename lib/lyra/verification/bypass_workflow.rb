# frozen_string_literal: true

module Lyra
  module Verification
    # Petri net model of the writes that skip ActiveRecord callbacks.
    #
    # The CRUD nets only cover writes that enter through a callback, so
    # Mapping Completeness says nothing about update_all and friends. This
    # net covers them, as StrictDataAccess, BypassEvents and CachedRelation
    # implement them in Lyra 1.0.0. It follows one record through one write.
    #
    # Configuration, fixed once at the start: strict_data_access on or off,
    # and one of three stores, given by two places that mirror
    # BypassEvents.locks_rows? and BypassEvents.checks_streams?:
    #
    # - table_backed: the rows are in a table, which bulk writes lock and
    #   write. ES-Sync, Hijack and Monitor delete the row with the destroy,
    #   so a write to a destroyed record reaches no row: SQL matches none,
    #   and delete, which locks the row first, finds none and logs nothing;
    # - table_backed with streams_checked: a table that lags the event store
    #   (ES-Async, whose rows wait for the projection job, and ES-Lazy, whose
    #   rows are brought up to date under the lock). Every write but
    #   insert_all reads the record's stream under its aggregate lock first:
    #   update_column(s), touch, delete, the bulk writes and dependent:
    #   :nullify leave out a record whose stream ends in a destroy; ES-Lazy's
    #   upsert_all refuses one whose row is still in the table, and
    #   ES-Async's insert_all, insert_all! and upsert_all bring the rows of
    #   the keys they write up to date with their streams first;
    # - events_only with streams_checked: event sourcing with projections
    #   disabled (ES-NoProj). The events are the write; destroyed records are
    #   left out, and a bulk write selects its records when it is called.
    #
    # Behaviour classes (METHODS), each after the strict guard where it has
    # one:
    #
    # - update_column(s) (column): write, then event (built from the
    #   persisted values, so "assign, then update_columns" is still seen);
    #   a value a unique index refuses raises ActiveRecord::RecordNotUnique
    #   and writes nothing (refuse_unique_column: the table's UPDATE, in
    #   ES-Sync after the value's lock; or, where the table lags the event
    #   store or there is none (ES-Async, ES-Lazy, ES-NoProj), the event
    #   store, read under the value's lock after the stream check:
    #   Lyra::Projections::UniqueIndexes);
    # - delete (instance): event, then write;
    # - touch: always allowed (Rails calls it itself for belongs_to ...
    #   touch: true), write, then event;
    # - update_all, delete_all, touch_all (bulk): write, then one event per
    #   row; in the events-only store the events are the write. A write
    #   that would hold more locks than config.bulk_write_lock_limit raises
    #   BulkWriteLockLimitError before it writes or records anything: the
    #   records' aggregate locks where the streams are checked, and in the
    #   event-sourcing modes, ES-Sync included, the locks of the unique
    #   values an update_all sets (UniqueIndexes::BulkUpdate#check!).
    #   Rails's update_counters,
    #   increment_counter, decrement_counter, increment! and decrement! reach
    #   update_all (in ES-NoProj through CrudInterceptor's class-level
    #   overrides, ROUTED). An update_all whose values a unique index
    #   refuses (two records given one value, or a value another record
    #   holds) raises ActiveRecord::RecordNotUnique and writes nothing
    #   (refuse_unique_bulk; in ES-NoProj, ES-Async and ES-Lazy checked
    #   from the event store before any write or event,
    #   UniqueIndexes::BulkUpdate);
    # - insert_all(!) (insert): write, then a created event per row, in
    #   every store (ES-NoProj sends inserts to the table relation too); a
    #   new row has nothing for Genesis to admit. Where the streams are
    #   checked, the rows are first made to conflict as Monitor's table
    #   would (bring_insert_keys_up_to_date): ES-NoProj reads the keys the
    #   rows give, and the values of the model's other unique indexes, from
    #   the event store under their locks; ES-Async locks the keys and
    #   brings their rows up to date with their streams
    #   (AsyncProjectionJob.project_pending), so a record whose destroy was
    #   pending is inserted again and one whose create was pending
    #   conflicts. Those locks count against bulk_write_lock_limit, with, in
    #   ES-Sync, ES-Async and ES-Lazy, the unique values' (below). Rows
    #   that give no key, and ES-Lazy (caught up when the write began),
    #   insert as given (insert_as_given). In ES-Async and ES-Lazy the
    #   values of the model's unique indexes are then looked up in the event
    #   store under their locks (a record whose create is not projected yet
    #   holds its value: StrictDataAccessRelation#projected_unique_rows),
    #   and in ES-Sync locked. A conflict: insert_all writes nothing and
    #   records nothing (ON CONFLICT DO NOTHING, or left out of the insert:
    #   unchanged), insert_all! (and a conflict on an index other than
    #   insert_all's unique_by) raises ActiveRecord::RecordNotUnique and
    #   writes nothing;
    # - upsert_all (upsert): write, then a created or updated event per row
    #   (existing rows found by the conflict key first); rejected in the
    #   events-only store, where ON CONFLICT would check the table, not the
    #   stream. Where the streams are checked, the rows it conflicts with are
    #   locked (within bulk_write_lock_limit) and their streams read
    #   (bring_upsert_rows_up_to_date): in ES-Async, with the keys the rows
    #   give, their rows are brought up to date with their streams, so a
    #   destroyed record whose row was still in the table is inserted again
    #   (a Created after the Destroyed), as Monitor inserts it; in ES-Lazy a
    #   destroy committed after the write's catch-up refuses the upsert with
    #   RecordDestroyedError before anything is written, since ON CONFLICT
    #   would update that row and bring the record back. A value of a unique
    #   index other than its conflict columns that another record holds, or
    #   (ES-Async, ES-Lazy) a value of its conflict columns whose holder's
    #   row is not in the table, raises ActiveRecord::RecordNotUnique and
    #   writes nothing (refuse_unique_upsert: the table's statement, or in
    #   ES-Async and ES-Lazy the event store, before the write). In ES-Sync,
    #   ES-Async and ES-Lazy the unique values' locks count against
    #   bulk_write_lock_limit with the rows' (refuse_lock_limit_upsert);
    # - Rails' association nullify: always allowed, events then write;
    #   limited and checked as the bulk writes are where the streams are
    #   checked. Only the write Rails' association code marks
    #   (Lyra::Associations::Maintenance: a has_many's dependent: :nullify
    #   and the removal of its children, a has_many :through's
    #   dependent: :nullify); the same update_all made by the application
    #   (Model.where(...).update_all(fk: nil)) is a bulk write, guarded. A
    #   has_one's dependent: :nullify is Rails' update_columns of the record
    #   it marked: the column path, with no strict guard
    #   (request_association_column); removing records from a has_many
    #   :through whose through model is monitored deletes the through
    #   records it marked: the bulk path, with no strict guard
    #   (request_through_delete);
    # - has_and_belongs_to_many links (link): deleting join rows
    #   (Lyra::Associations::HabtmLinks). When Rails' association code
    #   deletes the rows it marked (delete, delete_all, clear, destroy,
    #   destroy_all, assigning records or ids, destroying the owner, and the
    #   same through a model the application declared on the join table)
    #   it is always allowed (request_unlink); the application's own
    #   delete_all on the join model, or on its model of the join table, is
    #   guarded as a bulk write is (request_join), when either side's model
    #   is monitored. Either way: write, then an AssociationUnlinked event
    #   (publish_unlink), wherever a side is monitored: on the owner's
    #   stream, linked into the associated records'; when only the
    #   associated records' model is monitored, on their streams; through
    #   the application's model of a join table several associations share,
    #   and for a row naming another association's owner too, on the stream
    #   of every monitored owner the rows name, as Rails' unlink from that
    #   side records it. The application's insert_all, insert_all! and
    #   upsert_all of join rows (insert, insert!, upsert) are guarded the
    #   same way (request_join_insert); allowed: write, then an
    #   AssociationLinked event for each row written (publish_link; an
    #   upsert that moved a row to another pair also unlinks the old one),
    #   recorded as Rails' own link from each side records it. A row ON
    #   CONFLICT skipped, or an upsert that left every pair as it was,
    #   records nothing (skip_conflict_link); insert_all! of a pair taken
    #   raises ActiveRecord::RecordNotUnique (refuse_conflict_link). A table
    #   is a join table when a has_and_belongs_to_many whose links Lyra
    #   records names it, the owner's model monitored or not
    #   (HabtmLinks.join_model_of). A write no monitored side records is not
    #   Lyra's: neither guarded nor modelled. The join rows live in a table
    #   in every configuration (ES-NoProj's too), and have no stream of
    #   their own: no Genesis, no stream check, no lock limit. (Rails'
    #   join-row inserts go through the join model's callbacks, one row at
    #   a time, and are recorded as AssociationLinked the same way; they are
    #   no bypass.)
    #
    # With strict mode on, each guarded method is rejected unless it runs
    # inside Lyra.without_strict_access (allow_*_in_bypass_block).
    #
    # The record the write reaches is one of three (a choice of the data,
    # not of the configuration):
    #
    # - live, and admitted: the write and its events, as above;
    # - a row Genesis could not import (config.genesis_unrepresentable :skip
    #   left it without a stream, or :refuse refused the model's import):
    #   Lyra::Genesis::Refused before any write or event (admit_all!), where
    #   Genesis runs (Hijack and the event-sourcing modes; Monitor with
    #   genesis: true). insert_all creates new rows, none of which is asked,
    #   nor is a join row (link); but where it reads keys or unique values
    #   from the event store (ES-NoProj, ES-Async, ES-Lazy), the model's
    #   first use refuses it when the model's import was refused
    #   (genesis_unrepresentable :refuse; refuse_genesis_insert);
    # - destroyed: its stream ends in a destroy (or, table-backed, its row
    #   is gone). No write and no event (unchanged): Active Record's write of
    #   a row already gone reaches none, and an event would bring the record
    #   back or log a second destroy. upsert_all and insert_all have no such
    #   ending: a destroyed record whose row is gone (in ES-Async, once its
    #   row is brought up to date) is inserted again (a new Created, as
    #   create!(id:) gives), and in ES-Lazy one whose row is still in the
    #   table refuses the upsert (above). insert_all's unchanged ending is a
    #   key or a unique value a live record holds (in ES-NoProj, as the
    #   event store holds it, read under its lock; the table's row of any
    #   other, left by a destroyed record, is deleted and the row inserted).
    #
    # The property checked by .coverage is Bypass Coverage: every reachable
    # marking in which nothing can fire ends in exactly one way: rejected
    # (nothing written, nothing logged), a store change with an event
    # logged, or unchanged with neither. A store change without an event is
    # a silent write; an event for a write that changed nothing (unchanged)
    # is the destroyed record brought back; a rejection beside a write or an
    # event is a write the refusal did not take back.
    #
    # What the net leaves out, by design:
    #
    # - config.record_touches true, the default, is modelled. With it false
    #   (Monitor only), a touch or touch_all whose only changes are the
    #   update timestamps ends at store_changed with no event;
    # - the append is modelled as succeeding. Where events are required
    #   (Hijack, the event-sourcing modes, Monitor with
    #   monitor_append_failure :fail_write) a failed one rolls the write
    #   back; in Monitor otherwise it is logged and the write stands without
    #   its event. So in Monitor with genesis: true, delete and dependent:
    #   :nullify, which ask Genesis inside the publish, write a row Genesis
    #   skipped (genesis_unrepresentable :skip) without an event, and log
    #   it: it has no stream to add to, and the other children of a nullify
    #   keep theirs. update_column(s), touch, the bulk writes and upsert_all
    #   ask before they write, and are refused there too. A link or unlink
    #   asks Genesis for the associated records' model inside its publish
    #   (HabtmLinks.link_into_targets), a refusal handled as a failed append;
    # - config.lock_aggregate_before_append on, the default, is modelled.
    #   With it off no stream is checked and no record's lock limited
    #   (checks_streams? is false; the unique values' locks still are):
    #   ES-Async and ES-Lazy write as table_backed, and an ES-NoProj
    #   write to a destroyed record logs an event after the destroy, as a
    #   write through callbacks does there with the lock off;
    # - a has_many :through over a model Lyra does not monitor: its through
    #   rows are that model's, written through its callbacks or by Rails'
    #   delete_all of them, and no link of either side is recorded, so none
    #   of its writes is modelled (its table is no join table:
    #   HabtmLinks.join_model_of). Monitored, the through model's rows are
    #   any monitored model's (request_through_delete, the bulk path);
    # - a model whose primary key has several columns, which Lyra does not
    #   support (refused at enrolment where the key is known): enrolled
    #   before Active Record read it, its bulk inserts are refused in the
    #   event-sourcing modes before anything is written, and Genesis refuses
    #   the model on its first use there; Monitor and Hijack record them
    #   (Genesis skips such a model there);
    # - ES-NoProj's create and update through callbacks are not bypass
    #   writes (their unique indexes are checked from the event store as
    #   update_column(s)' and update_all's are, Lyra::Projections
    #   ::UniqueIndexes);
    # - Lyra.unrecorded_write, the application's write without events
    #   (seeding, fixtures, a wipe): inside it each write here is past the
    #   strict guard and records no event for its rows, only the block's
    #   UnrecordedWrite (reason, caller) in Lyra::UnrecordedWrites, or is
    #   refused with the block (config.unrecorded_writes :deny); Lyra's own
    #   projection writes (Lyra.projection_write) record nothing;
    # - a projection's refusal (Lyra::Projections::ProjectionBehind,
    #   DuplicateInLog) is not a bypass write's outcome: an ES-Async job or
    #   an ES-Lazy catch-up meets it after the write committed. Inside one,
    #   only where ES-Async brings rows up to date before writing
    #   (AsyncProjectionJob.project_pending, UniqueIndexes
    #   .bring_rows_up_to_date), it is an ActiveRecord::RecordNotUnique
    #   raised before the write, which writes and records nothing: rejected,
    #   as refuse_conflict_insert and refuse_unique_* end;
    class BypassWorkflow < PetriFlow::Workflow
      # Every callback-bypassing method Lyra overrides, and the behaviour
      # class that models it. Kept equal to the overrides in
      # StrictDataAccess and StrictDataAccessRelation by
      # test/verification/bypass_workflow_test.rb.
      METHODS = {
        update_columns: :column,
        update_column: :column,
        delete: :instance,
        update_all: :bulk,
        delete_all: :bulk,
        insert_all: :insert,
        insert_all!: :insert,
        upsert_all: :upsert,
        touch: :touch,
        touch_all: :bulk
      }.freeze

      # Class-level methods Lyra overrides elsewhere (ES-NoProj's
      # CrudInterceptor) that write through a method of METHODS. Kept equal
      # to those overrides by the same test.
      ROUTED = {
        update_counters: :update_all,
        increment_counter: :update_all,
        decrement_counter: :update_all
      }.freeze

      workflow_name "Callback-Bypassing Writes"

      places :idle, :ready,
             :strict_on, :strict_off, :table_backed, :events_only, :streams_checked,
             :instance_requested, :instance_allowed, :instance_event_first,
             :column_requested, :column_allowed, :column_event_pending,
             :touch_requested, :touch_event_pending,
             :bulk_requested, :bulk_allowed, :bulk_event_pending,
             :insert_requested, :insert_allowed, :insert_ready, :insert_event_pending,
             :upsert_requested, :upsert_allowed, :upsert_ready, :upsert_event_pending,
             :nullify_allowed, :nullify_event_first,
             :join_requested, :link_allowed, :link_event_pending,
             :join_insert_requested, :join_insert_allowed, :linked_event_pending,
             :rejected, :event_logged, :store_changed, :unchanged

      initial_place :idle
      terminal_places :rejected, :store_changed, :unchanged

      # Configuration
      transition :configure_strict_table, from: :idle, to: [:strict_on, :table_backed, :ready],
                 trigger: "strict_data_access = true; ES-Sync, Hijack or Monitor"
      transition :configure_strict_lagging, from: :idle, to: [:strict_on, :table_backed, :streams_checked, :ready],
                 trigger: "strict_data_access = true; ES-Async or ES-Lazy (BypassEvents.checks_streams?)"
      transition :configure_strict_events, from: :idle, to: [:strict_on, :events_only, :streams_checked, :ready],
                 trigger: "strict_data_access = true, event sourcing with projections disabled"
      transition :configure_permissive_table, from: :idle, to: [:strict_off, :table_backed, :ready],
                 trigger: "strict_data_access = false (default); ES-Sync, Hijack or Monitor"
      transition :configure_permissive_lagging, from: :idle, to: [:strict_off, :table_backed, :streams_checked, :ready],
                 trigger: "strict_data_access = false; ES-Async or ES-Lazy (BypassEvents.checks_streams?)"
      transition :configure_permissive_events, from: :idle, to: [:strict_off, :events_only, :streams_checked, :ready],
                 trigger: "strict_data_access = false, event sourcing with projections disabled"

      # The strict guard, shared by every overridable method
      %i[instance column bulk insert upsert].each do |kind|
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

      # update_column(s): write, then publish the persisted change
      # (StrictDataAccess#with_bypass_event)
      transition :write_column, from: :column_allowed, to: [:store_changed, :column_event_pending],
                 trigger: "super (SQL), persisted values read first"
      # A value a unique index refuses: the table's UPDATE raises (ES-Sync:
      # under the value's lock); in ES-NoProj, ES-Async and ES-Lazy the
      # event store says it is taken, before anything is written or
      # recorded (Lyra::Projections::UniqueIndexes).
      transition :refuse_unique_column, from: :column_allowed, to: :rejected,
                 trigger: "raise ActiveRecord::RecordNotUnique (a unique index: the table's UPDATE, or in ES-NoProj, " \
                          "ES-Async and ES-Lazy a value a live record holds in the event store, UniqueIndexes)"
      transition :publish_column_event, from: :column_event_pending, to: :event_logged,
                 trigger: "BypassEvents.publish"

      # touch: never a strict-mode violation; write, then publish
      transition :request_touch, from: :ready, to: :touch_requested,
                 trigger: "touch, or belongs_to ... touch: true"
      transition :write_touch, from: :touch_requested, to: [:store_changed, :touch_event_pending],
                 trigger: "super (SQL)"
      transition :publish_touch_event, from: :touch_event_pending, to: :event_logged,
                 trigger: "BypassEvents.publish"

      # delete: publish, then write (StrictDataAccess)
      transition :publish_instance_event, from: :instance_allowed, to: [:event_logged, :instance_event_first],
                 trigger: "BypassEvents.publish"
      transition :write_instance, from: :instance_event_first, to: :store_changed,
                 trigger: "super (SQL)"

      # update_all, delete_all, touch_all: write, then an event per row
      # (StrictDataAccessRelation)...
      transition :write_bulk, from: [:bulk_allowed, :table_backed], to: [:store_changed, :bulk_event_pending, :table_backed],
                 trigger: "super (SQL) on the rows snapshotted, and locked, first"
      transition :publish_bulk_events, from: :bulk_event_pending, to: :event_logged,
                 trigger: "BypassEvents.publish_updates / publish_destroys"
      # ...or, with the stream as the only store, the events are the write
      # (CachedRelation#event_sourced_bulk_mutate)
      transition :publish_bulk_as_write, from: [:bulk_allowed, :events_only], to: [:event_logged, :store_changed, :events_only],
                 trigger: "BypassEvents.publish per record selected now (locked_records_now)"
      # A value a unique index refuses (update_all; update_counters reaches
      # it): the table's UPDATE raises; in ES-NoProj, ES-Async and ES-Lazy
      # the records' tuples are checked against each other and the event
      # store before any write or event (UniqueIndexes::BulkUpdate).
      transition :refuse_unique_bulk, from: :bulk_allowed, to: :rejected,
                 trigger: "raise ActiveRecord::RecordNotUnique (a unique index: the table's UPDATE, or in ES-NoProj, " \
                          "ES-Async and ES-Lazy the values the records would hold, UniqueIndexes::BulkUpdate)"

      # insert_all(!): the rows made to conflict as Monitor's would where
      # the streams are checked, or as given...
      transition :insert_as_given, from: :insert_allowed, to: :insert_ready,
                 trigger: "the rows as given: a table that does not lag, ES-Lazy (caught up when the write began), " \
                          "rows that give no key"
      transition :bring_insert_keys_up_to_date, from: [:insert_allowed, :streams_checked],
                 to: [:insert_ready, :streams_checked],
                 trigger: "the keys and unique values the rows give, locked: ES-NoProj reads them from the event store " \
                          "(events_only_inserts); ES-Async brings their rows up to date with their streams " \
                          "(AsyncProjectionJob.project_pending); ES-Async and ES-Lazy read the unique values " \
                          "from the event store (projected_unique_rows)"
      transition :refuse_lock_limit_insert, from: :insert_allowed, to: :rejected,
                 trigger: "raise BulkWriteLockLimitError (the keys locked where the streams are checked, and in ES-Sync, " \
                          "ES-Async and ES-Lazy the unique values: projected_unique_rows)"
      transition :refuse_genesis_insert, from: [:insert_allowed, :streams_checked], to: [:rejected, :streams_checked],
                 trigger: "raise Genesis::Refused (Genesis.first_use, before the keys or unique values are read " \
                          "from the event store: the model's import refused, genesis_unrepresentable :refuse)"
      # ...then write, then a created event per row, in every store
      # (StrictDataAccessRelation; CachedRelation#insert_through_table)
      transition :write_insert, from: :insert_ready, to: [:store_changed, :insert_event_pending],
                 trigger: "super (SQL), primary keys returned"
      transition :publish_insert_events, from: :insert_event_pending, to: :event_logged,
                 trigger: "BypassEvents.publish_upserts (created)"
      # A key or a unique value taken: insert_all skips the row, insert_all!
      # fails its statement. Neither writes or records anything. In
      # ES-NoProj the event store says which are taken
      # (StrictDataAccessRelation#events_only_inserts, under their locks),
      # and in ES-Async and ES-Lazy which unique values are
      # (projected_unique_rows): the conflict is found before anything is
      # written.
      transition :skip_conflict_insert, from: :insert_ready, to: :unchanged,
                 trigger: "insert_all: ON CONFLICT DO NOTHING, no key returned " \
                          "(ES-NoProj: a key or unique value the event store holds, left out of the insert)"
      transition :refuse_conflict_insert, from: :insert_ready, to: :rejected,
                 trigger: "insert_all!, or a conflict on an index other than insert_all's unique_by: " \
                          "raise ActiveRecord::RecordNotUnique"

      # Rails' association nullify, always allowed (StrictDataAccessRelation
      # #update_all; in ES-NoProj AssociationInterceptor and CachedRelation,
      # through the bulk write)
      transition :request_nullify, from: :ready, to: :nullify_allowed,
                 trigger: "Rails' association code nullifies the relation it marked " \
                          "(Lyra::Associations::Maintenance: dependent: :nullify, children removed); " \
                          "the application's update_all(fk: nil) is request_bulk"
      transition :publish_nullify_events, from: :nullify_allowed, to: [:event_logged, :nullify_event_first],
                 trigger: "publish_nullify_events"
      transition :write_nullify, from: :nullify_event_first, to: :store_changed,
                 trigger: "super (SQL)"

      # has_one dependent: :nullify: Rails' update_columns of the record it
      # marked, the column path without the strict guard (StrictDataAccess
      # #update_columns).
      transition :request_association_column, from: :ready, to: :column_allowed,
                 trigger: "has_one dependent: :nullify: update_columns of the record Rails marked"

      # Removing records from a has_many :through whose through model is
      # monitored: Rails deletes the through records it marked, the bulk
      # path without the strict guard (StrictDataAccessRelation#delete_all,
      # CachedRelation#publish_bulk_events).
      transition :request_through_delete, from: :ready, to: :bulk_allowed,
                 trigger: "has_many :through: delete_all of the through records Rails marked"

      # has_and_belongs_to_many links. Rails' own deletes of the join rows
      # it marked are never refused; the application's delete_all on the
      # join model (or its model of the join table) is guarded as a bulk
      # write is. Then the rows are read, deleted, and each owner's unlink
      # logged (HabtmLinks.delete_all), in every configuration.
      transition :request_unlink, from: :ready, to: :link_allowed,
                 trigger: "Rails' association code deletes the join rows it marked " \
                          "(delete, clear, destroy, assigning, the owner destroyed)"
      transition :request_join, from: :ready, to: :join_requested,
                 trigger: "the application's delete_all on a join model or its model of the join table"
      transition :reject_join, from: [:join_requested, :strict_on], to: [:rejected, :strict_on],
                 trigger: "raise StrictDataAccessViolation"
      transition :allow_join, from: [:join_requested, :strict_off], to: [:link_allowed, :strict_off],
                 trigger: "strict mode off"
      transition :allow_join_in_bypass_block, from: [:join_requested, :strict_on], to: [:link_allowed, :strict_on],
                 trigger: "inside Lyra.without_strict_access"
      transition :write_unlink, from: :link_allowed, to: [:store_changed, :link_event_pending],
                 trigger: "super (SQL), the pairs read first"
      transition :publish_unlink, from: :link_event_pending, to: :event_logged,
                 trigger: "AssociationUnlinked on each monitored side's streams, every owner a row names " \
                          "(HabtmLinks.publish, publish_sides)"

      # The application's insert_all, insert_all!, upsert_all of join rows,
      # guarded as its delete_all of them is; the rows written read back
      # (RETURNING) and each side's link logged (HabtmLinks.insert_all), in
      # every configuration.
      transition :request_join_insert, from: :ready, to: :join_insert_requested,
                 trigger: "the application's insert_all, insert_all! or upsert_all on a join model " \
                          "or its model of the join table"
      transition :reject_join_insert, from: [:join_insert_requested, :strict_on], to: [:rejected, :strict_on],
                 trigger: "raise StrictDataAccessViolation"
      transition :allow_join_insert, from: [:join_insert_requested, :strict_off], to: [:join_insert_allowed, :strict_off],
                 trigger: "strict mode off"
      transition :allow_join_insert_in_bypass_block, from: [:join_insert_requested, :strict_on],
                 to: [:join_insert_allowed, :strict_on],
                 trigger: "inside Lyra.without_strict_access"
      transition :write_link, from: :join_insert_allowed, to: [:store_changed, :linked_event_pending],
                 trigger: "super (SQL), the rows written returned (an upsert's rows read by its keys first)"
      transition :publish_link, from: :linked_event_pending, to: :event_logged,
                 trigger: "AssociationLinked on each monitored side's streams, every owner a row names " \
                          "(an upsert that moved a row: the old pair's AssociationUnlinked too; HabtmLinks.publish_sides)"
      transition :skip_conflict_link, from: :join_insert_allowed, to: :unchanged,
                 trigger: "ON CONFLICT DO NOTHING skipped every row, or an upsert left every pair as it was"
      transition :refuse_conflict_link, from: :join_insert_allowed, to: :rejected,
                 trigger: "insert_all! of a pair taken: raise ActiveRecord::RecordNotUnique"

      # upsert_all: snapshot by conflict key, write, then created/updated events
      transition :upsert_as_given, from: [:upsert_allowed, :table_backed], to: [:upsert_ready, :table_backed],
                 trigger: "the rows found by conflict key, as the table has them (ES-Sync, Hijack, Monitor)"
      # Where the streams are checked, the rows it conflicts with (and, in
      # ES-Async, the keys the rows give) are locked and their streams read
      # first (StrictDataAccessRelation#lock_upserted_rows).
      transition :bring_upsert_rows_up_to_date, from: [:upsert_allowed, :table_backed, :streams_checked],
                 to: [:upsert_ready, :table_backed, :streams_checked],
                 trigger: "their rows brought up to date with their streams and read again " \
                          "(ES-Async: AsyncProjectionJob.project_pending; ES-Lazy: LazyProjection.refresh_records)"
      transition :write_upsert, from: [:upsert_ready, :table_backed], to: [:store_changed, :upsert_event_pending, :table_backed],
                 trigger: "super (SQL), existing rows snapshotted by conflict key first"
      transition :publish_upsert_events, from: :upsert_event_pending, to: :event_logged,
                 trigger: "BypassEvents.publish_upserts"
      # A value of a unique index other than the conflict columns that
      # another record holds: the table's statement raises; in ES-Async and
      # ES-Lazy the event store says it is taken (a record not yet projected
      # holds it), or a value of the conflict columns is held by a record
      # whose row is not in the table, before anything is written or
      # recorded (StrictDataAccessRelation#projected_unique_rows).
      transition :refuse_unique_upsert, from: :upsert_ready, to: :rejected,
                 trigger: "raise ActiveRecord::RecordNotUnique (a unique index: the table's statement, or in ES-Async " \
                          "and ES-Lazy a value a live record holds in the event store, or a conflict-column holder " \
                          "whose row is not in the table, projected_unique_rows)"
      transition :reject_upsert_events_only, from: [:upsert_allowed, :events_only], to: [:rejected, :events_only],
                 trigger: "raise UnsupportedQuery (ON CONFLICT would check the table, not the stream)"
      transition :refuse_lock_limit_upsert, from: [:upsert_allowed, :table_backed], to: [:rejected, :table_backed],
                 trigger: "raise BulkWriteLockLimitError (the rows locked where the streams are checked, and in ES-Sync, " \
                          "ES-Async and ES-Lazy the unique values: projected_unique_rows)"
      transition :refuse_destroyed_upsert, from: [:upsert_allowed, :table_backed, :streams_checked],
                 to: [:rejected, :table_backed, :streams_checked],
                 trigger: "ES-Lazy: raise RecordDestroyedError (a destroy committed after the write's catch-up, " \
                          "its row still in the table)"

      # A row Genesis could not import: refused before any write or event.
      # upsert_all asks after the events-only rejection (its snapshot by
      # conflict key admits the rows), so only where there is a table.
      {
        column: :column_allowed, touch: :touch_requested, instance: :instance_allowed,
        bulk: :bulk_allowed, nullify: :nullify_allowed
      }.each do |kind, at|
        transition :"refuse_genesis_#{kind}", from: at, to: :rejected,
                   trigger: "raise Genesis::Refused (Genesis.admit_all!)"
      end
      transition :refuse_genesis_upsert, from: [:upsert_allowed, :table_backed], to: [:rejected, :table_backed],
                 trigger: "raise Genesis::Refused (Genesis.admit_all!)"

      # More locks than config.bulk_write_lock_limit: refused before any
      # write or event (BypassEvents.check_lock_limit!). The records'
      # aggregate locks where the streams are checked; for update_all,
      # insert_all(!) and upsert_all in ES-Sync, ES-Async and ES-Lazy also
      # the unique values' (UniqueIndexes::BulkUpdate#check!,
      # projected_unique_rows), so ES-Sync, which shares table_backed with
      # Hijack and Monitor, reaches the bulk, insert and upsert refusals.
      transition :refuse_lock_limit_bulk, from: :bulk_allowed, to: :rejected,
                 trigger: "raise BulkWriteLockLimitError (the records locked where the streams are checked, and in " \
                          "ES-Sync an update_all's unique values: UniqueIndexes::BulkUpdate#check!)"
      transition :refuse_lock_limit_nullify, from: [:nullify_allowed, :streams_checked], to: [:rejected, :streams_checked],
                 trigger: "raise BulkWriteLockLimitError"

      # A record destroyed since it was read: no write, no event. Where the
      # streams are checked, its stream ends in a destroy, read under its
      # aggregate lock (BypassEvents.destroyed_ids / locked_snapshot,
      # CachedRelation#locked_records_now; a row still in the table is not
      # written: BypassEvents.unwritten); table-backed, its row is gone
      # (SQL matches none; delete locks the row first and finds none).
      {
        column: :column_allowed, touch: :touch_requested, instance: :instance_allowed,
        bulk: :bulk_allowed, nullify: :nullify_allowed
      }.each do |kind, at|
        transition :"skip_destroyed_#{kind}", from: at, to: :unchanged,
                   trigger: "the record's stream ends in a destroy, or its row is gone"
      end

      ENDING_PLACES = %i[rejected store_changed event_logged unchanged].freeze
      # The outcome places a covered dead marking holds, exactly.
      ENDINGS = [%i[rejected], %i[event_logged store_changed], %i[unchanged]].freeze

      # Bypass Coverage over every reachable dead marking of the workflow.
      #
      # @return [Hash] covered: true when there is no silent write;
      #   dead_markings: how many there are; unchanged: how many of them
      #   end with no write and no event; silent_writes: the offending dead
      #   markings (any other combination of ENDING_PLACES, none included),
      #   as place => tokens hashes.
      def self.coverage(workflow = new)
        analyzer = PetriFlow::Verification::ReachabilityAnalyzer.new(workflow.net, workflow.initial_marking)
        analyzer.analyze
        dead = analyzer.reachable_markings.filter_map do |marking|
          workflow.net.set_marking(marking)
          marked_places(marking, workflow) if workflow.net.deadlocked?
        end

        endings = dead.map { |marked| marked.slice(*ENDING_PLACES).keys.sort }
        silent = dead.reject.with_index { |_, i| ENDINGS.include?(endings[i]) }

        {
          covered: silent.empty?,
          dead_markings: dead.size,
          unchanged: endings.count(%i[unchanged]),
          silent_writes: silent
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
