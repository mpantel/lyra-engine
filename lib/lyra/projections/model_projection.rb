# frozen_string_literal: true

module Lyra
  module Projections
    # A projected create met, in a unique index, the row of a record whose
    # stream no longer holds the value (destroyed, or moved to another): the
    # row waits for that record's projection (ES-Async: its job). Projecting
    # again later converges; AsyncProjectionJob retries it with no limit on
    # the attempts (ModelProjection.refuse_skipped_create!).
    class ProjectionBehind < ActiveRecord::RecordNotUnique; end

    # A projected create met, in a unique index, the row of a live record
    # whose stream holds the value too: two records of the log hold one
    # value (written under REPEATABLE READ or SERIALIZABLE, or before 1.0.0),
    # which no projection can hold. Logged once per record and process; not
    # retried (ModelProjection.refuse_skipped_create!).
    class DuplicateInLog < ActiveRecord::RecordNotUnique; end

    # Synchronous projection handler for updating model tables from events.
    #
    # In event_sourcing mode, this class is responsible for keeping the model
    # (read model) tables in sync with the event store. It uses raw SQL operations
    # (insert, update_all, delete_all) to avoid triggering ActiveRecord callbacks
    # or PaperTrail versioning.
    #
    # Usage:
    #   ModelProjection.project(Registration, :create, result)
    #   ModelProjection.project(Registration, :update, result)
    #   ModelProjection.project(Registration, :destroy, result)
    #
    class ModelProjection
      class << self
        # Project a command result to the model table
        #
        # @param model_class [Class] The ActiveRecord model class
        # @param operation [Symbol] :create, :update, or :destroy
        # @param result [CommandResult] The result from CommandHandler
        # Writes the table with no event, so only Lyra calls it (Lyra::INTERNAL),
        # as for Lyra.projection_write; project_create, project_update and
        # project_destroy are private.
        def project(model_class, operation, result, token = nil)
          raise InternalApiError, "ModelProjection.project is for Lyra's own projections" unless token.equal?(INTERNAL)

          # Projection writes the table, so it must address the table. With
          # projection_mode :disabled (ES-NoProj), the model's where/all answer
          # from the event store instead; update and destroy below go through
          # model_class.where(...), and would then act on event-store records
          # rather than rows. A record destroyed in the log is absent from
          # those, so its row was never deleted. Rebuild and AsyncProjectionJob
          # both project through here, whatever the projection mode.
          previous = Thread.current[:lyra_bypass_read_override]
          Thread.current[:lyra_bypass_read_override] = true
          Lyra::PurposeBoundReads.internal(INTERNAL) do
            case operation
            when :create
              project_create(model_class, result)
            when :update
              project_update(model_class, result)
            when :destroy
              project_destroy(model_class, result)
            else
              raise ArgumentError, "Unknown operation: #{operation}"
            end
          end
        ensure
          Thread.current[:lyra_bypass_read_override] = previous
        end

        # Insert a new record into the model table
        #
        # Uses insert() to bypass all callbacks and validations.
        # This is intentional - the event is the source of truth.
        def project_create(model_class, result)
          # Encrypted attributes arrive from the log as ciphertext; Active
          # Record encrypts what it inserts, so they are decrypted first.
          # String keys throughout: an event's attributes come from the store, or
          # from a record, with string keys, and a symbol-keyed default added
          # beside a string-keyed value overwrote it when the keys were
          # stringified (every created_at and updated_at became the projection
          # time).
          attributes = Lyra::EncryptedAttributes.open(model_class, result.attributes.dup).stringify_keys

          # Ensure we have the record's key (the primary key column, whatever
          # its name)
          raise "Cannot project create without ID" unless attributes[Lyra.key_column(model_class)]

          # No default timestamps: a create's event carries created_at and
          # updated_at like any other column (from 1.0.0), and a value made up
          # here would differ from the row's.

          # Convert to database-safe format
          insert_attrs = sanitize_attributes(model_class, attributes)

          # Use insert to bypass callbacks
          # Lyra.projection_write: skips strict access and publishes no bypass events
          #
          # ON CONFLICT DO NOTHING, so a create projected again (a replay, a
          # job after a write that projected its own row) inserts nothing.
          inserted = Lyra.projection_write(INTERNAL) { model_class.insert(insert_attrs) }
          # :key_taken when a row already holds the key: ES-Sync's own write
          # refuses it (CrudInterceptor#lyra_run_sync_projection); a replay or
          # a job projecting a create again goes on.
          refuse_skipped_create!(model_class, insert_attrs, inserted) || inserted
        end

        # A create that inserted nothing (no key returned) although no row has
        # its key (on the table, whatever the record's class now: an STI
        # record whose type changed is still its row) conflicted on another
        # unique index: a row another record holds. ON CONFLICT DO NOTHING
        # skipped it silently: a projection job that ran before the job of
        # the holder its record replaced (the holder's row busy when the
        # write checked it) completed and moved its checkpoint past the
        # create, and the log held a record the table never got. One query,
        # only when nothing was inserted; then the rows holding its values
        # are read (one query per unique index whose tuple the create gives
        # and that a NULL in it does not exempt) and their records' streams:
        #
        # - Every such row is of a record whose stream no longer holds the
        #   value (destroyed, or moved): its projection lags. ES-Async brings
        #   those rows up to date with their streams here, where nothing has
        #   to be waited for (UniqueIndexes.bring_rows_up_to_date: a holder
        #   whose own job was lost no longer blocks), and inserts again. A row
        #   still held by another transaction raises ProjectionBehind, which
        #   AsyncProjectionJob retries (BEHIND_ATTEMPTS: about a day, then
        #   reported and given up); ES-Sync's write fails with it.
        # - A live record holds the value in the log too, or a row with no
        #   stream (Monitor's table holds it), or no holder is found once the
        #   insert has been tried again (an expression index, which Lyra does
        #   not read): DuplicateInLog. No projection can hold both. Reported
        #   once per record and process (report_duplicate); raised for a job,
        #   which discards it, and for ES-Sync's write.
        #
        # In ES-Lazy's catch-up neither is raised: raising there would stop
        # every read. It is reported (once) and the catch-up goes on.
        def refuse_skipped_create!(model_class, attributes, inserted)
          key = model_class.primary_key
          return unless key.is_a?(String) && inserted.respond_to?(:rows) && inserted.rows.empty?
          return unless model_class.with_connection(&:supports_insert_returning?)

          table = model_class.base_class
          id = attributes[key]
          present = table.uncached { table.unscoped.where(key => id).exists? }
          return :key_taken if present

          holders = holder_rows(table, attributes)
          lagging = holders.any? && holders.all? { |holder, held| lagging?(table, holder, held) }
          ids = holders.map(&:first).uniq
          # ES-Async: the lagging rows brought up to date, then the insert
          # again; with no holder found, the insert again (a row gone since).
          if holders.empty? || (lagging && UniqueIndexes.bring_rows_up_to_date(table, ids.map(&:to_s)).any?)
            again = Lyra.projection_write(INTERNAL) { model_class.insert(attributes) }
            return if again.rows.any?
          end

          error = if lagging
                    ProjectionBehind.new("Lyra: the projection of #{model_class.name} #{id}'s create met the row of " \
                                         "#{table.name} #{ids.join(', ')}, which gave the value up but whose projection lags " \
                                         "(its row held by another transaction); nothing was inserted")
                  else
                    DuplicateInLog.new("Lyra: the projection of #{model_class.name} #{id}'s create met a value of a unique index " \
                                       "of #{model_class.table_name} that #{holders.empty? ? 'a row Lyra cannot match (an expression index)' : 'another live record holds in the log too'} " \
                                       "holds; nothing was inserted")
                  end
          lazy = Lyra.event_sourcing_mode? && Lyra.config.projection_mode == :lazy
          report_duplicate(table, id, error) if !lagging || lazy
          raise error unless lazy
        end

        # [[primary key, { column => value }]] of the rows that hold one of
        # +attributes+' unique values: one query per unique index (other than
        # the primary key, on columns) whose columns the create gives, a
        # tuple with a NULL left out unless the index is NULLS NOT DISTINCT
        # (it conflicts with nothing).
        def holder_rows(table, attributes)
          key = table.primary_key
          indexes = table.with_connection { |c| c.indexes(table.table_name) }.select do |index|
            index.unique && index.columns.is_a?(Array) && index.columns != [key]
          end
          indexes.flat_map do |index|
            next [] unless index.columns.all? { attributes.key?(_1) }

            distinct = !(index.respond_to?(:nulls_not_distinct) && index.nulls_not_distinct)
            next [] if distinct && index.columns.any? { attributes[_1].nil? }

            scope = table.unscoped.where(index.columns.to_h { [_1, attributes[_1]] })
            scope = scope.where(Arel.sql(index.where)) if index.where
            table.uncached { scope.pluck(key, *index.columns) }.map { |id, *values| [id, index.columns.zip(values).to_h] }
          end
        end

        # Whether the row of +id+, holding +held+, is of a record whose stream
        # no longer holds those values: destroyed, or moved to another.
        def lagging?(table, id, held)
          return true if Lyra::StreamTail.destroyed?(Lyra.stream_name(table, id))

          now = Lyra::PurposeBoundReads.internal(INTERNAL) { CachedProjection.find(table, id) }
          return false unless now # no stream: a row the log does not know, which holds the value

          reader = TypedValues::EventReader.new(table)
          held.any? { |column, value| UniqueIndexes.key(table, column, reader.read(now, column)) != UniqueIndexes.key(table, column, value) }
        end

        # How many creates report_duplicate remembers, per process.
        REPORTED_LIMIT = 10_000

        # A create the projection could not insert: logged at error level once
        # per record and process (debug after), and handed to
        # config.projection_error_handler once. The records remembered are
        # bounded (REPORTED_LIMIT): past it, they are forgotten and each is
        # reported once more.
        def report_duplicate(table, id, error)
          reported = (@reported_duplicates ||= Concurrent::Set.new)
          reported.clear if reported.size >= REPORTED_LIMIT
          first = reported.add?([table.name, id.to_s])
          logger = defined?(Rails) && Rails.logger
          if first
            logger&.error(error.message)
            Lyra.config.projection_error_handler&.call(error, nil, :create)
          else
            logger&.debug(error.message)
          end
        end

        # Update an existing record in the model table
        #
        # Uses update_all() to bypass all callbacks.
        # The model without its default scope, where it has one.
        def unscoped(model_class) = model_class.respond_to?(:unscoped) ? model_class.unscoped : model_class

        def project_update(model_class, result)
          event = result.events&.first
          return unless event

          model_id = event.data[:model_id] || event.data["model_id"]
          changes = event.data[:changes] || event.data["changes"] || {}

          return if changes.empty?

          # Extract new values from changes (changes are [old_value, new_value] tuples)
          # Use symbol keys consistently to avoid duplicate column errors
          updates = {}
          changes.each do |field, change|
            new_value = change.is_a?(Array) ? change.last : change
            updates[field.to_sym] = new_value
          end

          # updated_at is set only when the event changed it: an update that
          # left it alone (update_columns, an update_all that did not set it)
          # left it alone in the row too, so stamping the projection time here
          # made a rebuilt row differ from its events.
          updates = Lyra::EncryptedAttributes.open(model_class, updates)

          # Use update_all to bypass callbacks
          # Lyra.projection_write: skips strict access and publishes no bypass events
          # Unscoped: a row the model's default scope hides (a soft-deleted one)
          # is still the record's row (from 1.0.1).
          Lyra.projection_write(INTERNAL) { unscoped(model_class).where(Lyra.key_column(model_class) => model_id).update_all(updates) }
        end

        # Delete a record from the model table
        #
        # Uses delete_all() to bypass callbacks and dependent destroy.
        def project_destroy(model_class, result)
          event = result.events&.first
          return unless event

          model_id = event.data[:model_id] || event.data["model_id"]

          # Use delete_all to bypass callbacks
          # Lyra.projection_write: skips strict access and publishes no bypass events
          Lyra.projection_write(INTERNAL) { unscoped(model_class).where(Lyra.key_column(model_class) => model_id).delete_all }
        end

        private :project_create, :project_update, :project_destroy, :refuse_skipped_create!, :holder_rows, :lagging?, :report_duplicate

        private

        # Sanitize attributes for database insertion
        #
        # Removes attributes that don't correspond to database columns
        # and ensures proper type conversion.
        def sanitize_attributes(model_class, attributes)
          column_names = model_class.column_names.map(&:to_s)

          attributes.stringify_keys.slice(*column_names).tap do |attrs|
            # Convert any special types
            attrs.each do |key, value|
              # Handle BigDecimal/Float precision
              column = model_class.columns_hash[key]
              if column&.type == :decimal && value.is_a?(Float)
                attrs[key] = BigDecimal(value.to_s)
              end
            end
          end
        end
      end
    end
  end
end
