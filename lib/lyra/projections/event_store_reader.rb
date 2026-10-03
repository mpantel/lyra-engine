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
    # -- aggregates included -- comes from streams alone and covers them.
    class EventStoreReader
      class << self
        # Find a record by ID (cached)
        #
        # @param model_class [Class] The ActiveRecord model class
        # @param id [Integer, String] The record ID
        # @return [ActiveRecord::Base, nil] The reconstructed record or nil
        def find(model_class, id)
          Genesis.first_use(model_class)
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
          result = CachedProjection.find_by(model_class, attributes)
          return nil unless result

          build_instance(model_class, result)
        end

        # Check if a record exists (cached)
        #
        # @param model_class [Class] The ActiveRecord model class
        # @param id [Integer, String] The record ID
        # @return [Boolean] True if record exists and is not destroyed
        def exists?(model_class, id)
          Genesis.first_use(model_class)
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
          CachedRelation.new(model_class, records)
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
        def where(model_class, conditions)
          relation(model_class).where(conditions)
        end

        # Count records (cached)
        #
        # @param model_class [Class] The ActiveRecord model class
        # @param conditions [Hash] Optional conditions
        # @return [Integer] Count of matching records
        def count(model_class, conditions = {})
          Genesis.first_use(model_class)
          CachedProjection.count(model_class, conditions)
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
          filtered_attrs = attrs.slice(*column_names)

          # Use AR's instantiate method - proper way to build from DB-style attributes
          record = model_class.instantiate(filtered_attrs)

          # Note: We don't mark as readonly because the app may need to modify
          # and re-save (which will go through event sourcing)

          record
        rescue => e
          Rails.logger.warn("Lyra::EventStoreReader: Failed to build instance - #{e.message}")
          nil
        end
      end
    end
  end
end
