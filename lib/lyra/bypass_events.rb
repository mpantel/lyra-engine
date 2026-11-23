# frozen_string_literal: true

module Lyra
  # Raised before a bulk write that would lock more records than
  # config.bulk_write_lock_limit: the write holds one aggregate lock per
  # record until its transaction ends, and PostgreSQL's lock table, which
  # every session shares, has room for about max_locks_per_transaction ×
  # (max_connections + background processes) locks. Past that, every
  # session's writes fail ("out of shared memory").
  class BulkWriteLockLimitError < StandardError
    attr_reader :model_class, :count, :limit

    def initialize(model_class, count, limit, write = "bulk write")
      @model_class = model_class
      @count = count
      @limit = limit
      name = model_class.respond_to?(:name) ? model_class.name : model_class.to_s
      records = count == 1 ? "record" : "records"
      locks = count == 1 ? "lock" : "locks"
      super(
        "Lyra: #{write} of #{count} #{name} #{records} would hold #{count} aggregate #{locks} until " \
        "its transaction ends, more than config.bulk_write_lock_limit (#{limit}). Write in batches " \
        "(in_batches(of: #{limit}) { |batch| batch.update_all(...) }): each batch commits, and gives its locks " \
        "back, on its own, but not inside a transaction already open, which holds them all until it ends. " \
        "Or raise the limit (nil: none), within PostgreSQL's lock table."
      )
    end
  end

  # Publishes events for writes that skip ActiveRecord callbacks
  # (update_column(s), delete, update_all, delete_all, insert_all,
  # upsert_all, dependent: :nullify), so the event stream records every state change
  # on a monitored model, not only the ones that went through the
  # interceptor.
  #
  # Lyra's own projection writes use the same bulk methods to update the
  # read model. Those run inside Lyra.projection_write and must never
  # publish: the event they project already exists.
  module BypassEvents
    class << self
      # Whether a bypass write's events must be stored for the write to
      # stand. In Hijack and the event-sourcing modes the log is the record of
      # every change (in ES-NoProj the only one), so a write whose event
      # cannot be stored must not happen: it fails, and is rolled back. In
      # Monitor the table stays authoritative and the event is a copy, so a
      # failed publish is logged and the write stands, unless
      # config.monitor_append_failure is :fail_write.
      def required?
        Lyra.config.events_required?
      end

      # Run a bypass write together with the publishing of its events: in
      # one transaction when they are required, so that a failed publish
      # rolls the write back with it.
      #
      # Under ES-Lazy the tables are brought up to date first, as before a
      # read: a write appends events only, so a record written since the last
      # read had no row yet, and update_columns, update_all or delete_all on it
      # matched nothing, recorded no event, and the change was lost. Only
      # then: the write's own reads (its snapshot, the rows it reads back for
      # the events) do not catch up again. A catch-up there waited for the
      # catch-up lock while the write held rows that a catch-up running
      # elsewhere, holding that lock, waited for: a deadlock, which bulk
      # writes and writes that skip callbacks met against catch-ups under
      # load (before 1.0.0 too). A destroy committed after the catch-up is
      # found by the stream check (checks_streams?).
      def atomically(model_class, &block)
        Lyra::Projections::LazyProjection.before_read(model_class)
        Lyra::Projections::LazyProjection.without_catch_up do
          required? || locks_rows? ? model_class.transaction(&block) : yield
        end
      end

      # Whether a bulk write locks the rows it matches and writes exactly
      # those (snapshot(lock: true), then write_snapshotted): wherever the
      # rows live in a table, so in every mode but the events-only store.
      # From 0.9.3: before, the snapshot was a plain read, and under READ
      # COMMITTED a row another transaction changed or inserted between the
      # snapshot and the write could be written without an event. A failed
      # append inside the transaction rolls back only its own savepoint, so in
      # Monitor the write still stands when its event fails.
      def locks_rows?
        !(Lyra.config.event_sourcing_mode? && Lyra.config.projection_mode == :disabled)
      end

      # Whether a write that skips callbacks must ask the record's stream
      # whether it was destroyed, under the aggregate lock, before it records
      # anything: wherever a destroy can be in the store without its row
      # being gone. In ES-NoProj there is no row (a stale copy, or a relation
      # built before the destroy, still holds the record); in ES-Async the
      # row stays until the destroy's projection job runs; in ES-Lazy until
      # the next catch-up, and one committed after the catch-up a write
      # began with is not in the table it writes. A write that reached the
      # record there appended an update after its destroy, and brought it
      # back. ES-Sync, Hijack and Monitor delete the row with the destroy.
      # With lock_aggregate_before_append off, as for a write through
      # callbacks, nothing is checked.
      def checks_streams?
        Lyra.config.lock_aggregate_before_append && Lyra.config.event_sourcing_mode? &&
          %i[disabled async lazy].include?(Lyra.config.projection_mode)
      end

      # Whether an insert_all, insert_all! or upsert_all brings the rows of the
      # keys it writes up to date with their streams first, under their
      # aggregate locks (Lyra::Projections::AsyncProjectionJob
      # .project_pending): in ES-Async, where a row waits for its projection
      # job. A record whose destroy was pending kept its row, and ON CONFLICT
      # skipped (insert_all) or updated (upsert_all) the dead record, where
      # Monitor creates it again; a record whose create was pending had no
      # row yet, and the insert logged a second Created, where Monitor's
      # conflicts. Deleting the row alone was no answer: the destroy's job,
      # run after, would delete the new row. ES-Lazy's rows are brought up to
      # date when the write begins (atomically), and its upsert_all refuses a
      # destroy committed since (StrictDataAccessRelation#lock_upserted_rows):
      # replaying a destroy onto a row there would be applied again by the
      # next catch-up, which replays from a checkpoint of its own, global, not
      # per stream, and would delete the row created again.
      def projects_pending?
        checks_streams? && Lyra.config.projection_mode == :async
      end

      # Of +ids+ (records of +model_class+), those whose streams end in a
      # destroy (Lyra::StreamTail), read under each stream's aggregate lock,
      # the one a write through callbacks takes
      # (CrudInterceptor#lyra_lock_aggregate_unless_destroyed!). The locks are
      # taken in one statement and held until the caller's transaction ends,
      # so no destroy can come between the read and the write. +write+ names
      # the write in a BulkWriteLockLimitError.
      def destroyed_ids(model_class, ids, write: "bulk write")
        ids = ids.uniq
        return [] if ids.empty?

        lock_streams!(model_class, ids, write: write)
        destroyed_among(model_class, ids)
      end

      # Of +ids+, those whose streams end in a destroy, read in one query
      # where it can be (Lyra::StreamTail.destroyed_streams); the caller holds
      # their aggregate locks.
      def destroyed_among(model_class, ids)
        return [] if ids.empty?

        streams = ids.to_h { |id| [Lyra.stream_name(model_class, id), id] }
        Lyra::StreamTail.destroyed_streams(streams.keys).map { streams[_1] }
      end

      # Run the write in the block (Active Record's own, on a record whose
      # stream says it was destroyed) and take back what it wrote to the
      # table, in a savepoint rolled back: a row still there (ES-Async, before
      # the destroy's projection job runs; ES-NoProj, one left from an
      # earlier mode) is not changed without an event. What the write set in
      # memory stays, as on a row already gone.
      def unwritten(model_class)
        model_class.transaction(requires_new: true) do
          yield
          raise ActiveRecord::Rollback
        end
        nil
      end

      # The snapshot a bulk write writes (snapshot(lock: true)): the rows it
      # matches, locked. Where the table can still hold the row of a record
      # whose stream ends in a destroy (checks_streams?: ES-Async, before the
      # destroy's projection job runs), less those rows, as Active Record's
      # write reaches no row of a destroyed record; the write then writes,
      # records and counts the others only.
      #
      # The records' aggregate locks are taken before their rows' locks, in
      # Lyra's order (Lyra::AdvisoryLock): the keys the relation matches are
      # read, their aggregate locks taken (all or none), then the rows
      # locked. A row that came to match in between, whose aggregate lock is
      # not held, sends the row locks back (a savepoint rolled back) and the
      # keys are read again, up to ROW_LOCK_TRIES times; after that such a
      # row is left out, as if it had matched after the write. In ES-Lazy,
      # once the aggregate locks are held, each record whose stream has an
      # event the tables have not had yet (one committed after the catch-up
      # the write began with: atomically) is replayed onto its row
      # (LazyProjection.refresh_records), so the write starts from the row
      # as the stream has it: an update committed in between is not lost
      # under it. The whole catch-up is not run again there: its lock is
      # taken before the aggregate locks by every writer that reads first,
      # and taking it after them deadlocked. Then the streams of the rows
      # locked are read, in one query where it can be
      # (Lyra::StreamTail.destroyed_streams). Genesis admits the rows
      # (snapshot) before the streams are read.
      def locked_snapshot(model_class, relation, write: "bulk write")
        return snapshot(model_class, relation, lock: true) unless checks_streams?

        pk = model_class.primary_key
        locked = Set.new
        ROW_LOCK_TRIES.times do |round|
          keys = Lyra::PurposeBoundReads.internal(INTERNAL) do
            model_class.unscoped.where(pk => relation.reselect(model_class.arel_table[pk])).pluck(pk)
          end
          added = keys.reject { locked.include?(_1) }
          if added.any?
            check_lock_limit!(model_class, locked.size + added.size, write)
            lock_streams!(model_class, added, write: write)
            locked.merge(added)
            # ES-Lazy: their rows as their streams have them now, under the
            # locks, before the rows are read and written.
            Lyra::Projections::LazyProjection.refresh_records(model_class, added)
          end

          before = nil
          model_class.transaction(requires_new: true) do
            rows = snapshot(model_class, relation, lock: true)
            raise ActiveRecord::Rollback if round < ROW_LOCK_TRIES - 1 && rows.each_key.any? { !locked.include?(_1) }

            before = rows
          end
          next unless before

          before = before.select { |id, _| locked.include?(id) }
          dead = destroyed_among(model_class, before.keys)
          return dead.empty? ? before : before.except(*dead)
        end
      end

      # How many times locked_snapshot reads the keys again for a row that
      # came to match while it took their aggregate locks.
      ROW_LOCK_TRIES = 3

      # Take the aggregate locks of +ids+' streams, in one statement, after
      # checking their number against config.bulk_write_lock_limit. Returns
      # the stream names, in the order of +ids+.
      def lock_streams!(model_class, ids, write: "bulk write")
        check_lock_limit!(model_class, ids.size, write)
        streams = ids.map { |id| Lyra.stream_name(model_class, id) }
        model_class.with_connection do |connection|
          Lyra::AdvisoryLock.xact_lock_all(connection, streams.map { "lyra_aggregate/#{_1}" }, purpose: "aggregate write")
        end
        streams
      end

      # Refuse a write that would hold more than config.bulk_write_lock_limit
      # aggregate locks (BulkWriteLockLimitError), before it locks or writes
      # anything.
      def check_lock_limit!(model_class, count, write = "bulk write")
        limit = Lyra.config.bulk_write_lock_limit
        return if limit.nil? || count <= limit

        raise Lyra::BulkWriteLockLimitError.new(model_class, count, limit, write)
      end

      # Run an insert_all, insert_all! or upsert_all (the block, given the
      # RETURNING to ask for) with +columns+ in its RETURNING, so the rows it
      # wrote can be told, and hand the caller the result it asked for.
      # Returns [caller_result, rows], rows as hashes of +columns+, each
      # value cast as the result types it (as Result#cast_values does).
      #
      # +returning+ as Active Record takes it: nil (the primary key, where
      # the adapter returns rows), false (nothing), column names, or raw SQL
      # (Arel.sql("code"), Arel.sql("*")). A column the caller did not ask
      # for is added (raw SQL: under an alias of Lyra's own, "lyra_returning_
      # <column>") and taken out of the caller's result again, which keeps
      # its column types (by name and by index, as Active Record's own),
      # its affected rows, and, for returning: false, is Active Record's
      # empty result. Before, it was rebuilt without the column types:
      # result.column_types came back empty and cast_values cast nothing.
      # Rows nil on an adapter with no RETURNING.
      def with_returning(model_class, returning, columns)
        # An adapter with no RETURNING (MySQL): the write as asked, and no
        # rows to tell.
        return [yield(returning), nil] unless model_class.with_connection(&:supports_insert_returning?)

        returning = default_returning(model_class) if returning.nil?
        quote = ->(name) { model_class.with_connection { |c| c.quote_column_name(name) } }
        names = columns
        case returning
        when false
          request = columns
        when Arel::Nodes::SqlLiteral
          names = columns.map { "#{RETURNING_ALIAS}#{_1}" }
          request = Arel.sql([returning, *columns.zip(names).map { |c, n| "#{quote.(c)} AS #{quote.(n)}" }].join(", "))
          added = columns.size
        else
          asked = Array(returning).map(&:to_s)
          added = (columns - asked).size
          request = added.zero? ? returning : asked + (columns - asked)
        end

        result = yield(request)
        indexes = names.map { result.columns.index(_1) }
        types = result.column_types
        rows = result.rows.map do |row|
          columns.each_with_index.to_h do |column, i|
            index = indexes[i]
            value = index && row[index]
            [column, index && types[index] ? types[index].deserialize(value) : value]
          end
        end
        [caller_result(result, returning == false ? nil : added.to_i), rows]
      end

      # The alias a column the caller's raw-SQL RETURNING did not name is
      # returned under (with_returning).
      RETURNING_ALIAS = "lyra_returning_"

      # Report a failed publish: raise when the events are required (see
      # required?), log otherwise.
      def publish_failed!(error, source)
        raise error if required?

        Rails.logger.error("Lyra: Failed to publish bypass event (#{source}) - #{error.message}")
      end

      # Whether a touch's event is left out of the log (config.record_touches
      # false, in Monitor: Configuration#skip_touches?): when every column it
      # changed is one of the model's update timestamps (updated_at,
      # updated_on). A touch that changed another column too (a named one,
      # touch(:completed_at), or lock_version) is recorded in full. Only once
      # this process's entry in the registry of processes that leave touches
      # out is live (Lyra::TouchRegistry.live!), so that every process's mode
      # gate sees it; when the entry cannot be written, the touch is recorded.
      def skip_touch?(model_class, changes)
        return false unless Lyra.config.skip_touches?
        return false if changes.empty?

        stamps = model_class.timestamp_attributes_for_update_in_model
        return false unless changes.each_key.all? { |column| stamps.include?(column.to_s) }

        Lyra::TouchRegistry.live!
      end

      # Run a touch_all, so that publish_updates can tell its rows from an
      # update_all's (Rails's touch_all is update_all of the timestamps).
      def touching_all
        previous = Thread.current[:lyra_touch_all]
        Thread.current[:lyra_touch_all] = true
        yield
      ensure
        Thread.current[:lyra_touch_all] = previous
      end

      def enabled_for?(model_class)
        return false if Thread.current[:lyra_projection_write]
        return false if Lyra.config.mode == :disabled

        model_class.respond_to?(:lyra_monitored) && model_class.lyra_monitored
      end

      def publish(model_class, id, operation, attributes:, changes: {}, source:)
        # Every path admits its rows before writing them; this catches one
        # that does not (the write is in the same transaction, and rolls back
        # with a refusal where events are required).
        admit(model_class, [id]) unless operation.to_sym == :created
        event_class = event_class_for(model_class, operation)
        metadata = current_metadata.merge(source_key(source) => source)

        data = Lyra::EventData.build(model_class, id, operation, attributes: attributes, changes: changes)
        event = event_class.new(data: data, metadata: Lyra::Privacy.stamp(model_class, data, metadata))
        begin
          Lyra.append_events(event, stream_name: Lyra.stream_name(model_class, id))
        rescue Lyra::RecordDestroyedError
          # A touch of a record whose stream ends in a destroy while its row
          # stays: a record soft-deleted under 1.0.0, which recorded a soft
          # delete as a Destroyed (from 1.0.1 it is the update it is, and its
          # stream stays live). Its row is written as plain Active Record
          # writes it, and nothing is recorded, as an update after a destroy
          # is a history Hypothesis H excludes (Lyra::StreamHeads). Monitor
          # records it, as it records what its table did.
          raise unless source.to_s == "touch"

          return nil
        end

        # With projections disabled, reads come from the cached event-stream
        # reconstruction, which would otherwise keep serving the old state.
        if Lyra.config.projection_mode == :disabled
          Lyra::Projections::EventStoreReader.invalidate(model_class, id)
        end
        event
      end

      # Who made the change and what it belongs with, for a write no record's
      # callbacks attribute. Read from the application's Current, as for a write
      # through callbacks; a bulk write has no record to ask, so a model's
      # lyra_current_user_id hook does not apply here.
      def current_metadata
        {
          user_id: current(:user)&.id,
          user_type: Lyra::Attribution.actor_type(current(:user)),
          request_id: current(:request_id),
          correlation_id: Lyra::Correlation.current_id,
          causation_id: Lyra::Causation.current_id
        }.compact
      end

      # Attributes of every row the relation matches, keyed by primary key.
      # Taken before a bulk write so the events can carry old values.
      def snapshot(model_class, relation, lock: false)
        pk = model_class.primary_key
        scope = relation
        if lock
          # Lock through a subquery of keys, so a relation with DISTINCT,
          # GROUP BY or joins, which FOR UPDATE refuses, can still be locked.
          keys = relation.reselect(model_class.arel_table[pk])
          scope = model_class.unscoped.where(pk => keys).lock
        end
        rows = Lyra::PurposeBoundReads.internal(INTERNAL) { lock ? Lyra::Projections::LazyProjection.own_locking_read { scope.to_a } : scope.to_a }
        rows.to_h { |record| [record_key(model_class, record), record.attributes] }.tap { |by_id| admit(model_class, by_id.keys) }
      end

      # Before a bypass write records per-row events: rows that predate Lyra
      # are imported first (Lyra::Genesis), as before a write through
      # callbacks, and a row Genesis skipped is imported now or the write is
      # refused, so a bypass event never begins a stream (Genesis.admit_all!).
      def admit(model_class, ids)
        Lyra::Genesis.admit_all!(model_class, ids) unless ids.empty?
      end

      # After update_all: compare each snapshotted row with its new state and
      # publish an "updated" event for every row that actually changed.
      def publish_updates(model_class, before, source:)
        return if before.empty?

        pk = model_class.primary_key
        after = Lyra::PurposeBoundReads.internal(INTERNAL) { model_class.unscoped.where(pk => before.keys).to_a }
                .to_h { |record| [record_key(model_class, record), record.attributes] }

        before.each do |id, old_attrs|
          new_attrs = after[id] or next
          changes = diff(old_attrs, new_attrs)
          next if changes.empty?
          next if Thread.current[:lyra_touch_all] && skip_touch?(model_class, changes)

          publish(model_class, id, :updated,
                  attributes: changes.transform_values(&:last), changes: changes, source: source)
        end
      end

      # After delete_all: publish a "destroyed" event for every snapshotted row.
      def publish_destroys(model_class, before, source:)
        before.each do |id, attrs|
          publish(model_class, id, :destroyed,
                  attributes: attrs, source: source)
        end
      end

      # Rows that already exist with the given conflict-key values, keyed by
      # primary key. Rows with a nil key value can't conflict and are skipped.
      def snapshot_by_keys(model_class, rows, keys)
        return {} if keys.empty?

        types = keys.map { |key| model_class.type_for_attribute(key) }
        tuples = rows.filter_map do |row|
          values = keys.map { |key| row[key] }
          next if values.any?(&:nil?)

          values.each_with_index.map { |value, i| types[i].cast(value) }
        end.uniq
        return {} if tuples.empty?

        wanted = tuples.to_set
        found = Lyra::PurposeBoundReads.internal(INTERNAL) { model_class.unscoped.where(keys.first => tuples.map(&:first).uniq).to_a }
        found.each_with_object({}) do |record, acc|
          next unless wanted.include?(keys.map { |key| record.read_attribute(key) })

          acc[record_key(model_class, record)] = record.attributes
        end.tap { |by_id| admit(model_class, by_id.keys) }
      end

      # After insert_all / upsert_all: a "created" event for each written row
      # that wasn't in the snapshot, an "updated" event (with its changes)
      # for each that was and changed. The rows are reloaded as Lyra's own
      # read, like the snapshots: before 1.0.0 the reload ran as the
      # application's, so under a purpose that does not allow a declared
      # field it was refused, and Monitor wrote the rows with no events.
      #
      # Returns what it published: { id => [:created or :updated, event id] }.
      def publish_upserts(model_class, before, ids, source:)
        published = {}
        return published if ids.blank?

        pk = model_class.primary_key
        # A row the upsert updated although no key was given for it: its
        # generated key met a live record (a sequence behind the table). The
        # database updated that record, so its event is an update, not a second
        # create (1.0.0 recorded a create, in every mode that records events).
        # Its old values are the replay of its stream.
        unknown = ids.reject { before.key?(_1) }
        met = model_class.with_connection { |c| Lyra::StreamHeads.live_streams(unknown.map { Lyra.stream_name(model_class, _1) }, connection: c) }
        Lyra::PurposeBoundReads.internal(INTERNAL) do
          model_class.unscoped.where(pk => ids).find_each do |record|
            id = record_key(model_class, record)
            old_attrs = before[id]
            if old_attrs.nil? && met.include?(Lyra.stream_name(model_class, id))
              state = Lyra::StateProjection.rebuild_state(model_class, id).transform_keys(&:to_s)
              old_attrs = model_class.instantiate(state.slice(*model_class.column_names)).attributes
            end
            if old_attrs
              changes = diff(old_attrs, record.attributes)
              next if changes.empty?

              event = publish(model_class, id, :updated,
                              attributes: changes.transform_values(&:last), changes: changes, source: source)
              published[id] = [:updated, event.event_id]
            else
              event = publish(model_class, id, :created,
                              attributes: record.attributes, source: source)
              published[id] = [:created, event.event_id]
            end
          end
        end
        published
      end

      private

      # The key a record's events name it by: its primary key's value, or,
      # for a primary key of several columns, the array of their values
      # (record.id), which no column's reader gives.
      def record_key(model_class, record)
        pk = model_class.primary_key
        pk.is_a?(Array) ? record.id : record.public_send(pk)
      end

      # What Active Record returns when returning: is nil: the primary key,
      # where the adapter returns rows; nothing otherwise (InsertAll).
      def default_returning(model_class)
        keys = Array(model_class.primary_key)
        supported = model_class.with_connection(&:supports_insert_returning?)
        supported && keys.any? ? keys : false
      end

      # The write's result as the caller asked for it: the last +added+
      # columns (those with_returning added) taken out, the column types,
      # by index, and the affected rows kept; for returning: false (+added+
      # nil), Active Record's empty result.
      def caller_result(result, added)
        return ActiveRecord::Result.empty(affected_rows: result.affected_rows) if added.nil?
        return result if added.zero?

        kept = result.columns.size - added
        types = result.column_types
        ActiveRecord::Result.new(
          result.columns.first(kept),
          result.rows.map { _1.first(kept) },
          types.empty? ? nil : Array.new(kept) { types[_1] },
          affected_rows: result.affected_rows
        )
      end

      def current(attribute)
        defined?(::Current) && ::Current.respond_to?(attribute) ? ::Current.public_send(attribute) : nil
      end

      # Column => [old, new] for every column that changed, created_at and
      # updated_at included: a bare touch_all changes updated_at, and that is a
      # change of the record's state.
      def diff(old_attrs, new_attrs)
        new_attrs.each_with_object({}) do |(column, new_value), acc|
          old_value = old_attrs[column]
          acc[column] = [old_value, new_value] unless old_value == new_value
        end
      end

      # Existing streams use bypass_source for instance and bulk writes and
      # nullify_source for dependent: :nullify; keep both keys stable.
      def source_key(source)
        source == "dependent_association" ? :nullify_source : :bypass_source
      end

      # The event class a write of +operation+ on +model_class+ is recorded
      # as (also used by Lyra::Repair).
      public def event_class_for(model_class, operation)
        config = model_class.lyra_config || Lyra.config.model_config(model_class)
        name = config.event_name_for(operation).to_s.gsub("::", "")

        if Lyra::Events.const_defined?(name, false)
          Lyra::Events.const_get(name, false)
        else
          Lyra::Events.const_set(name, Class.new(Lyra::Event))
        end
      end
    end
  end

  # Run a block of Lyra's own read-model writes. Bypasses strict data
  # access and publishes no bypass events. Only Lyra's own call sites may call
  # it (they pass Lyra::INTERNAL): application code that needs the same uses
  # Lyra.unrecorded_write.
  def self.projection_write(token = nil)
    unless token.equal?(INTERNAL)
      raise InternalApiError,
            "Lyra.projection_write is for Lyra's own projections. To write without events " \
            "(seeding, fixtures, a wipe whose history you do not want) use " \
            "Lyra.unrecorded_write(reason: \"...\") { ... }, which records that it happened."
    end

    # Refused above, before the flags are touched: a refused call leaves the
    # block it was called in as it was.
    previous_write = Thread.current[:lyra_projection_write]
    previous_bypass = Thread.current[:lyra_bypass_strict_access]
    begin
      Thread.current[:lyra_projection_write] = true
      Thread.current[:lyra_bypass_strict_access] = true
      yield
    ensure
      Thread.current[:lyra_projection_write] = previous_write
      Thread.current[:lyra_bypass_strict_access] = previous_bypass
    end
  end

  UNRECORDED_WRITES_STREAM = "Lyra::UnrecordedWrites"
  LIB_ROOT = File.expand_path("..", __dir__)

  # The way application code writes without events: seeding, fixtures, a table
  # wipe whose history is not wanted. The block's changes are not in the log, and
  # in Monitor lyra:repair reports them; but the write itself is recorded, with
  # its reason, who ran it and where it was called from, in the stream
  # Lyra::UnrecordedWrites, so an unrecorded change leaves a record that it was
  # made. config.unrecorded_writes = :deny refuses it (production hardening).
  # Nothing is recorded in disabled mode, where nothing is.
  def self.unrecorded_write(reason:, &block)
    raise ArgumentError, "unrecorded_write needs a reason: why this write should not be in the log" if reason.to_s.strip.empty?
    raise ArgumentError, "unrecorded_write needs a block" unless block

    if config.unrecorded_writes == :deny
      raise UnrecordedWriteDenied, "unrecorded writes are refused (config.unrecorded_writes = :deny): #{reason}"
    end

    record_unrecorded_write(reason) unless config.disabled_mode?
    projection_write(INTERNAL, &block)
  end

  def self.record_unrecorded_write(reason)
    caller_frame = caller_locations.find { |frame| !frame.absolute_path.to_s.start_with?(LIB_ROOT) }
    event = Lyra::Events::UnrecordedWrite.new(
      data: { reason: reason.to_s, called_from: caller_frame && "#{caller_frame.path}:#{caller_frame.lineno}", at: Time.current },
      metadata: Lyra::BypassEvents.current_metadata.merge(source: "lyra_unrecorded_write")
    )
    append_events(event, stream_name: UNRECORDED_WRITES_STREAM)
  rescue => e
    # As for any event: Hijack and event sourcing fail the write, Monitor logs and goes on.
    raise if config.events_required?

    Rails.logger.error("Lyra: could not record an unrecorded write (#{reason}) - #{e.message}")
  end
  private_class_method :record_unrecorded_write

  module Events
    class UnrecordedWrite < Lyra::Event; end
  end
end
