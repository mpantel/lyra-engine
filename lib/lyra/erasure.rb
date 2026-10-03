# frozen_string_literal: true

module Lyra
  # Erases one record's personal data (Art. 17) from its row and from every
  # event in its stream.
  #
  # The event log is otherwise append-only. Erasure is the one exception, and
  # it is itself recorded: each event that carried a personal value is
  # overwritten in place (same event id, position and time) with the value
  # replaced, the row gets the same replacement, and an ErasureApplied event
  # names the fields erased (never a value), the reason and who erased them.
  # The stream still replays to the row, so DualView, mode checks and
  # projections keep working.
  #
  # Personal fields are those the record's policy declares plus those the
  # events' privacy stamps (config.annotate_privacy) list, or exactly the
  # +fields:+ given. In the record's events a value is erased wherever it
  # appears: under the attribute's own name (attributes, both sides of each
  # change, payload keys), and under any other name, matched by value (a
  # domain-event payload that copies the email as payer_email).
  #
  # With +everywhere: true+ the whole log is searched for those values too.
  # Events of other records that copied them are scrubbed the same way, and
  # the rows of those records (monitored models) get the value replaced
  # where they hold it, with an ErasureApplied event in their streams, so
  # every stream still replays to its row. The search is a text match on the
  # stored events, then an exact match on each candidate's data.
  #
  # The replacement is nil where the column allows it, "erased:<id>" for a
  # string column that does not, and the column's default otherwise; a value
  # with no column of its own (a payload key) gets the origin field's.
  #
  # Crypto-shredding, which would leave the log untouched, remains future
  # work.
  module Erasure
    SOURCE = "lyra_erasure"

    class Unsupported < StandardError; end

    # Other records holding a value, beyond which it is taken to be shared by
    # many people (a city, a placeholder) rather than a copy of this one's.
    MAX_COPIES = 10

    # The PAM types searched for in other records: direct identifiers, whose
    # copy elsewhere is this person's. A name, a city or a postal code is a
    # quasi-identifier: another customer can share it by coincidence (on the
    # Olist replay, erasing one customer's postal code erased two other
    # customers' addresses). Those are erased in the person's own record only.
    IDENTIFYING_TYPES = %i[email phone identifier ssn credit_card financial payment_token ip_address
                           credential token].freeze

    Result = Struct.new(:model, :id, :fields, :events_rewritten, :row_erased, :copies, :shared_values,
                        keyword_init: true)

    class << self
      def erase!(model, id, reason:, fields: nil, erased_by: nil, everywhere: false, max_copies: MAX_COPIES)
        stream = "#{model.name}$#{id}"
        events = Lyra.config.event_store.read.stream(stream).to_a
        personal = (fields || personal_fields(model, events)).map(&:to_s).uniq
        raise Unsupported, "#{model.name} #{id}: no personal fields to erase" if personal.empty?

        replacements = personal.to_h { |field| [field, replacement(model, id, field)] }
        rewritten = []
        row_erased = false
        copies = []
        shared = []

        PurposeBoundReads.internal do
          model.transaction do
            originals = original_values(model, id, events, personal)
            resolve = ->(key, value) { resolve_in(model, id, replacements, originals, key, value) }
            rewritten = events.filter_map { |event| rewrite(event, resolve) }
            Lyra.config.event_store.overwrite(rewritten) if rewritten.any?
            row_erased = erase_row(model, id, replacements)
            record_erasure(model, id, stream, personal, reason, erased_by)
            if everywhere
              copies, shared = erase_copies(model, id, stream, originals, replacements, reason, erased_by, max_copies)
            end
          end
        end
        forget_cached(model, id)

        Result.new(model: model.name, id: id, fields: personal, events_rewritten: rewritten.size,
                   row_erased: row_erased, copies: copies, shared_values: shared)
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

      # value => the personal field it was found under, for every non-empty
      # string the record's row or events held in a personal field.
      def original_values(model, id, events, personal)
        found = {}
        row = model.unscoped.find_by(model.primary_key => id) unless events_only?
        personal.each { |field| remember(found, row&.read_attribute(field), field) } if row
        events.each { |event| collect(event.data, personal, found) }
        found
      end

      def collect(value, personal, found, under: nil)
        case value
        when Hash
          value.each do |key, inner|
            if personal.include?(key.to_s)
              Array(inner).each { |v| remember(found, v, key.to_s) }
            else
              collect(inner, personal, found, under: key.to_s)
            end
          end
        when Array then value.each { |inner| collect(inner, personal, found, under: under) }
        end
      end

      def remember(found, value, field)
        found[value] ||= field if value.is_a?(String) && !value.empty?
      end

      # The replacement for +value+ found under +key+ in +model+ +id+'s data,
      # or :keep. Under a personal field's own name, or as a copy of one of
      # its values under any name.
      def resolve_in(model, id, replacements, originals, key, value)
        return replacements[key] if replacements.key?(key)
        return :keep unless value.is_a?(String) && originals.key?(value)

        replacement_for(model, id, key, replacements[originals[value]])
      end

      # A copy held in +model+'s own column gets that column's replacement
      # (so the row and its events agree); elsewhere the origin field's.
      def replacement_for(model, id, key, fallback)
        model.columns_hash.key?(key) ? replacement(model, id, key) : fallback
      rescue Unsupported
        fallback
      end

      # The event with every personal value replaced, or nil if it carried none.
      def rewrite(event, resolve)
        data, changed = scrub(event.data, resolve)
        return nil unless changed

        event.class.new(event_id: event.event_id, data: data, metadata: event.metadata.to_h)
      end

      # [copy of +value+ with personal values replaced, whether any was].
      def scrub(value, resolve, key: nil)
        case value
        when Hash
          changed = false
          copy = value.to_h do |inner_key, inner|
            new_value, inner_changed = scrub(inner, resolve, key: inner_key.to_s)
            changed ||= inner_changed
            [inner_key, new_value]
          end
          [copy, changed]
        when Array
          results = value.map { |inner| scrub(inner, resolve, key: key) }
          [results.map(&:first), results.any?(&:last)]
        else
          replaced = resolve.call(key, value)
          replaced == :keep || replaced == value ? [value, false] : [replaced, true]
        end
      end

      def erase_row(model, id, replacements)
        return false if events_only?

        row = model.unscoped.lock.find_by(model.primary_key => id)
        return false unless row

        columns = replacements.slice(*row.attribute_names)
        write_columns(model, id, columns)
        true
      end

      # everywhere: events of other streams holding the erased values, and
      # the rows of the monitored records they belong to. Returns [records
      # erased, values left as shared]. A value held by more than
      # +max_copies+ other records is shared by many people, not a copy of
      # this one's: erasing it everywhere erased everyone's (a replay's
      # placeholder address took all 1,954 addresses with it). It is left,
      # and reported.
      def erase_copies(origin, origin_id, origin_stream, originals, replacements, reason, erased_by, max_copies)
        return [[], []] if originals.empty?

        policy = Lyra::Privacy.policy_for(origin)
        originals = originals.select { |_value, field| IDENTIFYING_TYPES.include?(policy.annotation(field)&.type&.to_sym) }
        shared = originals.keys.select { |value| holders(value, origin_stream) > max_copies }
        originals = originals.except(*shared)
        return [[], shared.size] if originals.empty?

        candidates = events_mentioning(originals.keys).reject { |event| streams_of(event).include?(origin_stream) }
        by_record = candidates.group_by { |event| record_of(event) }
        by_record.filter_map do |(model, id), events|
          resolve = lambda do |key, value|
            next :keep unless value.is_a?(String) && originals.key?(value)

            model ? replacement_for(model, id, key, replacements[originals[value]]) : replacements[originals[value]]
          end
          rewritten = events.filter_map { |event| rewrite(event, resolve) }
          next if rewritten.empty?

          Lyra.config.event_store.overwrite(rewritten)
          next "#{rewritten.size} events" unless model

          copied = erase_copied_columns(model, id, originals, replacements)
          record_erasure(model, id, "#{model.name}$#{id}", copied,
                         "#{reason} (copies of #{origin.name} #{origin_id})", erased_by)
          forget_cached(model, id)
          "#{model.name} #{id}"
        end.then { |copies| [copies, shared.size] }
      end

      # How many streams other than +origin_stream+ hold +value+ (text match).
      def holders(value, origin_stream)
        conn = ActiveRecord::Base.connection
        conn.select_value(<<~SQL.squish).to_i
          SELECT count(DISTINCT s.stream) FROM event_store_events e
          JOIN event_store_events_in_streams s ON s.event_id = e.event_id
          WHERE convert_from(e.data, 'UTF8') LIKE #{conn.quote("%#{ActiveRecord::Base.sanitize_sql_like(value)}%")}
            AND s.stream <> #{conn.quote(origin_stream)}
        SQL
      end

      def events_mentioning(values)
        conn = ActiveRecord::Base.connection
        clauses = values.map do |value|
          "convert_from(data, 'UTF8') LIKE #{conn.quote("%#{ActiveRecord::Base.sanitize_sql_like(value)}%")}"
        end
        ids = conn.select_values("SELECT event_id FROM event_store_events WHERE #{clauses.join(' OR ')}")
        ids.filter_map { |event_id| Lyra.config.event_store.read.event(event_id) rescue nil }
      end

      def streams_of(event)
        Lyra.config.event_store.streams_of(event.event_id).map(&:name)
      end

      # [model, id] when the event is in a monitored record's stream, else [nil, nil].
      def record_of(event)
        streams_of(event).each do |name|
          model_name, id = name.split("$", 2)
          model = Lyra.config.monitored_models.find { |m| m.name == model_name }
          return [model, id] if model && id
        end
        [nil, nil]
      end

      # The columns of +model+ +id+'s row that hold an erased value, replaced.
      # Returns the column names.
      def erase_copied_columns(model, id, originals, replacements)
        return [] if events_only?

        row = model.unscoped.lock.find_by(model.primary_key => id)
        return [] unless row

        columns = row.attributes.each_with_object({}) do |(column, value), acc|
          next unless value.is_a?(String) && originals.key?(value)

          acc[column] = replacement_for(model, id, column, replacements[originals[value]])
        end
        write_columns(model, id, columns)
        columns.keys
      end

      # The replacements, written to the row as Lyra's own write (no bypass
      # event: the events were rewritten above). One UPDATE by id, so a record
      # the application marks read-only is erased too (Solidus freezes an
      # address once an order uses it, and update_columns refused it).
      def write_columns(model, id, columns)
        return if columns.empty?

        Lyra.projection_write { model.unscoped.where(model.primary_key => id).update_all(columns) }
      end

      def events_only?
        Lyra.config.event_sourcing_mode? && Lyra.config.projection_mode == :disabled
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
