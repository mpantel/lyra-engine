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
    TIMESTAMP_COLUMNS = %w[created_at updated_at].freeze

    class << self
      # Whether a bypass write's events must be stored for the write to
      # stand. In Hijack and the event-sourcing modes the log is the record of
      # every change (in ES-NoProj the only one), so a write whose event
      # cannot be stored must not happen: it fails, and is rolled back. In
      # Monitor the table stays authoritative and the event is a copy, so a
      # failed publish is logged and the write stands.
      def required?
        Lyra.hijack_mode? || Lyra.event_sourcing_mode?
      end

      # Run a bypass write together with the publishing of its events: in
      # one transaction when they are required, so that a failed publish
      # rolls the write back with it.
      def atomically(model_class, &block)
        required? ? model_class.transaction(&block) : yield
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
        metadata = {
          correlation_id: Lyra::Correlation.current_id,
          causation_id: Lyra::Causation.current_id,
          source_key(source) => source
        }.compact

        data = {
          model_class: model_class.name,
          model_id: id,
          operation: operation,
          attributes: attributes,
          changes: changes,
          timestamp: Time.current
        }
        event = event_class.new(data: data, metadata: Lyra::Privacy.stamp(model_class, data, metadata))
        Lyra.append_events(event, stream_name: "#{model_class.name}$#{id}")

        # With projections disabled, reads come from the cached event-stream
        # reconstruction, which would otherwise keep serving the old state.
        if Lyra.config.projection_mode == :disabled
          Lyra::Projections::EventStoreReader.invalidate(model_class, id)
        end
      end

      # Attributes of every row the relation matches, keyed by primary key.
      # Taken before a bulk write so the events can carry old values.
      def snapshot(model_class, relation)
        pk = model_class.primary_key
        rows = Lyra::PurposeBoundReads.internal { relation.to_a }
        rows.to_h { |record| [record.public_send(pk), record.attributes] }
      end

      # After update_all: compare each snapshotted row with its new state and
      # publish an "updated" event for every row that actually changed.
      def publish_updates(model_class, before, source:)
        return if before.empty?

        pk = model_class.primary_key
        after = Lyra::PurposeBoundReads.internal { model_class.unscoped.where(pk => before.keys).to_a }
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
                  attributes: attrs.except(*TIMESTAMP_COLUMNS), source: source)
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
        found = Lyra::PurposeBoundReads.internal { model_class.unscoped.where(keys.first => tuples.map(&:first).uniq).to_a }
        found.each_with_object({}) do |record, acc|
          next unless wanted.include?(keys.map { |key| record.read_attribute(key) })

          acc[record.public_send(pk)] = record.attributes
        end
      end

      # After insert_all / upsert_all: a "created" event for each written row
      # that wasn't in the snapshot, an "updated" event (with its changes)
      # for each that was and changed.
      def publish_upserts(model_class, before, ids, source:)
        return if ids.blank?

        pk = model_class.primary_key
        model_class.unscoped.where(pk => ids).find_each do |record|
          id = record.public_send(pk)
          if (old_attrs = before[id])
            changes = diff(old_attrs, record.attributes)
            next if changes.empty?

            publish(model_class, id, :updated,
                    attributes: changes.transform_values(&:last), changes: changes, source: source)
          else
            publish(model_class, id, :created,
                    attributes: record.attributes.except(*TIMESTAMP_COLUMNS), source: source)
          end
        end
      end

      private

      # Column => [old, new] for every non-timestamp column that changed.
      def diff(old_attrs, new_attrs)
        new_attrs.each_with_object({}) do |(column, new_value), acc|
          next if TIMESTAMP_COLUMNS.include?(column)

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
  # access and publishes no bypass events.
  def self.projection_write
    previous_write = Thread.current[:lyra_projection_write]
    previous_bypass = Thread.current[:lyra_bypass_strict_access]
    Thread.current[:lyra_projection_write] = true
    Thread.current[:lyra_bypass_strict_access] = true
    yield
  ensure
    Thread.current[:lyra_projection_write] = previous_write
    Thread.current[:lyra_bypass_strict_access] = previous_bypass
  end
end
