# frozen_string_literal: true

module Lyra
  module Projections
    # Cached projection layer using Solid Cache (or any Rails.cache backend).
    #
    # In disabled projection mode (ES-NoProj) the event streams are the only
    # source of truth, and a record is rebuilt by replaying its stream. This
    # class caches those rebuilds, one entry per record.
    #
    # Each entry is stamped with the id of the last event it was built from,
    # and is used only while that is still its stream's last event. Streams
    # are append-only and event ids are never reused, so a stamped entry is
    # either exactly right or detectably out of date, whatever happens around
    # it: a write in another process, a transaction that rolls back after
    # warming the cache, two readers racing to fill the same key. Nothing has
    # to be invalidated for reads to be correct; invalidation only saves a
    # rebuild.
    #
    # Collections (all, where, find_by on non-key attributes, count) are
    # assembled from those entries: one query for the last event of every
    # stream of the model, one bulk cache read, and a replay of only the
    # streams whose entry is missing or out of date.
    #
    # This replaced collection caches that every write threw away. After any
    # write the next collection read replayed every stream of the model, so a
    # dependent: :nullify delete, which must find the children by attribute,
    # rebuilt every Registration stream (1.7-3.5 s per delete in the Aegean
    # smoke runs). The where/find_by results were also cached for five minutes
    # and never invalidated, so they could answer with records a write had
    # already changed.
    #
    # Usage:
    #   CachedProjection.find(User, 123)
    #   CachedProjection.where(User, status: "active")
    #   CachedProjection.invalidate(User, 123)
    #
    class CachedProjection
      # 2: entries are { "v" => last event id, "a" => attributes or nil }.
      CACHE_VERSION = 2
      DEFAULT_EXPIRES_IN = 1.hour

      class << self
        # Find a single record by ID
        #
        # @param model_class [Class] The ActiveRecord model class
        # @param id [Integer, String] The record ID
        # @param force [Boolean] Ignore a cached entry and rebuild
        # @return [Hash, nil] The record attributes or nil
        def find(model_class, id, force: false)
          version = stream_version(model_class, id)
          return nil unless version

          key = record_cache_key(model_class, id)
          entry = cache_read(key) unless force
          return entry["a"] if fresh?(entry, version)

          attributes, built_version = build_record(model_class, id)
          cache_write(key, entry_for(attributes, built_version)) if built_version
          attributes
        end

        # Find a record by attributes
        #
        # @param model_class [Class] The ActiveRecord model class
        # @param attributes [Hash] The attributes to match
        # @return [Hash, nil] The first matching record attributes or nil
        def find_by(model_class, attributes)
          primary_key = model_class.primary_key.to_s
          id = attributes[primary_key.to_sym] || attributes[primary_key]

          # A lookup that pins the primary key names exactly one stream, so it
          # is answered by that stream alone. The remaining conditions are
          # checked against the record it produced. The primary key itself is
          # not re-checked: it is satisfied by construction, and comparing it
          # again would reintroduce the type mismatch that makes
          # find_by(id: "5") differ from find_by(id: 5).
          if id
            record = find(model_class, id)
            return nil unless record

            rest = attributes.reject { |key, _| key.to_s == primary_key }
            return record if rest.empty?

            return matches_attributes?(record, rest) ? record : nil
          end

          # Without a primary key there is no way to know which stream holds
          # the answer, so every record of the model is considered. That cost
          # is inherent to querying by a non-key attribute with projections
          # disabled; the entries keep it to one bulk read once warm.
          all(model_class).find { |record| matches_attributes?(record, attributes) }
        end

        # Every live record of the model, in primary-key order
        #
        # @param model_class [Class] The ActiveRecord model class
        # @return [Array<Hash>] All record attributes
        def all(model_class)
          versions = stream_versions(model_class)
          return [] if versions.empty?

          keys = versions.keys.to_h { |id| [record_cache_key(model_class, id), id] }
          cached = cache_store.read_multi(*keys.keys)
          rebuilt = {}

          records = keys.filter_map do |key, id|
            entry = cached[key]
            next entry["a"] if fresh?(entry, versions[id])

            attributes, built_version = build_record(model_class, id)
            rebuilt[key] = entry_for(attributes, built_version) if built_version
            attributes
          end

          cache_store.write_multi(rebuilt, expires_in: DEFAULT_EXPIRES_IN) if rebuilt.any?
          records
        end

        # Query records with conditions
        #
        # @param model_class [Class] The ActiveRecord model class
        # @param conditions [Hash] Query conditions
        # @return [Array<Hash>] Matching record attributes
        def where(model_class, conditions)
          all(model_class).select { |record| matches_conditions?(record, conditions) }
        end

        # Count records
        #
        # @param model_class [Class] The ActiveRecord model class
        # @param conditions [Hash] Optional conditions
        # @return [Integer] Count of matching records
        def count(model_class, conditions = {})
          conditions.empty? ? all(model_class).size : where(model_class, conditions).size
        end

        # Check if a record exists
        #
        # @param model_class [Class] The ActiveRecord model class
        # @param id [Integer, String] The record ID
        # @return [Boolean] True if record exists and not destroyed
        def exists?(model_class, id)
          find(model_class, id).present?
        end

        # Drop a record's entry. Not needed for correctness (a stale entry is
        # never used); it only spares the next read a comparison.
        #
        # @param model_class [Class] The ActiveRecord model class
        # @param id [Integer, String] The record ID
        def invalidate(model_class, id)
          cache_delete(record_cache_key(model_class, id))
        end

        # Drop every entry of a model where the store can delete by prefix.
        #
        # Stores that cannot (Solid Cache, MemCacheStore) raise
        # NotImplementedError from delete_matched; their entries are left to
        # expire, which is safe because an out-of-date entry is never used.
        #
        # @param model_class [Class] The ActiveRecord model class
        def invalidate_all(model_class)
          cache_store.delete_matched("#{cache_namespace}/#{model_class.name}/*")
        rescue NotImplementedError
          nil
        end

        # Rebuild a record's entry after a write, so the next read is a hit.
        #
        # @param model_class [Class] The ActiveRecord model class
        # @param id [Integer, String] The record ID
        def warm(model_class, id)
          find(model_class, id, force: true)
        end

        private

        def fresh?(entry, version)
          entry.is_a?(Hash) && entry.key?("v") && entry["v"] == version
        end

        def entry_for(attributes, version)
          { "v" => version, "a" => attributes }
        end

        # [attributes or nil (destroyed), id of the last event replayed or
        # nil (no stream)]
        def build_record(model_class, id)
          events = load_events("#{model_class.name}$#{id}")
          return [nil, nil] if events.empty?

          version = events.last.event_id
          return [nil, version] if events.last.event_type.end_with?("Destroyed")

          [reconstruct_state(model_class, id, events), version]
        end

        # The id of the last event in a record's stream, or nil if it has none.
        def stream_version(model_class, id)
          connection = ActiveRecord::Base.connection
          connection.select_value(
            "SELECT event_id FROM event_store_events_in_streams " \
            "WHERE stream = #{connection.quote("#{model_class.name}$#{id}")} ORDER BY id DESC LIMIT 1"
          )
        end

        # { record id (String) => id of its stream's last event }, in
        # primary-key order. One query for the whole model.
        def stream_versions(model_class)
          connection = ActiveRecord::Base.connection
          prefix = "#{model_class.name}$"
          pattern = connection.quote("#{ActiveRecord::Base.sanitize_sql_like(prefix)}%")
          rows = connection.select_rows(<<~SQL.squish)
            SELECT stream, event_id FROM event_store_events_in_streams
            WHERE id IN (SELECT MAX(id) FROM event_store_events_in_streams WHERE stream LIKE #{pattern} GROUP BY stream)
          SQL
          versions = rows.to_h { |stream, event_id| [stream.delete_prefix(prefix), event_id] }
          ordered = versions.keys.all? { _1.match?(/\A\d+\z/) } ? versions.keys.sort_by(&:to_i) : versions.keys.sort
          ordered.to_h { |id| [id, versions[id]] }
        end

        # Shared by find_by and where so both decide a match the same way.
        def matches_attributes?(record, attributes)
          attributes.all? do |key, value|
            record[key.to_s] == value || record[key.to_sym] == value
          end
        end

        def matches_conditions?(record, conditions)
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

        # Reconstruct record state from events
        def reconstruct_state(model_class, id, events)
          attributes = { "id" => id }

          events.each do |event|
            case event.event_type
            when /Created$/, /Imported$/
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
        rescue RubyEventStore::EventNotFoundInStream
          []
        end

        def record_cache_key(model_class, id)
          "#{cache_namespace}/#{model_class.name}/records/#{id}/v#{CACHE_VERSION}"
        end

        def cache_namespace
          "lyra_projections"
        end

        # Cache operations (uses Rails.cache which can be Solid Cache)
        def cache_store
          Rails.cache
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

        def stringify_keys(hash)
          hash.transform_keys(&:to_s)
        end
      end
    end
  end
end
