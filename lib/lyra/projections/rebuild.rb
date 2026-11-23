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
    # Clearing the table (truncate: true, the default) deletes every row
    # before the replay, and the database applies each foreign key's ON
    # DELETE action to the rows that reference them. From 1.0.1 a rebuild
    # refuses to clear a table while that would lose what the log cannot
    # restore (clear_hazards): rows of another table that reference it
    # through a foreign key that cascades, sets null or sets a default (the
    # model's own HABTM join tables excepted, restored from their link
    # events), and rows of the table itself that have no event stream.
    # force: true clears it anyway; truncate: false replays in place and
    # deletes only the rows whose records the log destroys.
    class Rebuild
      # A rebuild that would undo what the log does not record
      # (config.record_touches false), or clear a table whose rows the log
      # cannot all restore (clear_hazards).
      class Refused < StandardError; end

      # Rows of another table that a foreign key's ON DELETE action reaches
      # when the table is cleared.
      Reference = Struct.new(:from_table, :columns, :action, :name, :rows, :monitored_by, keyword_init: true) do
        def to_s
          by = monitored_by ? "monitored by #{monitored_by}, restored only by its own rebuild after this one" : "unmonitored"
          "#{rows} row#{'s' unless rows == 1} of #{from_table} (#{by}; #{from_table}.#{columns} ON DELETE #{action}, " \
            "constraint #{name})"
        end
      end

      ACTIONS = { "c" => "CASCADE", "n" => "SET NULL", "d" => "SET DEFAULT" }.freeze
      # Streamless row ids named in a refusal.
      LISTED = 5

      class << self
        # Rebuild a single model's read-model table from its event streams.
        #
        # @param model_class [Class] the ActiveRecord model to rebuild
        # @param truncate [Boolean] clear the table before replaying (default true);
        #   set false to reconstruct only the streamed rows in place
        # @param force [Boolean] clear the table even where that loses rows the
        #   log cannot restore (clear_hazards); without it such a rebuild is
        #   refused (Refused) before anything is written
        # @return [Hash] statistics for the rebuild
        def rebuild(model_class, truncate: true, force: false)
          # With touches left out of the log, the rows' updated_at is newer
          # than the events say, and a rebuild would set every touched row back.
          if Lyra.config.record_touches == false
            raise Lyra::Projections::Rebuild::Refused,
                  "Lyra refuses to rebuild #{model_class.name} from its events: config.record_touches is false, so " \
                  "the log misses touches and the rebuild would set each touched row's updated_at back. Set " \
                  "config.record_touches = true and run lyra:repair first."
          end
          live = Lyra::TouchRegistry.live_processes
          if live.any?
            raise Lyra::Projections::Rebuild::Refused,
                  "Lyra refuses to rebuild #{model_class.name} from its events: processes leave touches out of the " \
                  "log (config.record_touches = false): #{Lyra::TouchRegistry.describe(live)}. The rebuild would set " \
                  "each touched row's updated_at back. #{Lyra::TouchRegistry::STEPS}"
          end

          stats = {
            model: model_class.name,
            streams: 0, events: 0, records: 0, destroyed: 0
          }
          rebuilt_ids = []

          Lyra::PurposeBoundReads.internal(INTERNAL) do
            rebuild_in_transaction(model_class, truncate, stats, rebuilt_ids, force: force)
          end
        end

        def rebuild_in_transaction(model_class, truncate, stats, rebuilt_ids, force: false)
          model_class.transaction do
            if truncate
              refuse_clear_hazards!(model_class) unless force
              Lyra::Associations::HabtmLinks.clear(model_class)
              clear_read_model(model_class)
            end

            stream_ids_for(model_class).each do |id|
              stats[:streams] += 1
              rebuilt_ids << id
              replayed, present = replay_stream(model_class, id)
              stats[:events] += replayed
              present ? stats[:records] += 1 : stats[:destroyed] += 1
            end

            # has_and_belongs_to_many join tables, from the link events.
            links = Lyra::Associations::HabtmLinks.rebuild(model_class)
            stats[:links] = links if links.positive?
          end

          invalidate_caches(model_class, rebuilt_ids)
          stats
        end

        # Rebuild every monitored model (or an explicit list).
        #
        # @param models [Array<Class>] models to rebuild (defaults to all monitored)
        # @param truncate [Boolean] clear each table before replaying
        # @param force [Boolean] clear each table even where rows would be lost (rebuild)
        # @return [Array<Hash>] per-model statistics
        def rebuild_all(models = Lyra.config.monitored_models, truncate: true, force: false)
          models.map { |model_class| rebuild(model_class, truncate: truncate, force: force) }
        end

        # What clearing +model_class+'s table would lose that its replay does
        # not restore: { references: [Reference], streamless: count,
        # streamless_ids: [the first LISTED] }.
        # - references: the foreign keys into the table from another one whose
        #   ON DELETE action is CASCADE, SET NULL or SET DEFAULT, with the rows
        #   they reach (all that reference a row). A monitored table's too: a
        #   rebuild restores one model's table, and a table rebuilt earlier
        #   would lose its rows again. Left out: the model's own HABTM join
        #   tables, which Rebuild restores from their link events, and a
        #   foreign key from the table into itself, whose rows are all
        #   deleted and replayed anyway.
        # - streamless: rows of the table with no stream, not yet imported
        #   (Lyra::Genesis). A row whose stream ends in a destroy is not one:
        #   deleting it is what the log says.
        def clear_hazards(model_class)
          # The table itself, also where ES-NoProj answers reads from events.
          previous = Thread.current[:lyra_bypass_read_override]
          Thread.current[:lyra_bypass_read_override] = true
          Lyra::PurposeBoundReads.internal(INTERNAL) do
            model_class.connection_pool.with_connection do |connection|
              relation = streamless_rows(model_class, connection)
              { references: references_into(model_class, connection),
                streamless: relation.count,
                streamless_ids: relation.order(model_class.primary_key).limit(LISTED).pluck(model_class.primary_key) }
            end
          end
        ensure
          Thread.current[:lyra_bypass_read_override] = previous
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

        # Project +events+ (of one record's stream, in append order) through
        # the live projector. Returns how many were projected. Projecting an
        # event the row already reflects is harmless: a create of an existing
        # row inserts nothing and an update sets the same values, so callers
        # may start from an earlier event than strictly needed.
        # Projects the events it is given, whether or not they are in the log,
        # so only Lyra calls it (Lyra::INTERNAL).
        def project_events(model_class, events, token = nil)
          raise InternalApiError, "Rebuild.project_events is for Lyra's own projections" unless token.equal?(INTERNAL)

          events.count do |event|
            operation = operation_for(event)
            next false unless operation

            ModelProjection.project(model_class, operation, build_result_from_event(event), INTERNAL)
            true
          end
        end

        private

        # Replay a single stream (one record's lifecycle) through the live
        # projector, in append order. Returns [events_replayed, still_present?].
        def replay_stream(model_class, id)
          stream_name = Lyra.stream_name(model_class, id)
          events = Lyra.config.event_store.read.stream(stream_name).to_a
          replayed = project_events(model_class, events, INTERNAL)

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
            attributes: if %i[created imported].include?(Lyra::Event.operation_of(event))
                          Lyra::Event.created_attributes(event.data)
                        else
                          event.data[:attributes] || event.data["attributes"] || {}
                        end,
            success?: true
          )
        end

        # Enumerate the record ids that have an event stream for this model.
        def stream_ids_for(model_class)
          prefix = Lyra.stream_prefix(model_class)
          sql = ActiveRecord::Base.sanitize_sql_array(
            ["SELECT DISTINCT stream FROM event_store_events_in_streams WHERE stream LIKE ?", "#{prefix}%"]
          )
          ActiveRecord::Base.with_connection { |c| c.select_values(sql) }.map { |stream| stream.sub(prefix, "") }
        end

        def refuse_clear_hazards!(model_class)
          hazards = clear_hazards(model_class)
          return if hazards[:references].empty? && hazards[:streamless].zero?

          table = model_class.table_name
          lost = hazards[:references].map(&:to_s)
          if (count = hazards[:streamless]).positive?
            ids = hazards[:streamless_ids].map(&:to_s).join(", ")
            ids += ", ..." if count > hazards[:streamless_ids].size
            lost << "#{count} row#{'s' unless count == 1} of #{table} with no event stream " \
                    "(#{model_class.primary_key} #{ids}; Lyra::Genesis imports them, rake lyra:genesis)"
          end
          raise Refused,
                "Lyra refuses to clear #{table} to rebuild #{model_class.name} from its events: deleting its rows " \
                "would delete or change what the log cannot restore: #{lost.join('; ')}. Back up the database, then " \
                "rebuild in place (truncate: false; rake TRUNCATE=false), which deletes only the rows whose records " \
                "the log destroys, or clear the table anyway (force: true; rake FORCE=1)."
        end

        # The rows of +model_class+'s table that have no event stream, as a
        # relation: rows clear_read_model deletes and no replay restores.
        def streamless_rows(model_class, connection)
          key = "#{connection.quote_table_name(model_class.table_name)}.#{connection.quote_column_name(model_class.primary_key)}"
          model_class.unscoped.where(
            "NOT EXISTS (SELECT 1 FROM event_store_events_in_streams lyra_s WHERE lyra_s.stream = " \
            "#{connection.quote(Lyra.stream_prefix(model_class))} || CAST(#{key} AS text))"
          )
        end

        # Foreign keys from other tables into +model_class+'s table whose ON
        # DELETE action deletes or rewrites the rows that reference it, each
        # with the rows that reference a row: once the table is cleared, every
        # one of them. From PostgreSQL's catalog (pg_constraint, which also
        # names SET DEFAULT; connection.foreign_keys does not); on other
        # adapters from connection.foreign_keys.
        def references_into(model_class, connection)
          return [] unless connection.supports_foreign_keys?

          own = Lyra::Associations::HabtmLinks.join_tables(model_class).map { unqualified(_1) }
          keys = if connection.adapter_name.match?(/postg/i)
                   pg_references(model_class, connection)
                 else
                   generic_references(model_class, connection)
                 end
          keys.filter_map do |fk|
            next if own.include?(unqualified(fk[:from_table]))

            condition = fk[:columns].map { "#{connection.quote_column_name(_1)} IS NOT NULL" }.join(" AND ")
            rows = connection.select_value("SELECT count(*) FROM #{fk[:sql_table]} WHERE #{condition}").to_i
            next if rows.zero?

            Reference.new(from_table: fk[:from_table], columns: fk[:columns].join(", "), action: fk[:action],
                          name: fk[:name], rows: rows, monitored_by: monitored_model_of(fk[:from_table]))
          end
        end

        def pg_references(model_class, connection)
          connection.select_all(<<~SQL).map do |row|
            SELECT c.conname AS name, c.conrelid::regclass::text AS from_table, c.confdeltype AS action,
                   (SELECT string_agg(a.attname, ',' ORDER BY array_position(c.conkey, a.attnum))
                      FROM pg_attribute a WHERE a.attrelid = c.conrelid AND a.attnum = ANY (c.conkey)) AS columns
            FROM pg_constraint c
            WHERE c.contype = 'f' AND c.conparentid = 0
              AND c.confrelid = #{connection.quote(model_class.table_name)}::regclass
              AND c.conrelid <> c.confrelid AND c.confdeltype IN ('c', 'n', 'd')
            ORDER BY 2, 1
          SQL
            # regclass::text is the name as PostgreSQL quotes it, valid in SQL as is.
            { name: row["name"], from_table: row["from_table"], sql_table: row["from_table"],
              columns: row["columns"].split(","), action: ACTIONS.fetch(row["action"]) }
          end
        end

        def generic_references(model_class, connection)
          table = model_class.table_name.to_s
          (connection.tables - [table]).flat_map do |from|
            connection.foreign_keys(from).filter_map do |fk|
              action = { cascade: "CASCADE", nullify: "SET NULL" }[fk.on_delete]
              next unless action && unqualified(fk.to_table) == unqualified(table)

              { name: fk.name.to_s, from_table: from, sql_table: connection.quote_table_name(from),
                columns: Array(fk.column).map(&:to_s), action: action }
            end
          end
        end

        # The monitored model that writes +table+, if any.
        def monitored_model_of(table)
          Lyra.config.monitored_models.find do |model|
            model.respond_to?(:table_name) && model.table_name && unqualified(model.table_name) == unqualified(table)
          end&.name
        end

        def unqualified(table) = table.to_s.split(".").last.delete('"')

        # Clear the read-model table, bypassing callbacks/strict-access guards
        # (this is a legitimate bulk projection operation, like ModelProjection).
        def clear_read_model(model_class)
          Lyra.projection_write(INTERNAL) { model_class.unscoped.delete_all }
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
