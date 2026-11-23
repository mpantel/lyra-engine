module Lyra
  # An update or destroy of a record whose event stream says it was destroyed
  # (see CrudInterceptor#lyra_lock_aggregate_unless_destroyed!). A
  # RecordNotFound, as for any write to a record that is gone.
  class RecordDestroyedError < ActiveRecord::RecordNotFound; end

  module Interceptors
    # Where hijack and event-sourcing modes take over a write.
    #
    # Prepended to ActiveRecord::Persistence, so these methods sit directly
    # above the ones that issue the INSERT, UPDATE and DELETE, and run inside
    # the create/update/destroy callbacks' block: after every before_* callback
    # of the model, whichever class defined it, and before the row write. The
    # event therefore sees the record as the application finished preparing it.
    #
    # This replaces before_create/before_update/before_destroy callbacks
    # registered on ActiveRecord::Base, which ran before the model's own. Values
    # those set (Solidus's Order#guest_token and Payment#number) were missing
    # from hijack events, and lost from the table under event sourcing, where
    # the row is projected from the event. A failed command returns false:
    # Rails then skips the after_* callbacks, save returns false and the
    # transaction rolls back (throw(:abort) is not caught inside the block).
    module WriteHooks
      def _create_record(*args)
        # A has_and_belongs_to_many join row: recorded as a link of its owner.
        return Lyra::Associations::HabtmLinks.create(self) { super(*args) } if Lyra::Associations::HabtmLinks.join_model?(self.class)

        lyra_genesis_first_use
        return super unless lyra_takes_over_write_here?
        return false unless lyra_hijack_mode? ? lyra_hijack_create : lyra_prepare_event_source_create

        # The columns to insert were chosen above this point (partial inserts),
        # before the command reserved the ID. Add the primary key, or the row
        # gets a database-assigned ID different from the one the event carries.
        pk = self.class.primary_key
        args[0] = Array(args[0]) | [pk] if args.any? && pk && !id.nil?
        super(*args)
      ensure
        # The skip-insert signal is for this record's INSERT only. Left set
        # (as it was when a later step failed), the next insert of any model
        # on this thread silently skipped its row while reporting success.
        Thread.current[:lyra_skip_insert] = nil
      end

      def _update_record(*args)
        lyra_genesis_first_use
        return super unless lyra_takes_over_write_here?

        # The key names the record's stream: a change of it would be recorded
        # on another record's stream (Hypothesis H, Lyra::StreamHeads).
        pk = self.class.primary_key
        if pk.is_a?(String) && will_save_change_to_attribute?(pk)
          Lyra::StreamHeads.refuse_key_change!(self.class, attribute_in_database(pk), read_attribute(pk))
        end
        return lyra_hijack_with_row_write { lyra_hijack_update ? super(*args) : false } if lyra_hijack_atomically?
        return false unless lyra_hijack_mode? ? lyra_hijack_update : lyra_prepare_event_source_update

        super
      end

      def destroy
        lyra_genesis_first_use
        # Active Record deletes no row of a record that is not persisted (a new
        # one, or a copy already destroyed) but still runs after_destroy:
        # nothing is recorded for it (CrudInterceptor#lyra_intercept_destroy).
        # Otherwise _delete_row counts the rows its DELETE reached.
        @lyra_rows_deleted = persisted? ? nil : 0 if respond_to?(:lyra_events_enabled?, true)
        return super unless lyra_takes_over_write_here? && persisted?
        return lyra_hijack_with_row_write { lyra_hijack_destroy ? super() : false } if lyra_hijack_atomically?
        return false unless lyra_hijack_mode? ? lyra_hijack_destroy : lyra_prepare_event_source_destroy

        super
      end

      private

      # Hijack appends a write's event before its row write. With optimistic
      # locking the row write can raise (StaleObjectError, the row's version
      # moved on) after the append; a caller that rescues inside an enclosing
      # transaction then commits the event of an update that never happened,
      # and the log and the row part. The append and the row write go in one
      # savepoint, so they commit or roll back together. The row lock taken
      # before the append is held to the end of the transaction when the
      # write succeeds (Assumption L); a savepoint rolled back releases it
      # with the write. Without optimistic locking an update or destroy that
      # reaches no row does not raise, and no savepoint is taken.
      def lyra_hijack_atomically?
        lyra_hijack_mode? && Lyra::OptimisticLocking.enabled?(self.class)
      end

      def lyra_hijack_with_row_write(&)
        self.class.transaction(requires_new: true, &)
      rescue StandardError
        # The savepoint took the event with it.
        @lyra_write_scope&.lost!("not saved")
        raise
      end

      # Before the model's first write in this process, give its pre-existing
      # rows their Imported events (Lyra::Genesis), so this write's event never
      # starts a stream without a head.
      def lyra_genesis_first_use
        return unless respond_to?(:lyra_events_enabled?, true) && lyra_events_enabled?

        Lyra::Genesis.first_use(self.class, (id if persisted?))
      end

      def lyra_takes_over_write_here?
        respond_to?(:lyra_takes_over_write?, true) && lyra_takes_over_write?
      end
    end

    # Where a write scope opens (CrudInterceptor#lyra_write_scope): around
    # the whole save or destroy callback chain, inside the write's
    # transaction. Prepended to ActiveRecord::Callbacks, so these methods sit
    # above Callbacks#create_or_update and Callbacks#destroy (which run the
    # callbacks) and below Transactions (which opens the transaction).
    #
    # The scope used to be an around_save/around_destroy callback, first in
    # its chain. Active Model prepends after_* callbacks, so a model's own
    # after_save and after_destroy ran outside it, and the writes they make
    # (Solidus's Payment#update_order) had no cause. Wrapping the chain from
    # outside adds no callback, so the application's callbacks keep their
    # order.
    #
    # A destroy chain run without Callbacks#destroy (a soft delete:
    # paranoia's paranoia_destroy runs run_callbacks(:destroy) itself, in
    # with_transaction_returning_status) gets its scope from run_callbacks;
    # a normal destroy, whose chain runs inside the scope destroy opened,
    # does not open a second one.
    module WriteScopeHooks
      def destroy
        return super unless lyra_write_scope_here?

        lyra_destroy_scope { super }
      end

      def run_callbacks(kind, type = nil, &block)
        return super unless kind.to_sym == :destroy && !@lyra_destroy_scope_open && lyra_write_scope_here?

        lyra_destroy_scope { super(kind, type, &block) }
      end

      private

      def create_or_update(**options)
        return super unless lyra_write_scope_here?

        lyra_write_scope(new_record? ? :create : :update) { super(**options) }
      end

      def lyra_destroy_scope
        open, @lyra_destroy_scope_open = @lyra_destroy_scope_open, true
        lyra_write_scope(:destroy) { yield }
      ensure
        @lyra_destroy_scope_open = open
      end

      def lyra_write_scope_here?
        respond_to?(:lyra_events_enabled?, true) && lyra_events_enabled?
      end
    end

    module CrudInterceptor

      extend ActiveSupport::Concern

      included do
        # Track if this model is being monitored
        class_attribute :lyra_monitored, default: false
        class_attribute :lyra_config

        # Callbacks for monitoring CRUD operations (after_* = non-blocking).
        # Gated on the mode as well as the model: in :disabled mode a monitored
        # model must behave exactly like plain ActiveRecord and emit no events.
        after_create :lyra_intercept_create, if: :lyra_events_enabled?
        after_update :lyra_intercept_update, if: :lyra_events_enabled?
        after_destroy :lyra_intercept_destroy, if: :lyra_events_enabled?

        # Every event-producing write runs in a write scope
        # (config.correlate_writes): its event id is fixed before any of its
        # callbacks, so the writes they make record it as their cause, or the
        # cause in scope when the write records no event (Causation::
        # WriteScope, Lyra::SavesWithoutEffect), and the outermost write opens
        # the correlation when none is in scope. The scope wraps the whole
        # callback chain, after_save and after_destroy included
        # (WriteScopeHooks).
        ActiveRecord::Callbacks.prepend(WriteScopeHooks) unless ActiveRecord::Callbacks.ancestors.include?(WriteScopeHooks)

        # Hijack and event-sourcing modes build their event in WriteHooks, after
        # every before_* callback and just before the row write (see below).
        # Only PaperTrail is switched off here, first, so that its own
        # callbacks (a before_destroy among them) do not record a version that
        # Lyra's event replaces.
        before_create :lyra_disable_paper_trail!, if: :lyra_takes_over_write?, prepend: true
        before_update :lyra_disable_paper_trail!, if: :lyra_takes_over_write?, prepend: true
        before_destroy :lyra_disable_paper_trail!, if: :lyra_takes_over_write?, prepend: true

        ActiveRecord::Persistence.prepend(WriteHooks) unless ActiveRecord::Persistence.ancestors.include?(WriteHooks)

        # After callbacks to finalize event sourcing
        after_create :lyra_finalize_event_source, if: :lyra_event_sourcing_mode?
        after_update :lyra_finalize_event_source, if: :lyra_event_sourcing_mode?
        after_destroy :lyra_finalize_event_source, if: :lyra_event_sourcing_mode?

        # H2, opt-in (config.check_effects): the row as written against its
        # events, after the row write and in its transaction (Lyra::EffectCheck).
        after_create :lyra_check_effect, if: :lyra_checks_effects?
        after_update :lyra_check_effect, if: :lyra_checks_effects?
        after_destroy :lyra_check_effect, if: :lyra_checks_effects?

        # Sampled DualView verification after commit (Lyra::DualViewSampler);
        # off unless config.dual_view_sample_rate is above 0.
        after_commit :lyra_sample_dual_view, if: :lyra_events_enabled?

        # Purpose-bound reads (Lyra::PurposeBoundReads): a loaded record is
        # checked against its policy for the purpose in scope.
        after_find :lyra_check_read_purpose, if: :lyra_monitored?

        # ES-NoProj: a validated update locks its record before its
        # uniqueness validation locks the value (lyra_lock_aggregate_before_validation).
        before_validation :lyra_lock_aggregate_before_validation, prepend: true, if: :lyra_event_sourcing_mode?
      end

      # Override _update_row to skip SQL UPDATE in event_sourcing mode.
      # Rails 6.1+ calls _update_row from within _run_update_callbacks,
      # so this runs AFTER before_update callbacks when @lyra_skip_sql is set.
      def _update_row(attribute_names, attempted_action = "update")
        if @lyra_skip_sql
          # Skip the UPDATE - projection will handle it
          # Return 1 to indicate one row was "updated"
          1
        elsif lyra_event_sourcing_mode? && Lyra::OptimisticLocking.enabled?(self.class)
          lyra_update_row_checked_by_log(attribute_names, attempted_action)
        else
          # How many rows the UPDATE reached: after_update runs even when it
          # reached none (a concurrent destroy took the row), and Monitor must
          # not record an update that changed nothing (lyra_intercept_update).
          @lyra_rows_updated = super
        end
      end

      # Override _delete_row to skip SQL DELETE in event_sourcing mode.
      # Similar to _update_row, runs after before_destroy callbacks.
      def _delete_row
        if @lyra_skip_sql
          # Skip the DELETE - projection will handle it
          # Return 1 to indicate one row was "deleted"
          1
        else
          # How many rows the DELETE reached: after_destroy runs even when it
          # reached none (a stale copy, whose row another copy, a delete_all or
          # hand-written SQL deleted first; without optimistic locking nothing
          # checks), and Monitor must not record a second destroy
          # (lyra_intercept_destroy).
          @lyra_rows_deleted = super
        end
      end

      # The attribution metadata every event of this record's writes carries,
      # whichever mode stores it: who (user_id, request_id), the causal chain
      # (correlation_id, causation_id), the user action in scope (action_id,
      # user_action), merged with config.metadata_proc's hash. Monitor's
      # after_* callbacks and the CommandHandler (hijack, event sourcing) both
      # build their metadata here, so the modes attribute a write alike.
      def lyra_event_metadata(operation)
        base_metadata = {
          user_id: lyra_current_user_id,
          request_id: lyra_current_request_id,
          correlation_id: Lyra::Correlation.current_id,
          # Inside its own write scope the current cause is this write itself;
          # its own cause is the one in scope when the write began.
          causation_id: @lyra_write_scope ? Lyra::Causation.resolve(@lyra_write_scope.outer) : Lyra::Causation.current_id,
          action_id: lyra_current_action_id,
          user_action: lyra_current_user_action
        }
        # The acting user's class, beside its id (from 1.0.0): an id alone does
        # not say whose account it is.
        user_type = lyra_current_user_type
        base_metadata[:user_type] = user_type if user_type

        base_metadata.merge(lyra_custom_metadata(operation))
      end

      # The event id fixed for this write by its write scope, for the write's
      # own event: given once, so no two events can share it; nil outside a
      # scope or once taken (the store then assigns one). From then on the
      # writes its callbacks make name it as their cause
      # (Causation::WriteScope).
      def lyra_take_own_event_id
        @lyra_write_scope&.take_event_id
      end

      # Around a save's or a destroy's callback chain (WriteScopeHooks).
      # Nested scopes of the same record (a save inside its own callbacks)
      # restore the outer one on the way out.
      #
      # A write that ends without its own event in the log after its id was
      # handed out (to a write in its before_* callbacks) appends a
      # SaveWithoutEffect marker with that id, in its transaction
      # (Lyra::SavesWithoutEffect). Also when it raises: a caller that rescues
      # inside an enclosing transaction keeps the writes made before the
      # error, and their cause. That marker is appended in a savepoint, best
      # effort: a failure there (the transaction aborted by the error) is
      # ignored, so the original error propagates; and if the enclosing
      # transaction rolls back, the marker goes with the writes that named it.
      #
      # The correlation the outermost write opens is its event id even when
      # that write records nothing: a correlation_id is a group's label, which
      # names an event only by convention (a request's or a job's id names
      # none), so the writes inside still share it.
      def lyra_write_scope(operation)
        return yield unless Lyra.config.correlate_writes

        outer = @lyra_write_scope
        scope = @lyra_write_scope = Lyra::Causation::WriteScope.new(Lyra::Causation.current)
        Lyra::Correlation.with_id(Lyra::Correlation.current_id || scope.event_id) do
          Lyra::Causation.with_id(scope) do
            result = yield
            if scope.owes_marker?
              Lyra::SavesWithoutEffect.record(scope, self, operation: operation,
                                                           reason: lyra_reason_without_effect(scope, operation, result))
            end
            result
          rescue StandardError
            lyra_marker_after_error(scope, operation) if scope.owes_marker?
            raise
          end
        end
      ensure
        @lyra_write_scope = outer if scope
      end

      # The owed marker of a write that raised, in a savepoint; nothing if it
      # cannot be appended (lyra_write_scope).
      def lyra_marker_after_error(scope, operation)
        ActiveRecord::Base.transaction(requires_new: true) do
          Lyra::SavesWithoutEffect.record(scope, self, operation: operation, reason: scope.lost_reason || "not saved")
        end
      rescue StandardError => e
        Rails.logger.error("Lyra: could not record a save without effect after #{self.class.name} #{id} raised - #{e.message}")
      end

      # The write's own event is in the log: the writes made from now on name
      # it (Causation::WriteScope). Monitor and Hijack call it once the append
      # returns, event sourcing once lyra_finalize_event_source has stored it.
      def lyra_own_event_appended!
        @lyra_write_scope&.appended!
      end

      # Called as Lyra's after_create, after_update and after_destroy end
      # (lyra_intercept_*, the first in each chain; in Hijack and event
      # sourcing the event was built before): the write has built its own
      # event, or it records none.
      def lyra_write_decided
        @lyra_write_scope&.decided!
      end

      # Why a write recorded no event (Lyra::SavesWithoutEffect).
      def lyra_reason_without_effect(scope, operation, result)
        if scope.lost? then scope.lost_reason
        elsif result == false || !scope.decided? then "not saved"
        elsif operation == :update && saved_changes.empty? then "no change"
        else "no row"
        end
      end

      class_methods do
        # Enable Lyra monitoring for this model
        # The model as it was at +time+, rebuilt from its event streams
        # (Lyra::Temporal::AsOf): Order.as_of(3.days.ago).find(42).
        def as_of(time)
          Lyra::Temporal::AsOf.new(self, time)
        end

        # The records the purpose in scope may process: those of subjects
        # whose restriction or objection (Arts. 18 and 21) covers it left
        # out, for a batch job that should skip them rather than stop at the
        # first (a load of one raises). +fields+: the declared fields the job
        # reads (default: all, so a restriction of any field leaves the record
        # out). With no purpose in scope, every record. A scope: it chains
        # with where, order, find_each (Lyra::Rights::Queries.processable).
        def lyra_processable(fields: nil)
          Lyra::PurposeBoundReads.processable(all, fields)
        end

        def monitor_with_lyra(options = {})
          Lyra::ModelSelection.refuse_composite_key!(self)
          self.lyra_monitored = true
          self.lyra_config = Lyra::ModelConfiguration.new(self, options)
          Lyra.config.monitor_model(self, options)

          # Prepend the strict data access guard for callback-bypassing instance
          # methods; prepend ensures ours run first and can call super. The bulk
          # methods are guarded on ActiveRecord::Relation (see Lyra::Engine).
          prepend Lyra::StrictDataAccess
          prepend Lyra::ModeSync::BeforeWrite
        end

        # Override _insert_record to skip SQL INSERT when Lyra signals to skip.
        # Uses Thread.current to receive signal from instance-level before_create.
        def _insert_record(connection, values, returning)
          if Thread.current[:lyra_skip_insert]
            # Skip the INSERT - projection will handle it
            # Return the pre-assigned ID as the "returning" value
            id_value = values[primary_key] || values[primary_key.to_sym]
            returning.map { |col| col == primary_key ? id_value : nil }
          else
            super
          end
        end

        # =======================================================================
        # Read overrides for disabled projection mode
        # When projection_mode is :disabled, read from event store instead of DB
        # =======================================================================

        # Every read below goes through the model's default scopes, or the
        # scope an unscoped { ... } block sets, as ActiveRecord's reads do
        # (Lyra::Projections::DefaultScopes); a model without default scopes
        # reads as before.
        def find(*args)
          if lyra_read_from_events?
            id = args.first
            record = lyra_find_from_events(id)
            raise ActiveRecord::RecordNotFound.new("Couldn't find #{name} with '#{primary_key}'=#{id}", self, primary_key, id) unless record
            lyra_checked_read(record)
          else
            super
          end
        end

        # The conditions are a use of the attributes they name, checked before
        # the query (Lyra::PurposeBoundReads.checked_finder): through
        # ActiveRecord's statement cache this path never reaches the
        # relation's hooks.
        def find_by(attributes)
          Lyra::PurposeBoundReads.checked_finder(self, attributes) do
            if lyra_read_from_events?
              lyra_checked_read(lyra_find_by_from_events(attributes))
            else
              super
            end
          end
        end

        def find_by!(attributes)
          Lyra::PurposeBoundReads.checked_finder(self, attributes) do
            if lyra_read_from_events?
              record = lyra_find_by_from_events(attributes)
              raise ActiveRecord::RecordNotFound.new("Couldn't find #{name}", self) unless record
              lyra_checked_read(record)
            else
              super
            end
          end
        end

        # A record rebuilt from events is checked when it is returned
        # (Lyra::PurposeBoundReads), as a loaded row is by after_find, with
        # the attributes its conditions named.
        def lyra_checked_read(record)
          Lyra::PurposeBoundReads.check(record) if record
          record
        end

        def exists?(conditions = :none)
          if lyra_read_from_events? && (conditions.is_a?(Integer) || conditions.is_a?(String))
            # A record a right in force leaves out of the purpose's queries
            # does not exist for it, as in Active Record's exists?.
            exclusion = Lyra::PurposeBoundReads.checking? && Lyra::PurposeBoundReads.rights_exclusion(self)
            if exclusion
              record = lyra_find_from_events(conditions)
              return !record.nil? && exclusion.keeps?(record)
            end

            scope = lyra_read_scope
            scope ? !lyra_find_from_events(conditions, scope).nil? : Lyra::Projections::EventStoreReader.exists?(self, conditions)
          else
            super
          end
        end

        # Override where to use cached projections in disabled mode
        # Returns a CachedRelation that supports method chaining
        def where(*args, **kwargs, &block)
          if lyra_read_from_events?
            # Under a relation's scoping block (a scope called on an
            # association) the conditions apply to that relation's records.
            scoped = Lyra::Projections::CachedRelation.scoped_for(self)
            return scoped.where(*args, **kwargs, &block) if scoped
            # where.not(...), where.missing(...): the chain of every record
            # the model reads.
            return lyra_all_from_events.where if args.empty? && kwargs.empty?

            # A plain hash of conditions can use the reference links (a
            # foreign-key lookup, as dependent associations make); anything
            # else is evaluated on every record. The default scope narrows
            # what they select (and orders it), so that an unscope can still
            # take it off (with_discarded).
            conditions = kwargs if args.empty?
            conditions = args.first if args.size == 1 && args.first.is_a?(Hash) && kwargs.empty?
            # The plan (for unscope and rewhere) starts from every record:
            # read then, if ever needed.
            linked = Lyra::Projections::EventStoreReader.linked_where(self, conditions) if block.nil? && conditions.present?
            every = linked ? -> { Lyra::Projections::EventStoreReader.relation(self) } : Lyra::Projections::EventStoreReader.relation(self)
            selected = linked || every.where(*args, **kwargs, &block)
            if conditions.is_a?(Hash) && block.nil?
              Lyra::Projections::DefaultScopes.narrow(selected, lyra_read_scope, base: every, steps: [[:where, conditions]])
            else
              # An SQL fragment: the relation keeps no plan.
              Lyra::Projections::DefaultScopes.narrow(selected, lyra_read_scope).tap { _1.plan = nil }
            end
          else
            super
          end
        end

        # Override all to use cached projections in disabled mode
        # Note: Rails 8 passes arguments to all() in internal call chains (e.g., reload)
        # A named scope called in a uniqueness validation's conditions:
        # (-> { live }) runs under the check's relation, an Active Record one
        # whose exists? reads the events (Lyra::Projections::Uniqueness): all
        # returns it, as Active Record's all returns the current scope, so
        # that the scope builds on it.
        def all(*args, **kwargs, &block)
          if lyra_read_from_events? && !Lyra::Projections::Uniqueness.scoped?(self)
            Lyra::Projections::CachedRelation.scoped_for(self) || lyra_all_from_events(all_queries: kwargs[:all_queries])
          else
            super
          end
        end

        # The attributes a new record gets from the current scope. ActiveRecord
        # computes them from all.scope_for_create, and every Model.new asks
        # (state machines do it to initialise their state), so under ES-NoProj
        # that was a load of every record of the model per record built. They
        # come from the relation being scoped, or from ActiveRecord's own
        # default scope, which reads nothing.
        def scope_attributes
          return super unless lyra_read_from_events?

          scoped = Lyra::Projections::CachedRelation.scoped_for(self)
          return scoped.scope_for_create if scoped

          previous = Thread.current[:lyra_bypass_read_override]
          Thread.current[:lyra_bypass_read_override] = true
          begin
            super
          ensure
            Thread.current[:lyra_bypass_read_override] = previous
          end
        end

        # As ActiveRecord's first and last: in the relation's order (a default
        # scope's), or else by primary key. last(n) is the last n in that
        # order, as ActiveRecord returns them.
        def first(limit = nil)
          if lyra_read_from_events?
            lyra_ordered_from_events.first(limit)
          else
            super
          end
        end

        def last(limit = nil)
          if lyra_read_from_events?
            lyra_ordered_from_events.last(limit)
          else
            super
          end
        end

        # Model.unscoped in application code reads every record of the model
        # from the event store, with no default scope (the table is empty or
        # stale under ES-NoProj). With a block, ActiveRecord's own: it sets
        # an empty current scope, which the reads above honour. ActiveRecord's
        # internals (association scopes, uniqueness validation, counter
        # caches) and Lyra's own code build relations on Model.unscoped or
        # read the table through it: they keep ActiveRecord's relation. The
        # caller is told by its file, past a model's own unscoped override
        # (DefaultScopes.application_caller?). Should a caller still be taken
        # for the application, what it builds is a CachedRelation, which
        # raises UnsupportedQuery for what it cannot do exactly (an Arel
        # where!) rather than act on other records.
        def unscoped(&block)
          return super if block || !lyra_read_from_events?
          return super unless Lyra::Projections::DefaultScopes.application_caller?(caller_locations(1, 6))

          Lyra::Projections::EventStoreReader.relation(self)
        end

        # Model.insert_all and the other inserts on the model itself, in
        # ES-NoProj and outside a scoping block: sent to the table relation
        # as a relation of the event store sends them
        # (CachedRelation#insert_through_table: unscoped, where
        # StrictDataAccessRelation records them), without building that
        # relation first. Active Record delegates them to Model.all, which
        # here rebuilt every record of the model: a cold insert_all of two
        # rows took 33 s at 10,000 records, its unique-index check 20 ms.
        %i[insert insert! insert_all insert_all! upsert upsert_all].each do |name|
          define_method(name) do |*args, **kwargs, &block|
            return super(*args, **kwargs, &block) unless lyra_read_from_events? && current_scope.nil?

            # Inside where(...).scoping { } (ES-NoProj keeps that scope itself,
            # so current_scope is nil): through the scoped relation, whose rows
            # take its attributes, as Active Record's InsertAll gives them.
            scoped = Lyra::Projections::CachedRelation.scoped_for(self)
            return scoped.public_send(name, *args, **kwargs, &block) if scoped

            begin
              previous = Thread.current[:lyra_bypass_read_override]
              Thread.current[:lyra_bypass_read_override] = true
              unscoped.public_send(name, *args, **kwargs, &block)
            ensure
              Thread.current[:lyra_bypass_read_override] = previous
            end
          end
        end

        # Model.update_counters(id, ...), increment_counter, decrement_counter
        # and a record's increment! and decrement! (which Active Record runs
        # through update_counters): in ES-NoProj, the records with those keys
        # read from the event store, written as a relation's update_counters
        # writes them (CachedRelation#update_counters: locks, current values,
        # an event each, touch: included), and the number written returned.
        # They went to Active Record's SQL on an empty table: 0, no event.
        # A counter cache, which Active Record's associations keep through
        # these, is still left as it is: ES-NoProj does not keep counter
        # caches (AssociationInterceptor).
        def update_counters(id, counters)
          return super unless lyra_counters_from_events?(caller_locations(1, 12))

          lyra_update_counters_from_events(id, counters)
        end

        def increment_counter(counter_name, id, by: 1, touch: nil)
          return super unless lyra_counters_from_events?(caller_locations(1, 12))

          lyra_update_counters_from_events(id, { counter_name => by, touch: touch })
        end

        def decrement_counter(counter_name, id, by: 1, touch: nil)
          return super unless lyra_counters_from_events?(caller_locations(1, 12))

          lyra_update_counters_from_events(id, { counter_name => -by, touch: touch })
        end

        private

        def lyra_counters_from_events?(locations)
          lyra_read_from_events? &&
            locations.none? { |frame| frame.path&.include?("/active_record/associations/") }
        end

        # The records with those keys only (EventStoreReader.keyed): the
        # cost is theirs, not the model's size. With optimistic locking the
        # lock version moves too, as Active Record's
        # Locking::Optimistic.update_counters moves it, so a copy read
        # before raises StaleObjectError on save.
        def lyra_update_counters_from_events(id, counters)
          counters = counters.merge(locking_column => 1) if locking_enabled?
          Lyra::Projections::EventStoreReader.keyed(self, Array(id)).update_counters(counters)
        end

        # The ActiveRecord relation reads select through: the current scope
        # of an unscoped { ... } block, else the default scopes; nil for
        # every record (Lyra::Projections::DefaultScopes).
        def lyra_read_scope(all_queries: nil)
          Lyra::Projections::DefaultScopes.read_scope(self, all_queries: all_queries)
        end

        def lyra_all_from_events(all_queries: nil)
          Lyra::Projections::DefaultScopes.narrow(Lyra::Projections::EventStoreReader.all(self), lyra_read_scope(all_queries: all_queries))
        end

        def lyra_ordered_from_events
          relation = Lyra::Projections::CachedRelation.scoped_for(self) || lyra_all_from_events
          relation.ordering.any? ? relation : relation.order(primary_key => :asc)
        end

        # The record with +id+, if the read scope selects it.
        def lyra_find_from_events(id, scope = lyra_read_scope)
          record = Lyra::Projections::EventStoreReader.find(self, id)
          record if record && Lyra::Projections::DefaultScopes.admits?(self, record, scope)
        end

        def lyra_find_by_from_events(attributes)
          Lyra::Projections::DefaultScopes.find_by(self, attributes, lyra_read_scope)
        end

        def lyra_read_from_events?
          return false if Thread.current[:lyra_bypass_read_override]
          lyra_monitored &&
            Lyra.event_sourcing_mode? &&
            Lyra.config.projection_mode == :disabled
        end
      end

      private

      def lyra_monitored?
        self.class.lyra_monitored
      end

      # Monitoring a model is not enough to emit events: :disabled mode must be a
      # true ORM baseline. Hijack and event-sourcing modes still pass this guard;
      # their after_* callbacks return early via @lyra_hijacked.
      def lyra_events_enabled?
        lyra_monitored? && !Lyra.disabled_mode?
      end

      # The column a command's result carries the record's key under (the
      # primary key, Lyra.key_column).
      def lyra_key_column
        Lyra.key_column(self.class)
      end

      def lyra_check_read_purpose
        Lyra::PurposeBoundReads.check(self)
      end

      def lyra_sample_dual_view
        Lyra::DualViewSampler.after_commit(self)
      end

      def lyra_hijack_mode?
        lyra_monitored? && Lyra.hijack_mode?
      end

      def lyra_event_sourcing_mode?
        lyra_monitored? && Lyra.event_sourcing_mode?
      end

      def lyra_checks_effects?
        lyra_monitored? && Lyra::EffectCheck.applies?
      end

      def lyra_check_effect
        Lyra::EffectCheck.verify!(self)
      end


      def lyra_takes_over_write?
        lyra_hijack_mode? || lyra_event_sourcing_mode?
      end

      # MONITOR MODE: After callbacks that log events
      def lyra_intercept_create
        return if @lyra_hijacked

        event_data = build_event_data(:created)
        publish_event(:created, event_data)
      ensure
        lyra_write_decided
      end

      def lyra_intercept_update
        return if @lyra_hijacked

        # A save that changed no row records nothing, though Active Record
        # still runs after_update: one whose UPDATE reached no row (a stale copy
        # saved after a concurrent destroy; an Updated after Destroyed makes the
        # stream ill-formed), and one that changed nothing, so ran no UPDATE
        # (rows is nil then). An update carries its changes, and there are none.
        rows, @lyra_rows_updated = @lyra_rows_updated, nil
        return if rows == 0 || previous_changes.empty?

        # A changed primary key: the table now holds the record under the new
        # key, so the log records what the table did, the old key's record
        # destroyed and the new key's created (from 1.0.1; 1.0.0 recorded an
        # update on the new key's stream, which had no create).
        pk = self.class.primary_key
        if pk.is_a?(String) && saved_change_to_attribute?(pk) && Lyra::StreamHeads.enabled?
          old_key = attribute_before_last_save(pk)
          gone = Lyra::EventData.build(self.class, old_key, :destroyed, attributes: {}, changes: {})
                                .merge(metadata: { source: "lyra_interceptor" }.merge(lyra_event_metadata(:destroyed)))
          publish_event(:destroyed, gone, stream_name: Lyra.stream_name(self.class, old_key))
          publish_event(:created, build_event_data(:created))
          return
        end

        event_data = build_event_data(:updated)
        publish_event(:updated, event_data)
      ensure
        lyra_write_decided
      end

      def lyra_intercept_destroy
        # A destroy that deleted no row records nothing, though Active Record
        # still runs after_destroy: one whose DELETE reached no row (a stale
        # copy destroyed after another copy, delete_all or hand-written SQL
        # deleted the row) and one of a record that was not persisted (a new
        # one, or a copy destroyed twice), which runs no DELETE (WriteHooks#
        # destroy sets 0). A second Destroyed makes the stream ill-formed. nil
        # means no count was taken: the destroy callbacks ran without Active
        # Record's destroy, a soft delete (paranoia's paranoia_destroy, which
        # keeps the row). It records nothing itself from 1.0.1: what it writes
        # (deleted_at, through update_columns or a save) is recorded as the
        # update it is, so the stream follows the row, which is still there.
        # 1.0.0 recorded a Destroyed, and the record's stream ended while its
        # row stayed.
        rows, @lyra_rows_deleted = @lyra_rows_deleted, nil
        return if @lyra_hijacked || rows == 0 || (rows.nil? && !destroyed?)

        event_data = build_event_data(:destroyed)
        publish_event(:destroyed, event_data)
      ensure
        lyra_write_decided
      end

      # HIJACK MODE: called from WriteHooks, after every before_* callback and
      # before the row write. Each command method returns true, or false with
      # an error on the record, which stops the write.
      def lyra_hijack_create
        @lyra_hijacked = true
        lyra_disable_paper_trail!

        command = Lyra::Commands::CreateCommand.new(self.class, attributes)
        command.record = self
        result = Lyra::CommandHandler.handle(command)

        if result.success?
          # Take the ID the Created event carries, so the row is inserted under
          # it. Nothing else changed: assigning every attribute back (as this
          # used to) is redundant and fails on models that guard a writer
          # (Solidus's StockItem#count_on_hand=).
          key = lyra_key_column.to_sym
          self.id = result.attributes[key] if result.attributes.key?(key)
          lyra_own_event_appended!
          true
        else
          errors.add(:base, result.error)
          false
        end
      end

      # Assumption L of Theorem 5: hold a lock on the aggregate from before its
      # event is appended until the transaction ends, so that two writers of
      # one record append and write its row in the same order. Without it a
      # writer that appended first can write its row last, and the row ends at
      # a value the log does not replay to (test/concurrent_same_record_test.rb).
      #
      # Taken where the row is written by the operation itself, Hijack and
      # ES-Sync, and in ES-Async, whose projection job applies only the events
      # after its checkpoint and so needs a record's events to commit in the
      # order they were appended (AsyncProjectionJob). Monitor writes the row
      # first, so the row lock is the lock; ES-NoProj has no row; ES-Lazy
      # projects every event in log order under a lock of its own. Creates have
      # no earlier writer: the identifier is reserved.
      #
      # In Hijack and ES-Sync the lock is the row's own, in the strength the
      # write takes anyway (FOR NO KEY UPDATE for an update, FOR UPDATE for a
      # destroy), only taken before the append instead of at the row write. So
      # a write takes the locks plain ActiveRecord takes, in the same order,
      # and adds no deadlock: a separate lock taken before the row's (an
      # advisory lock, as first written) deadlocked against a writer that holds
      # the row first (record.lock!, with_lock) and then updates it
      # (test/aggregate_lock_deadlock_test.rb). An ES-Async writer does not
      # write the row (its job does), so it takes the advisory lock on the
      # stream: it never waits for the row, and cannot deadlock that way.
      # Where the row is missing, or the database has no such row lock, the
      # advisory lock is taken too.
      #
      # A model with optimistic locking has its version checked against the
      # log before the append (Lyra::OptimisticLocking), which needs this lock
      # in every event-sourcing mode, ES-NoProj and ES-Lazy included, whatever
      # lock_aggregate_before_append says.
      def lyra_lock_aggregate!(operation = :update)
        return unless id
        checks_version = lyra_event_sourcing_mode? && Lyra::OptimisticLocking.enabled?(self.class)
        return unless Lyra.config.lock_aggregate_before_append || checks_version
        es_async = lyra_event_sourcing_mode? && Lyra.config.projection_mode == :async
        es_sync = lyra_event_sourcing_mode? && Lyra.config.projection_mode == :sync
        return unless lyra_hijack_mode? || es_sync || es_async || checks_version
        return :row if (lyra_hijack_mode? || es_sync) && lyra_lock_own_row(operation)

        lyra_aggregate_advisory_lock
        :advisory
      end

      # The lock on the aggregate, then a refusal if the record's stream says
      # it was destroyed (from 0.9.3). A destroy and an update of one record
      # could both pass before: the second writer found no row to lock, fell
      # back to the advisory lock and appended after the Destroyed event,
      # leaving a stream that brings the record back (state_at, DualView).
      # Where the record's row was found and locked it exists, so there is
      # nothing to check. Elsewhere the stream's last replayed event is read
      # (Lyra::StreamTail) under the advisory lock, which this takes in
      # ES-NoProj and ES-Lazy too, for updates and destroys only. A destroy
      # followed by events that are not replayed (an also: domain event, an
      # ErasureApplied, a habtm link) is still a destroy. With
      # lock_aggregate_before_append off, as
      # in the benchmarks' no-lock controls, nothing is checked.
      def lyra_lock_aggregate_unless_destroyed!(operation = :update)
        locked = lyra_lock_aggregate!(operation)
        return if locked == :row || id.nil? || !Lyra.config.lock_aggregate_before_append

        lyra_aggregate_advisory_lock unless locked == :advisory
        # One query when the last event is a replayed create, import or update.
        return unless Lyra::StreamTail.destroyed?(lyra_stream_name)

        raise Lyra::RecordDestroyedError, "#{self.class.name} #{id} was destroyed; its #{operation} is refused"
      end

      # The advisory lock on the record's stream, once per save: not again
      # when the save took it before its validations
      # (lyra_lock_aggregate_before_validation), in the transaction it is in.
      def lyra_aggregate_advisory_lock
        self.class.with_connection do |connection|
          early, @lyra_aggregate_locked_in = @lyra_aggregate_locked_in, nil
          next if early && early.equal?(connection.current_transaction) && early.open?

          Lyra::AdvisoryLock.xact_lock(connection, "lyra_aggregate/#{lyra_stream_name}", purpose: "aggregate write")
        end
      end

      # ES-NoProj: an update of a model with a uniqueness validation takes the
      # record's aggregate lock before its validations, so the value lock the
      # validation takes (Projections::Uniqueness.lock!) comes after it, as
      # every other write of one record takes them (the aggregate, then the
      # value: Projections::UniqueIndexes): a validated save and an update_all
      # (or update_columns, or update_counters) of the record and value no
      # longer deadlock, nor two transactions crossing two records and one
      # value. The save's own lock (lyra_lock_aggregate_unless_destroyed!)
      # is then not taken again; the statements are the same, in another
      # order. A create has no stream to lock.
      def lyra_lock_aggregate_before_validation
        return unless persisted? && Lyra::Projections::Uniqueness.reads_events?(self.class)
        return unless Lyra.config.lock_aggregate_before_append
        # Only for a validation no unique index covers (Uniqueness.index_covered?):
        # one an index covers takes no value lock, so there is nothing to order.
        return unless self.class.validators.any? do |validator|
          validator.is_a?(ActiveRecord::Validations::UniquenessValidator) &&
            validator.attributes.any? { !Lyra::Projections::Uniqueness.index_covered?(self.class, _1, validator.options) }
        end

        self.class.with_connection do |connection|
          next unless connection.transaction_open?

          Lyra::AdvisoryLock.xact_lock(connection, "lyra_aggregate/#{lyra_stream_name}", purpose: "aggregate write")
          @lyra_aggregate_locked_in = connection.current_transaction
        end
      end

      # True when the record's row was found and locked.
      def lyra_lock_own_row(operation)
        primary_key = self.class.primary_key
        return false unless primary_key.is_a?(String)

        # The write's own transaction holds this connection: the lock is taken
        # on it and lasts until that transaction ends.
        self.class.with_connection do |connection|
          next false unless connection.adapter_name.match?(/postgres/i)

          strength = operation == :destroy ? "FOR UPDATE" : "FOR NO KEY UPDATE"
          key = respond_to?(:id_in_database) ? id_in_database : id
          sql = "SELECT 1 FROM #{connection.quote_table_name(self.class.table_name)} " \
                "WHERE #{connection.quote_column_name(primary_key)} = #{connection.quote(key)} #{strength}"
          # Never from the query cache: a lock is taken by running the statement.
          connection.uncached { connection.select_value(sql, "Lyra aggregate lock") }.present?
        end
      end

      def lyra_hijack_update
        @lyra_hijacked = true
        lyra_disable_paper_trail!
        lyra_lock_aggregate_unless_destroyed!

        # Active Record checks and increments lock_version in the row write
        # that follows; the event records the increment it makes.
        recorded = changes
        # A save that changes nothing writes no row and records no update, as
        # in Monitor (lyra_intercept_update).
        return true if recorded.empty?

        recorded = recorded.merge(Lyra::OptimisticLocking.increment(self)) if Lyra::OptimisticLocking.enabled?(self.class)
        command = Lyra::Commands::UpdateCommand.new(self.class, id, recorded)
        command.record = self
        result = Lyra::CommandHandler.handle(command)

        if result.success?
          lyra_own_event_appended!
          return true
        end

        errors.add(:base, result.error)
        false
      end

      def lyra_hijack_destroy
        @lyra_hijacked = true
        lyra_disable_paper_trail!
        lyra_lock_aggregate_unless_destroyed!(:destroy)

        command = Lyra::Commands::DestroyCommand.new(self.class, id)
        command.record = self
        result = Lyra::CommandHandler.handle(command)

        if result.success?
          lyra_own_event_appended!
          return true
        end

        errors.add(:base, result.error)
        false
      end

      # EVENT SOURCING MODE: Prepare phase (called from WriteHooks, like hijack)
      # Generate ID, create event, mark to skip SQL.
      # For creates: Thread.current[:lyra_skip_insert] signals _insert_record to skip.
      # For updates/deletes: @lyra_skip_sql causes _update_row/_delete_row to skip.
      # The sync projection handles persistence instead.
      def lyra_prepare_event_source_create
        @lyra_hijacked = true
        lyra_disable_paper_trail!
        # The table's unique indexes, as its INSERT would check them, before
        # the event is built (Projections::UniqueIndexes): every
        # event-sourcing mode appends first, and ES-NoProj writes no row.
        claims = lyra_unique_claims(:create)
        if claims.present?
          Lyra::Projections::UniqueIndexes.lock!(self.class, claims)
          Lyra::Projections::UniqueIndexes.refuse_taken!(self.class, claims)
        end

        command = Lyra::Commands::CreateCommand.new(self.class, attributes)
        command.record = self
        result = Lyra::CommandHandler.handle(command)

        if result.success?
          # Store result for after callback
          @lyra_event_result = result
          @lyra_event_operation = :create
          @lyra_assigned_id = result.attributes[lyra_key_column.to_sym]

          # Assign the pre-generated ID
          self.id = @lyra_assigned_id if @lyra_assigned_id

          # Signal class method _insert_record to skip the SQL INSERT
          Thread.current[:lyra_skip_insert] = true
          true
        else
          errors.add(:base, result.error)
          false
        end
      end

      def lyra_prepare_event_source_update
        @lyra_hijacked = true
        lyra_disable_paper_trail!
        lyra_lock_aggregate_unless_destroyed!
        # A save that changes nothing records no update, as in Monitor
        # (lyra_intercept_update); Active Record then writes no row either.
        return true unless has_changes_to_save?

        # Active Record checks and increments lock_version only when it writes
        # the row, that is when something changed.
        lock_was = lyra_take_lock_version!("update")
        # The values the update claims in the table's unique indexes, under
        # the record's aggregate lock (as Monitor's UPDATE locks the row, then
        # the index entries) and once its version is known current, the
        # columns it does not write as the record's stream (ES-Sync: its row)
        # has them: locked, then checked before the event is built
        # (Projections::UniqueIndexes).
        claims = lyra_unique_claims(:update)
        if claims.present?
          Lyra::Projections::UniqueIndexes.lock!(self.class, claims)
          Lyra::Projections::UniqueIndexes.refuse_taken!(self.class, claims, except: id)
        end

        command = Lyra::Commands::UpdateCommand.new(self.class, id, changes)
        command.record = self
        result = Lyra::CommandHandler.handle(command)

        if result.success?
          @lyra_event_result = result
          @lyra_event_operation = :update
          @lyra_skip_sql = true
          true
        else
          lyra_restore_lock_version(lock_was)
          errors.add(:base, result.error)
          false
        end
      rescue Exception # as Active Record restores the version
        lyra_restore_lock_version(lock_was)
        raise
      end

      # The values this save claims in the table's unique indexes
      # (Lyra::Projections::UniqueIndexes), in the event-sourcing modes, where
      # the event is appended before the projection writes a row for the
      # index to refuse (ES-Sync, ES-Async, ES-Lazy), or no row is written
      # (ES-NoProj): those of every index on a create; on an update, of the
      # indexes whose columns it changes, the other columns of each as the
      # record's stream (ES-Sync: its locked row) has them (a copy read
      # before another writer changed them claims the tuple the row would
      # hold). nil elsewhere, or for a model without such an index.
      def lyra_unique_claims(operation)
        return nil unless Lyra::Projections::UniqueIndexes.enforced?(self.class)
        return nil if Lyra::Projections::UniqueIndexes.of(self.class).empty?
        return Lyra::Projections::UniqueIndexes.claims(self.class) { |column| read_attribute(column) } if operation == :create
        return nil unless has_changes_to_save?

        changed = changed_attribute_names_to_save
        # Nothing built for an update that sets no indexed column.
        return nil unless changed.intersect?(Lyra::Projections::UniqueIndexes.watched_columns(self.class))

        written = changed.to_h { |name| [name, read_attribute(name)] }
        Lyra::Projections::UniqueIndexes.update_claims(self.class, id_in_database, written)
      end

      # Optimistic locking in the event-sourcing modes (Lyra::OptimisticLocking):
      # check the version against the log, under the lock on the aggregate, and
      # take the next one, as Active Record's UPDATE would, so the event
      # records the increment as a change. Returns the attribute to restore if
      # the write then fails, as Active Record restores it.
      def lyra_take_lock_version!(attempted_action)
        return unless Lyra::OptimisticLocking.enabled?(self.class)

        Lyra::OptimisticLocking.check!(self, attempted_action)
        column = self.class.locking_column
        was = @attributes[column]
        self[column] = Lyra::OptimisticLocking.increment(self)[column].last
        was
      end

      def lyra_restore_lock_version(was)
        @attributes[self.class.locking_column] = was if was
      end

      # A row write that Lyra does not take over (touch) on a model with
      # optimistic locking, in an event-sourcing mode. Active Record would
      # check the version against the row, which in ES-Async can trail the log
      # and in ES-NoProj does not exist (every touch there raised
      # StaleObjectError). The version is checked against the log instead, and
      # the row, where there is one, written by its primary key. touch records
      # the new version in its event (StrictDataAccess#touch).
      def lyra_update_row_checked_by_log(attribute_names, attempted_action)
        lyra_lock_aggregate!
        was = lyra_take_lock_version!(attempted_action)
        return 1 if Lyra.config.projection_mode == :disabled

        # A row not projected yet (ES-Async) matches nothing; the touch's event
        # reaches it with the rest of the stream.
        self.class._update_record(attributes_with_values(attribute_names | [self.class.locking_column]),
                                  { self.class.primary_key => id_in_database })
        1
      rescue Exception # as Active Record restores the version
        lyra_restore_lock_version(was)
        raise
      end

      def lyra_prepare_event_source_destroy
        @lyra_hijacked = true
        lyra_disable_paper_trail!
        lyra_lock_aggregate_unless_destroyed!(:destroy)
        Lyra::OptimisticLocking.check!(self, "destroy")

        command = Lyra::Commands::DestroyCommand.new(self.class, id)
        command.record = self
        result = Lyra::CommandHandler.handle(command)

        if result.success?
          @lyra_event_result = result
          @lyra_event_operation = :destroy
          @lyra_skip_sql = true
          true
        else
          errors.add(:base, result.error)
          false
        end
      end

      # EVENT SOURCING MODE: Finalize phase (after callbacks)
      # Store events and run projections
      def lyra_finalize_event_source
        return unless @lyra_event_result

        # Store events to the event store
        if @lyra_event_result.events&.any?
          lyra_store_events(@lyra_event_result.events)
          lyra_own_event_appended!
        end

        # Run projection based on configured mode
        case Lyra.config.projection_mode
        when :sync
          lyra_run_sync_projection(@lyra_event_operation, @lyra_event_result)
        when :async
          lyra_enqueue_async_projection(@lyra_event_operation, @lyra_event_result)
        when :disabled
          # Warm cache with the new data (uses Solid Cache or Rails.cache)
          lyra_warm_cache(@lyra_event_operation, @lyra_event_result)
        when :lazy
          # ES-Lazy: nothing to do now. The next read brings the tables up to
          # date from the log (Projections::LazyProjection).
        end

      ensure
        # Clear state whatever happened: a failed store (which now fails the
        # write) must not leave it for the next write.
        @lyra_event_result = nil
        @lyra_event_operation = nil
        @lyra_skip_sql = false
        Thread.current[:lyra_skip_insert] = nil
      end

      # Run synchronous projection (update model table from event)
      #
      # Inside ReadYourWrites.with_guaranteed_read too (from 1.0.0): the block
      # used to defer the row to its end, so reads inside it missed the
      # write, and the unique-index check of every write (which reads the
      # table in ES-Sync: Projections::UniqueIndexes) missed its value: two
      # creates of one email in a block were both saved, the second row
      # dropped. ES-Sync's row is the writer's own, written now.
      #
      # A database error raises whatever strict_projections says: it aborted
      # the transaction (PostgreSQL), so the write cannot go on, and logging
      # it let the save report success while its COMMIT rolled everything
      # back, the event included (a unique index the check could not see,
      # under REPEATABLE READ). It now fails the write, as Monitor's INSERT
      # or UPDATE fails it.
      def lyra_run_sync_projection(operation, result)
        projected = Lyra::Projections::ModelProjection.project(self.class, operation, result, INTERNAL)
        # The table's primary key, as Monitor's INSERT meets it: a row already
        # holds the key, so the create is refused with its event, in the same
        # transaction (from 1.0.1; 1.0.0 skipped the insert and kept the event).
        # The stream heads refuse a live key before this; this catches a row
        # with no live stream (one written around Lyra).
        if operation == :create && projected == :key_taken && Lyra::StreamHeads.enabled?
          raise Lyra::StreamHeads::LiveKeyError, "Lyra: #{self.class.name} #{id}: a row already holds this key; the create is refused"
        end

        projected
      rescue ActiveRecord::StatementInvalid
        raise
      rescue => e
        if Lyra.config.strict_projections
          raise
        else
          Rails.logger.error("Lyra: Sync projection failed - #{e.message}")
          Lyra.config.projection_error_handler&.call(e, self, operation)
        end
      end

      # Enqueue asynchronous projection job
      def lyra_enqueue_async_projection(operation, result)
        event = result.events&.first
        return unless event

        # Inline in the test environment unless a test opts out
        # (Configuration#async_projections_inline?). Inline runs what the job
        # runs, in this thread, once the writing transaction has committed:
        # the record's whole stream replayed under the per-stream lock. It used
        # to apply only this event, inside the transaction and under no lock,
        # so of two writers of one record the one that projected last could
        # leave the row at its own, older value while the log ended at the
        # other's (test/concurrent_same_record_test.rb).
        if Lyra.config.async_projections_inline?
          job = Lyra::Projections::AsyncProjectionJob.new
          model_name = self.class.name
          ActiveRecord.after_all_transactions_commit do
            job.perform(event.event_id, model_name, operation.to_s)
          end
        else
          # Inside ReadYourWrites.with_guaranteed_read the write is also
          # projected when the block ends, so the block's reads find it. The
          # job is still enqueued: it replays the whole stream, so it
          # converges on the same row whichever runs first.
          if Lyra::Consistency::ReadYourWrites.in_guaranteed_block?
            Lyra::Consistency::ReadYourWrites.record_write(self.class, operation, result)
          end
          Lyra::Projections::AsyncProjectionJob.perform_later(
            event.event_id,
            self.class.name,
            operation.to_s
          )
        end
      rescue => e
        if Lyra.config.strict_projections
          raise
        else
          Rails.logger.error("Lyra: Failed to enqueue async projection - #{e.message}")
          Lyra.config.projection_error_handler&.call(e, self, operation)
        end
      end

      # Warm cache after event stored (for disabled projection mode)
      # Uses Solid Cache (or any Rails.cache backend) for fast reads
      def lyra_warm_cache(operation, result)
        model_id = case operation
        when :create
          result.attributes[lyra_key_column.to_sym] || result.attributes[lyra_key_column]
        when :update, :destroy
          event = result.events&.first
          event&.data&.dig(:model_id) || event&.data&.dig("model_id")
        end

        return unless model_id

        if operation == :destroy
          # Invalidate cache for destroyed record
          Lyra::Projections::EventStoreReader.invalidate(self.class, model_id)
        else
          # Warm cache with new/updated data
          Lyra::Projections::EventStoreReader.warm(self.class, model_id)
        end
      rescue => e
        Rails.logger.warn("Lyra: Failed to warm cache - #{e.message}")
      end

      # Store events to the event store
      # In event-sourcing mode the stored event is the write: if it cannot
      # be stored, the write must fail and its transaction roll back. This
      # used to log the error and carry on (unless strict_projections, a
      # setting about projections, was on). ES-NoProj then reported a write
      # that existed nowhere, and ES-Sync projected a row from an event that
      # was never stored.
      def lyra_store_events(events)
        stream_name = lyra_stream_name
        events.each do |event|
          Lyra.append_events(event, stream_name: stream_name)
        end
      rescue => e
        Rails.logger.error("Lyra: Failed to store events, the write is rolled back - #{e.message}")
        raise
      end

      # Disable PaperTrail for this record in hijack/event_sourcing mode
      # (Lyra's event sourcing replaces PaperTrail's audit trail)
      def lyra_disable_paper_trail!
        return unless defined?(PaperTrail)

        # PaperTrail's request store: switch versioning off for this model
        # only. Before 0.9.3 this set PaperTrail.request.enabled = false,
        # which switched it off for every model for the rest of the request
        # or job thread and was never restored, so writes to versioned models
        # Lyra does not monitor lost their versions with no event in their
        # place.
        if PaperTrail.respond_to?(:request) && PaperTrail.request.respond_to?(:disable_model)
          PaperTrail.request.disable_model(self.class)
        elsif respond_to?(:paper_trail) && paper_trail.respond_to?(:enabled=)
          # Older PaperTrail versions use instance-level enabled
          paper_trail.enabled = false
        end
      rescue => e
        # Silently ignore if PaperTrail integration fails
      end

      # Monitor's event data. attributes is the record's every column,
      # created_at and updated_at included, as in Hijack and the event-sourcing
      # modes (CommandHandler#create_event), so replay and projection reproduce
      # the two timestamps from a create. DualView compares them like any
      # other column.
      def build_event_data(operation)
        # source is Lyra's default: a metadata_proc that sets its own wins, as
        # its other keys do.
        merged_metadata = { source: "lyra_interceptor" }.merge(lyra_event_metadata(operation))

        Lyra::EventData.build(self.class, id, operation, attributes: attributes, changes: previous_changes)
                       .merge(metadata: merged_metadata)
      end

      # Get custom metadata from configured metadata_proc
      def lyra_custom_metadata(operation)
        return {} unless Lyra.config.metadata_proc

        begin
          result = Lyra.config.metadata_proc.call(self, operation)
          result.is_a?(Hash) ? result : {}
        rescue => e
          Rails.logger.warn("Lyra: metadata_proc failed - #{e.message}")
          {}
        end
      end

      def publish_event(operation, data, stream_name: lyra_stream_name)
        # Extract metadata from data and pass separately to RailsEventStore
        metadata = Lyra::Privacy.stamp(self.class, data, data.delete(:metadata) || {})
        # The CRUD event, or the domain events the model's rules choose
        # (Lyra::DomainEvents): its own event first, then any additional ones.
        events = Lyra::DomainEvents.build(
          self.class, operation, data: data, metadata: metadata,
          default_class: lyra_event_class_for(operation),
          record: self, changes: operation == :destroyed ? {} : previous_changes,
          event_id: lyra_take_own_event_id
        )

        Lyra.append_events(events, stream_name: stream_name)
        lyra_own_event_appended!
      rescue => e
        # Its event is not in the log, so the writes made next do not name it
        # as their cause, and one named before is owed a marker.
        @lyra_write_scope&.lost!
        # Monitor with monitor_append_failure :fail_write: fail the write, which
        # rolls back with its transaction, as Hijack and event sourcing do.
        raise if Lyra.config.events_required?

        # Monitor's default policy, log-and-continue: the table is authoritative,
        # so the write stands and its stream falls behind until lyra:repair.
        Rails.logger.error("Lyra: Failed to publish event - #{e.message}; the write stands, " \
                           "run bin/rails lyra:repair to bring #{lyra_stream_name} back in line")
      end

      def lyra_event_class_for(operation)
        config = self.class.lyra_config || Lyra.config.model_config(self.class)
        event_name = config.event_name_for(operation)
        # Sanitize namespaced event names (e.g., "Spree::OrderCreated" -> "SpreeOrderCreated")
        sanitized_name = event_name.to_s.gsub("::", "")

        # Find or create the event class in Lyra::Events namespace
        if Lyra::Events.const_defined?(sanitized_name, false)
          Lyra::Events.const_get(sanitized_name, false)
        else
          Lyra::Events.const_set(sanitized_name, Class.new(Lyra::Event))
        end
      end

      def lyra_stream_name
        Lyra.stream_name(self.class, id)
      end

      # Hook methods for context (can be overridden by the application)
      def lyra_current_user_id
        defined?(Current) && Current.respond_to?(:user) ? Current.user&.id : nil
      end

      # Current.user's class, when Current.user is the user lyra_current_user_id
      # names (a model may override that hook with someone else).
      def lyra_current_user_type
        return nil unless defined?(Current) && Current.respond_to?(:user)

        user = Current.user
        user && user.id == lyra_current_user_id ? Lyra::Attribution.actor_type(user) : nil
      end

      def lyra_current_request_id
        defined?(Current) && Current.respond_to?(:request_id) ? Current.request_id : nil
      end

      def lyra_current_action_id
        Lyra::UserActionContext.current&.action_id
      end

      def lyra_current_user_action
        context = Lyra::UserActionContext.current
        return nil unless context

        {
          type: context.action_type,
          controller: context.controller,
          action: context.action_name
        }
      end
    end
  end
end
