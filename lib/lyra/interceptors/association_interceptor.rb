# frozen_string_literal: true

module Lyra
  module Interceptors
    # Patches AR association loading to use cached projections when:
    # - The target model is monitored by Lyra
    # - Lyra is in event_sourcing mode
    # - projection_mode is :disabled
    #
    # This allows belongs_to/has_one associations to work transparently
    # even when the target record only exists in the cache, not the DB.
    #
    module AssociationInterceptor
      module BelongsToAssociationPatch
        # Rails 8+ passes async: keyword argument to find_target
        def find_target(async: false)
          if lyra_should_use_cache?
            lyra_find_target_from_cache
          else
            super
          end
        end

        private

        def lyra_should_use_cache?
          return false unless Lyra.event_sourcing_mode? && Lyra.config.projection_mode == :disabled

          target_klass = lyra_resolve_target_class
          return false unless target_klass

          target_klass.respond_to?(:lyra_monitored) && target_klass.lyra_monitored
        end

        def lyra_resolve_target_class
          if reflection.polymorphic?
            # For polymorphic associations, get class from the type column
            type_column = reflection.foreign_type
            type_name = owner.read_attribute(type_column)
            return nil if type_name.blank?
            type_name.safe_constantize
          else
            reflection.klass
          end
        rescue => e
          # If class resolution fails, fall back to AR's normal loading
          nil
        end

        def lyra_find_target_from_cache
          foreign_key_value = owner.read_attribute(reflection.foreign_key)
          return nil if foreign_key_value.nil?

          target_klass = lyra_resolve_target_class
          return nil unless target_klass

          # The record is returned to the application: checked as a loaded
          # row is by after_find (Lyra::PurposeBoundReads), consent included.
          # As ActiveRecord's association scope, it is read through the
          # target's default scopes, less what the association's scope
          # unscopes (belongs_to :variant, -> { with_discarded }).
          record = Lyra::Projections::EventStoreReader.find(target_klass, foreign_key_value)
          default_scope = record && Lyra::Projections::DefaultScopes.for_association(target_klass, reflection, owner)
          record = nil if default_scope && !Lyra::Projections::DefaultScopes.admits?(target_klass, record, default_scope)
          Lyra::PurposeBoundReads.check(record) if record
          record
        end
      end

      module HasOneAssociationPatch
        # Rails 8+ passes async: keyword argument to find_target
        def find_target(async: false)
          if lyra_should_use_cache?
            lyra_find_target_from_cache
          else
            super
          end
        end

        private

        def lyra_should_use_cache?
          klass = reflection.klass
          klass.respond_to?(:lyra_monitored) &&
            klass.lyra_monitored &&
            Lyra.event_sourcing_mode? &&
            Lyra.config.projection_mode == :disabled
        end

        def lyra_find_target_from_cache
          return lyra_find_target_through if reflection.through_reflection?

          owner_key_value = owner.read_attribute(reflection.active_record_primary_key)
          return nil if owner_key_value.nil?

          # Through the target's default scopes, as the belongs_to above: a
          # soft-deleted record is not the one the owner has.
          klass = reflection.klass
          conditions = lyra_has_one_conditions(reflection, owner_key_value)
          default = Lyra::Projections::DefaultScopes.for_association(klass, reflection, owner)
          return lyra_scoped_has_one(klass, conditions, default) if reflection.scope

          record = Lyra::Projections::DefaultScopes.find_by(klass, conditions, default)
          # Checked as a loaded row is, with the key it was found by.
          Lyra::PurposeBoundReads.check(record, Array(reflection.foreign_key).map(&:to_s)) if record
          record
        end

        # A has_one with a scope of its own (-> { where(selected: true) },
        # -> { order(created_at: :desc) }): the owner's records, through the
        # target's default scopes, narrowed by the scope, and the first of
        # them in its order, as Active Record's query with LIMIT 1. What the
        # scope holds that CachedRelation cannot evaluate raises
        # UnsupportedQuery. The scope used to be left out: any record of the
        # owner's was the answer.
        def lyra_scoped_has_one(klass, conditions, default)
          relation = Lyra::Projections::DefaultScopes.narrow(Lyra::Projections::EventStoreReader.where(klass, conditions), default)
          lyra_scoped(relation, reflection.scope).first
        end

        # +relation+ narrowed by an association +scope+ (a scope returning
        # nil leaves it as it is, as in Active Record).
        def lyra_scoped(relation, scope)
          result = scope.arity.zero? ? relation.instance_exec(&scope) : relation.instance_exec(owner, &scope)
          result || relation
        end

        # Whether narrowing +before+ by a scope into +after+ ordered it.
        def lyra_orders?(before, after)
          after.respond_to?(:ordering) && after.ordering != before.ordering
        end

        # The foreign key of a has_one :through is on the intermediate record,
        # not on the target. Solidus's InventoryUnit has_one :order, through:
        # :shipment was looked up as Spree::Order.find_by(order_id: <the
        # unit's id>), a column only the shipment has: 0.9.x answered nil, so
        # carton.orders was empty and no shipped email went out. The target
        # is read through the intermediate record and then the source
        # association (AssociationInterceptor.records_through), each as that
        # association reads (from the event store when its model is
        # monitored, through its default scopes, checked as a loaded row),
        # and then narrowed by this association's own scope, which raises
        # UnsupportedQuery where it cannot be evaluated.
        #
        # Known differences from Active Record's join, left as they are:
        # - an association scope that unscopes (-> { with_discarded }) cannot
        #   bring back a target the source reader's default scope left out;
        # - through a has_one that is itself :through, only the intermediate
        #   record that association reads is followed, where the join
        #   chooses among all candidates (through a plain has_one, the
        #   candidates are read: lyra_through_has_one);
        # - an intermediate record already loaded on the owner is used even
        #   if stale, and reading the target leaves it loaded there (as the
        #   has_many :through path does).
        def lyra_find_target_through
          answer = lyra_through_has_one
          return answer.first if answer

          records = AssociationInterceptor.records_through(owner, reflection)
          return records.first unless reflection.scope

          lyra_scoped(Lyra::Projections::CachedRelation.new(reflection.klass, records), reflection.scope).first
        end

        # The key (and, for a polymorphic as: association, the owner's type)
        # a direct has_one reads its record by, as the has_many path reads
        # its records. Without the type, an owner read a record of another
        # type of owner with the same id.
        def lyra_has_one_conditions(has_one, owner_key_value)
          conditions = { has_one.foreign_key => owner_key_value }
          conditions[has_one.type] = owner.class.polymorphic_name if has_one.type
          conditions
        end

        # Through a plain has_one, Active Record's join reaches the target
        # through every intermediate record the owner has (those the through
        # association's scope selects, in its order), not only the one the
        # has_one reads. Those intermediate records are read here, as Lyra's
        # own read (the join reads them in SQL, unchecked), and the targets
        # they reach, narrowed by this association's own scope. When either
        # scope, or the intermediate model's default scope, orders, the first
        # target in that order is the join's answer; otherwise none or one
        # target is, and more than one is refused
        # (UnsupportedQuery): the join would choose among them, where the
        # reader would answer with the one its has_one read. Returns the
        # answer as [] or [target], or nil when the through association is
        # not a plain has_one, or its model is not read from events.
        def lyra_through_has_one
          through = reflection.through_reflection
          return nil unless through.macro == :has_one && !through.through_reflection?

          klass = through.klass
          return nil unless klass.respond_to?(:lyra_monitored) && klass.lyra_monitored

          owner_key_value = owner.read_attribute(through.active_record_primary_key)
          return [] if owner_key_value.nil?

          ordered = false
          candidates = Lyra::PurposeBoundReads.internal(INTERNAL) do
            found = Lyra::Projections::EventStoreReader.where(klass, lyra_has_one_conditions(through, owner_key_value))
            relation = Lyra::Projections::DefaultScopes.narrow(
              found, Lyra::Projections::DefaultScopes.for_association(klass, through, owner)
            )
            # A default scope that orders (order(:position)) orders the
            # join too: its order first, then the association scope's.
            ordered = lyra_orders?(found, relation)
            if through.scope
              scoped = lyra_scoped(relation, through.scope)
              ordered ||= lyra_orders?(relation, scoped)
              relation = scoped
            end
            relation.to_a
          end
          targets = AssociationInterceptor.records_through(owner, reflection, candidates)
          if reflection.scope
            relation = Lyra::Projections::CachedRelation.new(reflection.klass, targets)
            scoped = lyra_scoped(relation, reflection.scope)
            ordered ||= lyra_orders?(relation, scoped)
            targets = scoped.to_a
          end
          return targets.first(1) if ordered || targets.size <= 1

          raise Lyra::Projections::UnsupportedQuery.new(
            owner.class, "#{reflection.name} (a has_one :through #{through.name}, which has #{candidates.size} " \
                         "#{klass.name} records for this owner, reaching #{targets.size} #{reflection.klass.name} " \
                         "records in no order: Active Record's join would choose among them)"
          )
        end
      end

      module HasManyAssociationPatch
        # Queries on the association (variant.prices.find_by, .where,
        # .find_or_create_by!) run on its scope; under ES-NoProj that is the
        # records the event store holds for this owner, as find_target reads
        # them. ActiveRecord's own scope was built through the target class's
        # all/where and failed in merge!. While a new record's attributes are
        # being built (ScopeForCreatePatch) ActiveRecord's scope is used.
        def scope
          return super unless lyra_should_use_cache?
          return super if Thread.current[:lyra_bypass_read_override] || Thread.current[:lyra_association_own_scope]

          lyra_get_cached_relation
        end

        # dependent: :nullify and :delete_all write through the association's
        # scope (scope.update_all), where Lyra records them as the
        # dependent_association bypass they are. Given the event-backed scope
        # they became plain update_all bypasses, refused in strict mode.
        # Recorded writes go to the event store instead
        # (lyra_delete_or_nullify_from_events); only Lyra's own projection
        # writes still use the table scope.
        def delete_or_nullify_all_records(method)
          return super unless lyra_should_use_cache?
          return lyra_delete_or_nullify_from_events(method, lyra_dependent_children) unless Thread.current[:lyra_projection_write]

          previous = Thread.current[:lyra_association_own_scope]
          Thread.current[:lyra_association_own_scope] = true
          begin
            super
          ensure
            Thread.current[:lyra_association_own_scope] = previous
          end
        end

        # Rails 8+ passes async: keyword argument to find_target
        def find_target(async: false)
          if lyra_should_use_cache?
            lyra_find_target_from_cache
          else
            super
          end
        end

        # Override count_records to use cache
        def count_records
          if lyra_should_use_cache?
            lyra_get_cached_relation.count
          else
            super
          end
        end

        # Override size to use cache (used by any?, empty?, etc.)
        def size
          if lyra_should_use_cache?
            if loaded?
              target.size
            else
              lyra_get_cached_relation.count
            end
          else
            super
          end
        end

        # Override empty? directly
        def empty?
          if lyra_should_use_cache?
            size == 0
          else
            super
          end
        end

        private

        def lyra_should_use_cache?
          klass = reflection.klass
          klass.respond_to?(:lyra_monitored) &&
            klass.lyra_monitored &&
            Lyra.event_sourcing_mode? &&
            Lyra.config.projection_mode == :disabled
        end

        # The foreign key of a :through association lives on the intermediate
        # records, not on the target (shipment.orders was filtered on an
        # order_id Spree::Order does not have): they are read through that
        # association and its source. A polymorphic (as:) association matches
        # the owner's type too. The target's default scopes apply, less what
        # the association's scope unscopes, and then the association's own
        # scope, as in ActiveRecord's association scope; reading, counting,
        # plucking and the collection's queries all start here.
        def lyra_get_cached_relation
          relation =
            if reflection.through_reflection?
              lyra_records_through
            else
              owner_key_value = owner.read_attribute(reflection.active_record_primary_key)
              return Lyra::Projections::CachedRelation.new(reflection.klass, []) if owner_key_value.nil?

              conditions = { reflection.foreign_key => owner_key_value }
              conditions[reflection.type] = owner.class.polymorphic_name if reflection.type
              # Read when first needed, so that a narrowing where made on it
              # (stock_items.where(variant_id: ...)) reaches the reference
              # links with all its keys. As ActiveRecord does for what an
              # association loads, the records point back at this owner, not
              # at a copy of it read from the events: a child asks its
              # parent in memory (shipment.order.paid?), and the copy was the
              # parent before the change under way was recorded.
              Lyra::Projections::DeferredRelation.new(
                reflection.klass, conditions: conditions,
                on_load: ->(records) { records.each { |record| set_inverse_instance(record) } }
              )
            end
          relation = Lyra::Projections::DefaultScopes.narrow(relation, lyra_target_default_scope)
          lyra_apply_reflection_scope(relation)
        end

        def lyra_records_through
          Lyra::Projections::CachedRelation.new(reflection.klass, AssociationInterceptor.records_through(owner, reflection))
        end

        def lyra_apply_reflection_scope(relation)
          scope = reflection.scope
          return relation unless scope

          scope.arity.zero? ? relation.instance_exec(&scope) : relation.instance_exec(owner, &scope)
        end

        def lyra_find_target_from_cache
          lyra_get_cached_relation.to_a
        end

        # Removing records from the association (delete(record), or assigning
        # a new set) deletes or nullifies them as dependent: says, through the
        # association's scope narrowed to them. In the events-only store that
        # is the same write as above, on those of the records the association
        # selects.
        def delete_records(records, method)
          return super if method == :destroy || !lyra_should_use_cache? || Thread.current[:lyra_projection_write]

          pk = reflection.klass.primary_key
          return super unless pk.is_a?(String)

          ids = records.map { |record| record.read_attribute(pk) }
          lyra_delete_or_nullify_from_events(method, lyra_dependent_children.select { |child| ids.include?(child.read_attribute(pk)) })
        end

        # dependent: :delete_all and :nullify in the events-only store. The
        # table scope ActiveRecord writes through matches no row there (or
        # stale ones), so the children were left alive in the log, and a
        # nullify found them by foreign key alone, past the association's
        # scope. Each child gets the event delete_all or update_all writes for
        # it there. A nullify is the dependent_association bypass, outside
        # strict mode, wherever StrictDataAccessRelation counts it as one.
        #
        # The owner's counter cache is left as it is: ES-NoProj does not
        # maintain counter caches, so the log still holds the old count, and
        # lowering the one in memory made it disagree (and go negative).
        def lyra_delete_or_nullify_from_events(method, children)
          relation = Lyra::Projections::CachedRelation.new(reflection.klass, children)
          if method == :delete_all
            relation.delete_all
          elsif Lyra::StrictDataAccessRelation.nullify_update?(nullified_owner_attributes)
            Lyra.without_strict_access do
              relation.send(:bulk_mutate_as, :update_all, "dependent_association", nullified_owner_attributes)
            end
          else
            relation.update_all(nullified_owner_attributes)
          end
        end

        # The children a dependent write reaches: those ActiveRecord's scope
        # for the association selects, read from the event store as Lyra's
        # own read (as a bulk write's snapshot is). That is the owner's
        # records, narrowed by the target's default scopes (less what the
        # association's scope unscopes) and then by the association's scope.
        # Leaving the default scopes out deleted or nullified children the
        # application had put out of scope (a soft-deleted one). A scope the event store cannot evaluate
        # (an SQL string) raises UnsupportedQuery: deleting or nullifying
        # other children than the association selects is worse than refusing
        # the parent's destroy.
        def lyra_dependent_children
          owner_key_value = owner.read_attribute(reflection.active_record_primary_key)
          return [] if owner_key_value.nil?

          what = "dependent: #{options[:dependent].inspect} of #{owner.class.name}##{reflection.name}"
          conditions = { reflection.foreign_key => owner_key_value }
          conditions[reflection.type] = owner.class.polymorphic_name if reflection.type
          default_scope = lyra_target_default_scope
          Lyra::PurposeBoundReads.internal(INTERNAL) do
            relation = Lyra::Projections::DeferredRelation.new(reflection.klass, conditions: conditions)
            relation = Lyra::Projections::DefaultScopes.narrow(
              relation, default_scope, "#{what} (#{Lyra::Projections::DefaultScopes.description(reflection.klass)})"
            )
            begin
              relation = lyra_apply_reflection_scope(relation)
            rescue Lyra::Projections::UnsupportedQuery
              raise Lyra::Projections::UnsupportedQuery.new(reflection.klass, "#{what} (its scope)")
            end
            relation.records.to_a
          end
        end

        # The target's default scopes as ActiveRecord applies them to the
        # association (scope_for_association), less what the association's
        # own scope unscopes; nil when they select every record.
        def lyra_target_default_scope
          Lyra::Projections::DefaultScopes.for_association(reflection.klass, reflection, owner)
        end
      end

      # A has_many proxy's calculations and plucks (payment.refunds.sum(:amount),
      # order.line_items.pluck(:id)) ran ActiveRecord's SQL against the table,
      # which under ES-NoProj is empty, or failed asking the event-backed scope
      # for relation internals. They go to that scope, as reading does.
      module CollectionProxyPatch
        %i[calculate pluck ids pick exists?].each do |name|
          define_method(name) do |*args, **kwargs, &block|
            return super(*args, **kwargs, &block) unless lyra_events_only_association?

            scope.public_send(name, *args, **kwargs, &block)
          end
        end

        private

        def lyra_events_only_association?
          @association.is_a?(ActiveRecord::Associations::HasManyAssociation) &&
            @association.send(:lyra_should_use_cache?)
        rescue StandardError
          false
        end
      end

      # Building a new associated record (variant.prices.build) takes its
      # attributes from the association's scope (scope_for_create). Under
      # ES-NoProj, ActiveRecord evaluated that scope's default scopes and
      # scope lambdas through the target class's all/where, which Lyra answers
      # from the event store with a CachedRelation, and ActiveRecord's merge!
      # rejected it (Solidus's prices are scoped with_discarded). Building
      # attributes is not a read: the scope is built as ActiveRecord's own.
      # Reading the association still goes through find_target above.
      module ScopeForCreatePatch
        def scope_for_create
          return super unless lyra_events_only_target?

          previous = Thread.current[:lyra_bypass_read_override]
          Thread.current[:lyra_bypass_read_override] = true
          super
        ensure
          Thread.current[:lyra_bypass_read_override] = previous if lyra_events_only_target?
        end

        private

        def lyra_events_only_target?
          target = klass
          target.respond_to?(:lyra_monitored) && target.lyra_monitored &&
            Lyra.event_sourcing_mode? && Lyra.config.projection_mode == :disabled
        rescue StandardError
          false
        end
      end

      # The records a :through +reflection+ of +owner+ reaches: each
      # intermediate record's source association, read as that association
      # reads. With source_type: (a polymorphic source), only the
      # intermediate records whose type column holds that name are followed,
      # as Active Record's join selects them (where(thing_type: "A")); the
      # source reader would return a record of whatever class the column
      # names.
      # +through+: the intermediate records, when not those the through
      # association reads (HasOneAssociationPatch#lyra_through_has_one).
      def self.records_through(owner, reflection, through = nil)
        through ||= Array(owner.association(reflection.through_reflection.name).reader)
        if (source_type = reflection.options[:source_type])
          type_column = reflection.source_reflection.foreign_type
          through = through.select { |record| record.read_attribute(type_column) == source_type.to_s }
        end
        through.flat_map { |record| Array(record.association(reflection.source_reflection.name).reader) }.compact.uniq
      end

      def self.install!
        return if @installed

        ActiveRecord::Associations::BelongsToAssociation.prepend(BelongsToAssociationPatch)
        ActiveRecord::Associations::HasOneAssociation.prepend(HasOneAssociationPatch)
        ActiveRecord::Associations::HasManyAssociation.prepend(HasManyAssociationPatch)
        ActiveRecord::Associations::Association.prepend(ScopeForCreatePatch)
        ActiveRecord::Associations::CollectionProxy.prepend(CollectionProxyPatch)

        @installed = true
      end
    end
  end
end
