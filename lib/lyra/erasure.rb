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
  # stored events, then an exact match on each candidate's data. From 1.0.0
  # the tables of monitored models with a policy are searched too (not in
  # ES-NoProj), so a row whose events lack the value is found; a row with no
  # stream is erased and then imported (Genesis), so its first event never
  # holds the value. Only the person's own values are searched for: a third
  # party's value nested under a personal key in the person's data is erased
  # there only. Holders are counted by record; the person's linked records
  # (belongs_to the erased record) do not count toward max_copies
  # (config.erasure_max_copies), and each value left as shared is reported
  # by field and count (Result#shared). Lyra's own record streams
  # (kept_stream?: rights and consent, access logs, exports) are never
  # rewritten. A dry run (dry_run: true) reports all of it and writes nothing.
  #
  # Each row gets the rule its own events get: the record's row the key and
  # value rule, another record's row the value rule only (a third party's
  # email under an "email" key there is not this person's). Every column is
  # scrubbed; from 1.0.0 a json, jsonb or array column, or a serialized
  # attribute, is recursed into and written back whole. A text column that
  # holds JSON is a string in its events, and is compared as one. A hash or
  # array under a personal field's name is replaced whole. Encrypted
  # attributes are compared in clear, in the events as in the row. A record
  # whose row still holds a value (as a JSON key, inside a longer string) is
  # reported in Result#left_behind, not in Result#copies.
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
    # many people (a city, a placeholder) rather than a copy of this one's: the
    # default of config.erasure_max_copies (from 1.0.0).
    MAX_COPIES = 10

    # The PAM types searched for in other records: direct identifiers, whose
    # copy elsewhere is this person's. A name, a city or a postal code is a
    # quasi-identifier: another customer can share it by coincidence (on the
    # Olist replay, erasing one customer's postal code erased two other
    # customers' addresses). Those are erased in the person's own record only.
    IDENTIFYING_TYPES = %i[email phone identifier ssn credit_card financial payment_token ip_address
                           credential token].freeze

    # +left_behind+: the records whose row still holds an erased value after
    # the erasure, as { record: "Model id", columns: [...] } (never the value):
    # a value held as a JSON key, inside a longer string, or in a key column
    # (a primary or foreign key is never rewritten). The erased record itself
    # (its replayed state in ES-NoProj) and, with everywhere, the other
    # records reached; those are not in +copies+. A record whose key holds an
    # erased value is named "Model <key withheld>".
    # +not_searched+: with everywhere, the encrypted columns of monitored
    # models ("Model.column"), which the search of the log cannot read.
    # +key_withheld+: the erased record's own key holds an erased value.
    # +shared+ (from 1.0.0): with everywhere, each value left as shared, as
    # { field:, type:, holders: } (the personal field it was found under, its
    # PAM type and how many other records hold it), never the value;
    # +shared_values+ is their count, an Integer as before.
    # +rows_without_events+ (from 1.0.0): with everywhere, the records whose
    # row held an erased value that their events did not (written by raw SQL,
    # say), found by searching the tables directly and erased in the row only:
    # their row already differed from their replay, and lyra:repair brings
    # the log in line. A row with no stream at all is imported instead (its
    # Imported event holds the erased values) and is not listed here.
    # +lifting+ (from 1.0.0, with PAM DSL's rights): the ids of the
    # restrictions of processing the erasure lifted (lifting:), or, in a dry
    # run, would lift; [] when none.
    # +restricted_copies+ (from 1.0.0, with everywhere and PAM DSL's rights):
    # the other records holding a copy that a restriction of processing
    # covers, as { record: "Model id", columns: [...] }, never the value. They
    # are not modified: the copy stays until the holder's restriction is
    # lifted, and an erasure then (everywhere again) takes it.
    Result = Struct.new(:model, :id, :fields, :events_rewritten, :row_erased, :copies, :shared_values,
                        :access_log, :access_log_entries, :left_behind, :not_searched, :key_withheld,
                        :shared, :rows_without_events, :dry_run, :lifting, :restricted_copies, keyword_init: true)

    WITHHELD = "<key withheld>"

    # Lyra's own records of how a person's rights were handled (kept_stream?):
    # restrictions and objections (Lyra::Rights::STREAM), consent
    # (Lyra::Rights::CONSENT_STREAM), the access log and its erasures, the
    # subject-access exports, each an index stream and its per-subject
    # streams ("<name>$<subject key>"). Evidence the controller keeps
    # (Art. 5(2)); everywhere never rewrites their events nor counts them as
    # holders, even when a subject key is an erased value. The record's own
    # access log is erased, or kept, by access_log:.
    def self.kept_streams
      names = []
      names += [Lyra::Rights::STREAM, Lyra::Rights::CONSENT_STREAM] if defined?(Lyra::Rights::STREAM)
      names += [Lyra::AccessLog::STREAM, Lyra::AccessLog::ERASURES, Lyra::AccessLog::EXPORTS] if defined?(Lyra::AccessLog::STREAM)
      names
    end

    def self.kept_stream?(name)
      kept_streams.any? { |kept| name == kept || name.start_with?("#{kept}$") }
    end

    # The replacement's own form: an earlier erasure's marker is no one's value.
    REPLACEMENT = /\Aerased:/

    # An event's envelope entries that name the record, never scrubbed.
    ENVELOPE_KEYS = %w[model_class model_id operation timestamp replay].freeze

    class << self
      # +max_copies+: nil takes config.erasure_max_copies (10 by default); else a
      # positive Integer (ArgumentError before anything is read or written).
      # +dry_run+ (from 1.0.0): do everything in a transaction and roll it back,
      # so the result says what the erasure would do (fields, events, copies,
      # rows without events, values left as shared and their holders, what would
      # be left behind) and nothing is written. A value left as shared cannot be
      # found again once the person's own values are erased, so the threshold is
      # chosen with a dry run first.
      def erase!(model, id, reason:, fields: nil, erased_by: nil, everywhere: false, max_copies: nil,
                 any_fields: false, access_log: nil, access_log_subjects: [], dry_run: false, lifting: nil)
        max_copies = Lyra.config.erasure_max_copies if max_copies.nil?
        unless max_copies.is_a?(Integer) && max_copies.positive?
          raise ArgumentError, "max_copies must be a positive Integer (got #{max_copies.inspect})"
        end

        # A restriction of processing (Art. 18) refuses the erasure (dry run
        # included) unless +lifting:+ names it, notice recorded: then it is lifted
        # and the record erased in one transaction; a dry run lifts nothing and
        # reports the restrictions it would lift in Result#lifting
        # (Lyra::Rights::ErasureGuard).
        lifts = if defined?(Rights::ErasureGuard)
                  Rights::ErasureGuard.check!(model, id, fields: fields, subjects: access_log_subjects, lifting: lifting)
                else
                  []
                end
        if lifts.any?
          return model.transaction(requires_new: true) do
            Rights::ErasureGuard.lift!(lifts, by: erased_by) unless dry_run
            Rights::ErasureGuard.lifted(lifts) do
              erase!(model, id, reason: reason, fields: fields, erased_by: erased_by, everywhere: everywhere,
                                max_copies: max_copies, any_fields: any_fields, access_log: access_log,
                                access_log_subjects: access_log_subjects, dry_run: dry_run)
            end.tap { |result| result.lifting = lifts.map(&:id) }
          end
        end

        stream = Lyra.stream_name(model, id)
        # The record's access stream, and those of the ids the application used
        # as this person's subject (validate_access!(…, subject: user_id)).
        access_streams = [stream, *Array(access_log_subjects).map { |s| Lyra::AccessLog.erasable_key(s) }]
                         .uniq.map { |key| Lyra::AccessLog.stream_for(key) }
        personal = []
        rewritten = []
        row_erased = false
        copies = []
        shared = []
        rows_only = []
        restricted_copies = []
        left = []
        not_searched = []
        withheld = false
        log_outcome = nil
        log_entries = 0
        touched = Thread.current[:lyra_erasure_touched] = []

        PurposeBoundReads.internal(INTERNAL) do
          # A savepoint for a dry run, so its rollback is real inside a caller's transaction.
          model.transaction(requires_new: dry_run) do
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
            originals, own = original_values(model, id, events, personal)
            # The origin as it was, for the links of its records (a belongs_to
            # with primary_key: names one of its columns, which may be erased).
            origin_state = current_state(model, id)
            resolve = ->(key, value) { resolve_in(model, id, replacements, originals, key, value) }
            rewritten = events.filter_map { |event| rewrite(event, resolve) }
            overwrite(rewritten) if rewritten.any?
            row_erased, row_copies = erase_row(model, id, replacements, resolve)
            # What the record's own row still holds (a JSON key, inside a
            # longer string), reported as for other records.
            left = [own_left_behind(model, id, originals.keys)].compact
            withheld = withheld?(id, originals.keys)
            log_outcome, log_entries = access_log!(access_streams, erase_log)
            # A key column is never rewritten, so it is not named as erased.
            record_erasure(model, id, stream, (personal | row_copies) - key_columns(model), reason, erased_by,
                           any_fields: any_fields, requested: fields, beyond_policy: any_fields ? personal - declared : [],
                           access_log: log_outcome, access_log_entries: log_entries,
                           access_log_subjects: access_streams.size - 1)
            if everywhere
              # Only the person's own values are searched for elsewhere (from
              # 1.0.0): a third party's email nested under an "email" key in
              # the person's data is erased here, but is not the person's.
              copies, shared, others, rows_only, restricted_copies =
                erase_copies(model, id, stream, origin_state, originals.slice(*own), replacements, reason, erased_by,
                             max_copies)
              left += others
              not_searched = encrypted_columns
            end
            raise ActiveRecord::Rollback if dry_run
          end
        end
        forget_cached(model, id)
        # A dry run's reads may have cached the erased state: drop it.
        touched.each { |m, i| forget_cached(m, i) } if dry_run

        Result.new(model: model.name, id: id, fields: personal, events_rewritten: rewritten.size,
                   row_erased: row_erased, copies: copies, shared_values: shared.size, shared: shared,
                   rows_without_events: rows_only, left_behind: left,
                   not_searched: not_searched, key_withheld: withheld,
                   access_log: log_outcome, access_log_entries: log_entries, dry_run: dry_run, lifting: [],
                   restricted_copies: restricted_copies)
      ensure
        Thread.current[:lyra_erasure_touched] = nil
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

      # Rewrite +events+ in place, and their value-stream links with them
      # (Projections::ReferenceLinks.relink_values): a link named by a digest
      # of an erased unique value is deleted, one of its replacement added.
      def overwrite(events)
        Lyra.config.event_store.overwrite(events)
        Lyra::Projections::ReferenceLinks.relink_values(events)
      end

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

      # A structured column (json, jsonb, an array, a serialized attribute)
      # that is NOT NULL gets its own default, read as the database stores it
      # (an int[] default '{}' is [], a jsonb default '{}' is {}), never a
      # string marker.
      def replacement(model, id, field)
        column = model.columns_hash[field]
        return nil if column.nil? || column.null

        structured = structured?(model, field)
        return "erased:#{id}" if %i[string text].include?(column.type) && !structured
        unless column.default.nil?
          type = model.type_for_attribute(field)
          return structured ? type.deserialize(column.default) : type.cast(column.default)
        end

        raise Unsupported, "#{model.name}.#{field} is NOT NULL with no default; name a replacement by hand"
      end

      # value => the personal field it was found under, for every non-empty
      # string the record's row or events held in a personal field. A plain
      # value, or the strings of an array (an array column, a change's [old,
      # new]), is the person's. Inside a hash (a jsonb declared personal) only
      # the strings that are identifying for the field's type are: an email for
      # :email, a phone number for :phone; a label ("home", "active") is not,
      # or it would be erased wherever it appears. A string under a nested key
      # that is itself a personal field counts as that field's. An earlier
      # erasure's replacement ("erased:<id>") is no one's value.
      #
      # Returns [found, own]. +own+ are the values of the person's own fields:
      # those at the top of a personal field, in the row and in the events
      # (an attribute, either side of a change, a payload entry of one of the
      # record's own CRUD events), with the strings inside a personal structure
      # taken by the rule above. Only those are searched for in other records
      # (everywhere). A value found only deeper, under a personal key nested
      # in the person's data ({"manager" => {"email" => …}} in a payload), is
      # someone else's: it is erased in this record by the key rule, as its
      # events are, but not searched for elsewhere, where it would erase that
      # person's own records (from 1.0.0).
      def original_values(model, id, events, personal)
        found = {}
        own = []
        policy = Lyra::Privacy.policy_for(model)
        types = personal.to_h { |field| [field, policy.annotation(field)&.type&.to_sym] }
        row = model.unscoped.find_by(model.primary_key => id) unless events_only?
        if row
          personal.each do |field|
            value = row.read_attribute(field)
            personal_strings(value, types[field]).each do |v|
              remember(found, v, field)
              own << v
            end
            collect(value, personal, found, types) if value.is_a?(Hash) || value.is_a?(Array)
          end
        end
        events.each do |event|
          data = opened(event.data)
          collect(data, personal, found, types)
          own.concat(top_level_values(data, personal, types, model, id))
        end
        [found, own.uniq & found.keys]
      end

      # The strings of +data+'s personal fields at the top of the record: in a
      # CRUD envelope its attributes, each side of its changes and its
      # payload's entries, when the envelope is the record's own; none otherwise.
      def top_level_values(data, personal, types, model, id)
        return [] unless own_envelope?(data, model, id)

        sections = %w[attributes changes payload].map { |key| data[key] || data[key.to_sym] }
        sections.grep(Hash).flat_map do |section|
          section.flat_map { |key, value| personal.include?(key.to_s) ? personal_strings(value, types[key.to_s]) : [] }
        end
      end

      # Whether +data+ is a CRUD envelope of the record +model+ +id+ itself
      # (Monitor's, Hijack's, a domain event named after its write). Any other
      # event in its stream (an invitation naming a friend's email) holds
      # values the key rule erases there, but they are not the person's own
      # and are not searched for elsewhere (from 1.0.0).
      def own_envelope?(data, model, id)
        return false unless data.is_a?(Hash) && Lyra::Event.recorded_operation(data)

        owner = envelope_model(data)
        record = data[:model_id] || data["model_id"]
        owner && Lyra.stream_owner_name(owner) == Lyra.stream_owner_name(model) && record.to_s == id.to_s
      end

      def personal_strings(value, type)
        case value
        when String then [value]
        when Array then value.flat_map { |inner| personal_strings(inner, type) }
        when Hash then strings_in(value).select { |inner| identifying_string?(inner, type) }
        else []
        end
      end

      EMAIL = /\A[^@\s]+@[^@\s]+\.[^@\s]+\z/

      # Whether +value+, found inside a personal structure of +type+, is
      # itself an identifier of that type.
      def identifying_string?(value, type)
        digits = value.count("0-9")
        case type
        when :email then value.match?(EMAIL)
        when :phone then value.match?(%r{\A\+?[\d\s().\-/]+\z}) && digits.between?(7, 15)
        when :ip_address then ip_address?(value)
        when :credit_card then value.match?(/\A[\d\s-]+\z/) && digits.between?(12, 19)
        when :financial
          value.match?(/\A[A-Z]{2}\d{2}[A-Z0-9 ]{10,32}\z/) || (value.match?(/\A[\d\s-]+\z/) && digits >= 6)
        when :ssn, :identifier, :payment_token, :token, :credential, :online_identifier
          !value.match?(/\s/) && value.length >= 6 && digits.positive?
        else false
        end
      end

      def ip_address?(value)
        require "ipaddr"
        IPAddr.new(value) && value.match?(/[.:]/)
      rescue IPAddr::Error
        false
      end

      def strings_in(value)
        case value
        when Hash then value.values.flat_map { |inner| strings_in(inner) }
        when Array then value.flat_map { |inner| strings_in(inner) }
        when String then [value]
        else []
        end
      end

      def collect(value, personal, found, types)
        case value
        when Hash
          value.each do |key, inner|
            if personal.include?(key.to_s)
              personal_strings(inner, types[key.to_s]).each { |v| remember(found, v, key.to_s) }
            end
            collect(inner, personal, found, types)
          end
        when Array then value.each { |inner| collect(inner, personal, found, types) }
        end
      end

      def remember(found, value, field)
        found[value] ||= field if value.is_a?(String) && !value.empty? && !value.match?(REPLACEMENT)
      end

      # The replacement for +value+ found under +key+ in +model+ +id+'s data,
      # or :keep. Under a personal field's own name, or as a copy of one of
      # its values under any name.
      def resolve_in(model, id, replacements, originals, key, value)
        return replacements[key] if replacements.key?(key)
        return :keep unless value.is_a?(String) && originals.key?(value)

        replacement_for(model, id, key, replacements[originals[value]])
      end

      # A copy held in +model+'s own scalar column gets that column's
      # replacement (so the row and its events agree); elsewhere, inside a
      # structured column included, the origin field's. A structured
      # replacement ([] or {}) never stands for one value inside another: nil.
      def replacement_for(model, id, key, fallback)
        fallback = scalar(fallback)
        return fallback unless model.columns_hash.key?(key) && !structured?(model, key)

        replacement(model, id, key)
      rescue Unsupported
        fallback
      end

      def scalar(value) = value.is_a?(Hash) || value.is_a?(Array) ? nil : value

      # The event with every personal value replaced, or nil if it carried none.
      def rewrite(event, resolve)
        data, changed = scrub_event(event.data, resolve)
        return nil unless changed

        event.class.new(event_id: event.event_id, data: data, metadata: event.metadata.to_h)
      end

      # An event's data. A CRUD envelope (an event that records an operation:
      # Monitor's, Hijack's, a domain event named after a write, a bypass
      # event) is scrubbed as its row is: each of its attributes as a column,
      # each side of each change ([old, new]) as a column, the domain payload
      # entry by entry. Its own entries are never replaced whole, whatever a
      # policy calls its fields. An encrypted attribute's ciphertext is
      # compared in clear, as the row's value is, and a replaced value sealed
      # again. Any other event gets the key rule at its top level too.
      def scrub_event(data, resolve)
        return scrub(data, resolve) unless data.is_a?(Hash) && Lyra::Event.recorded_operation(data)

        model = envelope_model(data)
        encrypted = model ? Lyra::EncryptedAttributes.names(model) : []
        keys = model ? key_columns(model) : []
        changed = false
        copy = data.to_h do |key, value|
          new_value, did = case key.to_s
                           when *ENVELOPE_KEYS then [value, false]
                           when "attributes"
                             scrub_columns(value, resolve, keys) { |c, v| scrub_column(model, encrypted, c, v, resolve) }
                           when "changes"
                             scrub_columns(value, resolve, keys) { |c, v| scrub_change(model, encrypted, c, v, resolve) }
                           when "payload" then scrub(value, resolve)
                           else scrub(value, resolve, key: key.to_s)
                           end
          changed ||= did
          [key, new_value]
        end
        [copy, changed]
      end

      # +keys+: the record's key columns, never rewritten (scrub_row).
      def scrub_columns(values, resolve, keys)
        return scrub(values, resolve) unless values.is_a?(Hash)

        changed = false
        copy = values.to_h do |column, value|
          next [column, value] if keys.include?(column.to_s)

          new_value, did = yield(column.to_s, value)
          changed ||= did
          [column, new_value]
        end
        [copy, changed]
      end

      def scrub_change(model, encrypted, column, change, resolve)
        return scrub_column(model, encrypted, column, change, resolve) unless change.is_a?(Array)

        results = change.map { |side| scrub_column(model, encrypted, column, side, resolve) }
        [results.map(&:first), results.any?(&:last)]
      end

      # One column's value in an event, as the row's is scrubbed.
      def scrub_column(model, encrypted, column, value, resolve)
        return scrub(value, resolve, key: column) unless encrypted.include?(column)

        clear = Lyra::EncryptedAttributes.open(model, { column => value })[column]
        new_value, did = scrub(clear, resolve, key: column)
        did ? [Lyra::EncryptedAttributes.seal_value(model, column, new_value), true] : [value, false]
      end

      # +data+ with an envelope's encrypted attributes in clear, to read
      # values from (never written back).
      def opened(data)
        return data unless data.is_a?(Hash) && Lyra::Event.recorded_operation(data)

        model = envelope_model(data)
        encrypted = model ? Lyra::EncryptedAttributes.names(model) : []
        return data if encrypted.empty?

        open = ->(column, value) { Lyra::EncryptedAttributes.open(model, { column.to_s => value })[column.to_s] }
        data.to_h do |key, value|
          next [key, value] unless value.is_a?(Hash) && %w[attributes changes].include?(key.to_s)

          [key, value.to_h do |column, inner|
            [column, key.to_s == "changes" && inner.is_a?(Array) ? inner.map { open.(column, _1) } : open.(column, inner)]
          end]
        end
      end

      def envelope_model(data)
        name = data[:model_class] || data["model_class"]
        return nil if name.nil?

        model = Lyra.config.monitored_model_named(name) || name.to_s.safe_constantize
        model.is_a?(Class) && model < ActiveRecord::Base ? model : nil
      end

      # [copy of +value+ with personal values replaced, whether any was].
      # A hash or an array under a personal field's own name (a json or array
      # column declared personal) is replaced whole, by the key rule, in the
      # row and in its events alike; one under any other name is recursed
      # into.
      def scrub(value, resolve, key: nil)
        if key && (value.is_a?(Hash) || value.is_a?(Array))
          replaced, changed = scrub_value(value, resolve, key)
          return [replaced, true] if changed
        end

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
          scrub_value(value, resolve, key)
        end
      end

      def scrub_value(value, resolve, key)
        replaced = resolve.call(key, value)
        replaced == :keep || replaced == value ? [value, false] : [replaced, true]
      end

      # The record's aggregate advisory lock, then its row: the locks a writer
      # holds (a Monitor or Hijack write keeps the row until it commits, with its
      # event appended in the same transaction; the other modes take the advisory
      # lock), in Lyra's order, the aggregate lock first (Lyra::AdvisoryLock).
      # Waiting here is what lets an in-flight write finish before the stream is
      # read. Taken the other way round (row, then advisory lock), it deadlocked
      # against a write that skips callbacks, which takes them in this order.
      def lock_record(model, id, stream)
        model.with_connection do |connection|
          Lyra::AdvisoryLock.xact_lock(connection, "lyra_aggregate/#{stream}", purpose: "erasure")
        end
        model.unscoped.lock.find_by(model.primary_key => id) unless events_only?
      end

      # The record's row, every column of it scrubbed with the rule its events
      # got (+resolve+: the origin's key and value rule). That covers the
      # erased fields, any other column that holds one of their values (a
      # username that is the email), and, from 1.0.0, values inside a json,
      # jsonb or array column: 0.9.3 and earlier left those in the row while
      # the events lost them, and the row no longer replayed to its events.
      # Returns [erased?, the changed columns other than the erased fields].
      def erase_row(model, id, replacements, resolve)
        return [false, []] if events_only?

        row = model.unscoped.lock.find_by(model.primary_key => id)
        return [false, []] unless row

        columns = scrub_row(model, row, resolve)
        write_with_lock(model, id, row, columns)
        [true, columns.keys - replacements.keys]
      end

      # The row's columns whose value +resolve+ changes => their new value.
      # Each value is scrubbed as the attribute's type gives it, which is how
      # its events hold it: a hash or an array (json, jsonb, hstore, a
      # PostgreSQL array, a serialized attribute, a text column the model casts
      # as json) is recursed into and written back whole; anything else is one
      # value, so a text column that holds JSON is compared as a string, as in
      # its events. Only the table's columns: a virtual attribute (attribute :x)
      # has none to write. Never a key column (key_columns). An encrypted
      # column is read in clear, as its events are compared, and Active Record
      # encrypts the replacement as it writes it.
      def scrub_row(model, row, resolve)
        keys = key_columns(model)
        row.attributes.slice(*(model.column_names - keys)).each_with_object({}) do |(column, value), changed|
          new_value, did = scrub(value, resolve, key: column)
          changed[column] = new_value if did
        end
      end

      # The primary key and the foreign keys (and polymorphic types): never
      # rewritten. The record's stream is named after its key, and a foreign
      # key is another record's. One that holds an erased value is reported
      # (left_behind), never erased.
      def key_columns(model)
        keys = [model.primary_key.to_s]
        model.reflect_on_all_associations(:belongs_to).each do |reflection|
          keys << reflection.foreign_key.to_s
          keys << reflection.foreign_type.to_s if reflection.polymorphic?
        end
        keys
      end

      # Whether the attribute's type gives a structure (a hash or an array).
      def structured?(model, column)
        definition = model.columns_hash[column]
        return false unless definition
        return true if definition.respond_to?(:array?) && definition.array?

        type = model.type_for_attribute(column)
        %i[json jsonb hstore].include?(type.type) || type.is_a?(ActiveRecord::Type::Serialized)
      end

      # The columns of +model+ +id+'s row that still hold one of +values+
      # anywhere: as a JSON key, or inside a longer string (a text column
      # holding JSON). The erasure replaces whole values only, so those are
      # left; this is what tells them apart from an erased copy.
      # In ES-NoProj, where there is no row, the record's replayed state.
      def columns_holding(model, id, values)
        return [] if values.empty?

        if events_only?
          state = Lyra::DualView.new(model, id).event_sourced_state[:state] || {}
          return state.filter_map { |column, value| column.to_s if holds?(value, values) }
        end

        row = model.unscoped.find_by(model.primary_key => id)
        return [] unless row

        row.attributes.slice(*model.column_names).filter_map do |column, value|
          # citext compares without case, so a copy differing in case is the value there.
          fold = model.columns_hash[column]&.type == :citext
          column if holds?(value, values, fold: fold)
        end
      end

      # The record's own row (or replayed state), as an entry of left_behind,
      # or nil when it holds none of +values+.
      def own_left_behind(model, id, values)
        held = columns_holding(model, id, values)
        { record: label(model, id, values), columns: held } if held.any?
      end

      # "Model id", or "Model <key withheld>" when the key holds one of
      # +values+: a result, a task's output and an ErasureApplied reason never
      # print an erased value.
      def label(model, id, values) = "#{model.name} #{withheld?(id, values) ? WITHHELD : id}"

      def withheld?(id, values) = holds?(id.to_s, values)

      def holds?(value, values, fold: false)
        case value
        when Hash then value.any? { |key, inner| holds?(key.to_s, values, fold: fold) || holds?(inner, values, fold: fold) }
        when Array then value.any? { |inner| holds?(inner, values, fold: fold) }
        when String
          fold ? values.any? { |v| value.downcase.include?(v.downcase) } : values.any? { |v| value.include?(v) }
        else false
        end
      end

      # With everywhere: the encrypted columns of the monitored models. The
      # search is a text match on the stored events, which hold their
      # ciphertext, so a copy there cannot be found; they are named, never
      # searched (decrypting the whole log is not done).
      def encrypted_columns
        Lyra.config.monitored_models.flat_map do |model|
          Lyra::EncryptedAttributes.names(model).map { |column| "#{model.name}.#{column}" }
        end.uniq
      end

      # The erasure is a write, and moves the optimistic lock column as any
      # write does: a copy loaded before it fails with StaleObjectError
      # instead of saving the erased values back. The move is recorded as an
      # ordinary update of that column alone (source lyra_erasure), so every
      # replay (DualView, the mode checks, ES-NoProj reads, rebuilds and
      # projections) gives the row's value. ErasureApplied is not replayed,
      # and the rewritten events keep their place in history, so neither can
      # carry it. A model without optimistic locking gets no such event.
      def write_with_lock(model, id, row, columns)
        return write_columns(model, id, columns) if columns.empty? || !model.locking_enabled?

        lock = model.locking_column
        # In ES-Async the row can trail the log: move from the later of the
        # two, so the log's version sequence never repeats.
        was = [row.read_attribute(lock), logged_version(model, id, lock)].compact.max
        moved = was.to_i + 1
        write_columns(model, id, columns.merge(lock => moved))
        data = Lyra::EventData.build(model, id, :updated, changes: { lock => [was, moved] })
        metadata = { source: SOURCE, lock_moved_by_erasure: true, correlation_id: Lyra::Correlation.current_id }.compact
        event = Lyra::BypassEvents.event_class_for(model, :updated)
                                  .new(data: data, metadata: Lyra::Privacy.stamp(model, data, metadata))
        Lyra.append_events(event, stream_name: Lyra.stream_name(model, id))
      end

      # The version the record's stream last recorded, or nil.
      def logged_version(model, id, lock)
        Lyra.config.event_store.read.stream(Lyra.stream_name(model, id)).backward.each do |event|
          version = Lyra::OptimisticLocking.version_in(event.data, lock.to_s)
          return version unless version.nil?
        end
        nil
      end

      # everywhere: the records other than the erased one that hold its
      # values, found through their events (events_mentioning, one text search
      # of the log for every value) and, from 1.0.0, by searching the tables of
      # monitored models with a policy directly (row_candidates: a row can hold
      # a value its events do not). Returns [records erased, values left as
      # shared ({ field:, type:, holders: }), records left behind, records
      # erased in the row only].
      #
      # A value held by more than +max_copies+ other records is shared by many
      # people, not a copy of this one's: erasing it everywhere erased
      # everyone's (a replay's placeholder address took all 1,954 addresses
      # with it). It is left, and reported. Holders are counted by record:
      # through their events (an exact match on each candidate event) and
      # their rows (the table search's match) alike. The person's linked
      # records (Lyra::Privacy::SubjectLinks: a belongs_to to the erased
      # record's model naming it) do not count (from 1.0.0). A record is
      # listed as erased only if its row, when it has one, no longer holds the
      # value; one whose row still holds it (as a JSON key, inside a longer
      # string, in a key column, in another case in a citext column) is listed
      # as left behind, with the columns, never the value.
      def erase_copies(origin, origin_id, origin_stream, origin_state, originals, replacements, reason, erased_by,
                       max_copies)
        none = [[], [], [], [], []]
        return none if originals.empty?

        policy = Lyra::Privacy.policy_for(origin)
        type_of = ->(field) { policy.annotation(field)&.type&.to_sym }
        originals = originals.select { |_value, field| IDENTIFYING_TYPES.include?(type_of.(field)) }
        return none if originals.empty?

        values = originals.keys
        candidates = events_mentioning(values)
        streams = event_streams(candidates.map(&:event_id))
        candidates = candidates.reject do |event|
          names = streams.fetch(event.event_id, [])
          names.include?(origin_stream) || names.any? { |name| kept_stream?(name) }
        end
        rows = events_only? ? {} : row_candidates(values, origin_stream)

        holders = values.to_h { |value| [value, Set.new] }
        candidates.each do |event|
          data = opened(event.data)
          holder = holder_of(streams.fetch(event.event_id, []))
          values.each { |value| holders[value] << holder if holds_whole?(data, value) }
        end
        rows.each { |stream, row| row[:values].each { |value| holders[value] << stream } }
        linked = nil
        shared = values.filter_map do |value|
          next if holders[value].size <= max_copies

          linked ||= linked_streams(origin, origin_id, origin_state)
          count = (holders[value] - linked).size
          [value, count] if count > max_copies
        end
        report = shared.map { |value, count| { field: originals[value], type: type_of.(originals[value]), holders: count } }
        originals = originals.except(*shared.map(&:first))
        return [[], report, [], [], []] if originals.empty?

        values = originals.keys
        # The candidates for the values erased: a text match without case, as
        # the search was (a citext copy differing in case is reported).
        candidates = candidates.select { |event| holds?(opened(event.data), values, fold: true) }
        by_record = candidates.group_by { |event| record_in(streams.fetch(event.event_id, [])) }
        copy_reason = "#{reason} (copies of #{label(origin, origin_id, values)})"
        copies = []
        left = []
        rows_only = []

        # Events in no monitored record's stream: their events only.
        by_record.each do |(model, _id), events|
          next if model

          rewritten = events.filter_map { |event| rewrite(event, holder_resolve(nil, nil, originals, replacements)) }
          next if rewritten.empty?

          overwrite(rewritten)
          copies << "#{rewritten.size} events"
        end

        targets = by_record.keys.filter_map { |model, id| [Lyra.stream_name(model, id), model, id] if model }
        rows.each { |stream, row| targets << [stream, row[:model], row[:id]] if row[:values].intersect?(values) }
        restricted = []
        targets.uniq(&:first).each do |stream, model, id|
          # A holder under a restriction of processing (Art. 18) keeps its
          # copy until the restriction is lifted: reported, never modified.
          if restricted_holder?(model, id)
            restricted << { record: label(model, id, values), columns: columns_holding(model, id, values) }
            next
          end

          erased, row_only = erase_holder(model, id, stream, originals, replacements, copy_reason, erased_by)
          held = columns_holding(model, id, values)
          name = label(model, id, values)
          left << { record: name, columns: held } if held.any?
          copies << name if erased && held.empty?
          rows_only << name if row_only
        end
        [copies, report, left, rows_only, restricted]
      end

      # Whether a restriction in force covers the holder +model+ +id+ (with
      # PAM DSL's rights; Lyra::Rights::ErasureGuard).
      def restricted_holder?(model, id)
        return false unless defined?(Rights::ErasureGuard) && PamDsl.rights_store.any_active?

        record = Rights::SubjectKeys.find_record(model, id)
        record ? Rights::ErasureGuard.covering_record(record).any? : false
      end

      # The value rule only, for a record other than the erased one: a copy
      # of an erased value is replaced, a third party's value under a
      # personal key is kept.
      def holder_resolve(model, id, originals, replacements)
        lambda do |key, value|
          next :keep unless value.is_a?(String) && originals.key?(value)

          fallback = replacements[originals[value]]
          model ? replacement_for(model, id, key, fallback) : scalar(fallback)
        end
      end

      # One record holding a copy, under its locks (row, then advisory lock),
      # its stream read again: a copy written since the search is in it. Its
      # events are rewritten by the value rule, and its row is scrubbed by the
      # same rule whether or not its events held the value whole (from 1.0.0:
      # a row given the value by raw SQL whose events mention it only inside a
      # longer string, or not at all). When only the row held it, its
      # ErasureApplied says row_only: its row already differed from its
      # replay. A row with no stream is erased and then imported
      # (erase_and_import). Returns [erased?, erased in the row only?].
      def erase_holder(model, id, stream, originals, replacements, reason, erased_by)
        lock_record(model, id, stream)
        events = Lyra.config.event_store.read.stream(stream).to_a
        if events.empty? && !events_only?
          # No Genesis run elsewhere imports the row as it was meanwhile.
          Lyra::Genesis.hold_lock!(model)
          events = Lyra.config.event_store.read.stream(stream).to_a
        end
        resolve = holder_resolve(model, id, originals, replacements)
        return erase_and_import(model, id, stream, resolve, reason, erased_by) if events.empty? && !events_only?

        rewritten = events.filter_map { |event| rewrite(event, resolve) }
        overwrite(rewritten) if rewritten.any?
        copied = erase_copied_columns(model, id, resolve)
        return [false, false] if copied.empty? && rewritten.empty?

        row_only = rewritten.empty?
        record_erasure(model, id, stream, copied, reason, erased_by, row_only: row_only)
        forget_cached(model, id)
        [true, row_only]
      end

      # A row with no stream: erased, then imported the Genesis way, so its
      # Imported event holds the erased values, never the personal ones (an
      # ErasureApplied alone would start a stream Genesis never imports: it
      # imports only rows with no stream), then its ErasureApplied. The lock
      # column moves as with any erasure; the Imported event holds its new
      # value. If the row was imported meanwhile (by a Genesis run on a
      # connection the lock did not hold back), that stream is read again and
      # rewritten instead, and no import is claimed.
      def erase_and_import(model, id, stream, resolve, reason, erased_by)
        row = model.unscoped.lock.find_by(model.primary_key => id)
        return [false, false] unless row

        columns = scrub_row(model, row, resolve)
        return [false, false] if columns.empty?

        lock = model.locking_enabled? ? model.locking_column : nil
        write_columns(model, id, lock ? columns.merge(lock => row.read_attribute(lock).to_i + 1) : columns)
        imported = Lyra::Genesis.import_one(model, id)
        unless imported
          rewritten = Lyra.config.event_store.read.stream(stream).to_a.filter_map { |event| rewrite(event, resolve) }
          overwrite(rewritten) if rewritten.any?
        end
        record_erasure(model, id, stream, columns.keys, reason, erased_by, imported: imported)
        forget_cached(model, id)
        [true, false]
      end

      # event_id => the streams the event is in, in one query.
      def event_streams(event_ids)
        return {} if event_ids.empty?

        ActiveRecord::Base.with_connection do |conn|
          event_ids.each_slice(1_000).flat_map do |ids|
            conn.select_rows("SELECT event_id, stream FROM event_store_events_in_streams " \
                             "WHERE event_id IN (#{ids.map { |i| conn.quote(i) }.join(', ')})")
          end.group_by(&:first).transform_values { |rows| rows.map(&:last) }
        end
      end

      # The holder an event counts for: the monitored record whose stream it is
      # in (so a reference link, Model.fk$id, adds none), else its stream.
      def holder_of(names)
        model, id = record_in(names)
        model ? Lyra.stream_name(model, id) : names.min
      end

      # [model, id] of the monitored record whose stream is among +names+, else [nil, nil].
      def record_in(names)
        names.each do |name|
          model_name, id = name.split("$", 2)
          model = Lyra.config.monitored_model_named(model_name)
          return [model, id] if model && id
        end
        [nil, nil]
      end

      # "%"…"%": +value+ as a JSON string, quotes included, for a LIKE on a
      # json or jsonb column as text: it matches the value whole, as a value
      # or a key, not inside a longer one.
      def json_pattern(value)
        "%#{ActiveRecord::Base.sanitize_sql_like(JSON.generate(value))}%"
      end

      # The streams of the person's linked records, by the rule of the
      # subject-access copy (Lyra::Privacy::SubjectLinks): the records of
      # monitored models with a belongs_to to +origin+'s model (any
      # association: an owner, an assignee, a manager), a polymorphic one with
      # its type column naming it, or a <model>_id column no association owns,
      # whose foreign key holds the origin's id, or the column the belongs_to
      # names as its primary_key (+origin_state+: the origin as it was before
      # this erasure). Records of the origin's own model are not linked. They
      # are taken as the person's own for the threshold only (they do not
      # count toward max_copies); they are erased as any holder is. Each query
      # runs in a savepoint: one that fails finds none.
      def linked_streams(origin, origin_id, origin_state)
        links = Lyra::Privacy::SubjectLinks.new(Lyra.stream_owner_name(origin))
        links.linked_models.each_with_object(Set.new) do |model, linked|
          links.for(model).each do |link|
            target = link_target(model, link, origin, origin_id, origin_state)
            next if target.nil?

            scope = model.unscoped.where(link.fk => target)
            scope = scope.where(link.type_column => link.type_value) if link.type_column
            ids = model.transaction(requires_new: true) { scope.pluck(model.primary_key) }
            ids.each { |id| linked << Lyra.stream_name(model, id) }
          rescue StandardError
            next
          end
        end
      end

      # What +link+'s foreign key holds for the origin: its id, or the value of
      # the column a belongs_to names with primary_key:.
      def link_target(model, link, origin, origin_id, origin_state)
        reflection = model.reflect_on_all_associations(:belongs_to)
                          .find { |r| !r.polymorphic? && r.foreign_key.to_s == link.fk }
        column = reflection&.association_primary_key.to_s
        return origin_id if column.empty? || column == origin.primary_key.to_s

        origin_state[column]
      end

      # The origin's attributes as they are now (its replayed state in
      # ES-NoProj), keyed by column name.
      def current_state(model, id)
        if events_only?
          state = Lyra::DualView.new(model, id).event_sourced_state[:state] || {}
          return state.transform_keys(&:to_s)
        end

        model.unscoped.find_by(model.primary_key => id)&.attributes || {}
      end

      # From 1.0.0, with everywhere: the rows of monitored models with a
      # policy that may hold one of +values+, searched in the tables
      # themselves, so a row whose events lack the value (raw SQL, a write
      # before monitoring, a write Lyra could not intercept) is found too.
      # One query per table, which returns the keys and, per value, whether
      # the row matched; no row is loaded here. String and text columns by
      # equality (a citext column without case), json and jsonb columns as text
      # by a LIKE on the value as a JSON string (a value or a key), a text
      # column the model reads as a structure (serialized, attribute :json) by
      # a LIKE on the bare value, string arrays with = ANY, hstore values with
      # = ANY(avals(…)). Encrypted columns are not searched (not_searched). The
      # erasure itself matches exactly, and reports what it cannot erase.
      # Returns { stream => { model:, id:, values: [matched] } } without the
      # origin's own row.
      def row_candidates(values, origin_stream)
        searched_models.each_with_object({}) do |model, found|
          model.with_connection do |conn|
            encrypted = Lyra::EncryptedAttributes.names(model)
            columns = model.columns.reject { |column| encrypted.include?(column.name) }
            conditions = values.map do |value|
              clauses = columns.filter_map { |column| search_clause(conn, model, column, value) }
              clauses.empty? ? "FALSE" : "(#{clauses.join(' OR ')})"
            end
            next if conditions.all?("FALSE")

            flags = conditions.each_with_index.map { |condition, i| "#{condition} AS v#{i}" }
            conn.select_rows(<<~SQL.squish).each do |id, *matched|
              SELECT #{conn.quote_column_name(model.primary_key)}, #{flags.join(', ')}
              FROM #{conn.quote_table_name(model.table_name)}
              WHERE #{conditions.join(' OR ')}
            SQL
              stream = Lyra.stream_name(model, id)
              next if stream == origin_stream

              held = values.select.with_index { |_value, i| [true, "t"].include?(matched[i]) }
              found[stream] = { model: model, id: id, values: held }
            end
          end
        end
      end

      # The monitored models with a policy, one per table, as the class that
      # owns it (the STI base class, so no type condition narrows the rows):
      # the tables of models without a policy, or not monitored, are not
      # searched.
      def searched_models
        Lyra.config.monitored_models
                    .select { |model| Lyra::Privacy.policy_for(model).loaded? }
                    .map { |model| model.respond_to?(:base_class) ? model.base_class : model }
                    .uniq(&:table_name)
                    .select(&:table_exists?)
      end

      TEXT_TYPES = %i[string text citext].freeze

      # The condition +column+ holds +value+, or nil for a column not searched.
      def search_clause(conn, model, column, value)
        name = conn.quote_column_name(column.name)
        quoted = conn.quote(value)
        if column.respond_to?(:array?) && column.array?
          "#{quoted} = ANY(#{name})" if TEXT_TYPES.include?(column.type)
        elsif %i[json jsonb].include?(column.type)
          "#{name}::text LIKE #{conn.quote(json_pattern(value))}"
        elsif column.type == :hstore
          "#{quoted} = ANY(avals(#{name}))"
        elsif TEXT_TYPES.include?(column.type) && structured?(model, column.name)
          "#{name} LIKE #{conn.quote("%#{ActiveRecord::Base.sanitize_sql_like(value)}%")}"
        elsif TEXT_TYPES.include?(column.type)
          "#{name} = #{quoted}"
        end
      end

      def holds_whole?(value, wanted)
        case value
        when Hash then value.any? { |_key, inner| holds_whole?(inner, wanted) }
        when Array then value.any? { |inner| holds_whole?(inner, wanted) }
        when String then value == wanted
        else false
        end
      end

      # The events whose stored data mentions one of +values+: one text search
      # of the log for all of them, without case (a citext column holds a copy
      # that differs in case; the match that erases is exact, and such a copy
      # is reported). Read in batches.
      def events_mentioning(values)
        ActiveRecord::Base.with_connection do |conn|
          clauses = values.map do |value|
            "convert_from(data, 'UTF8') ILIKE #{conn.quote("%#{ActiveRecord::Base.sanitize_sql_like(value)}%")}"
          end
          ids = conn.select_values("SELECT event_id FROM event_store_events WHERE #{clauses.join(' OR ')}")
          ids.each_slice(1_000).flat_map { |batch| Lyra.config.event_store.read.events(batch).to_a }
        end
      end

      # The columns of +model+ +id+'s row that hold an erased value, replaced
      # by the rule its events got (+resolve+: the value rule only, so a third
      # party's email under an "email" key is kept), inside json, jsonb and
      # array columns too (scrub_row). Returns the column names.
      def erase_copied_columns(model, id, resolve)
        return [] if events_only?

        row = model.unscoped.lock.find_by(model.primary_key => id)
        return [] unless row

        columns = scrub_row(model, row, resolve)
        write_with_lock(model, id, row, columns)
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
      # +row_only+: the value was in the row, not in the record's events, and
      # only the row was erased; +imported+: the row had no stream, and was
      # imported after it was erased (both from 1.0.0, with everywhere).
      def record_erasure(model, id, stream, fields, reason, erased_by, any_fields: false, requested: nil, beyond_policy: [],
                         access_log: nil, access_log_entries: nil, access_log_subjects: 0, row_only: false, imported: false)
        data = { model_class: model.name, model_id: id, fields: fields, reason: reason.to_s, erased_at: Time.current,
                 any_fields: any_fields, requested_fields: requested&.map(&:to_s), beyond_policy: beyond_policy }
        data.merge!(access_log: access_log, access_log_entries: access_log_entries) if access_log
        data[:access_log_subjects] = access_log_subjects if access_log_subjects.positive?
        data[:row_only] = true if row_only
        data[:imported] = true if imported
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
        Thread.current[:lyra_erasure_touched]&.push([model, id])
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
