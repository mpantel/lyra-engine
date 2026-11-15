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
  # +fields:+ given, which must be among those unless +any_fields: true+
  # (from 0.9.3: an erasure rewrites history in place, so naming any column,
  # a payment's status, say, would rewrite non-personal history under an
  # Art. 17 reason). In the record's events a value is erased wherever it
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
  # The subject's access log (Lyra::AccessLog, the stream
  # Lyra::DataAccess$<Model>$<id>) holds who read the record, when and under
  # which purpose, never a value. It may be evidence the application must
  # keep (Art. 5(2), a security investigation) or the subject's data to
  # erase with the rest; Lyra cannot know which. From 1.0.0 erasure keeps it
  # unless config.erase_access_log or +access_log: true+ says otherwise; then
  # its events are deleted, from every stream they are in and from the
  # events table (unlinking the stream alone would leave them). The
  # configuration applies only once the record is fully erased: when this
  # erasure, with any earlier ones, has covered every personal field. A
  # field-level erasure (a retention period for one field) leaves a record
  # whose other data is still processed, and its log with it. An explicit
  # +access_log: true+ deletes the log whatever was erased. Either way
  # ErasureApplied records access_log ("erased" or "kept") and
  # access_log_entries (how many it held), so the decision is visible.
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
                        :access_log, :access_log_entries, keyword_init: true)

    class << self
      def erase!(model, id, reason:, fields: nil, erased_by: nil, everywhere: false, max_copies: MAX_COPIES,
                 any_fields: false, access_log: nil, access_log_subjects: [])
        stream = Lyra.stream_name(model, id)
        # The record's access stream, and those of the ids the application used
        # as this person's subject (validate_access!(…, subject: user_id)).
        access_streams = [stream, *Array(access_log_subjects).map { |s| Lyra::AccessLog.erasable_key(s) }]
                         .uniq.map { |key| Lyra::AccessLog.stream_for(key) }
        personal = []
        rewritten = []
        row_erased = false
        copies = []
        shared = 0
        log_outcome = nil
        log_entries = 0

        PurposeBoundReads.internal(INTERNAL) do
          model.transaction do
            # The locks first, the stream second: a write that is half-way between
            # its row and its event (a Monitor update appends its event in the
            # transaction that writes the row) must finish before the stream is
            # read, or its event, committed in the window, keeps the value the
            # erasure was asked to remove (0.9.3 and earlier read the stream first).
            lock_record(model, id, stream)
            events = Lyra.config.event_store.read.stream(stream).to_a
            declared = personal_fields(model, events)
            personal = (fields || declared).map(&:to_s).uniq
            undeclared = any_fields || fields.nil? ? [] : personal - declared
            if undeclared.any?
              raise Unsupported, "#{model.name} #{id}: #{undeclared.join(', ')} not declared personal by its policy " \
                                 "or the events' privacy stamps; pass any_fields: true to erase them anyway"
            end
            raise Unsupported, "#{model.name} #{id}: no personal fields to erase" if personal.empty?

            replacements = personal.to_h { |field| [field, replacement(model, id, field)] }
            erase_log = access_log.nil? ? Lyra.config.erase_access_log && complete?(declared, personal, events) : access_log
            originals = original_values(model, id, events, personal)
            resolve = ->(key, value) { resolve_in(model, id, replacements, originals, key, value) }
            rewritten = events.filter_map { |event| rewrite(event, resolve) }
            Lyra.config.event_store.overwrite(rewritten) if rewritten.any?
            row_erased, row_copies = erase_row(model, id, replacements, originals)
            log_outcome, log_entries = access_log!(access_streams, erase_log)
            record_erasure(model, id, stream, personal | row_copies, reason, erased_by,
                           any_fields: any_fields, requested: fields, beyond_policy: any_fields ? personal - declared : [],
                           access_log: log_outcome, access_log_entries: log_entries,
                           access_log_subjects: access_streams.size - 1)
            if everywhere
              copies, shared = erase_copies(model, id, stream, originals, replacements, reason, erased_by, max_copies)
            end
          end
        end
        forget_cached(model, id)

        Result.new(model: model.name, id: id, fields: personal, events_rewritten: rewritten.size,
                   row_erased: row_erased, copies: copies, shared_values: shared,
                   access_log: log_outcome, access_log_entries: log_entries)
      end

      # The subject's access log alone: for a record whose personal fields
      # were all erased before (Retention's hard delete, when an earlier
      # erasure kept the log). Records an ErasureApplied with no fields when
      # the log held entries. Returns how many it deleted.
      def erase_access_log!(model, id, reason:, erased_by: nil)
        stream = Lyra.stream_name(model, id)
        model.transaction do
          _, entries = access_log!([Lyra::AccessLog.stream_for(stream)], true)
          if entries.positive?
            record_erasure(model, id, stream, [], reason, erased_by, access_log: "erased", access_log_entries: entries)
          end
          entries
        end
      end

      private

      # Whether this erasure, with the ones before it (their ErasureApplied
      # events), covers every personal field of the record.
      def complete?(declared, personal, events)
        earlier = events.select { |event| event.is_a?(Lyra::Events::ErasureApplied) }
                        .flat_map { |event| Array(event.data[:fields]).map(&:to_s) }
        (declared - personal - earlier).empty?
      end

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

      # The record's row, then its aggregate's advisory lock: the locks a writer
      # holds (a Monitor or Hijack write keeps the row until it commits, with its
      # event appended in the same transaction; the other modes take the advisory
      # lock), taken in the order writers take them. Waiting here is what lets an
      # in-flight write finish before the stream is read.
      def lock_record(model, id, stream)
        model.unscoped.lock.find_by(model.primary_key => id) unless events_only?
        model.with_connection do |connection|
          Lyra::AdvisoryLock.xact_lock(connection, "lyra_aggregate/#{stream}", purpose: "erasure")
        end
      end

      # The erased fields, and any other column of the row that still holds
      # one of their values (a username that is the email): its events were
      # rewritten with that column's replacement, so the row gets it too and
      # still equals its replay. Returns [erased?, the copied columns].
      def erase_row(model, id, replacements, originals)
        return [false, []] if events_only?

        row = model.unscoped.lock.find_by(model.primary_key => id)
        return [false, []] unless row

        columns = replacements.slice(*row.attribute_names)
        copies = row.attributes.each_with_object({}) do |(column, value), acc|
          next if columns.key?(column) || !value.is_a?(String) || !originals.key?(value)

          acc[column] = replacement_for(model, id, column, replacements[originals[value]])
        end
        write_columns(model, id, columns.merge(copies))
        [true, copies.keys]
      end

      # everywhere: events of other streams holding the erased values, and
      # the rows of the monitored records they belong to. Returns [records
      # erased, values left as shared]. A value held by more than
      # +max_copies+ other records is shared by many people, not a copy of
      # this one's: erasing it everywhere erased everyone's (a replay's
      # placeholder address took all 1,954 addresses with it). It is left,
      # and reported.
      def erase_copies(origin, origin_id, origin_stream, originals, replacements, reason, erased_by, max_copies)
        return [[], 0] if originals.empty?

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
          record_erasure(model, id, Lyra.stream_name(model, id), copied,
                         "#{reason} (copies of #{origin.name} #{origin_id})", erased_by)
          forget_cached(model, id)
          "#{model.name} #{id}"
        end.then { |copies| [copies, shared.size] }
      end

      # How many streams other than +origin_stream+ hold +value+ (text match).
      def holders(value, origin_stream)
        ActiveRecord::Base.with_connection do |conn|
          conn.select_value(<<~SQL.squish).to_i
            SELECT count(DISTINCT s.stream) FROM event_store_events e
            JOIN event_store_events_in_streams s ON s.event_id = e.event_id
            WHERE convert_from(e.data, 'UTF8') LIKE #{conn.quote("%#{ActiveRecord::Base.sanitize_sql_like(value)}%")}
              AND s.stream <> #{conn.quote(origin_stream)}
          SQL
        end
      end

      def events_mentioning(values)
        ActiveRecord::Base.with_connection do |conn|
          clauses = values.map do |value|
            "convert_from(data, 'UTF8') LIKE #{conn.quote("%#{ActiveRecord::Base.sanitize_sql_like(value)}%")}"
          end
          ids = conn.select_values("SELECT event_id FROM event_store_events WHERE #{clauses.join(' OR ')}")
          ids.filter_map { |event_id| Lyra.config.event_store.read.event(event_id) rescue nil }
        end
      end

      def streams_of(event)
        Lyra.config.event_store.streams_of(event.event_id).map(&:name)
      end

      # [model, id] when the event is in a monitored record's stream, else [nil, nil].
      def record_of(event)
        streams_of(event).each do |name|
          model_name, id = name.split("$", 2)
          model = Lyra.config.monitored_model_named(model_name)
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

        Lyra.projection_write(INTERNAL) { model.unscoped.where(model.primary_key => id).update_all(columns) }
      end

      def events_only?
        Lyra.config.event_sourcing_mode? && Lyra.config.projection_mode == :disabled
      end

      # The subject's access streams: their events deleted when +erase+, else
      # kept. Returns ["erased" or "kept", how many entries they held].
      def access_log!(access_streams, erase)
        if erase
          ["erased", access_streams.sum { |s| Lyra::AccessLog.delete_stream!(s) }]
        else
          ["kept", access_streams.sum { |s| Lyra::AccessLog.count_stream(s) }]
        end
      end

      # +access_log+ and +access_log_entries+: what happened to the subject's
      # access log ("erased" or "kept", and how many entries it held).
      # +any_fields+: the request named columns the policy does not declare personal
      # (ANY_FIELDS=1); +requested+ is what it named (nil: the declared ones);
      # +beyond_policy+ the columns erased only because of it. The operating
      # system's user and the host are recorded beside the label in erased_by.
      def record_erasure(model, id, stream, fields, reason, erased_by, any_fields: false, requested: nil, beyond_policy: [],
                         access_log: nil, access_log_entries: nil, access_log_subjects: 0)
        data = { model_class: model.name, model_id: id, fields: fields, reason: reason.to_s, erased_at: Time.current,
                 any_fields: any_fields, requested_fields: requested&.map(&:to_s), beyond_policy: beyond_policy }
        data.merge!(access_log: access_log, access_log_entries: access_log_entries) if access_log
        data[:access_log_subjects] = access_log_subjects if access_log_subjects.positive?
        who = Lyra::Attribution.of
        metadata = {
          source: SOURCE,
          erased_by: erased_by&.to_s || (defined?(::Current) && ::Current.respond_to?(:user) ? ::Current.user&.id : nil),
          os_user: who[:os_user],
          host: who[:host],
          pid: who[:pid],
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
