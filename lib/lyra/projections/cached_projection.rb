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
    # An out-of-date entry is not thrown away. When the event it is stamped
    # with is still in the record's stream, only the events after it are
    # replayed onto its attributes: the stream is append-only, so that reaches
    # the state a full replay reaches. A stamp that is no longer in the stream
    # (a write that rolled back after warming the cache) is not trusted, and
    # the whole stream is replayed. Without this, a record read after each of
    # its updates was replayed from its first event every time.
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
      MEMORY_CACHE_BYTES = 32.megabytes

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
          return of_class(model_class, entry["a"]) if fresh?(entry, version)

          attributes, built_version = build_record(model_class, id, entry)
          cache_write(key, entry_for(attributes, built_version)) if built_version
          of_class(model_class, attributes)
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
          records_at(model_class, stream_versions(model_class))
        end

        # The live records with these ids, in the order given. Like all, but
        # for a known set of streams: one query for their last events and one
        # cache read, instead of one of each per record (find). The reference
        # links read their candidates this way.
        #
        # @param model_class [Class] The ActiveRecord model class
        # @param ids [Array<Integer, String>] The record IDs
        # @return [Array<Hash>] Record attributes; destroyed or unknown ids are left out
        def find_many(model_class, ids)
          ids = ids.map(&:to_s).uniq
          return [] if ids.empty?

          versions = stream_versions_of(model_class, ids)
          records_at(model_class, ids.to_h { |id| [id, versions[id]] }.compact)
        end

        # Query records with conditions
        #
        # @param model_class [Class] The ActiveRecord model class
        # @param conditions [Hash] Query conditions
        # @return [Array<Hash>] Matching record attributes
        def where(model_class, conditions)
          candidates = ReferenceLinks.lookup(model_class, conditions) || all(model_class)
          candidates.select { |record| matches_conditions?(record, conditions) }
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
          memory_cache.delete_matched("#{cache_namespace}/#{Lyra.stream_owner_name(model_class)}/*")
          cache_store.delete_matched("#{cache_namespace}/#{Lyra.stream_owner_name(model_class)}/*")
        rescue NotImplementedError
          nil
        end

        # Rebuild a record's entry after a write, so the next read is a hit.
        #
        # @param model_class [Class] The ActiveRecord model class
        # @param id [Integer, String] The record ID
        def warm(model_class, id)
          find(model_class, id)
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
        #
        # +entry+ is the record's out-of-date cache entry, if any: when its
        # stamp is still in the stream, only the events after it are replayed
        # onto its attributes.
        def build_record(model_class, id, entry = nil)
          stream = Lyra.stream_name(model_class, id)
          incremental = build_from_entry(model_class, id, stream, entry)
          return incremental if incremental

          events = load_events(stream)
          return [nil, nil] if events.empty?

          version = events.last.event_id
          replayed = events.select { Lyra::Event.operation_of(_1) }
          return [nil, version] if replayed.empty? || Lyra::Event.operation_of(replayed.last) == :destroyed

          [reconstruct_state(model_class, id, replayed), version]
        end

        # The state reached by replaying the events after +entry+'s stamp onto
        # its attributes, as [attributes or nil, version]; nil when that cannot
        # be done exactly (no usable entry, a stamp that is no longer in the
        # stream, nothing after it), and the caller replays the whole stream.
        def build_from_entry(model_class, id, stream, entry)
          return nil unless entry.is_a?(Hash) && entry["v"] && entry["a"].is_a?(Hash)

          events = load_events_after(stream, entry["v"])
          return nil if events.nil? || events.empty?

          version = events.last.event_id
          replayed = events.select { Lyra::Event.operation_of(_1) }
          return [entry["a"], version] if replayed.empty?
          return [nil, version] if Lyra::Event.operation_of(replayed.last) == :destroyed

          [reconstruct_state(model_class, id, replayed, entry["a"]), version]
        end

        # The id of the last event in a record's stream, or nil if it has none.
        def stream_version(model_class, id)
          ActiveRecord::Base.with_connection do |connection|
            connection.select_value(
              "SELECT event_id FROM event_store_events_in_streams " \
              "WHERE stream = #{connection.quote(Lyra.stream_name(model_class, id))} ORDER BY id DESC LIMIT 1"
            )
          end
        end

        # The records whose streams' last events are +versions+ ({ id => event
        # id }): one bulk cache read, and a replay of only the streams whose
        # entry is missing or out of date.
        def records_at(model_class, versions)
          return [] if versions.empty?

          keys = versions.keys.to_h { |id| [record_cache_key(model_class, id), id] }
          cached = cache_read_multi(keys.keys)
          rebuilt = {}

          records = keys.filter_map do |key, id|
            entry = cached[key]
            next entry["a"] if fresh?(entry, versions[id])

            attributes, built_version = build_record(model_class, id, entry)
            rebuilt[key] = entry_for(attributes, built_version) if built_version
            attributes
          end

          cache_write_multi(rebuilt) if rebuilt.any?
          records.select { |attributes| of_class(model_class, attributes) }
        end

        # +attributes+ if the record belongs to +model_class+, nil otherwise.
        # A table's records share one stream prefix (Lyra.stream_name); under
        # single-table inheritance a subclass keeps those of its own type and
        # its subclasses', as ActiveRecord's type condition does.
        def of_class(model_class, attributes)
          return attributes if attributes.nil? || !sti_subclass?(model_class)

          types = [model_class, *model_class.descendants].map(&:sti_name)
          types.include?(attributes[model_class.inheritance_column].to_s) ? attributes : nil
        end

        def sti_subclass?(model_class)
          model_class.respond_to?(:base_class) && model_class.base_class != model_class
        end

        # { record id (String) => id of its stream's last event } for the
        # given ids that have a stream. One query.
        def stream_versions_of(model_class, ids)
          ActiveRecord::Base.with_connection do |connection|
            streams = ids.map { |id| connection.quote(Lyra.stream_name(model_class, id)) }.join(", ")
            rows = connection.select_rows(<<~SQL.squish)
              SELECT stream, event_id FROM event_store_events_in_streams
              WHERE id IN (SELECT MAX(id) FROM event_store_events_in_streams WHERE stream IN (#{streams}) GROUP BY stream)
            SQL
            prefix = Lyra.stream_prefix(model_class)
            rows.to_h { |stream, event_id| [stream.delete_prefix(prefix), event_id] }
          end
        end

        # { record id (String) => id of its stream's last event }, in
        # primary-key order. One query for the whole model.
        def stream_versions(model_class)
          ActiveRecord::Base.with_connection do |connection|
            prefix = Lyra.stream_prefix(model_class)
            pattern = connection.quote("#{ActiveRecord::Base.sanitize_sql_like(prefix)}%")
            rows = connection.select_rows(<<~SQL.squish)
              SELECT stream, event_id FROM event_store_events_in_streams
              WHERE id IN (SELECT MAX(id) FROM event_store_events_in_streams WHERE stream LIKE #{pattern} GROUP BY stream)
            SQL
            versions = rows.to_h { |stream, event_id| [stream.delete_prefix(prefix), event_id] }
            ordered = versions.keys.all? { _1.match?(/\A\d+\z/) } ? versions.keys.sort_by(&:to_i) : versions.keys.sort
            ordered.to_h { |id| [id, versions[id]] }
          end
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
        # +base+: the attributes the +events+ are applied onto (the state at
        # an earlier event), instead of an empty record.
        def reconstruct_state(model_class, id, events, base = nil)
          attributes = base ? base.dup : { "id" => id }

          events.each do |event|
            case Lyra::Event.operation_of(event)
            when :created, :imported
              event_attrs = event.data[:attributes] || event.data["attributes"] || {}
              attributes.merge!(stringify_keys(event_attrs))
            when :updated
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

        # The events of a stream after +event_id+; nil when that event is not
        # in the stream (a write that rolled back, a stream that was rewritten).
        def load_events_after(stream_name, event_id)
          Lyra.config.event_store.read.stream(stream_name).from(event_id).to_a
        rescue RubyEventStore::EventNotFound
          nil
        end

        # Load events from stream
        def load_events(stream_name)
          Lyra.config.event_store.read.stream(stream_name).to_a
        rescue RubyEventStore::EventNotFoundInStream
          []
        end

        def record_cache_key(model_class, id)
          "#{cache_namespace}/#{Lyra.stream_owner_name(model_class)}/records/#{id}/v#{CACHE_VERSION}"
        end

        def cache_namespace
          "lyra_projections"
        end

        # Cache operations (uses Rails.cache which can be Solid Cache)
        def cache_store
          Rails.cache
        end

        # A process-local copy in front of the shared cache. An entry is
        # stamped with its stream's last event and used only while that
        # still is the last one, so a copy that fell behind another process's
        # write is detected as an out-of-date entry is, never trusted. What it
        # saves is the shared cache's round trip (a database query when the
        # cache is Solid Cache) on every read and write of a record.
        def memory_cache
          @memory_cache ||= ActiveSupport::Cache::MemoryStore.new(size: MEMORY_CACHE_BYTES)
        end

        def cache_write(key, value, expires_in: DEFAULT_EXPIRES_IN)
          memory_cache.write(key, value, expires_in: expires_in)
          cache_store.write(key, value, expires_in: expires_in)
        end

        def cache_read(key)
          memory_cache.read(key) || begin
            entry = cache_store.read(key)
            memory_cache.write(key, entry, expires_in: DEFAULT_EXPIRES_IN) if entry
            entry
          end
        end

        def cache_read_multi(keys)
          found = memory_cache.read_multi(*keys)
          missing = keys - found.keys
          return found if missing.empty?

          fetched = cache_store.read_multi(*missing)
          memory_cache.write_multi(fetched, expires_in: DEFAULT_EXPIRES_IN) if fetched.any?
          found.merge(fetched)
        end

        def cache_write_multi(entries)
          memory_cache.write_multi(entries, expires_in: DEFAULT_EXPIRES_IN)
          cache_store.write_multi(entries, expires_in: DEFAULT_EXPIRES_IN)
        end

        def cache_delete(key)
          memory_cache.delete(key)
          cache_store.delete(key)
        end

        def stringify_keys(hash)
          hash.transform_keys(&:to_s)
        end
      end
    end
  end
end
