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
          record = AssociationInterceptor.scoped(relation, reflection.scope, owner).first
          Lyra::PurposeBoundReads.check(record, Array(reflection.foreign_key).map(&:to_s)) if record
          record
        end

        # The foreign key of a has_one :through is on the intermediate record,
        # not on the target. Solidus's InventoryUnit has_one :order, through:
        # :shipment was looked up as Spree::Order.find_by(order_id: <the
        # unit's id>), a column only the shipment has: 0.9.x answered nil, so
        # carton.orders was empty and no shipped email went out.
        #
        # The targets are those Active Record's join reaches, in its order
        # (AssociationInterceptor.through_scoped): through every intermediate
        # record (every one a has_one selects, not only the one it reads),
        # read afresh, and narrowed as the join narrows them. When a scope in
        # the chain orders, the first target in that order is the answer;
        # otherwise none or one target is, and more than one is refused
        # (UnsupportedQuery): the join would choose among them. What a scope
        # holds that CachedRelation cannot evaluate raises UnsupportedQuery.
        # Only the answer is checked as a loaded row: the join loads nothing
        # else.
        def lyra_find_target_through
          relation, ordered = AssociationInterceptor.through_scoped(owner, reflection)
          joined = relation.is_a?(ThroughRelation)
          targets = (joined ? relation.join_records : Lyra::PurposeBoundReads.internal(INTERNAL) { relation.to_a }).uniq
          if targets.size > 1 && !ordered
            raise Lyra::Projections::UnsupportedQuery.new(
              owner.class, "#{reflection.name} (a has_one :through #{reflection.through_reflection.name}, reaching " \
                           "#{targets.size} #{reflection.klass.name} records for this owner in no order: " \
                           "Active Record's join would choose among them)"
            )
          end
          if targets.size > 1 && joined && relation.unordered_reason
            raise Lyra::Projections::UnsupportedQuery.new(owner.class, relation.unordered_reason)
          end
          # Delivered alone, as the join's LIMIT 1 row: checked as a
          # loaded row, and as a query through the intermediate models.
          targets.empty? ? nil : relation.spawn_records(targets.first(1)).first
        end

        # The key (and, for a polymorphic as: association, the owner's type)
        # a direct has_one reads its record by.
        def lyra_has_one_conditions(has_one, owner_key_value)
          AssociationInterceptor.has_one_conditions(owner, has_one, owner_key_value)
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
        # association and its source, afresh, as Active Record's join reads
        # them, narrowed by the target's default scopes as the join applies
        # them, in its order and narrowed by the association's own scope
        # (AssociationInterceptor.through_scoped). A direct polymorphic (as:)
        # association matches the owner's type too. The
        # target's default scopes apply, less what the association's scope
        # unscopes, and then the association's own scope, as in
        # ActiveRecord's association scope; reading, counting, plucking and
        # the collection's queries all start here.
        def lyra_get_cached_relation
          if reflection.through_reflection?
            # A write reads the join again (Lyra::Projections::Rebuildable)
            # with the default scopes built now (DefaultScopes.remembering),
            # where that runs none of the application's code again: no
            # association on the way has a scope. Otherwise it writes the
            # records the relation holds.
            scopes = {}
            relation = Lyra::Projections::DefaultScopes.remembering(scopes) do
              AssociationInterceptor.through_scoped(owner, reflection).first
            end
            if relation.is_a?(Lyra::Projections::CachedRelation) && AssociationInterceptor.plain_through?(reflection)
              relation.rebuild_recipe = [lambda {
                Lyra::Projections::DefaultScopes.remembering(scopes) { AssociationInterceptor.through_scoped(owner, reflection).first }
              }, []]
            end
            return relation
          end

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
          relation = Lyra::Projections::DeferredRelation.new(
            reflection.klass, conditions: conditions,
            on_load: ->(records) { records.each { |record| set_inverse_instance(record) } }
          )
          relation = Lyra::Projections::DefaultScopes.narrow(relation, lyra_target_default_scope)
          lyra_apply_reflection_scope(relation)
        end

        def lyra_apply_reflection_scope(relation)
          scope = reflection.scope
          return relation unless scope

          scope.arity.zero? ? relation.instance_exec(&scope) : relation.instance_exec(owner, &scope)
        end

        # The records are checked as loaded rows as the relation delivers
        # them (CachedRelationDelivery), those returned only.
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
        # it there. A nullify is Rails' own write, the dependent_association
        # bypass, outside strict mode, whatever its columns (a polymorphic
        # key's type, a key not named *_id), as StrictDataAccessRelation
        # takes the marked nullify (Lyra::Associations::Maintenance); a
        # polymorphic one was an update_all, refused in strict mode.
        #
        # The owner's counter cache is left as it is: ES-NoProj does not
        # maintain counter caches, so the log still holds the old count, and
        # lowering the one in memory made it disagree (and go negative).
        def lyra_delete_or_nullify_from_events(method, children)
          relation = Lyra::Projections::CachedRelation.new(reflection.klass, children)
          if method == :delete_all
            relation.delete_all
          else
            Lyra.without_strict_access do
              relation.send(:bulk_mutate_as, :update_all, "dependent_association", nullified_owner_attributes)
            end
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
      #
      # update_all (author.articles.update_all(author_id: nil)) is Active
      # Record's on the association's scope; it was the table's under
      # ES-NoProj, and refused. It goes to the event-backed scope too, which
      # records an event for each record the association selects
      # (CachedRelation#update_all). delete_all and destroy_all go through
      # the association (HasManyAssociationPatch#delete_or_nullify_all_records,
      # and each record's destroy).
      module CollectionProxyPatch
        %i[calculate pluck ids pick exists? update_all].each do |name|
          define_method(name) do |*args, **kwargs, &block|
            return super(*args, **kwargs, &block) unless lyra_events_only_association?

            scope.public_send(name, *args, **kwargs, &block)
          end
        end

        # first, last and take on a :through association not loaded: Active
        # Record's query orders by the join's orders (the intermediate
        # records' among them), which the event-backed scope holds in its
        # records' order; the proxy's own query ordered by the target's
        # primary key alone.
        # length on a :through association not loaded counts what the
        # event-backed scope holds, as size does, without loading the target:
        # a target loaded where the join's order cannot be reproduced would
        # list the records in another order (ThroughRelation).
        def length
          return super if @association.send(:find_from_target?) || !lyra_events_only_association?
          return super unless scope.is_a?(ThroughRelation)

          scope.length
        end

        %i[first last take].each do |name|
          define_method(name) do |*args|
            return super(*args) if @association.send(:find_from_target?) || !lyra_events_only_association?
            return super(*args) unless scope.is_a?(ThroughRelation)

            scope.public_send(name, *args)
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

      # The relation a :through association's targets come in under ES-NoProj
      # (AssociationInterceptor.through_scoped).
      #
      # - Active Record's unscope(where: :col) on such an association drops
      #   the predicate on +col+ from every table of the join, the
      #   intermediate tables' default scopes included:
      #   owner.tags.unscope(where: :deleted_at) also follows a soft-deleted
      #   intermediate record. The intermediate records here were read through
      #   their default scopes already, so an unscope of a column one of them
      #   conditions is refused rather than answered short.
      # - Where the join's order cannot be reproduced (+unordered_reason+), a
      #   read that depends on it (loading, first, last, take, a limit or
      #   offset, pluck and ids, which list in that order) is refused when
      #   there is more than one record; counts, sums, length and exists?
      #   answer, as they do not depend on it.
      # - A bulk write writes each record once: the join may reach a record
      #   through two intermediate records, and SQL updates or deletes the row
      #   once.
      class ThroughRelation < Lyra::Projections::CachedRelation
        # Its own query methods come before CachedRelation's recording
        # (Lyra::Projections::Rebuildable).
        prepend Lyra::Projections::Rebuildable.wrappers

        # Columns the intermediate models' default scopes condition.
        attr_accessor :intermediate_columns
        # Why the join's order cannot be reproduced, if it cannot.
        attr_accessor :unordered_reason
        # While the association's own scope is applied: the records are in
        # the join's order already, which its order is part of.
        attr_accessor :keep_order

        ORDER_DEPENDENT = %i[to_a to_ary each records first last take second third [] find_each
                             find_in_batches in_batches limit offset pluck ids].freeze

        ORDER_DEPENDENT.each do |name|
          define_method(name) do |*args, **kwargs, &block|
            refuse_join_order!
            super(*args, **kwargs, &block)
          end
        end

        %i[update_all delete_all touch_all destroy_all].each do |name|
          define_method(name) do |*args, **kwargs, &block|
            unique = @records.uniq
            return super(*args, **kwargs, &block) if unique.size == @records.size

            # The same selection, each record once: built again as this one is.
            spawn_records(unique).inherit_rebuild(self).public_send(name, *args, **kwargs, &block)
          end
        end

        def order(*args)
          keep_order ? self : super
        end

        # As size: how many records, which does not depend on their order
        # (they are loaded, and checked, as Active Record loads them).
        def length
          @order_free = true
          to_a.length
        ensure
          @order_free = false
        end

        def reorder(*args)
          relation = super
          relation.unordered_reason = nil if relation.respond_to?(:unordered_reason=)
          relation
        end

        def unscope(*args)
          hit = through_unscoped_columns(args.flatten)
          if hit.any?
            raise Lyra::Projections::UnsupportedQuery.new(
              model_class, "unscope(#{args.inspect[1..-2]}) on a :through association: Active Record's join drops " \
                           "#{hit.join(', ')} from the intermediate tables' default scopes too, and ES-NoProj read " \
                           "the intermediate records through them"
            )
          end
          super
        end

        def spawn_records(records)
          relation = super
          if relation.is_a?(ThroughRelation)
            relation.intermediate_columns = intermediate_columns
            relation.unordered_reason = unordered_reason
            relation.keep_order = keep_order
          end
          relation
        end

        # The records in the join's order as far as it is known, for Lyra's
        # own use (AssociationInterceptor): no order check, no purpose check.
        def join_records = @records.dup

        private

        def refuse_join_order!
          return if @order_free || unordered_reason.nil? || @records.size < 2

          raise Lyra::Projections::UnsupportedQuery.new(model_class, unordered_reason)
        end

        def through_unscoped_columns(args)
          columns = Array(intermediate_columns)
          return [] if columns.empty?

          args.flat_map do |arg|
            case arg
            when :where, "where" then columns
            when Hash then Array(arg[:where] || arg["where"]).map { |c| c.to_s.split(".").last.delete('"') } & columns
            else []
            end
          end.uniq
        end
      end

      class << self
        # Whether reading a :through +reflection+'s join again runs none of
        # the application's code: no association on the way has a scope (the
        # default scopes are remembered: DefaultScopes.remembering).
        def plain_through?(reflection)
          return false unless reflection.scope.nil?

          reflection.chain.all? { |step| step.scope.nil? }
        rescue StandardError
          false
        end

        # +relation+ narrowed by an association +scope+ evaluated with +owner+
        # (a scope returning nil leaves it as it is, as in Active Record).
        def scoped(relation, scope, owner)
          result = scope.arity.zero? ? relation.instance_exec(&scope) : relation.instance_exec(owner, &scope)
          result || relation
        end

        # Whether narrowing +before+ by a scope into +after+ ordered it.
        def orders?(before, after)
          after.respond_to?(:ordering) && after.ordering != before.ordering
        end

        # The key (and, for a polymorphic as: association, the owner's type)
        # a direct +has_one+ of +owner+ reads its record by, as the has_many
        # path reads its records. Without the type, an owner read a record
        # of another type of owner with the same id.
        def has_one_conditions(owner, has_one, owner_key_value)
          conditions = { has_one.foreign_key => owner_key_value }
          conditions[has_one.type] = owner.class.polymorphic_name if has_one.type
          conditions
        end

        # The targets of a :through +reflection+ of +owner+, as Active
        # Record's join reaches them, as [relation, ordered]: a
        # ThroughRelation, and whether a scope on the way orders them.
        #
        # Every record on the way is read afresh, on an association object of
        # its own (join_candidates: the join reads the tables), as Lyra's own
        # read: the join loads no intermediate record, so none is checked
        # here. The records returned are checked where they are returned
        # (HasOneAssociationPatch, HasManyAssociationPatch#find_target), and a
        # query on the relation is checked as a query through the
        # intermediate models (joined_classes), as the join's SQL is. Through
        # a has_one, every record it selects counts, not only the one it
        # reads.
        #
        # The targets are read without their default scope and then narrowed
        # by it as the join applies it (DefaultScopes.for_through: less what
        # the source's scope or the association's own unscopes, so that
        # -> { with_discarded } brings back a soft-deleted target), ordered as
        # the join orders them (join_order), and narrowed by the association's
        # own scope. In no order at all, they are in primary key order, as
        # Active Record's first takes them.
        #
        # An intermediate model on the target's own table is aliased in the
        # join, which applies no default scope to it (cat.grandchildren
        # through a soft-deleted child): it is read without its default
        # scope too.
        #
        # With source_type: (a polymorphic source), only the intermediate
        # records whose type column holds that name are followed, as the
        # join selects them (where(thing_type: "A")). A target reached
        # through two intermediate records is there twice, as in the join.
        def through_scoped(owner, reflection, head = reflection.klass)
          klass = reflection.klass
          source = reflection.source_reflection
          through = reflection.through_reflection
          pairs, inner_reason = Lyra::PurposeBoundReads.internal(INTERNAL) do
            found, _, reason = aliased(through.klass, head) { join_candidates(owner, through, head) }
            if (source_type = reflection.options[:source_type])
              found = found.select { |record| record.read_attribute(source.foreign_type) == source_type.to_s }
            end
            reason = nil if found.size < 2
            reached = without_default_scope(klass) do
              found.flat_map { |record| join_candidates(record, source, head).first.compact.map { [_1, record] } }
            end
            [reached, reason]
          end

          default = Lyra::Projections::DefaultScopes.for_through(reflection, owner)
          keys, reason = join_order(owner, reflection, head, default)
          pairs = Lyra::PurposeBoundReads.internal(INTERNAL) { sort_pairs(pairs, keys, klass, through.klass) } if reason.nil?
          targets = pairs.map(&:first)
          targets = by_primary_key(klass, targets) if keys.empty?

          base = ThroughRelation.new(klass, targets)
          base.intermediate_columns = intermediate_columns(reflection, head)
          base.unordered_reason = reason || inner_reason
          # The intermediate models, joined as in the SQL: a query on the
          # relation is checked as the join is (a right in force for them).
          base.joined_classes = reflection.chain.drop(1).map(&:klass).uniq
          relation = Lyra::Projections::DefaultScopes.narrow(base, default)
          if reflection.scope
            # The association's own unscope is the target table's alone in
            # the join (DefaultScopes.for_through has taken it into account),
            # and its order is in the records' order already.
            relation.keep_order = true
            columns = relation.intermediate_columns
            relation.intermediate_columns = nil
            relation = scoped(relation, reflection.scope, owner)
            if relation.is_a?(ThroughRelation)
              relation.intermediate_columns = columns
              relation.keep_order = nil
            end
          end
          [relation, keys.any? || !inner_reason.nil?]
        end

        # The records Active Record's join reaches through +reflection+ of
        # +owner+, as [records, ordered, reason]: +ordered+ when a scope on
        # the way (an association's, or a model's default scope) orders them,
        # +reason+ when that order cannot be reproduced (ThroughRelation).
        # +head+ is the model the whole join reads.
        #
        # - A :through association: through_scoped.
        # - A has_one: every record it selects, in its order (the join does
        #   not stop at the first: has_one_candidates).
        # - A belongs_to or has_many: what it reads.
        def join_candidates(owner, reflection, head = reflection.klass)
          if reflection.through_reflection?
            relation, ordered = through_scoped(owner, reflection, head)
            [relation.join_records, ordered, relation.unordered_reason]
          elsif reflection.macro == :has_one
            has_one_candidates(owner, reflection)
          elsif reflection.collection?
            relation = fresh_association(owner, reflection).scope
            [relation.to_a, ordered?(relation), nil]
          else
            [Array(fresh_association(owner, reflection).reader), false, nil]
          end
        end

        # Every record a direct +has_one+ of +owner+ selects, as
        # [records, ordered]: those of the owner's (its type too, for as:),
        # through the target's default scopes and then the has_one's own
        # scope, in their order. A model read from events is read from the
        # event store; any other with the association's own SQL, less the
        # LIMIT 1 a has_one reads with (the join keeps every row).
        def has_one_candidates(owner, has_one)
          klass = has_one.klass
          unless klass.respond_to?(:lyra_monitored) && klass.lyra_monitored
            relation = fresh_association(owner, has_one).scope.except(:limit, :offset)
            return [relation.to_a, ordered?(relation), nil]
          end

          owner_key_value = owner.read_attribute(has_one.active_record_primary_key)
          return [[], false, nil] if owner_key_value.nil?

          found = Lyra::Projections::EventStoreReader.where(klass, has_one_conditions(owner, has_one, owner_key_value))
          relation = Lyra::Projections::DefaultScopes.narrow(
            found, Lyra::Projections::DefaultScopes.for_association(klass, has_one, owner)
          )
          # A default scope that orders (order(:position)) orders the
          # join too: its order first, then the association scope's.
          ordered = orders?(found, relation)
          if has_one.scope
            scoped = scoped(relation, has_one.scope, owner)
            ordered ||= orders?(relation, scoped)
            relation = scoped
          end
          [relation.to_a, ordered, nil]
        end

        # A new association object for +reflection+ of +owner+: what it
        # reads is read afresh (from the event store, or the table) and is
        # not left loaded on the owner.
        def fresh_association(owner, reflection)
          reflection.association_class.new(owner, reflection)
        end

        private

        # Whether +relation+ (Active Record's, or a CachedRelation) orders.
        def ordered?(relation)
          if relation.respond_to?(:ordering)
            relation.ordering.any?
          else
            relation.respond_to?(:order_values) && relation.order_values.any?
          end
        end

        # The order values of +scopes+ (association scope procs, in the
        # order the join takes them) evaluated with +owner+ on Active
        # Record's relation of +klass+, as AssociationScope evaluates them.
        def order_values(klass, scopes, owner)
          Lyra::Projections::DefaultScopes.built do
            scopes.flat_map do |scope|
              relation = klass.unscoped
              item = relation.instance_exec(owner, &scope) || relation
              item.respond_to?(:order_values) ? item.order_values : []
            end
          end
        end

        # The join's order for a :through +reflection+ of +owner+, as
        # [keys, reason]: +keys+ is [side, order value] pairs, most
        # significant first, side :target or :intermediate (the record of
        # the step next to the target), or [:inner, nil] for steps further
        # on, whose order the intermediate records came in already. Active
        # Record's join orders by the target's default scope, the
        # intermediate models' default scopes, then the association scopes on
        # the target (its own, then the source's) and then the intermediate
        # steps' scopes; an unscope(:order) in a scope on the target takes the
        # default scopes' and the steps' orders off. +reason+, when the order
        # cannot be reproduced here: an order on a table that is neither the
        # target's nor the next step's, or a default scope ordering a step
        # further on while an association scope orders too.
        def join_order(owner, reflection, head, default)
          klass = reflection.klass
          first, *further = reflection.chain.drop(1)
          unordered = unscopes_order?(klass, reflection.constraints, owner)
          target_default = default ? default.order_values : []
          first_default = unordered || same_table?(first.klass, head) ? [] : default_order_values(first.klass)
          first_scope = unordered ? [] : order_values(first.klass, first.scopes, owner)
          on_target = order_values(klass, reflection.constraints.reverse, owner)

          keys = target_default.map { [:target, _1] } + first_default.map { [:intermediate, _1] } +
                 on_target.map { [side_of(_1, klass, first.klass), _1] } + first_scope.map { [:intermediate, _1] }
          further_default = !unordered && further.any? { !same_table?(_1.klass, head) && default_orders?(_1.klass) }
          further_scope = !unordered && further.any? { order_values(_1.klass, _1.scopes, owner).any? }
          keys << [:inner, nil] if further_default || further_scope

          reason =
            if keys.any? { _1.first.nil? }
              "#{reflection.name} (an order on a table other than the target's and the next step's)"
            elsif further_default && (on_target.any? || first_scope.any?)
              "#{reflection.name} (a default scope orders a step past the first, and an association scope orders too)"
            end
          reason &&= "#{reason}: ES-NoProj cannot order its records as Active Record's join does"
          [keys, reason]
        end

        # +pairs+ ([target, intermediate record]) sorted by +keys+
        # (join_order), stably, one key at a time from the least significant.
        def sort_pairs(pairs, keys, klass, through_klass)
          return pairs if pairs.size < 2

          keys.reverse_each do |side, value|
            next if side == :inner

            index = side == :target ? 0 : 1
            copies = pairs.map { |pair| pair[index].clone }
            back = {}.compare_by_identity
            copies.each_with_index { |copy, i| back[copy] = pairs[i] }
            sorted = Lyra::Projections::CachedRelation.new(index.zero? ? klass : through_klass, copies).order(value).to_a
            pairs = sorted.map { |copy| back[copy] }
          end
          pairs
        end

        # Which record an order value of a scope on the target reads: the
        # target's (its table, or a string, which CachedRelation reads as
        # the target's), the next step's, or neither (nil).
        def side_of(value, klass, first_klass)
          return :target unless value.is_a?(Arel::Nodes::Ordering) && value.expr.is_a?(Arel::Attributes::Attribute)

          table = value.expr.relation.respond_to?(:name) ? value.expr.relation.name.to_s : nil
          return :target if table == klass.table_name
          return :intermediate if table == first_klass.table_name

          nil
        end

        # Whether one of +scopes+ takes the order off (unscope(:order)).
        def unscopes_order?(klass, scopes, owner)
          Lyra::Projections::DefaultScopes.built do
            scopes.any? do |scope|
              relation = klass.unscoped
              item = relation.instance_exec(owner, &scope) || relation
              item.respond_to?(:unscope_values) && item.unscope_values.include?(:order)
            end
          end
        end

        def default_order_values(klass)
          return [] unless Lyra::Projections::DefaultScopes.any?(klass)

          Lyra::Projections::DefaultScopes.built { klass.scope_for_association }.order_values
        end

        # The columns the intermediate models' default scopes condition
        # (ThroughRelation#unscope).
        def intermediate_columns(reflection, head)
          reflection.chain.drop(1).flat_map do |step|
            next [] if same_table?(step.klass, head) || !Lyra::Projections::DefaultScopes.any?(step.klass)

            scope = Lyra::Projections::DefaultScopes.built { step.klass.scope_for_association }
            names = []
            scope.where_clause.send(:predicates).each do |node|
              Arel.fetch_attribute(node) { |attribute| names << attribute.name.to_s }
            end
            names
          end.uniq
        end

        # +records+ in primary key order (left as they are if the keys do
        # not compare).
        def by_primary_key(klass, records)
          key = klass.primary_key
          return records unless key.is_a?(String)

          records.sort_by { |record| record.read_attribute(key) }
        rescue ArgumentError, NoMethodError
          records
        end

        def default_orders?(klass)
          Lyra::Projections::DefaultScopes.any?(klass) &&
            Lyra::Projections::DefaultScopes.built { klass.scope_for_association }.order_values.any?
        end

        def same_table?(klass, head) = klass.table_name == head.table_name

        # The block run with +klass+'s default scopes off when +klass+ is on
        # +head+'s table, where the join aliases it and applies none.
        def aliased(klass, head, &block)
          same_table?(klass, head) ? without_default_scope(klass, &block) : yield
        end

        # The block run with +klass+'s default scopes off, as
        # Model.unscoped { } turns them off: the source associations read
        # every target, and through_scoped narrows them by the default
        # scopes as the join applies them.
        def without_default_scope(klass, &block)
          Lyra::Projections::DefaultScopes.any?(klass) ? klass.unscoped(&block) : yield
        end
      end

      def self.install!
        return if @installed

        ActiveRecord::Associations::BelongsToAssociation.prepend(BelongsToAssociationPatch)
        ActiveRecord::Associations::HasOneAssociation.prepend(HasOneAssociationPatch)
        ActiveRecord::Associations::HasManyAssociation.prepend(HasManyAssociationPatch)
        ActiveRecord::Associations::Association.prepend(ScopeForCreatePatch)
        ActiveRecord::Associations::CollectionProxy.prepend(CollectionProxyPatch)
        Lyra::Associations::Maintenance.install!

        @installed = true
      end
    end
  end
end
