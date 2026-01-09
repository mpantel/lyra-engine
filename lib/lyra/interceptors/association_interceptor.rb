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

        def lyra_get_cached_relation
          owner_key_value = owner.read_attribute(reflection.active_record_primary_key)
          return Lyra::Projections::CachedRelation.new(reflection.klass, []) if owner_key_value.nil?

          Lyra::Projections::EventStoreReader.where(
            reflection.klass,
            { reflection.foreign_key => owner_key_value }
          )
        end

        def lyra_find_target_from_cache
          lyra_get_cached_relation.to_a
        end
      end

      def self.install!
        return if @installed

        ActiveRecord::Associations::BelongsToAssociation.prepend(BelongsToAssociationPatch)
        ActiveRecord::Associations::HasOneAssociation.prepend(HasOneAssociationPatch)
        ActiveRecord::Associations::HasManyAssociation.prepend(HasManyAssociationPatch)

        @installed = true
      end
    end
  end
end
