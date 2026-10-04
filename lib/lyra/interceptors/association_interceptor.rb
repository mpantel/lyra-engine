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

          Lyra::Projections::EventStoreReader.find(target_klass, foreign_key_value)
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
          owner_key_value = owner.read_attribute(reflection.active_record_primary_key)
          return nil if owner_key_value.nil?

          Lyra::Projections::EventStoreReader.find_by(
            reflection.klass,
            { reflection.foreign_key => owner_key_value }
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
        def delete_or_nullify_all_records(method)
          return super unless lyra_should_use_cache?

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
        # the owner's type too, and the association's own scope applies.
        def lyra_get_cached_relation
          relation =
            if reflection.through_reflection?
              lyra_records_through
            else
              owner_key_value = owner.read_attribute(reflection.active_record_primary_key)
              return Lyra::Projections::CachedRelation.new(reflection.klass, []) if owner_key_value.nil?

              conditions = { reflection.foreign_key => owner_key_value }
              conditions[reflection.type] = owner.class.polymorphic_name if reflection.type
              Lyra::Projections::EventStoreReader.where(reflection.klass, conditions)
            end
          lyra_apply_reflection_scope(relation)
        end

        def lyra_records_through
          through = Array(owner.association(reflection.through_reflection.name).reader)
          records = through.flat_map { |record| Array(record.association(reflection.source_reflection.name).reader) }
          Lyra::Projections::CachedRelation.new(reflection.klass, records.compact.uniq)
        end

        def lyra_apply_reflection_scope(relation)
          scope = reflection.scope
          return relation unless scope

          scope.arity.zero? ? relation.instance_exec(&scope) : relation.instance_exec(owner, &scope)
        end

        def lyra_find_target_from_cache
          lyra_get_cached_relation.to_a
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
