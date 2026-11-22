# frozen_string_literal: true

module Lyra
  # Genesis: event streams for rows that existed before Lyra recorded them.
  #
  # A table row written before Lyra was enabled has no stream. Its first
  # Updated event would then start a stream with no head, and everything that
  # rebuilds state from events -- DualView, Rebuild, ES-NoProj reads and their
  # aggregates (count, sum, average, minimum, maximum) -- would see the record
  # wrongly or not at all.
  #
  # Genesis gives each such row one Imported event, carrying the row exactly as
  # it is (timestamps included). Imported is replayed like Created, but says
  # what happened: the record was adopted, not created at that moment.
  #
  # It runs on a model's first use in a process, not ahead of time:
  # - the first write to the model (any event-producing mode), before the
  #   write's own event, so the Imported event holds the row as it was;
  # - in ES-NoProj, the first read of the model (find, where, all, count, sum,
  #   ...), before the record set is assembled, so that every answer, the SQL
  #   aggregates included, is computed from streams alone.
  # The first use imports every row of the model that has no stream; each later
  # use costs nothing. For a large table, run `rake lyra:genesis` before
  # enabling a mode, so the first request does not pay for it.
  #
  # Concurrency: the import runs under a per-model PostgreSQL advisory lock
  # and selects only rows whose stream is still empty, so two processes never
  # import a row twice. When the caller is inside a transaction, the import
  # runs on a connection of its own and commits there: the lock is held only
  # while importing, not until the caller commits (a long transaction would
  # otherwise block every other first use of the model), and the Imported
  # events stand whether the caller commits or rolls back -- they record rows
  # that already existed, not the caller's write. Where no second connection
  # can be had (Rails' transactional tests pin one; a pool may have none
  # free), the import runs in the caller's transaction and the model counts as
  # imported only once it commits (Lyra::OwnConnection).
  #
  # Enabled with config.genesis: :auto (the default) runs it in event-sourcing
  # mode, where the event log is the only source of truth; true also runs it in
  # Monitor and Hijack modes (for DualView and Rebuild); false never runs it.
  #
  # Values the model cannot represent (from 1.0.0). The Imported event holds
  # the row as the model reads it. A stored value the model cannot read --
  # refund_requests.status = '2' under a string enum without that value, which
  # the model reads as nil -- would give an event that disagrees with its row,
  # and the disagreement would surface later and elsewhere (an ES-Lazy
  # catch-up writing NULL into a NOT NULL column). So every attribute of every
  # row is checked first (loss): the value the model reads, written back by
  # the model's type, must be the value stored, compared as the column's own
  # type reads both or as the database would be sent them. '1' and 1, a
  # timestamp and its time zone, a time of day, a decimal's trailing zeros or
  # a jsonb object's key order are no difference; a lossy reading is (an enum
  # value outside the mapping, `attribute :n, :integer` over 10.50, an inet
  # value's host bits, which Rails drops, also in an inet[] array, a value out
  # of the model's integer range). Whatever the type, a stored value the model
  # writes back as NULL is lost, in a nullable column too: a JSON null in a
  # json/jsonb column, an empty range, a blank or 'null' JSON text or an empty
  # YAML hash in a serialized column (read as nil or {}). A serialized,
  # encrypted or JSON attribute's stored text is otherwise one of many
  # encodings of its value (JSON whitespace, a fresh ciphertext), so its text
  # is not compared; a value of another class is. Columns the model ignores
  # are imported as stored and not checked.
  #
  # What happens to such rows is config.genesis_unrepresentable (or the
  # +unrepresentable:+ argument of import and import_all):
  # - :refuse (default): every row is checked before anything is written, and
  #   the model's import raises Refused, listing the rows (model, id,
  #   attribute, stored value, value read; at most LISTED of them, with the
  #   count): nothing of the model is imported. The import runs in a savepoint
  #   inside a caller's transaction, so a caller that rescues the refusal
  #   commits nothing of it either. Fix the rows or the model, then import
  #   again. A refused first use is remembered for REFUSAL_RECHECK seconds
  #   from the scan that found it: the uses meanwhile raise it again without
  #   scanning; an explicit import (lyra:genesis) always scans. At a gated
  #   mode switch the refusal refuses the switch (ModeTransition);
  # - :skip: those rows are left without a stream and the rest is imported;
  #   import's Result and `lyra:genesis` list them, and the log warns. A write
  #   to a skipped row -- through callbacks (update!, destroy!) or bypassing
  #   them (update_columns, touch, update_all, touch_all, delete_all,
  #   upsert_all, ...; admit_all!) -- or an ES-NoProj find of it, imports it
  #   if the model can now represent it, and is refused (Refused, naming the
  #   rows) while it cannot: its stream would otherwise begin with the
  #   write's event. A query over many records (where, count) does not see
  #   it. So a skipped row is fixed in the database (SQL), not through the
  #   model; the next use of it, or lyra:genesis, then imports it.
  # A process imports on its own first use of a model and keeps what it
  # skipped: a row written outside Lyra (SQL) after that first use, or
  # skipped by another process, is unknown to it until lyra:genesis imports
  # it. Values of attributes the model's privacy policy declares, or
  # encrypted ones, are not shown in the listing.
  module Genesis
    BATCH = 1_000
    OPERATION = :imported
    LISTED = 20

    # One stored value the model cannot represent: +stored+ as the row holds
    # it, +read_as+ as the model reads it (and the Imported event would hold
    # it). +reason+: nil (the value read writes back to another value),
    # :null (it would be written back as NULL),
    # :out_of_range (the model's type cannot hold it), or a String. +personal+:
    # the values are not shown.
    Unrepresentable = Struct.new(:model, :id, :attribute, :stored, :read_as, :personal, :reason, keyword_init: true) do
      def details
        shown = personal ? "#{attribute} (a personal value, not shown)" : "#{attribute} stored #{stored.inspect}"
        read = personal ? "" : ", read as #{read_as.inspect}"
        case reason
        when nil then "#{shown}#{read}"
        when :null then "#{shown}#{read}, which would be written back as NULL"
        when :out_of_range then "#{shown}: out of range for the model's type"
        else "#{shown}: #{reason}"
        end
      end

      def to_s = "#{model} #{id}: #{details}"
    end

    # The model holds rows it cannot represent; nothing of it was imported.
    # +rows+: how many rows; +values+: the first LISTED Unrepresentable values
    # of the +found+ in all. +id+: a row an import skipped, refused on a write
    # or read of it (see admit!), or the rows (an Array) a bulk write would
    # have written (admit_all!).
    class Refused < StandardError
      attr_reader :model, :rows, :values, :found, :id

      def initialize(model, rows:, values:, found:, id: nil)
        @model = model
        @rows = rows
        @values = values
        @found = found
        @id = id
        listing = "#{values.map(&:to_s).join('; ')}#{" (and #{found - values.size} more)" if found > values.size}"
        super(if id
                "Lyra::Genesis left #{model} #{Array(id).join(', ')} without events (genesis_unrepresentable :skip): " \
                  "#{id.is_a?(Array) ? 'they hold' : 'it holds'} values the model cannot represent, so a write or read " \
                  "would start a stream without its state. Fix the row in the database (SQL) or the model; the next " \
                  "use imports it. #{listing}"
              else
                "Lyra::Genesis will not import #{model}: #{rows} row(s) hold values the model cannot represent, so " \
                  "their Imported events would not match them. Fix the rows or the model; or skip those rows " \
                  "(config.genesis_unrepresentable = :skip, or UNREPRESENTABLE=skip for lyra:genesis). #{listing}"
              end)
      end
    end

    # What import did: +imported+ rows; +skipped+ rows the model cannot
    # represent (with :skip), and the first LISTED of their values.
    Result = Struct.new(:model, :imported, :skipped, :unrepresentable, keyword_init: true) do
      def summary
        "#{model}: #{imported} rows imported#{", #{skipped} skipped (values the model cannot represent)" if skipped.positive?}"
      end
    end

    # How an attribute's value goes back to its column (round_trip_type).
    RoundTripType = Struct.new(:column, :writer, :opaque, :enum, :inet)
    private_constant :RoundTripType

    # A refused first use is not repeated for this long (seconds): the next
    # uses raise the same refusal without scanning the table again. An
    # explicit import (lyra:genesis) always scans.
    REFUSAL_RECHECK = 30

    @imported = {}
    @skipped = {}
    @refused = {}
    @mutex = Mutex.new

    class << self
      def enabled?
        case Lyra.config.genesis
        when true then !Lyra.disabled_mode?
        when false, nil then false
        else Lyra.event_sourcing_mode?
        end
      end

      # Import +model_class+'s rows without a stream, once per process.
      # Returns the number of rows imported by this call. +id+: the row about
      # to be written or read, refused if an import skipped it and it still
      # holds values the model cannot represent (admit!).
      def first_use(model_class, id = nil)
        return 0 unless enabled?
        return 0 if Thread.current[:lyra_genesis_running]

        count = 0
        unless imported?(model_class)
          # Raised here, not in import_on_first_use, whose rescue would store
          # it again as new: a busy process would then never scan again.
          if (refusal = recent_refusal(model_class))
            raise Refused.new(refusal.model, rows: refusal.rows, values: refusal.values, found: refusal.found)
          end

          count = import_on_first_use(model_class)
        end
        admit!(model_class, id) unless id.nil?
        count
      end

      # Before a write that bypasses callbacks and records an event per row
      # (update_all, update_columns, touch, delete_all, upsert_all, ...): the
      # model's first use, as for a write through callbacks, and then admit!
      # for each of +ids+ the import skipped. Rows the model can now represent
      # are imported first; the write is refused (Refused, naming the rows)
      # if any still cannot be, so a bypass event never begins a stream. Costs
      # nothing more than first_use while no row was skipped.
      def admit_all!(model_class, ids)
        return unless enabled?
        return if Thread.current[:lyra_genesis_running]

        first_use(model_class)
        return if @skipped.empty?

        refusals = ids.filter_map do |id|
          next unless skipped?(model_class, id)

          admit!(model_class, id)
          nil
        rescue Refused => e
          e
        end
        return if refusals.empty?

        values = refusals.flat_map(&:values)
        raise Refused.new(model_class.name, rows: refusals.size, values: values.first(LISTED),
                                            found: refusals.sum(&:found),
                                            id: refusals.one? ? refusals.first.id : refusals.map(&:id))
      end

      # Import every row of +model_class+ that has no stream, now, whatever the
      # mode. Returns the number of rows imported (see import for the rest).
      def import_all(model_class, unrepresentable: Lyra.config.genesis_unrepresentable)
        import(model_class, unrepresentable: unrepresentable).imported
      end

      # Import every row of +model_class+ that has no stream, now, whatever the
      # mode, in one transaction (a savepoint inside the caller's). With
      # +unrepresentable+ :refuse every row is checked first, and one holding
      # a value the model cannot represent (see above) raises Refused before
      # anything is written; with :skip such rows are left out, and refused
      # on a later write or read (admit!). Returns a Result.
      def import(model_class, unrepresentable: Lyra.config.genesis_unrepresentable)
        skip = unrepresentable_choice(unrepresentable) == :skip
        running = Thread.current[:lyra_genesis_running]
        Thread.current[:lyra_genesis_running] = true
        imported = []
        skipped = []
        listed = []
        found = 0

        model_class.with_connection do |connection|
          model_class.transaction(requires_new: true) do
            lock!(connection, model_class)
            types = {}
            unless skip
              bad = 0
              each_row_without_stream(connection, model_class) do |record, row, attributes|
                problems = unrepresentable_values(connection, types, record, row, attributes)
                next if problems.empty?

                bad += 1
                found += problems.size
                listed.concat(problems.first(LISTED - listed.size))
              end
              raise Refused.new(model_class.name, rows: bad, values: listed, found: found) if bad.positive?
            end

            each_row_without_stream(connection, model_class) do |record, row, attributes|
              problems = unrepresentable_values(connection, types, record, row, attributes)
              if problems.empty?
                imported << import_record(model_class, record, attributes)
              elsif skip
                skipped << record.id.to_s
                found += problems.size
                listed.concat(problems.first(LISTED - listed.size))
              else
                # Changed since the check above; rolls back what was imported.
                raise Refused.new(model_class.name, rows: 1, values: problems.first(LISTED), found: problems.size)
              end
            end
          end
        end

        @mutex.synchronize do
          skipped.empty? ? @skipped.delete(owner(model_class)) : @skipped[owner(model_class)] = skipped.to_set
          @refused.delete(owner(model_class))
        end
        forget_cached(model_class, imported)
        warn_unrepresentable(model_class, skipped.size, listed, found) if skipped.any?
        Result.new(model: model_class.name, imported: imported.size, skipped: skipped.size, unrepresentable: listed)
      ensure
        Thread.current[:lyra_genesis_running] = running
      end

      # Import the one row +id+ of +model_class+ if it still has no stream, now,
      # whatever the mode, under the model's Genesis lock (see hold_lock!).
      # Lyra::Erasure imports a row it erased that had no stream, so that the
      # Imported event holds the erased values, never the personal ones (from
      # 1.0.0). Returns whether it imported the row. A value the model cannot
      # represent is logged, not refused: an erasure must not fail on it.
      def import_one(model_class, id)
        running = Thread.current[:lyra_genesis_running]
        Thread.current[:lyra_genesis_running] = true
        model_class.with_connection do |connection|
          lock!(connection, model_class)
          row = rows_without_stream(connection, model_class, nil, limit: 1, id: id).first
          record, attributes = read_row(model_class, row) if row
          next false if record.nil? || record.id.nil?

          problems = unrepresentable_values(connection, {}, record, row, attributes)
          warn_unrepresentable(model_class, 0, problems, problems.size) if problems.any?
          forget_cached(model_class, [import_record(model_class, record, attributes)])
          forget_skipped(model_class, id)
          true
        end
      ensure
        Thread.current[:lyra_genesis_running] = running
      end

      # Before a write to, or a read of, the row +id+: if an import skipped it
      # (:skip), import it now when the model can represent it, or else raise
      # Refused for it. Its stream would otherwise begin with the write's
      # Updated event, no Imported event giving the rest of its state, and an
      # ES-NoProj read would build a partial record from it.
      def admit!(model_class, id)
        return unless skipped?(model_class, id)

        inline = Lyra::OwnConnection.run(model_class) do |in_caller_transaction|
          import_skipped(model_class, id)
          in_caller_transaction
        end
        forget = -> { forget_skipped(model_class, id) }
        inline ? Lyra::OwnConnection.after_commit(model_class, &forget) : forget.call
      end

      # Whether an import in this process skipped the row +id+ (:skip).
      def skipped?(model_class, id)
        return false if @skipped.empty? # every write asks: no lock while nothing was skipped

        @mutex.synchronize { @skipped[owner(model_class)]&.include?(id.to_s) || false }
      end

      # Take +model_class+'s Genesis lock until the caller's transaction ends: no
      # Genesis run imports one of its rows meanwhile. Lyra::Erasure takes it
      # before erasing a row with no stream, so no import elsewhere reads the row
      # as it was.
      def hold_lock!(model_class)
        model_class.with_connection { |connection| lock!(connection, model_class) }
      end

      def imported?(model_class)
        @mutex.synchronize { @imported.key?(model_class.name) }
      end

      # Forget which models were imported, which rows were skipped and which
      # imports were refused (tests, or after the event store or the tables
      # were reset).
      def reset!
        @mutex.synchronize do
          @imported.clear
          @skipped.clear
          @refused.clear
        end
      end

      # The stored values of +record+, as loaded from its row and not changed
      # since, that its model does not represent (the check above), as
      # Unrepresentable; only those of +columns+ if given. Lyra::Repair checks
      # what it writes into an event this way (from 1.0.0).
      def unrepresentable(record, columns: nil)
        row = record.attributes_before_type_cast
        row = row.slice(*columns.map(&:to_s)) if columns
        attributes = record.attributes
        record.class.with_connection { |connection| unrepresentable_values(connection, {}, record, row, attributes) }
      end

      # :refuse or :skip; a string (from ENV, say) is taken as its symbol.
      def unrepresentable_choice(value)
        choice = value.is_a?(String) ? value.strip.to_sym : value
        return choice if Lyra::Configuration::GENESIS_UNREPRESENTABLE.include?(choice)

        raise ArgumentError, "unrepresentable must be :refuse or :skip (got #{value.inspect})"
      end

      private

      # The first use's import. Usually every row already has a stream: then
      # nothing is written and no lock is needed. The model counts as done
      # once the caller's transaction, if any, commits: the streams it sees
      # may be an inline import's, uncommitted in that transaction (see
      # below). A refusal is remembered for REFUSAL_RECHECK seconds.
      def import_on_first_use(model_class)
        if model_class.with_connection { |c| rows_without_stream(c, model_class, nil, limit: 1) }.empty?
          Lyra::OwnConnection.after_commit(model_class) { mark_imported(model_class) }
          return 0
        end

        # On a connection of its own when the caller is in a transaction; in
        # the caller's transaction where none can be had (a pinned test
        # connection, a pool with none free), and then done only at commit.
        inline = false
        count = Lyra::OwnConnection.run(model_class) do |in_caller_transaction|
          inline = in_caller_transaction
          import_all(model_class)
        end
        mark = -> { mark_imported(model_class) }
        inline ? Lyra::OwnConnection.after_commit(model_class, &mark) : mark.call
        count
      rescue Refused => e
        @mutex.synchronize { @refused[owner(model_class)] = [Process.clock_gettime(Process::CLOCK_MONOTONIC), e] } if e.id.nil?
        raise
      end

      def recent_refusal(model_class)
        at, refusal = @mutex.synchronize { @refused[owner(model_class)] }
        refusal if at && Process.clock_gettime(Process::CLOCK_MONOTONIC) - at < REFUSAL_RECHECK
      end

      # admit!'s import of one skipped row, under the Genesis lock.
      def import_skipped(model_class, id)
        running = Thread.current[:lyra_genesis_running]
        Thread.current[:lyra_genesis_running] = true
        model_class.with_connection do |connection|
          model_class.transaction(requires_new: true) do
            lock!(connection, model_class)
            row = rows_without_stream(connection, model_class, nil, limit: 1, id: id).first
            record, attributes = read_row(model_class, row) if row
            next if record.nil? || record.id.nil? # imported meanwhile, or gone

            problems = unrepresentable_values(connection, {}, record, row, attributes)
            if problems.any?
              raise Refused.new(model_class.name, rows: 1, values: problems.first(LISTED), found: problems.size, id: id)
            end

            forget_cached(model_class, [import_record(model_class, record, attributes)])
          end
        end
      ensure
        Thread.current[:lyra_genesis_running] = running
      end

      def forget_skipped(model_class, id)
        @mutex.synchronize do
          rows = @skipped[owner(model_class)]
          rows&.delete(id.to_s)
          @skipped.delete(owner(model_class)) if rows&.empty?
        end
      end

      # Skipped rows and refusals are kept per table (its stream owner): an STI
      # subclass shares its base class's rows.
      def owner(model_class) = Lyra.stream_owner_name(model_class)

      # Each row of +model_class+ without a stream, in batches, as the model
      # reads it: yields the record, the row and the record's attributes.
      def each_row_without_stream(connection, model_class)
        after = nil
        loop do
          rows = rows_without_stream(connection, model_class, after)
          break if rows.empty?

          rows.each do |row|
            record, attributes = read_row(model_class, row)
            yield record, row, attributes unless record.id.nil?
          end
          after = rows.last[model_class.primary_key]
        end
      end

      def mark_imported(model_class)
        @mutex.synchronize { @imported[model_class.name] = true }
      end

      def rows_without_stream(connection, model_class, after, limit: BATCH, id: nil)
        # A primary key of several columns (a model enrolled before Active
        # Record read its key): Lyra's refusal (ArgumentError), before the
        # query fails on it (PG::UndefinedColumn) and takes the transaction
        # it is in with it.
        Lyra::ModelSelection.refuse_composite_key!(model_class) if model_class.primary_key.is_a?(Array)
        table = connection.quote_table_name(model_class.table_name)
        pk = connection.quote_column_name(model_class.primary_key)
        prefix = connection.quote(Lyra.stream_prefix(model_class))
        keyset = after.nil? ? "" : "AND t.#{pk} > #{connection.quote(after)}"
        keyset += " AND t.#{pk} = #{connection.quote(id)}" unless id.nil?

        connection.select_all(<<~SQL.squish).to_a
          SELECT t.* FROM #{table} t
          WHERE NOT EXISTS (
            SELECT 1 FROM event_store_events_in_streams s
            WHERE s.stream = #{prefix} || CAST(t.#{pk} AS VARCHAR)
          ) #{keyset}
          ORDER BY t.#{pk} LIMIT #{Integer(limit)}
        SQL
      end

      # The row as the model reads it: the record and its attributes.
      def read_row(model_class, row)
        record = Lyra::PurposeBoundReads.internal(INTERNAL) { model_class.instantiate(row) }
        [record, record.id.nil? ? nil : record.attributes]
      end

      def import_record(model_class, record, attributes)
        data = Lyra::EventData.build(model_class, record.id, OPERATION, attributes: attributes)
        event = event_class(model_class).new(data: data, metadata: Lyra::Privacy.stamp(model_class, data, { genesis: true }))
        # The lock and the NOT EXISTS above make the stream empty here.
        stream_name = Lyra.stream_name(model_class, record.id)
        Lyra.append_events(event, stream_name: stream_name)
        # The has_and_belongs_to_many links the row already has.
        Associations::HabtmLinks.import(model_class, record.id, stream_name)
        record.id
      end

      # The values of +row+ that +record+, the model's reading of it, does not
      # represent (see the module comment), as Unrepresentable. +types+ caches
      # each attribute's types for one import.
      def unrepresentable_values(connection, types, record, row, attributes)
        klass = record.class
        row.filter_map do |name, stored|
          next if stored.nil?

          type = types.fetch([klass, name]) { types[[klass, name]] = round_trip_type(connection, klass, name) }
          next if type.nil?

          reason = loss(connection, type, stored, attributes[name])
          next if reason.nil?

          personal = (types[[klass, :personal]] ||= personal_attributes(klass)).include?(name)
          Unrepresentable.new(model: klass.name, id: record.id, attribute: name, stored: stored,
                              read_as: attributes[name], personal: personal, reason: (reason unless reason == :value))
        end
      end

      # How +name+'s value goes back to its column: +column+, the column's own
      # type (no enum, serializer, encryption or time zone); +writer+, the
      # model's type without normalizes (which applies to assignment, not to a
      # value read); +opaque+, a serialized, encrypted or JSON attribute (a
      # stored text of many encodings); +enum+, an enum; +inet+, a PostgreSQL
      # inet column or array of inet. nil for a column the model ignores.
      def round_trip_type(connection, klass, name)
        column = klass.columns_hash[name]
        return nil if column.nil?

        type = klass.attribute_types[name]
        column_type = if column.respond_to?(:fetch_cast_type)
                        column.fetch_cast_type(connection)
                      else
                        connection.lookup_cast_type_from_column(column)
                      end
        writer = type
        writer = writer.cast_type while writer.class.name.to_s.end_with?("NormalizedValueType") && writer.respond_to?(:cast_type)
        chain = type_chain(type)
        opaque = chain.any? do |t|
          t.is_a?(ActiveRecord::Type::Serialized) || t.is_a?(ActiveRecord::Type::Json) ||
            t.class.name == "ActiveRecord::Encryption::EncryptedAttributeType"
        end
        inet = type_chain(column_type).any? { |t| t.class.name.to_s.end_with?("::OID::Inet") }
        RoundTripType.new(column_type, writer, opaque, chain.any? { |t| t.is_a?(ActiveRecord::Enum::EnumType) }, inet)
      end

      # +type+ and the types it decorates (time zone, enum, serializer,
      # encryption, normalizes, array element).
      def type_chain(type)
        chain = []
        while type && chain.size < 8
          chain << type
          type = if type.respond_to?(:cast_type) then type.cast_type
                 elsif type.respond_to?(:subtype) then type.subtype
                 elsif type.is_a?(Delegator) then type.__getobj__
                 end
        end
        chain
      end

      # nil if +read_as+ writes back to +stored+ (not NULL: the caller skips
      # NULLs): equal as the column's own type reads them, or as the database
      # would be sent them (a time of day read in another time zone carries
      # another date, which the column does not keep). Otherwise why not (see
      # Unrepresentable#reason; :value: it writes back to another value).
      #
      # Whatever the type, a value the model writes back as NULL is lost: an
      # enum value outside the mapping, a JSON null in a json/jsonb column, an
      # empty range, a blank or 'null' JSON text or an empty YAML hash in a
      # serialized column (read as nil or {}, written back as NULL), into a
      # nullable column too (where(col: nil) would then find the row).
      #
      # A serialized, encrypted or JSON attribute's stored text is one of many
      # encodings of its value (JSON whitespace, a fresh ciphertext), so a
      # re-encoding need not equal it: there it is checked that the value
      # comes back (not NULL, above, and not a value of another class).
      def loss(connection, type, stored, read_as)
        serialized = begin
          type.writer.serialize(read_as)
        rescue ActiveModel::RangeError
          return :out_of_range
        rescue StandardError => e
          return "cannot be written back (#{e.class})"
        end
        return :value if type.enum && read_as.nil?
        return :null if serialized.nil?

        stored_value = type.column.deserialize(stored)
        if same_written?(connection, type.column, stored_value, serialized)
          return type.inet && host_bits_lost?(stored, stored_value) ? "host bits lost (read as #{stored_value.inspect})" : nil
        end

        written = written_value(type.column, serialized)
        return :value unless type.opaque
        return :value if !written.nil? && !stored_value.nil? && written.class != stored_value.class

        nil
      rescue StandardError
        :value
      end

      # Whether +serialized+, the model's writing of the value it read, is the
      # stored value: equal as the column's own type reads both, or as the
      # database would be sent them.
      def same_written?(connection, column_type, stored_value, serialized)
        written = written_value(column_type, serialized)
        return true if same_value?(stored_value, written)

        sent = connection.type_cast(column_type.serialize(stored_value))
        sent == connection.type_cast(column_type.serialize(written)) || sent == connection.type_cast(serialized)
      rescue StandardError
        false
      end

      def written_value(column_type, serialized)
        column_type.deserialize(serialized)
      rescue StandardError
        serialized
      end

      def same_value?(stored, written)
        stored == written || (stored.respond_to?(:nan?) && written.respond_to?(:nan?) && stored.nan? && written.nan?)
      end

      # An inet value keeps its host bits (192.168.1.5/24); Rails reads it as
      # an IPAddr of the network (192.168.1.0/24), and writes that back.
      # In an inet[] array, element by element.
      def host_bits_lost?(stored, read)
        return false unless stored.is_a?(String)
        if read.is_a?(Array)
          texts = PG::TextDecoder::Array.new.decode(stored).flatten
          return texts.zip(read.flatten).any? { |text, element| text && host_bits_lost?(text, element) }
        end
        return false unless read.is_a?(IPAddr)

        IPAddr.new(stored.split("/").first).to_i != read.to_i
      rescue IPAddr::Error, PG::Error
        false
      end

      # Attributes whose values a listing does not show: those the privacy
      # policy declares, and encrypted ones.
      def personal_attributes(klass)
        Lyra::Privacy.policy_for(klass).declared_fields.map(&:to_s) | Lyra::EncryptedAttributes.names(klass)
      end

      def warn_unrepresentable(model_class, rows, listed, found)
        what = rows.positive? ? "skipped #{rows} row(s) of #{model_class.name}" : "imported a row of #{model_class.name}"
        more = found > listed.size ? " (and #{found - listed.size} more)" : ""
        Rails.logger&.warn("Lyra::Genesis #{what} holding values the model cannot represent: " \
                           "#{listed.map(&:to_s).join('; ')}#{more}")
      end

      # An ES-NoProj lookup made before the import (in an earlier process, or
      # before the event store was reset) may have cached "not found" for these
      # records. invalidate_all cannot drop per-record entries on every store
      # (Solid Cache cannot delete by prefix), so such a record stayed missing
      # until the entry expired, up to an hour. Drop each one by id.
      def forget_cached(model_class, ids)
        return if ids.empty?

        ids.each { |id| Projections::CachedProjection.invalidate(model_class, id) }
      end

      def event_class(model_class)
        config = model_class.respond_to?(:lyra_config) && model_class.lyra_config || Lyra.config.model_config(model_class)
        name = config.event_name_for(OPERATION).to_s.gsub("::", "")
        return Lyra::Events.const_get(name, false) if Lyra::Events.const_defined?(name, false)

        Lyra::Events.const_set(name, Class.new(Lyra::Event))
      end

      # One lock per table, named after its stream owner (the STI base class):
      # an import through a subclass and one through the base class, or an
      # erasure of one of its rows (hold_lock!), wait for each other. Before
      # 1.0.0 it was named after the class given.
      def lock!(connection, model_class)
        Lyra::AdvisoryLock.xact_lock(connection, "lyra_genesis/#{Lyra.stream_owner_name(model_class)}", purpose: "Genesis")
      end
    end
  end
end
