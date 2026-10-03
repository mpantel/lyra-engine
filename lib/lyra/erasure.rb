# frozen_string_literal: true

module Lyra
  # Erases one record's personal data (Art. 17) from its row and from every
  # event in its stream.
  #
  # The event log is otherwise append-only. Erasure is the one exception, and
  # it is itself recorded: each event of the record that carried a personal
  # value is overwritten in place (same event id, position and time) with the
  # value replaced, the row gets the same replacement, and an ErasureApplied
  # event names the fields erased (never a value), the reason and who erased
  # them. The stream still replays to the row, so DualView, mode checks and
  # projections keep working.
  #
  # Personal fields are those the record's policy declares plus those the
  # events' privacy stamps (config.annotate_privacy) list, or exactly the
  # +fields:+ given. A field is erased wherever it appears in an event's
  # data under its own name: attributes, changes (both old and new values),
  # and domain-event payloads that use the attribute's name. A payload that
  # copies a value under another name is not found; name such keys in
  # +fields:+.
  #
  # The replacement is nil where the column allows it, "erased:<id>" for a
  # string column that does not, and the column's default otherwise.
  #
  # Other records that hold the same person's data (a payment copying the
  # registrant's email) are erased separately, one record at a time;
  # Lyra::Privacy::GDPRCompliance#right_to_be_forgotten_report lists them.
  #
  # Crypto-shredding, which would leave the log untouched, remains future
  # work.
  module Erasure
    SOURCE = "lyra_erasure"

    class Unsupported < StandardError; end

    Result = Struct.new(:model, :id, :fields, :events_rewritten, :row_erased, keyword_init: true)

    class << self
      def erase!(model, id, reason:, fields: nil, erased_by: nil)
        stream = "#{model.name}$#{id}"
        events = Lyra.config.event_store.read.stream(stream).to_a
        personal = (fields || personal_fields(model, events)).map(&:to_s).uniq
        raise Unsupported, "#{model.name} #{id}: no personal fields to erase" if personal.empty?

        replacements = personal.to_h { |field| [field, replacement(model, id, field)] }
        rewritten = []
        row_erased = false

        PurposeBoundReads.internal do
          model.transaction do
            rewritten = events.filter_map { |event| rewrite(event, replacements) }
            Lyra.config.event_store.overwrite(rewritten) if rewritten.any?
            row_erased = erase_row(model, id, replacements)
            record_erasure(model, id, stream, personal, reason, erased_by)
          end
        end
        forget_cached(model, id)

        Result.new(model: model.name, id: id, fields: personal, events_rewritten: rewritten.size,
                   row_erased: row_erased)
      end

      private

      def personal_fields(model, events)
        declared = Lyra::Privacy.policy_for(model).declared_fields.map(&:to_s)
        stamped = events.flat_map { |event| Lyra::Privacy.stamp_of(event)&.dig("fields")&.keys || [] }
        declared | stamped
      end

      def replacement(model, id, field)
        column = model.columns_hash[field]
        return nil if column.nil? || column.null
        return "erased:#{id}" if %i[string text].include?(column.type)
        return model.type_for_attribute(field).cast(column.default) unless column.default.nil?

        raise Unsupported, "#{model.name}.#{field} is NOT NULL with no default; name a replacement by hand"
      end

      # The event with every personal value replaced, or nil if it carried none.
      def rewrite(event, replacements)
        data, changed = scrub(event.data, replacements)
        return nil unless changed

        event.class.new(event_id: event.event_id, data: data, metadata: event.metadata.to_h)
      end

      # [copy of +value+ with personal values replaced, whether any was].
      def scrub(value, replacements, under: nil)
        case value
        when Hash
          changed = false
          copy = value.to_h do |key, inner|
            if replacements.key?(key.to_s)
              new_value = erased(inner, replacements[key.to_s], changes: under == "changes")
              changed ||= new_value != inner
              [key, new_value]
            else
              scrubbed, inner_changed = scrub(inner, replacements, under: key.to_s)
              changed ||= inner_changed
              [key, scrubbed]
            end
          end
          [copy, changed]
        when Array
          results = value.map { |inner| scrub(inner, replacements, under: under) }
          [results.map(&:first), results.any?(&:last)]
        else
          [value, false]
        end
      end

      # A change is [old, new]: both go.
      def erased(value, replacement, changes:)
        changes && value.is_a?(Array) ? value.map { replacement } : replacement
      end

      def erase_row(model, id, replacements)
        row = model.unscoped.lock.find_by(model.primary_key => id)
        return false unless row

        columns = replacements.slice(*row.attribute_names)
        Lyra.projection_write { row.update_columns(columns) } if columns.any?
        true
      end

      def record_erasure(model, id, stream, fields, reason, erased_by)
        data = { model_class: model.name, model_id: id, fields: fields, reason: reason.to_s, erased_at: Time.current }
        metadata = {
          source: SOURCE,
          erased_by: erased_by&.to_s || (defined?(::Current) && ::Current.respond_to?(:user) ? ::Current.user&.id : nil),
          correlation_id: Lyra::Correlation.current_id
        }.compact
        Lyra.append_events(Lyra::Events::ErasureApplied.new(data: data, metadata: metadata), stream_name: stream)
      end

      def forget_cached(model, id)
        Lyra::Projections::EventStoreReader.invalidate(model, id)
        Lyra::Projections::CachedProjection.invalidate(model, id)
      rescue StandardError => e
        Rails.logger.warn("Lyra: erasure could not drop the cache for #{model.name} #{id} - #{e.message}")
      end
    end
  end

  module Events
    class ErasureApplied < Lyra::Event; end
  end
end
