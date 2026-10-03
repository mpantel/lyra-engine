# frozen_string_literal: true

module Lyra
  module Projections
    # Rebuilds read-model tables from the event log.
    #
    # This is the load-bearing operation of event sourcing: because the event
    # log is the source of truth and the model tables are a derived projection,
    # the tables must be reconstructable from the log alone. Rebuild enumerates
    # every stream for a model, clears the read model, and replays each event
    # through the *same* +ModelProjection.project+ path used by live sync/async
    # projection -- so a rebuilt table is byte-for-byte what live projection
    # would have produced.
    #
    # Usage:
    #   Lyra::Projections::Rebuild.rebuild(Registration)
    #   Lyra::Projections::Rebuild.rebuild_all            # all monitored models
    #   Lyra::Projections::Rebuild.rebuild(Order, truncate: false)
    #
    # Or via rake:
    #   rake lyra:projections:rebuild MODEL=Registration
    #   rake lyra:projections:rebuild                     # all monitored models
    #
    class Rebuild
      class << self
        # Rebuild a single model's read-model table from its event streams.
        #
        # @param model_class [Class] the ActiveRecord model to rebuild
        # @param truncate [Boolean] clear the table before replaying (default true);
        #   set false to reconstruct only the streamed rows in place
        # @return [Hash] statistics for the rebuild
        def rebuild(model_class, truncate: true)
          stats = {
            model: model_class.name,
            streams: 0, events: 0, records: 0, destroyed: 0
          }
          rebuilt_ids = []

          model_class.transaction do
            clear_read_model(model_class) if truncate

            stream_ids_for(model_class).each do |id|
              stats[:streams] += 1
              rebuilt_ids << id
              replayed, present = replay_stream(model_class, id)
              stats[:events] += replayed
              present ? stats[:records] += 1 : stats[:destroyed] += 1
            end
          end

          invalidate_caches(model_class, rebuilt_ids)
          stats
        end

        # Rebuild every monitored model (or an explicit list).
        #
        # @param models [Array<Class>] models to rebuild (defaults to all monitored)
        # @param truncate [Boolean] clear each table before replaying
        # @return [Array<Hash>] per-model statistics
        def rebuild_all(models = Lyra.config.monitored_models, truncate: true)
          models.map { |model_class| rebuild(model_class, truncate: truncate) }
        end

        # Bring one record's row to the state its whole stream implies, in
        # place (no delete first, so rows that others reference by foreign key
        # stay put). Projection is idempotent per event: create is an insert
        # that ignores an existing row, each update re-applies its changes,
        # destroy deletes. Replaying the full stream in order therefore always
        # ends at the latest event, however stale the row was.
        #
        # Used by AsyncProjectionJob, under a per-stream lock, so that jobs
        # finishing out of order still converge.
        #
        # @return [Integer] events replayed
        def replay_record(model_class, id)
          replay_stream(model_class, id).first
        end

        private

        # Replay a single stream (one record's lifecycle) through the live
        # projector, in append order. Returns [events_replayed, still_present?].
        def replay_stream(model_class, id)
          stream_name = "#{model_class.name}$#{id}"
          events = Lyra.config.event_store.read.stream(stream_name).to_a
          replayed = 0

          events.each do |event|
            operation = operation_for(event)
            next unless operation

            ModelProjection.project(model_class, operation, build_result_from_event(event))
            replayed += 1
          end

          last = events.reverse_each.find { Lyra::Event.operation_of(_1) }
          present = !(last && Lyra::Event.operation_of(last) == :destroyed)
          [replayed, present]
        end

        # The projection operation for an event (Lyra::Event.operation_of);
        # events that are not replayed are skipped.
        def operation_for(event)
          case Lyra::Event.operation_of(event)
          when :created, :imported then :create
          when :updated then :update
          when :destroyed then :destroy
          end
        end

        # Reconstruct the CommandResult-like struct ModelProjection expects.
        # AsyncProjectionJob projects through replay_record, so rebuild and live
        # async projection share this one code path.
        def build_result_from_event(event)
          Struct.new(:events, :attributes, :success?, keyword_init: true).new(
            events: [event],
            attributes: event.data[:attributes] || event.data["attributes"] || {},
            success?: true
          )
        end

        # Enumerate the record ids that have an event stream for this model.
        def stream_ids_for(model_class)
          prefix = "#{model_class.name}$"
          sql = ActiveRecord::Base.sanitize_sql_array(
            ["SELECT DISTINCT stream FROM event_store_events_in_streams WHERE stream LIKE ?", "#{prefix}%"]
          )
          ActiveRecord::Base.connection.select_values(sql).map { |stream| stream.sub(prefix, "") }
        end

        # Clear the read-model table, bypassing callbacks/strict-access guards
        # (this is a legitimate bulk projection operation, like ModelProjection).
        def clear_read_model(model_class)
          Lyra.projection_write { model_class.unscoped.delete_all }
        end

        # Drop any cached (ES-NoProj) reconstructions so reads reflect the rebuild.
        #
        # Invalidates the specific rebuilt record ids individually (store-agnostic
        # +cache_delete+) rather than a wildcard sweep -- SolidCache, the default
        # backend, advertises +delete_matched+ but raises NotImplementedError.
        def invalidate_caches(model_class, ids)
          return unless defined?(CachedProjection)

          ids.each { |id| CachedProjection.invalidate(model_class, id) }
        rescue StandardError, NotImplementedError => e
          Rails.logger.warn("Lyra::Projections::Rebuild: cache invalidation failed - #{e.message}") if defined?(Rails)
        end
      end
    end
  end
end
