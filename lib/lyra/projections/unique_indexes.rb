# frozen_string_literal: true

module Lyra
  module Projections
    # A monitored model's unique indexes, enforced in the event-sourcing modes
    # on the writes that record one record's change: create and update
    # through callbacks (CrudInterceptor), update_columns and update_column
    # (StrictDataAccess), and update_all (CachedRelation in ES-NoProj,
    # StrictDataAccessRelation elsewhere; update_counters reaches it). In
    # Monitor and Hijack the table's index refuses a duplicate: PostgreSQL
    # raises ActiveRecord::RecordNotUnique from the INSERT or UPDATE, before
    # the event. ES-NoProj writes no row, so a duplicate was saved, unless a
    # uniqueness validation caught it; ES-Sync, ES-Async and ES-Lazy append
    # the event first and project it after, so the duplicate's event was
    # appended and its projection met the index (logged with
    # strict_projections off: the log held a record the table could not, and
    # ES-Lazy's next catch-up failed on it, for every model's reads).
    # insert_all, insert_all! and upsert_all are checked against the same
    # indexes (StrictDataAccessRelation#events_only_unique_rows in ES-NoProj,
    # #projected_unique_rows elsewhere).
    #
    # ES-Sync looks the value up in its table (in_table?): its projection
    # writes the row in the writer's transaction, so once the value's lock is
    # held (see Races) the table holds every committed claim of it and the
    # transaction's own, compared by the database as its index compares
    # them; a write that skips callbacks takes the lock, and the table's
    # statement checks. ES-Async and ES-Lazy, whose tables lag the event
    # store (a job not run yet, a read not made since), look it up in the
    # value streams, as ES-NoProj does (see Lookup), and ES-Async brings up to
    # date, where it waits for no lock, the rows of records that gave the
    # value up (bring_rows_up_to_date), so the table does not refuse a value
    # no record holds. A transaction at REPEATABLE READ or SERIALIZABLE reads
    # its snapshot, which misses a value committed after it began: not
    # covered (ES-Sync's write then fails at its projection, which raises;
    # ES-Async's and ES-Lazy's projection of the second record fails,
    # ModelProjection.refuse_skipped_create!).
    #
    # Which indexes: unique, on columns (not an expression), not partial (no
    # WHERE), other than the primary key, and on no column with a
    # nondeterministic collation (whose equality only the database knows:
    # Uniqueness refuses such columns too). They are read from the database
    # once per model and process, again when its columns change
    # (reset_column_information) and every config.unique_index_refresh
    # seconds (60), so an index a migration adds is enforced in a process
    # that started before it. The indexes left out are not enforced before
    # the event (named in the log once per model). NULL conflicts with
    # nothing, unless the index is NULLS NOT
    # DISTINCT. A value is compared as the column holds it
    # (Uniqueness.canonical: "250" and 250.00 on a decimal are one value, a
    # time in UTC, a character(n) value without its trailing spaces); a
    # citext column's by its LOWER as the database computes it, as citext
    # compares.
    #
    # When: an index is checked when the write sets one of its columns (a
    # create sets every column; an update, the columns it changes), at the
    # point where the table modes write the row: after every before_*
    # callback, before the event is built, so after_* callbacks do not run
    # and nothing is appended (nor a projection job enqueued). The tuple an
    # update claims takes the columns it does not write from the record's
    # stream (ES-Sync: its row, which the update has locked), read under the
    # record's aggregate lock, not from the copy being saved: a copy read before
    # another writer moved the record claims the tuple the row would hold.
    # A record that keeps its value conflicts with nothing; a destroyed
    # record holds no value.
    #
    # Races. Each claimed value is locked (Uniqueness.lock_all!: a
    # transaction-level advisory lock on the index's first column and a
    # keyed digest of its value, the key a uniqueness validation of that
    # column and insert_all take), so a second writer of the value waits
    # until the first's transaction ends, and then finds its record. An
    # update takes the value locks after the record's aggregate lock (and
    # update_all after its records'), as Monitor's UPDATE takes the row
    # lock and then the index entry: two writers of one record, or of two
    # records and one value, wait for each other as they would there, and
    # do not deadlock where Monitor does not. An update of a model with a
    # uniqueness validation takes the record's aggregate lock before its
    # validations (CrudInterceptor#lyra_lock_aggregate_before_validation),
    # so the validation's value lock comes after it too. Several values are
    # locked all or none (xact_lock_all). In ES-Sync update_columns locks its
    # row (FOR NO KEY UPDATE) before the values, and update_all after its
    # rows, as Monitor's UPDATE takes them.
    #
    # Lookup. Each event that sets an indexed column's value is linked into a
    # value stream, "Model!column$<digest>" (ReferenceLinks, beside its
    # foreign-key links in ES-NoProj; alone in ES-Async and ES-Lazy:
    # ReferenceLinks.values_enabled?), named by a keyed digest of the value as compared
    # (ValueDigest: an HMAC under a secret of the installation), so the
    # stream table holds no value, nor a hash anyone can reverse by trying
    # values. A check reads the stream of the value (one query; nothing more
    # when no event ever set it), rebuilds the records whose events it holds
    # (CachedProjection.find_many), and keeps those that hold the value now:
    # its cost is that of the value's history, not the model's size. A
    # multi-column index reads the stream of the column with the fewest
    # events (one query to count them). Where links are off
    # (config.reference_links false) or no column of the tuple has a value
    # (all NULL, NULLS NOT DISTINCT), every record of the model is read
    # (Uniqueness::Snapshot). Before the first check of a model in a process
    # (and before its value locks), the events stored before its columns
    # were linked are linked (ReferenceLinks.catch_up: per column).
    module UniqueIndexes
      Index = Struct.new(:name, :columns, :nulls_not_distinct)

      # A value a write claims: the index, the tuple's comparison keys (nil
      # for NULL), and the values as given (for the lock and the message).
      Claim = Struct.new(:index, :keys, :values)

      # One model's indexes, the attribute types they were read with, and
      # when (monotonic seconds).
      Facts = Struct.new(:types, :indexes, :columns, :read_at)

      @facts = ObjectSpace::WeakKeyMap.new
      @lock = Mutex.new

      class << self
        # Whether +klass+'s writes are checked here: a monitored model, in an
        # event-sourcing mode (ES-NoProj, ES-Sync, ES-Async, ES-Lazy), where
        # the event is appended before any row is written, or none is.
        def enforced?(klass)
          klass.respond_to?(:lyra_monitored) && klass.lyra_monitored && Lyra.event_sourcing_mode?
        end

        # Whether the check reads the table rather than the value streams:
        # ES-Sync, whose projection writes the row in the writer's
        # transaction, so that under the value lock the table holds every
        # committed claim and the transaction's own (see Lookup).
        def in_table?(_klass = nil) = Lyra.config.projection_mode == :sync

        # The mode's name, for the error's message.
        def mode_name
          { sync: "ES-Sync", async: "ES-Async", lazy: "ES-Lazy", disabled: "ES-NoProj" }
            .fetch(Lyra.config.projection_mode, "event sourcing")
        end

        # The unique indexes checked (see the module's comment).
        def of(klass) = facts(klass).indexes

        # The columns of those indexes, whose values are linked.
        def columns(klass) = facts(klass).columns

        # The comparison key of +value+ (as the record holds it) in +column+;
        # nil for NULL. A citext column's is its LOWER, as the database
        # computes it (Uniqueness.lower_texts, remembered per process).
        def key(klass, column, value)
          if Uniqueness.citext?(klass, column)
            text = Uniqueness.lowered_key_text(klass, column, value)
            return text && "/#{Uniqueness.lower_texts(klass, [text], name: column).first}"
          end
          text = Uniqueness.canonical(klass, column, value)
          text == "#null" ? nil : text
        end

        # The value stream an event that sets +column+ to the value of +key+
        # is linked into.
        def stream(klass, column, key)
          prefix = "#{Lyra.stream_owner_name(klass)}!#{column}"
          "#{prefix}$#{ValueDigest.hex("#{prefix}#{key}")}"
        end

        # The value streams of +values+ ({ column => value as an event gives
        # it }): one for each indexed column with a value. Each value is read
        # as the projection cache reads an entry (in the table's form: an
        # enum's value; then through the attribute's type: a ciphertext
        # decrypted), so it meets the key the check computes for a holder.
        def streams_for(klass, values)
          wanted = columns(klass)
          return [] if wanted.empty?

          given = values.slice(*wanted).compact
          return [] if given.empty?

          table = TypedValues.database_attributes(klass, given)
          reader = TypedValues::EventReader.new(klass)
          given.each_key.filter_map do |column|
            key = key(klass, column, reader.read(table, column))
            key && stream(klass, column, key)
          end
        end

        # The claims of one record's write: for each index whose columns
        # +touched+ includes (nil: every index, a create), the tuple the
        # record will hold, read by the block (column => value as the record
        # holds it). A tuple with a NULL claims nothing, unless the index is
        # NULLS NOT DISTINCT.
        def claims(klass, touched = nil)
          of(klass).filter_map do |index|
            next unless touched.nil? || index.columns.any? { touched.include?(_1) }

            values = index.columns.map { yield _1 }
            keys = index.columns.each_with_index.map { |column, i| key(klass, column, values[i]) }
            next if keys.any?(&:nil?) && !index.nulls_not_distinct

            Claim.new(index, keys, values)
          end
        end

        # The claims of an update of the record +id+ that writes +written+
        # ({ column => value as the record will hold it }): the indexes with a
        # column it changes, each tuple completed from the record's stream
        # (current, read only when a tuple needs a column not written);
        # +current+: that state, if the caller has read it. Called under the
        # record's aggregate lock.
        def update_claims(klass, id, written, current: nil)
          indexes = of(klass).select { |index| index.columns.any? { written.key?(_1) } }
          return [] if indexes.empty?

          stored = lambda do |column|
            current ||= current_state(klass, id)
            current[column]
          end
          indexes.filter_map do |index|
            values = index.columns.map { |column| written.key?(column) ? written[column] : stored.(column) }
            keys = index.columns.each_with_index.map { |column, i| key(klass, column, values[i]) }
            next if keys.any?(&:nil?) && !index.nulls_not_distinct

            Claim.new(index, keys, values)
          end
        end

        # { column => value as the record holds it } of the record +id+ as its
        # stream has it now ({} for a record the store does not hold).
        def current_state(klass, id)
          table = owner(klass)
          return row_state(table, id) if in_table?(table)

          attributes = Lyra::PurposeBoundReads.internal(INTERNAL) { CachedProjection.find(table, id) }
          return {} unless attributes

          reader = TypedValues::EventReader.new(table)
          columns(table).to_h { |column| [column, reader.read(attributes, column)] }
        end

        # The value locks of +claims+, all or none, after the model's value
        # streams are caught up (outside the locks: a first use links the
        # events stored before).
        def lock!(klass, claims)
          return if claims.blank?

          table = owner(klass)
          ReferenceLinks.catch_up(table) if !in_table?(table) && ReferenceLinks.values_enabled?
          Uniqueness.lock_all!(table, claims.map { |claim| [claim.index.columns.first, claim.values.first] })
        end

        # Raise ActiveRecord::RecordNotUnique, as PostgreSQL's unique index
        # would, for the first claim a live record other than those of
        # +except+ (primary keys) holds.
        def refuse_taken!(klass, claims, except: [])
          claim = first_taken(klass, claims, except: except)
          raise not_unique(claim) if claim
        end

        # The first of +claims+ a live record other than those of +except+
        # holds, or nil. In ES-Async the rows of the records whose events
        # set a claimed value and that no longer hold it (destroyed, or
        # moved to another value) are brought up to date first, where that
        # waits for no one (bring_rows_up_to_date), so neither this write's
        # projection nor the table write of one that skips callbacks meets
        # the value in a row whose job has still to delete or change it.
        def first_taken(klass, claims, except: [])
          return nil if claims.blank?

          others = Array(except).map(&:to_s)
          claims.find do |claim|
            held, gave_up = scan(klass, claim)
            bring_rows_up_to_date(klass, gave_up - others)
            (held - others).any?
          end
        end

        # [the primary keys (strings) of the live records that hold +claim+'s
        # tuple, those of the records whose events set one of its values and
        # that no longer hold it]. ES-Sync reads the table (in_table?), whose
        # rows are its records: the second list is empty there.
        def scan(klass, claim)
          table = owner(klass)
          return [table_holders(table, claim), []] if in_table?(table)

          Lyra::PurposeBoundReads.internal(INTERNAL) do
            Genesis.first_use(table)
            records, named = candidates(table, claim.index, claim.keys)
            reader = TypedValues::EventReader.new(table)
            fold_ahead(table, claim.index, records, reader)
            pk = table.primary_key
            held = records.filter_map do |attributes|
              holds = claim.index.columns.each_with_index.all? { |column, i| key(table, column, reader.read(attributes, column)) == claim.keys[i] }
              attributes[pk].to_s if holds
            end
            [held, named - held]
          end
        end

        # ES-Async: bring the rows of +ids+ (records of +klass+ whose events
        # set a value a write claims, and that no longer hold it) up to date
        # with their streams, as their projection jobs will, where a row
        # still waits for its job (AsyncCheckpoint.behind: one query) and
        # nothing has to be waited for: the record's aggregate lock, its row
        # and its stream's projection lock are each only tried
        # (pg_try_advisory_xact_lock, FOR UPDATE SKIP LOCKED), and a record
        # one of them is taken for is left to its job. Never waiting, it
        # adds no deadlock, whatever the caller holds. In the caller's
        # transaction (AsyncProjectionJob.project_stream moves the
        # checkpoint with the row: the jobs then find nothing new; rolled
        # back, both go back). Returns the ids brought up to date.
        def bring_rows_up_to_date(klass, ids)
          return [] if ids.empty? || !Lyra::BypassEvents.projects_pending?

          table = owner(klass)
          table.with_connection do |connection|
            next [] unless connection.transaction_open? && connection.adapter_name.match?(/postgres/i)

            prefix = Lyra.stream_prefix(table)
            behind = AsyncCheckpoint.behind(connection, ids.uniq.map { Lyra.stream_name(table, _1) })
            behind.filter_map do |stream|
              id = stream.delete_prefix(prefix)
              next unless Lyra::AdvisoryLock.try_xact_lock(connection, "lyra_aggregate/#{stream}", purpose: "aggregate write")
              next unless row_free?(connection, table, id)
              next unless Lyra::AdvisoryLock.try_xact_lock(connection, stream, purpose: "ES-Async projection")

              AsyncProjectionJob.project_stream(table, stream)
              id
            end
          end
        end

        # The error PostgreSQL's unique index raises for +claim+, with its
        # message, naming the index.
        def not_unique(claim)
          shown = claim.values.map { _1.nil? ? "null" : _1.to_s }
          ActiveRecord::RecordNotUnique.new(
            "Lyra (#{mode_name}): duplicate key value violates unique constraint \"#{claim.index.name}\"\n" \
            "DETAIL:  Key (#{claim.index.columns.join(', ')})=(#{shown.join(', ')}) already exists " \
            "#{in_table? ? 'in the table' : 'in the event store'}."
          )
        end

        # update_all(+updates+) on records of +klass+ (CachedRelation, in the
        # events-only store): a BulkUpdate when it sets a column of an index;
        # nil otherwise.
        def bulk_update(klass, updates)
          return nil unless updates.is_a?(Hash) && enforced?(klass)

          set = updates.to_h { |name, value| [klass.attribute_aliases.fetch(name.to_s, name.to_s), value] }
          indexes = of(klass).select { |index| index.columns.any? { set.key?(_1) } }
          return nil if indexes.empty?

          BulkUpdate.new(klass, set)
        end

        # Forget the indexes read, and the warnings given (tests).
        def reset!
          @lock.synchronize do
            @facts = ObjectSpace::WeakKeyMap.new
            @warned = Set.new
          end
        end

        # The live records (attribute hashes, as the projection cache holds
        # them) that may hold any of +wanted+ ([[index, keys], ...]), for a
        # bulk insert (StrictDataAccessRelation#events_only_unique_rows): those
        # whose events are in the streams of the tuples' values (each tuple's
        # first column with a value), read together, and those of +ids+.
        # Every record of the model where links are off or a tuple is all
        # NULL (NULLS NOT DISTINCT).
        def candidate_records(klass, wanted, ids: [])
          table = owner(klass)
          if !ReferenceLinks.values_enabled? || wanted.any? { |_, keys| keys.all?(&:nil?) }
            return Uniqueness::Snapshot.records(table)
          end

          streams = wanted.filter_map do |index, keys|
            i = keys.index { !_1.nil? }
            stream(table, index.columns[i], keys[i])
          end.uniq
          # Links not caught up (another thread is linking): every record.
          return Uniqueness::Snapshot.records(table) unless ReferenceLinks.catch_up(table)

          found = streams.empty? ? [] : ReferenceLinks.record_ids_in_any(table, streams)
          all = (found + ids.map(&:to_s)).uniq
          all.empty? ? [] : CachedProjection.find_many(table, all)
        end

        private

        def owner(klass) = klass.respond_to?(:base_class) ? klass.base_class : klass

        # ES-Sync (in_table?): the primary keys (strings) of the rows that hold
        # +claim+'s tuple, read now (never from the query cache: the value
        # lock just taken may have waited for a writer that committed one),
        # compared by the database as its index compares them (a citext
        # column without case).
        def table_holders(table, claim)
          conditions = claim.index.columns.zip(claim.values).to_h
          pk = table.primary_key
          Lyra::PurposeBoundReads.internal(INTERNAL) do
            table.uncached { table.unscoped.where(conditions).limit(2).pluck(pk) }.map(&:to_s)
          end
        end

        # ES-Sync: { column => value as the record holds it } of the row of
        # +id+, for the columns of the indexes ({} when there is no row). The
        # row is the record's: written in the writers' transactions, and
        # locked by this update (CrudInterceptor#lyra_lock_own_row).
        def row_state(table, id)
          wanted = columns(table)
          return {} if wanted.empty?

          values = Lyra::PurposeBoundReads.internal(INTERNAL) do
            table.uncached { table.unscoped.where(table.primary_key => id).pluck(*wanted).first }
          end
          return {} if values.nil?

          wanted.zip(wanted.one? ? [values] : values).to_h
        end

        # Whether the row of +id+ is absent, or now locked by this
        # transaction (FOR UPDATE SKIP LOCKED): false when another holds it.
        def row_free?(connection, table, id)
          pk = table.primary_key
          bound = table.type_for_attribute(pk).serialize(table.type_for_attribute(pk).cast(id))
          from = "FROM #{connection.quote_table_name(table.table_name)} " \
                 "WHERE #{connection.quote_column_name(pk)} = #{connection.quote(bound)}"
          present, held = connection.uncached do
            connection.select_rows("SELECT (SELECT 1 #{from}), (SELECT 1 #{from} FOR UPDATE SKIP LOCKED)", "Lyra unique index row").first
          end
          present.nil? || !held.nil?
        end

        # The records that may hold the tuple: those whose events set one of
        # its values (the value stream with the fewest events), or every
        # record (see Lookup above); and the primary keys (strings) of the
        # records named, destroyed ones included.
        def candidates(table, index, keys)
          streams = index.columns.each_with_index.filter_map { |column, i| keys[i] && stream(table, column, keys[i]) }
          return every_record(table) if streams.empty? || !ReferenceLinks.values_enabled?
          return every_record(table) unless ReferenceLinks.catch_up(table)

          ids = ReferenceLinks.record_ids_in(table, streams)
          [ids.empty? ? [] : CachedProjection.find_many(table, ids), ids.map(&:to_s)]
        end

        def every_record(table)
          records = Uniqueness::Snapshot.records(table)
          [records, records.map { _1[table.primary_key].to_s }]
        end

        # The LOWER of the candidates' citext values, in one query.
        def fold_ahead(table, index, records, reader)
          folded = index.columns.select { Uniqueness.citext?(table, _1) }
          return if folded.empty? || records.empty?

          folded.each do |column|
            texts = records.filter_map { |attributes| Uniqueness.lowered_key_text(table, column, reader.read(attributes, column)) }
            Uniqueness.lower_texts(table, texts.uniq, name: column) if texts.any?
          end
        end

        # The model's facts, read again when its attribute types change or
        # config.unique_index_refresh has passed. A column of an index that
        # the facts did not have before is new to this process: its events
        # may not all be linked (written here, or by a process that read the
        # indexes earlier), so ReferenceLinks links its values again from the
        # first event (ReferenceLinks.unlinked!).
        def facts(klass)
          table = owner(klass)
          types = table.attribute_types
          now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          found = @lock.synchronize { @facts[table] }
          refresh = Lyra.config.unique_index_refresh
          return found if found&.types.equal?(types) && (refresh.nil? || now - found.read_at < refresh.to_f)

          indexes = read_indexes(table)
          columns = indexes.flat_map(&:columns).uniq.freeze
          gained = found ? columns - found.columns : []
          fresh = Facts.new(types, indexes, columns, now).freeze
          @lock.synchronize { @facts[table] = fresh }
          ReferenceLinks.unlinked!(table, gained) if gained.any?
          fresh
        end

        def read_indexes(table)
          primary_key = Array(table.primary_key).map(&:to_s)
          table.with_connection do |connection|
            listed = connection.indexes(table.table_name)
            unique = listed.select(&:unique)
            candidates = unique.select { |index| index.columns.is_a?(Array) && index.where.nil? }
            nondeterministic = nondeterministic_columns(connection, table, candidates.flat_map(&:columns))
            skipped = (unique - candidates).map { |index| [index.name, index.where ? "partial" : "an expression"] }
            indexes = candidates.filter_map do |index|
              columns = index.columns.map(&:to_s)
              next if columns == primary_key

              if columns.intersect?(nondeterministic)
                skipped << [index.name, "on a column with a nondeterministic collation"]
                next
              end
              nulls = index.respond_to?(:nulls_not_distinct) && index.nulls_not_distinct ? true : false
              Index.new(index.name, columns.freeze, nulls).freeze
            end.freeze
            warn_unenforced(table, skipped)
            indexes
          end
        end

        # Once per model and process, in an event-sourcing mode: the unique
        # indexes it does not check before a write's event is appended, by
        # name (the table modes' table does; ES-Sync's, ES-Async's and
        # ES-Lazy's projection meets such a duplicate after its event).
        def warn_unenforced(table, skipped)
          return if skipped.empty? || !enforced?(table)

          @warned ||= Set.new
          fresh = @lock.synchronize { @warned.add?(table.name) }
          return unless fresh

          listed = skipped.map { |name, why| "#{name} (#{why})" }.join(", ")
          message = "Lyra: #{mode_name} does not enforce these unique indexes of #{table.name}: #{listed}; " \
                    "a duplicate is refused only by a uniqueness validation there" \
                    "#{Lyra.config.projection_mode == :disabled ? '' : ' (its projection meets the index after the event)'}"
          defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger ? Rails.logger.warn(message) : Kernel.warn(message)
        end

        # Of +names+, the columns with a collation of their own that is
        # nondeterministic (PostgreSQL 12+): one query, only when a column
        # has a collation.
        def nondeterministic_columns(connection, table, names)
          collations = names.uniq.filter_map do |name|
            column = table.columns_hash[name.to_s]
            [name.to_s, column.collation] if column.respond_to?(:collation) && column.collation
          end.to_h
          return [] if collations.empty? || !connection.adapter_name.match?(/postgres/i)

          wanted = collations.values.uniq.map { connection.quote(_1.delete('"')) }.join(", ")
          loose = connection.select_values(
            "SELECT collname FROM pg_collation WHERE NOT collisdeterministic AND collname IN (#{wanted})", "Lyra unique indexes"
          )
          collations.select { |_, collation| loose.include?(collation.delete('"')) }.keys
        rescue ActiveRecord::StatementInvalid
          collations.keys
        end
      end

      # The unique-index check of one update_all (UniqueIndexes.bulk_update).
      class BulkUpdate
        def initialize(klass, set)
          @klass = klass
          # The values set, as the records will hold them.
          @set = set.to_h { |column, value| [column, klass.type_for_attribute(column).cast(value)] }
        end

        # Before the events of +records+ (the records written, locked and
        # read now, CachedRelation#locked_records_now) are appended: the
        # tuples they will hold locked (after the records' aggregate locks,
        # as Monitor's UPDATE takes the rows, then the index entries) and
        # checked, against each other and against the records that keep
        # theirs, as the table's index checks the rows an UPDATE writes (the
        # state after it; the order in which PostgreSQL visits the rows is
        # not followed). A record whose tuple does not change claims nothing.
        #
        # +records+: records, or attribute hashes as a snapshot of the rows
        # holds them (StrictDataAccessRelation#update_all, in ES-Sync,
        # ES-Async and ES-Lazy, after the rows and their aggregate locks are
        # taken). +check+ false (ES-Sync, whose table is current): the values
        # locked only, so a write through callbacks checking the table waits
        # for this one; the table's UPDATE checks them.
        def check!(records, check: true)
          return if records.empty?

          pk = @klass.primary_key
          touched = @set.keys
          claims = records.flat_map do |record|
            read = record.is_a?(Hash) ? ->(column) { record[column] } : ->(column) { record.read_attribute(column) }
            id = read.(pk).to_s
            held = UniqueIndexes.claims(@klass, touched) { read.(_1) }.to_h { [_1.index, _1.keys] }
            UniqueIndexes.claims(@klass, touched) { |column| @set.key?(column) ? @set[column] : read.(column) }
                         .reject { |claim| held[claim.index] == claim.keys }
                         .map { |claim| [id, claim] }
          end
          return if claims.empty?

          Lyra::BypassEvents.check_lock_limit!(@klass, claims.size, "update_all")
          UniqueIndexes.lock!(@klass, claims.map(&:last))
          return unless check

          claims.group_by { |_, claim| claim.index }.each_value do |of_index|
            moving = of_index.map(&:first)
            of_index.group_by { |_, claim| claim.keys }.each_value do |same|
              raise UniqueIndexes.not_unique(same.first.last) if same.size > 1

              UniqueIndexes.refuse_taken!(@klass, [same.first.last], except: moving)
            end
          end
        end
      end
    end
  end
end
