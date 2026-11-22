# frozen_string_literal: true

module Lyra
  module Projections
    # Reads model state from event store when projections are disabled.
    #
    # Uses CachedProjection (backed by Solid Cache or Rails.cache) for
    # fast reads while keeping events as the source of truth.
    #
    # Usage:
    #   EventStoreReader.find(User, 123)
    #   EventStoreReader.find_by(User, email: "test@example.com")
    #   EventStoreReader.where(User, status: "active")
    #
    # Every read first runs Genesis.first_use: on the model's first read in the
    # process, rows that predate Lyra get their Imported events, so the answer
    # -- aggregates included -- comes from streams alone and covers them. A
    # find or exists? of a row Genesis skipped (genesis_unrepresentable :skip)
    # imports it if it has become representable, or raises Genesis::Refused.
    class EventStoreReader
      class << self
        # Find a record by ID (cached)
        #
        # @param model_class [Class] The ActiveRecord model class
        # @param id [Integer, String] The record ID
        # @return [ActiveRecord::Base, nil] The reconstructed record or nil
        def find(model_class, id)
          Genesis.first_use(model_class, id)
          attributes = CachedProjection.find(model_class, id)
          return nil unless attributes

          build_instance(model_class, attributes)
        end

        # Find a record by attributes (cached)
        #
        # @param model_class [Class] The ActiveRecord model class
        # @param attributes [Hash] The attributes to match
        # @return [ActiveRecord::Base, nil] The first matching record or nil
        def find_by(model_class, attributes)
          Genesis.first_use(model_class)
          result = CachedProjection.find_by(model_class, AssociationConditions.rewrite(model_class, attributes))
          return nil unless result

          build_instance(model_class, result)
        end

        # The live records with these ids, in the order given, as their
        # streams have them now: the streams' last events are read afresh,
        # and a cached entry is used only when it is stamped with that event
        # (CachedProjection.find_many).
        def find_many(model_class, ids)
          Genesis.first_use(model_class)
          CachedProjection.find_many(model_class, ids).map { |attrs| build_instance(model_class, attrs) }.compact
        end

        # Check if a record exists (cached)
        #
        # @param model_class [Class] The ActiveRecord model class
        # @param id [Integer, String] The record ID
        # @return [Boolean] True if record exists and is not destroyed
        def exists?(model_class, id)
          Genesis.first_use(model_class, id)
          CachedProjection.exists?(model_class, id)
        end

        # Get a CachedRelation for the model (supports method chaining)
        #
        # @param model_class [Class] The ActiveRecord model class
        # @return [CachedRelation] A relation-like object for chaining
        def relation(model_class)
          Genesis.first_use(model_class)
          results = CachedProjection.all(model_class)
          records = results.map { |attrs| build_instance(model_class, attrs) }.compact
          # A write on it, or on a relation made from it, reads it again
          # (Rebuildable).
          # Not loaded (false, as Active Record's Model.all; a relation
          # derived from it answers nil).
          CachedRelation.new(model_class, records).tap do |relation|
            relation.rebuild_recipe = [Rebuildable::AllRecords.new(model_class), []]
            relation.instance_variable_set(:@loaded_records, false)
          end
        end

        # Load all records of a given type (cached)
        # Warning: Can be expensive for large datasets
        #
        # @param model_class [Class] The ActiveRecord model class
        # @return [CachedRelation] A relation containing all reconstructed records
        def all(model_class)
          relation(model_class)
        end

        # Query records with conditions (cached)
        #
        # @param model_class [Class] The ActiveRecord model class
        # @param conditions [Hash] Query conditions
        # @return [CachedRelation] A relation containing matching records
        # A foreign-key condition is answered from the reference links
        # (ReferenceLinks), not by building every record of the model.
        def where(model_class, conditions)
          linked_where(model_class, conditions) || relation(model_class).where(conditions)
        end

        # The records matching +conditions+, built from the reference links'
        # candidates; nil when the conditions name no foreign-key value.
        def linked_where(model_class, conditions)
          Genesis.first_use(model_class)
          candidates = ReferenceLinks.lookup(model_class, conditions)
          return nil unless candidates

          records = candidates.map { |attrs| build_instance(model_class, attrs) }.compact
          found = CachedRelation.new(model_class, records).where(conditions)
          # Read again by the same lookup (Rebuildable), with the conditions
          # as they are now: a copy, which the caller's changes do not reach.
          copied = Rebuildable.copy(conditions)
          unless copied.equal?(Rebuildable::UNSAFE)
            found.rebuild_recipe = [-> { where(model_class, Rebuildable.copy(copied, freeze: false)) }, []]
          end
          found
        end

        # The live records with these primary keys, as a relation that a
        # write reads again the same way (Rebuildable::Keyed): its cost is
        # that of the records, not of the model's size.
        def keyed(model_class, ids)
          ids = Array(ids).uniq
          CachedRelation.new(model_class, find_many(model_class, ids)).tap do |found|
            found.rebuild_recipe = [Rebuildable::Keyed.new(model_class, ids.map { Rebuildable.copy(_1) }.freeze), []]
          end
        end

        # Count records (cached)
        #
        # @param model_class [Class] The ActiveRecord model class
        # @param conditions [Hash] Optional conditions
        # @return [Integer] Count of matching records
        def count(model_class, conditions = {})
          Genesis.first_use(model_class)
          CachedProjection.count(model_class, AssociationConditions.rewrite(model_class, conditions))
        end

        # Invalidate cache for a record (call after event stored)
        #
        # @param model_class [Class] The ActiveRecord model class
        # @param id [Integer, String] The record ID
        def invalidate(model_class, id)
          CachedProjection.invalidate(model_class, id)
        end

        # Warm cache for a record (call after event stored)
        #
        # @param model_class [Class] The ActiveRecord model class
        # @param id [Integer, String] The record ID
        def warm(model_class, id)
          CachedProjection.warm(model_class, id)
        end

        private

        def build_instance(model_class, attributes)
          # Ensure attributes are stringified
          attrs = attributes.transform_keys(&:to_s)

          # Filter to only known columns
          column_names = model_class.column_names
          # (CachedProjection's entries hold them as the table does.)
          filtered_attrs = attrs.slice(*column_names)

          # Use AR's instantiate method - proper way to build from DB-style attributes
          # Lyra's own reconstruction: the purpose check is made on the records
          # a query returns (CachedRelationDelivery), not on every one built.
          record = Lyra::PurposeBoundReads.internal(INTERNAL) { model_class.instantiate(filtered_attrs) }

          # Note: We don't mark as readonly because the app may need to modify
          # and re-save (which will go through event sourcing)

          record
        rescue => e
          # Fail closed: a record that cannot be built from its events (a
          # value its type cannot read) is an error, not a row left out of
          # the answer, which it used to be.
          Rails.logger.error("Lyra::EventStoreReader: cannot build #{model_class.name} from its events - #{e.class}: #{e.message}")
          raise
        end
      end
    end
  end
end
