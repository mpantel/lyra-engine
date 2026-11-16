# frozen_string_literal: true

module Lyra
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
      # matched nothing, recorded no event, and the change was lost.
      def atomically(model_class, &block)
        Lyra::Projections::LazyProjection.before_read(model_class)
        required? || locks_rows? ? model_class.transaction(&block) : yield
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

      # Report a failed publish: raise when the events are required (see
      # required?), log otherwise.
      def publish_failed!(error, source)
        raise error if required?

        Rails.logger.error("Lyra: Failed to publish bypass event (#{source}) - #{error.message}")
      end

      def enabled_for?(model_class)
        return false if Thread.current[:lyra_projection_write]
        return false if Lyra.config.mode == :disabled

        model_class.respond_to?(:lyra_monitored) && model_class.lyra_monitored
      end

      def publish(model_class, id, operation, attributes:, changes: {}, source:)
        event_class = event_class_for(model_class, operation)
        metadata = current_metadata.merge(source_key(source) => source)

        data = Lyra::EventData.build(model_class, id, operation, attributes: attributes, changes: changes)
        event = event_class.new(data: data, metadata: Lyra::Privacy.stamp(model_class, data, metadata))
        Lyra.append_events(event, stream_name: Lyra.stream_name(model_class, id))

        # With projections disabled, reads come from the cached event-stream
        # reconstruction, which would otherwise keep serving the old state.
        if Lyra.config.projection_mode == :disabled
          Lyra::Projections::EventStoreReader.invalidate(model_class, id)
        end
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
        rows = Lyra::PurposeBoundReads.internal(INTERNAL) { scope.to_a }
        rows.to_h { |record| [record.public_send(pk), record.attributes] }
      end

      # After update_all: compare each snapshotted row with its new state and
      # publish an "updated" event for every row that actually changed.
      def publish_updates(model_class, before, source:)
        return if before.empty?

        pk = model_class.primary_key
        after = Lyra::PurposeBoundReads.internal(INTERNAL) { model_class.unscoped.where(pk => before.keys).to_a }
                .to_h { |record| [record.public_send(pk), record.attributes] }

        before.each do |id, old_attrs|
          new_attrs = after[id] or next
          changes = diff(old_attrs, new_attrs)
          next if changes.empty?

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
        pk = model_class.primary_key
        found = Lyra::PurposeBoundReads.internal(INTERNAL) { model_class.unscoped.where(keys.first => tuples.map(&:first).uniq).to_a }
        found.each_with_object({}) do |record, acc|
          next unless wanted.include?(keys.map { |key| record.read_attribute(key) })

          acc[record.public_send(pk)] = record.attributes
        end
      end

      # After insert_all / upsert_all: a "created" event for each written row
      # that wasn't in the snapshot, an "updated" event (with its changes)
      # for each that was and changed. The rows are reloaded as Lyra's own
      # read, like the snapshots: before 1.0.0 the reload ran as the
      # application's, so under a purpose that does not allow a declared
      # field it was refused, and Monitor wrote the rows with no events.
      def publish_upserts(model_class, before, ids, source:)
        return if ids.blank?

        pk = model_class.primary_key
        Lyra::PurposeBoundReads.internal(INTERNAL) do
          model_class.unscoped.where(pk => ids).find_each do |record|
            id = record.public_send(pk)
            if (old_attrs = before[id])
              changes = diff(old_attrs, record.attributes)
              next if changes.empty?

              publish(model_class, id, :updated,
                      attributes: changes.transform_values(&:last), changes: changes, source: source)
            else
              publish(model_class, id, :created,
                      attributes: record.attributes, source: source)
            end
          end
        end
      end

      private

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
