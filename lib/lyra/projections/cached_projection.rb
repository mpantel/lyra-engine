# frozen_string_literal: true

module Lyra
  module Projections
    # Cached projection layer using Solid Cache (or any Rails.cache backend).
    #
    # In disabled projection mode, this caches reconstructed model state from events.
    # Provides fast reads while keeping events as the source of truth.
    #
    # Cache Strategy:
    # - Individual records: cached by model class + id
    # - Collections: cached by query fingerprint
    # - Invalidation: on event publish for affected streams
    #
    # Usage:
    #   CachedProjection.find(User, 123)
    #   CachedProjection.where(User, status: "active")
    #   CachedProjection.invalidate(User, 123)
    #
    class CachedProjection
      # Cache configuration
      CACHE_VERSION = 1
      DEFAULT_EXPIRES_IN = 1.hour

      class << self
        # Find a single record by ID (cached)
        #
        # @param model_class [Class] The ActiveRecord model class
        # @param id [Integer, String] The record ID
        # @param force [Boolean] Bypass cache and rebuild
        # @return [Hash, nil] The record attributes or nil
        def find(model_class, id, force: false)
          cache_key = record_cache_key(model_class, id)

          if force
            result = build_from_events(model_class, id)
            cache_write(cache_key, result) if result
            result
          else
            cache_fetch(cache_key) do
              build_from_events(model_class, id)
            end
          end
        end

        # Find a record by attributes (cached)
        #
        # @param model_class [Class] The ActiveRecord model class
        # @param attributes [Hash] The attributes to match
        # @return [Hash, nil] The first matching record attributes or nil
        def find_by(model_class, attributes)
          # Optimization: if looking up by :id only, use the fast find() path
          # which uses single-stream lookup instead of scanning all events
          if attributes.size == 1 && (attributes.key?(:id) || attributes.key?("id"))
            id = attributes[:id] || attributes["id"]
            return find(model_class, id)
          end

          cache_key = query_cache_key(model_class, :find_by, attributes)

          cache_fetch(cache_key, expires_in: 5.minutes) do
            build_find_by_from_events(model_class, attributes)
          end
        end

        # Get all records (cached, use with caution on large datasets)
        #
        # @param model_class [Class] The ActiveRecord model class
        # @return [Array<Hash>] All record attributes
        def all(model_class)
          cache_key = collection_cache_key(model_class, :all)

          cache_fetch(cache_key, expires_in: 5.minutes) do
            build_all_from_events(model_class)
          end
        end

        # Query records with conditions (cached)
        #
        # @param model_class [Class] The ActiveRecord model class
        # @param conditions [Hash] Query conditions
        # @return [Array<Hash>] Matching record attributes
        def where(model_class, conditions)
          cache_key = query_cache_key(model_class, :where, conditions)

          cache_fetch(cache_key, expires_in: 5.minutes) do
            build_where_from_events(model_class, conditions)
          end
        end

        # Count records (cached)
        #
        # @param model_class [Class] The ActiveRecord model class
        # @param conditions [Hash] Optional conditions
        # @return [Integer] Count of matching records
        def count(model_class, conditions = {})
          if conditions.empty?
            cache_key = collection_cache_key(model_class, :count)
          else
            cache_key = query_cache_key(model_class, :count, conditions)
          end

          cache_fetch(cache_key, expires_in: 1.minute) do
            build_count_from_events(model_class, conditions)
          end
        end

        # Check if a record exists (cached)
        #
        # @param model_class [Class] The ActiveRecord model class
        # @param id [Integer, String] The record ID
        # @return [Boolean] True if record exists and not destroyed
        def exists?(model_class, id)
          # Use find - if it returns data, it exists
          find(model_class, id).present?
        end

        # Invalidate cache for a specific record
        #
        # @param model_class [Class] The ActiveRecord model class
        # @param id [Integer, String] The record ID
        def invalidate(model_class, id)
          # Invalidate individual record cache
          cache_delete(record_cache_key(model_class, id))

          # Invalidate collection caches (they may contain this record)
          invalidate_collection_caches(model_class)
        end

        # Invalidate all caches for a model class
        #
        # @param model_class [Class] The ActiveRecord model class
        def invalidate_all(model_class)
          # Use cache key prefix deletion if available
          prefix = "#{cache_namespace}/#{model_class.name}/"

          if cache_store.respond_to?(:delete_matched)
            cache_store.delete_matched("#{prefix}*")
          else
            # Fallback: invalidate known collection keys
            invalidate_collection_caches(model_class)
          end
        end

        # Warm the cache for a record (call after event is stored)
        #
        # Also invalidates collection caches (all, count) to ensure
        # accurate counts after creates/updates.
        #
        # @param model_class [Class] The ActiveRecord model class
        # @param id [Integer, String] The record ID
        def warm(model_class, id)
          # Rebuild the individual record cache
          find(model_class, id, force: true)

          # Invalidate collection caches so count/all queries are rebuilt
          # This ensures assert_difference "Model.count" works correctly
          invalidate_collection_caches(model_class)
        end

        private

        # Build record state from events
        def build_from_events(model_class, id)
          stream_name = "#{model_class.name}$#{id}"
          events = load_events(stream_name)

          return nil if events.empty?
          return nil if events.last.event_type.end_with?("Destroyed")

          reconstruct_state(model_class, id, events)
        end

        # Build find_by result from events
        def build_find_by_from_events(model_class, attributes)
          # Get all records and filter
          all_records = build_all_from_events(model_class)

          all_records.find do |record|
            attributes.all? do |key, value|
              record[key.to_s] == value || record[key.to_sym] == value
            end
          end
        end

        # Build all records from events
        def build_all_from_events(model_class)
          stream_prefix = "#{model_class.name}$"
          streams = find_streams_with_prefix(stream_prefix)

          streams.filter_map do |stream_name|
            id = stream_name.sub(stream_prefix, "")
            build_from_events(model_class, id)
          end
        end

        # Build where result from events
        def build_where_from_events(model_class, conditions)
          all_records = build_all_from_events(model_class)

          all_records.select do |record|
            conditions.all? do |key, value|
              record_value = record[key.to_s] || record[key.to_sym]

              case value
              when Array
                value.include?(record_value)
              when Range
                value.cover?(record_value)
              else
                record_value == value
              end
            end
          end
        end

        # Build count from events
        def build_count_from_events(model_class, conditions)
          if conditions.empty?
            build_all_from_events(model_class).size
          else
            build_where_from_events(model_class, conditions).size
          end
        end

        # Reconstruct record state from events
        def reconstruct_state(model_class, id, events)
          attributes = { "id" => id }

          events.each do |event|
            case event.event_type
            when /Created$/
              event_attrs = event.data[:attributes] || event.data["attributes"] || {}
              attributes.merge!(stringify_keys(event_attrs))
            when /Updated$/
              changes = event.data[:changes] || event.data["changes"] || {}
              changes.each do |field, change|
                new_value = change.is_a?(Array) ? change.last : change
                attributes[field.to_s] = new_value
              end
            end
          end

          # Convert id to integer if needed
          attributes["id"] = id.to_i if id.to_s =~ /^\d+$/
          attributes
        end

        # Load events from stream
        def load_events(stream_name)
          Lyra.config.event_store.read.stream(stream_name).to_a
        rescue RubyEventStore::StreamNotFound
          []
        end

        # Find all streams matching prefix
        def find_streams_with_prefix(prefix)
          # Query event store for streams
          ActiveRecord::Base.connection.select_values(
            "SELECT DISTINCT stream FROM event_store_events_in_streams WHERE stream LIKE '#{prefix}%'"
          )
        rescue StandardError => e
          Rails.logger.warn("Lyra::CachedProjection: Stream enumeration failed - #{e.message}")
          []
        end

        # Cache key helpers
        def record_cache_key(model_class, id)
          "#{cache_namespace}/#{model_class.name}/records/#{id}/v#{CACHE_VERSION}"
        end

        def collection_cache_key(model_class, operation)
          "#{cache_namespace}/#{model_class.name}/collections/#{operation}/v#{CACHE_VERSION}"
        end

        def query_cache_key(model_class, operation, params)
          fingerprint = Digest::SHA256.hexdigest(params.to_json)[0..15]
          "#{cache_namespace}/#{model_class.name}/queries/#{operation}/#{fingerprint}/v#{CACHE_VERSION}"
        end

        def cache_namespace
          "lyra_projections"
        end

        # Cache operations (uses Rails.cache which can be Solid Cache)
        def cache_store
          Rails.cache
        end

        def cache_fetch(key, expires_in: DEFAULT_EXPIRES_IN, &block)
          cache_store.fetch(key, expires_in: expires_in, &block)
        end

        def cache_write(key, value, expires_in: DEFAULT_EXPIRES_IN)
          cache_store.write(key, value, expires_in: expires_in)
        end

        def cache_read(key)
          cache_store.read(key)
        end

        def cache_delete(key)
          cache_store.delete(key)
        end

        def invalidate_collection_caches(model_class)
          # Invalidate known collection operations
          [:all, :count].each do |op|
            cache_delete(collection_cache_key(model_class, op))
          end

          # Note: Query caches (where, find_by) expire quickly (5 min)
          # so we don't need to explicitly invalidate them
        end

        def stringify_keys(hash)
          hash.transform_keys(&:to_s)
        end
      end
    end
  end
end
