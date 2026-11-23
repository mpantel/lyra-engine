# frozen_string_literal: true

require "objspace"

module Lyra
  module Projections
    # Rails' uniqueness validation (validates :x, uniqueness: true) in
    # ES-NoProj, where a monitored model's table stays empty and its records
    # are rebuilt from events.
    #
    # The validator builds an Active Record relation (Model.unscoped, the
    # value compared as the connection compares it, the scope: columns, the
    # conditions: lambda, and on update where.not(primary key: the record's))
    # and asks it exists?. That query read the empty table, so every value
    # passed and duplicates were saved; the table's unique index could not
    # catch them, since no row is written.
    #
    # The relation is still built by Rails, unchanged, so that scope,
    # conditions and case sensitivity follow Rails' own construction. Only
    # its exists? is answered here, from the event-sourced records: its where
    # clause is evaluated on every record of the model, each predicate as the
    # database evaluates it (TypedValues: the value bound through the
    # attribute's type, SQL's three-valued logic). What cannot be evaluated
    # exactly raises UnsupportedQuery instead of passing or refusing a value
    # on a guess: an SQL fragment or a subquery in conditions:, a join, a
    # comparison with another column, LIKE, a string column with a collation
    # of its own, an adapter other than PostgreSQL or SQLite for a string
    # comparison. LOWER(column) = LOWER(value) (case_sensitive: false) and a
    # citext column's equality are evaluated by the database's own LOWER, on
    # the values the records hold (Predicates#lower_all).
    #
    # The check reads the records as Rails reads the table: through
    # Model.unscoped, so a default scope (a soft delete) is not applied, and
    # with the type condition of the class Rails chooses (under STI, the one
    # that declared the validation). Other modes are untouched: the relation
    # is extended only when the model reads from events.
    #
    # A check is a read and then a write, and two writers of one value can
    # both check before either commits. In the table modes a unique index
    # refuses the second INSERT. ES-NoProj writes no row, so the check takes
    # a transaction-level advisory lock on (model, attribute, value) before it
    # reads (lock!): the second writer's check waits until the first's
    # transaction ends, and then reads its events. See lock! for its limits.
    # Where a unique index covers the validation (index_covered?, from 1.0.1)
    # no lock is taken: the index check at the append refuses the second
    # writer (RecordNotUnique), as the table's index does in Monitor.
    #
    # The purpose check exemption (PurposeBoundReads::UniquenessExemption)
    # still applies: the validation is part of writing the record.
    module Uniqueness
      # Thread-local: the class, attribute and value a uniqueness validation is
      # checking (ValidatorPatch), for holders_of_value.
      VALUE_HINT = :lyra_uniqueness_value

      LOCK = "lyra_unique"

      class << self
        # Whether +klass+'s reads are answered from events (ES-NoProj), as
        # the model's read overrides decide it, Lyra's own table reads aside:
        # whoever builds the relation, the table has no rows to answer from.
        def reads_events?(klass)
          klass.respond_to?(:lyra_monitored) && klass.lyra_monitored &&
            Lyra.event_sourcing_mode? && Lyra.config.projection_mode == :disabled
        end

        # LOWER of texts already sent to a database, per database, in this
        # process (Predicates#lower_all): LOWER depends only on the text and
        # the database's character type.
        LOWER_MEMO_LIMIT = 200_000

        def lower_memo(connection)
          config = connection.pool.db_config
          key = [config.env_name, config.name, config.database]
          (@lower_memos ||= Concurrent::Map.new).compute_if_absent(key) { Concurrent::Map.new }
        end

        def remember_lower(memo, text, lowered)
          memo.clear if memo.size >= LOWER_MEMO_LIMIT
          memo[text] = lowered
        end

        # The current scope of +klass+ when it is a uniqueness check's
        # relation: a named scope called in conditions: (-> { live }) runs
        # under it (Relation#scoping), and Model.all must return it, as
        # Active Record's all does, for the scope to build on it.
        def scoped?(klass)
          scope = klass.current_scope
          scope.is_a?(Relation) && scope.model == klass
        end

        # Whether a record matches +relation+'s where clause: its exists?.
        def exists?(relation)
          klass = relation.model
          refuse_unsupported!(relation)
          return false if relation.limit_value&.zero?

          predicates = Predicates.new(klass)
          begin
            test = predicates.compile_all(relation.where_clause.send(:predicates))
          rescue Predicates::LiteralOutOfRange
            # Active Record cannot quote the literal; select_all rescues the
            # RangeError and answers no row: the value is not taken.
            return false
          end
          Genesis.first_use(klass)
          records = holders_of_value(klass) || Snapshot.records(klass)
          predicates.prepare(records)
          records.any? { |attributes| true.equal?(test.call(attributes)) }
        end

        # The records a uniqueness check need test (1.0.1): where the validated
        # attribute is a column of a unique index, every record that ever held the
        # value has an event in that value's stream (ReferenceLinks, as the index
        # check reads it: UniqueIndexes.candidate_records), so those are read, not
        # every record of the model; the where clause is then tested on them as on
        # all. nil (every record, as before) where that does not hold: no hint (a
        # relation Rails did not build for a validation), a column without a unique
        # index, a nil value, a comparison without case on a column whose key keeps
        # it (only a citext column's key is its LOWER), value links off, or links
        # another thread is still writing.
        def holders_of_value(klass)
          hint = Thread.current[VALUE_HINT]
          return nil unless hint && hint[:klass].equal?(klass) && !hint[:value].nil?

          table = klass.respond_to?(:base_class) ? klass.base_class : klass
          column = klass.attribute_aliases.fetch(hint[:attribute].to_s, hint[:attribute].to_s)
          return nil unless ReferenceLinks.values_enabled? && UniqueIndexes.columns(table).include?(column)
          return nil if hint[:case_insensitive] && !citext?(table, column)

          key = UniqueIndexes.key(table, column, table.type_for_attribute(column).cast(hint[:value]))
          return nil if key.nil?
          return nil unless ReferenceLinks.catch_up(table)

          ids = ReferenceLinks.record_ids_in_any(table, [UniqueIndexes.stream(table, column, key)])
          ids.empty? ? [] : CachedProjection.find_many(table, ids).compact
        end
        # Whether a unique index Lyra checks at the append (UniqueIndexes) covers
        # this validation of +attribute+ (with +options+ :scope, :conditions,
        # :case_sensitive): one on every row (not partial) whose columns are exactly
        # the attribute and its scope, the validation with no conditions:, and
        # compared as the index compares (case_sensitive: false only on a citext
        # column). There the validation takes no value lock, nor the record's
        # aggregate lock before it (from 1.0.1): two writers of one value may both
        # pass it, as in Monitor, and the second is refused at its append by the
        # index check, under the value's lock, after the aggregate lock
        # (ActiveRecord::RecordNotUnique, as the table's index raises in Monitor).
        # A validation no index covers keeps its lock, which Monitor does not take
        # (Rails' validation alone is a read, then a write).
        def index_covered?(klass, attribute, options)
          return false if options[:conditions]

          table = klass.respond_to?(:base_class) ? klass.base_class : klass
          return false unless UniqueIndexes.enforced?(table)

          aliases = table.attribute_aliases
          column = aliases.fetch(attribute.to_s, attribute.to_s)
          return false if options.key?(:case_sensitive) && !options[:case_sensitive] && !citext?(table, column)

          wanted = ([column] + Array(options[:scope]).map { aliases.fetch(_1.to_s, _1.to_s) }).sort
          UniqueIndexes.of(table).any? { |index| index.condition.nil? && index.columns.sort == wanted }
        end
        # A transaction-level advisory lock on (model, attribute, value),
        # taken before the check reads, held until the writer's transaction
        # ends: a second writer of the value waits in its check until the
        # first commits or rolls back, and then reads the first's events.
        #
        # The value is the one the check binds, as the column holds it:
        # the attribute's type serializes it ("250" and 250.00 on a decimal
        # are one value, a time is taken in UTC, -0.0 is 0.0, a character(n)
        # value without its trailing spaces), under the column an
        # alias_attribute names. Under case_sensitive: false on a text
        # column, and on a citext column, the key is made from LOWER(value)
        # as the database computes it, as the check compares: values that
        # differ only in case take one lock. The key holds a keyed digest of
        # the value (value_lock_key), never the value: lock statements reach
        # the database's log. The scope: and conditions: are
        # left out of the key, which makes it coarser (writers of one value
        # in two scopes wait for each other), never finer; keys are hashed
        # to 32 bits (hashtext), so two values may rarely share one.
        #
        # Not taken for a persisted record whose attribute and scope columns
        # did not change, with no conditions: (ValidatorPatch#lyra_claims?):
        # it holds a value committed before (or written earlier in its own
        # transaction, under the lock that write took), and claims nothing a
        # second writer could also claim. Rails still runs its check whenever it would
        # (validation_needed?, which runs it for every save under
        # case_sensitive:), and it is still answered.
        #
        # Limits. PostgreSQL only (Lyra::AdvisoryLock; SQLite serialises
        # writers). Taken only inside a transaction (save, create, update
        # run their validations in one); valid? alone, then save(validate:
        # false), is a race in every mode. Under REPEATABLE READ or
        # SERIALIZABLE a transaction whose snapshot was taken before the
        # first writer committed does not see its events after the wait
        # (PostgreSQL's default, READ COMMITTED, takes a new snapshot per
        # statement). Two transactions that each claim the same two values
        # in opposite orders deadlock, as two inserts of those values into a
        # unique index do, and PostgreSQL fails one of them
        # (ActiveRecord::Deadlocked); a lock key coarser than the index (a
        # scope or conditions left out, a hash shared) can make two writers
        # wait, or deadlock, where an index on the scoped columns would not.
        def lock!(klass, attribute, value, case_insensitive:)
          klass.with_connection do |connection|
            next unless connection.transaction_open?

            key = value_lock_key(klass, attribute, value, fold: case_insensitive)
            Lyra::AdvisoryLock.xact_lock(connection, key, purpose: "uniqueness check")
          end
        end

        # The locks lock! takes for each [attribute, value] of +pairs+, as a
        # case-sensitive check takes them (a citext column's folded, as the
        # column compares), all or none in one statement
        # (Lyra::AdvisoryLock.xact_lock_all). For the writes checked against
        # the unique indexes from the event store (UniqueIndexes, and
        # StrictDataAccessRelation#events_only_unique_rows): they wait for, and
        # are waited for by, a uniqueness validation of the same value.
        def lock_all!(klass, pairs)
          klass.with_connection do |connection|
            next unless connection.transaction_open?

            keys = pairs.uniq.map { |attribute, value| value_lock_key(klass, attribute, value, fold: false) }
            Lyra::AdvisoryLock.xact_lock_all(connection, keys, purpose: "unique index check")
          end
        end

        # The advisory lock key of +value+ in +attribute+ (lock!, lock_all!):
        # "lyra_unique/<model>/<column>/" and a keyed digest (ValueDigest) of
        # the value as the column holds it (canonical), or, folded (+fold+, or
        # a citext column), of its LOWER as the database computes it; never the
        # value itself, which would reach the statement log. NULL is "#null".
        def value_lock_key(klass, attribute, value, fold:)
          name = klass.attribute_aliases.fetch(attribute.to_s, attribute.to_s)
          prefix = "#{LOCK}/#{Lyra.stream_owner_name(klass)}/#{name}"
          text = lowered_key_text(klass, name, value) if fold || citext?(klass, name)
          return "#{prefix}/#{ValueDigest.hex("#{prefix}/#{lower_texts(klass, [text], name: name).first}")}" if text

          bound = canonical(klass, name, value)
          bound == "#null" ? "#{prefix}#null" : "#{prefix}/#{ValueDigest.hex("#{prefix}#{bound}")}"
        end

        # LOWER of each of +texts+ as +klass+'s database computes it, those
        # lowered before (per database, in this process) not sent again; the
        # rest in one query, as bind parameters named +name+ (a column's: the
        # statement log shows them as it shows that column's, filtered where
        # the application filters it).
        def lower_texts(klass, texts, name: "value")
          klass.with_connection do |connection|
            memo = lower_memo(connection)
            known = {}
            texts.each { |text| (lowered = memo[text]) ? known[text] = lowered : nil }
            missing = texts.reject { known.key?(_1) }.uniq
            if missing.any?
              lower_query(connection, missing, name.to_s).each_with_index do |lowered, i|
                known[missing[i]] = lowered
                remember_lower(memo, missing[i], lowered)
              end
            end
            texts.map { known.fetch(_1) }
          end
        end

        # "/" and the value as the column holds it; "#null" for NULL: the
        # lock key's value, and the value a unique index compares in ES-NoProj
        # (Lyra::Projections::UniqueIndexes).
        def canonical(klass, name, value)
          type = klass.type_for_attribute(name)
          value = TypedValues.normalize(value)
          bound = value.nil? || !type.serializable?(value) ? nil : type.serialize(value)
          return "#null" if bound.nil?

          bound = TypedValues.unpadded(bound) if TypedValues.schema(klass).blank_padded.include?(name)
          bound = bound.utc if bound.is_a?(Time)
          bound = 0.0 if bound.is_a?(Float) && bound.zero?
          bound = bound.strftime("%Y-%m-%d %H:%M:%S.%N") if bound.is_a?(Time)
          "/#{bound}"
        rescue StandardError
          "/#{value.inspect}"
        end

        # A citext column, wherever its type lives (public.citext, a schema
        # outside the search path).
        def citext?(klass, name)
          column = klass.columns_hash[name]
          return false unless column

          column.type == :citext || column.sql_type.to_s.match?(/(\A|\.)"?citext"?\z/)
        end

        # The text LOWER is applied to in a lock's key or a citext comparison, for a value of a
        # text column (nil otherwise, or for NULL: the canonical key then).
        def lowered_key_text(klass, name, value)
          column = klass.columns_hash[name]
          return nil unless column && %i[string text citext].include?(column.type)

          value = TypedValues.normalize(value)
          type = klass.type_for_attribute(name)
          return nil if value.nil? || !type.serializable?(value)

          text = type.serialize(value)&.to_s
          TypedValues.schema(klass).blank_padded.include?(name) ? TypedValues.unpadded(text) : text
        end

        private

        # LOWER of +texts+ in one query (lower_texts), the texts bound.
        def lower_query(connection, texts, name)
          type = ActiveModel::Type::String.new
          if connection.adapter_name.match?(/postgres/i)
            array = PG::TextEncoder::Array.new.encode(texts)
            connection.select_values(
              "SELECT LOWER(t.x) FROM unnest($1::text[]) WITH ORDINALITY AS t(x, i) ORDER BY t.i",
              "Lyra uniqueness LOWER", [ActiveRecord::Relation::QueryAttribute.new(name, array, type)]
            )
          else
            texts.each_slice(500).flat_map do |slice|
              binds = slice.map { ActiveRecord::Relation::QueryAttribute.new(name, _1, type) }
              connection.select_rows("SELECT #{slice.map { 'LOWER(?)' }.join(', ')}", "Lyra uniqueness LOWER", binds).first
            end
          end
        end

        def refuse_unsupported!(relation)
          used = {
            "joins" => relation.joins_values.any? || relation.left_outer_joins_values.any?,
            "eager loading" => relation.eager_loading?,
            "group" => relation.group_values.any?,
            "having" => !relation.having_clause.empty?,
            "offset" => !relation.offset_value.nil?,
            "from" => !relation.from_clause.empty?
          }.select { |_, present| present }.keys
          return if used.empty?

          raise UnsupportedQuery.new(relation.model, "a uniqueness check (it uses #{used.join(', ')})")
        end
      end

      # Every record of a model, as CachedProjection.all reads them, for the
      # checks: each stream's last event is read (one query), and a copy of
      # the records, stamped as the projection cache's entries are, is kept
      # in this process. Only the streams whose last event is not the stamp
      # are read from the cache or rebuilt (CachedProjection.entries_for);
      # the others are used as they are. CachedProjection.all reads every
      # entry from the cache, which copies each (Marshal) on every read: at
      # 3,000 records that was 55 of a check's 94 ms.
      #
      # Each check reads every entry of the copy once, into a hash of its
      # own, decides from it which are stale, and answers from it alone:
      # another thread replacing an entry meanwhile cannot change what this
      # check sees. An entry is used only while its stamp is its stream's
      # last event as this transaction sees it. The copy can hold an entry
      # built inside a transaction from that transaction's own uncommitted
      # events (the projection cache's shared entries can too): it is
      # stamped with an event no other transaction sees until it commits,
      # and one that rolls back is never any stream's last event, so no
      # other check uses it; a check after the commit uses it, and then it
      # is committed state.
      #
      # Bounded: a model with more than LIMIT streams is read through
      # CachedProjection.all, and the copies of all models together are kept
      # under BYTES (as ObjectSpace measures their records), beside the
      # projection cache's own MEMORY_CACHE_BYTES: past it the copies used
      # least recently are dropped. A copy is dropped and rebuilt after
      # EXPIRES_IN, as the projection cache's memory entries expire, and
      # when its model's attribute types change (reset_column_information,
      # a migration) or the projection cache's CACHE_VERSION does.
      module Snapshot
        LIMIT = 20_000
        BYTES = 32.megabytes
        EXPIRES_IN = CachedProjection::DEFAULT_EXPIRES_IN

        # One model's copy: { id => [stamp, frozen attributes or nil] }.
        Copy = Struct.new(:entries, :types, :version, :born, :used, :bytes)

        @copies = {} # stream owner (a class) => Copy
        @lock = Mutex.new

        class << self
          def records(klass)
            versions = CachedProjection.stream_versions_for(klass)
            return CachedProjection.all(klass) if versions.size > LIMIT

            copy = copy_for(klass)
            local = versions.each_key.to_h { |id| [id, copy.entries[id]] }
            stale = versions.reject { |id, version| local[id]&.first == version }
            if stale.any?
              CachedProjection.entries_for(klass, stale).each do |id, (version, attributes)|
                local[id] = [version, frozen(attributes)].freeze
              end
              keep(copy, local, stale.keys)
            end
            prune(copy, versions)
            local.each_value.filter_map do |entry|
              attributes = entry&.last
              attributes if attributes && CachedProjection.of_class?(klass, attributes)
            end
          end

          # Forget every copy (tests).
          def reset!
            @lock.synchronize { @copies = {} }
          end

          # The bytes the copies hold, as counted (tests, monitoring).
          def bytes = @lock.synchronize { @copies.each_value.sum(&:bytes) }

          private

          # One copy per table: the stream owner (an STI base class). A new
          # one when it has expired or its model's types have changed.
          def copy_for(klass)
            owner = klass.respond_to?(:base_class) ? klass.base_class : klass
            now = monotonic
            @lock.synchronize do
              copy = @copies[owner]
              if copy.nil? || !copy.types.equal?(owner.attribute_types) || copy.version != CachedProjection::CACHE_VERSION ||
                 now - copy.born > EXPIRES_IN.to_f
                copy = @copies[owner] = Copy.new(Concurrent::Map.new, owner.attribute_types, CachedProjection::CACHE_VERSION, now, now, 0)
              end
              copy.used = now
              copy
            end
          end

          # The entries this check read again, into the shared copy, within
          # the byte budget.
          def keep(copy, local, ids)
            @lock.synchronize do
              ids.each do |id|
                entry = local[id]
                previous = copy.entries[id]
                copy.bytes += size_of(entry) - (previous ? size_of(previous) : 0)
                copy.entries[id] = entry
              end
              enforce_budget(copy)
            end
          end

          # Past BYTES, drop the copies used least recently, this one last.
          def enforce_budget(current)
            total = @copies.each_value.sum(&:bytes)
            return if total <= BYTES

            (@copies.reject { |_, copy| copy.equal?(current) }.sort_by { |_, copy| copy.used } +
              @copies.select { |_, copy| copy.equal?(current) }.to_a).each do |owner, copy|
              break if total <= BYTES

              total -= copy.bytes
              @copies.delete(owner)
            end
          end

          # Streams that are gone (an erasure that rewrote them) are dropped
          # once the copy has grown well past the model's streams.
          def prune(copy, versions)
            return unless copy.entries.size > (versions.size * 2) + 100

            @lock.synchronize do
              copy.entries.each_key do |id|
                next if versions.key?(id)

                removed = copy.entries.delete(id)
                copy.bytes -= size_of(removed) if removed
              end
            end
          end

          def frozen(attributes)
            return nil unless attributes

            attributes.each_value { |value| value.freeze if value.is_a?(String) }
            attributes.freeze
          end

          # The memory an entry holds: its hash and its strings.
          def size_of(entry)
            attributes = entry&.last
            return 40 unless attributes

            attributes.sum(ObjectSpace.memsize_of(attributes)) do |key, value|
              ObjectSpace.memsize_of(key) + (value.is_a?(String) ? ObjectSpace.memsize_of(value) : 0)
            end
          end

          def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
      end

      # Extends the relation a uniqueness check builds (ValidatorPatch): its
      # exists? is answered from the event-sourced records. The relations
      # the validator derives from it (where, where.not, the conditions)
      # are clones and keep the extension.
      module Relation
        def exists?(conditions = :none)
          return super unless conditions == :none && !null_relation? && Uniqueness.reads_events?(model)

          Uniqueness.exists?(self)
        end
      end

      # Prepended to ActiveRecord::Validations::UniquenessValidator: the
      # relation Rails builds for the check is extended (Relation), and the
      # advisory lock taken, when the model reads from events. In other modes
      # the relation is Rails' own.
      module ValidatorPatch
        RECORD = :lyra_uniqueness_record

        # The record being validated, for build_relation (which Rails does
        # not pass it): whether its save claims a value (lyra_claims?).
        def validate_each(record, attribute, value)
          previous = Thread.current[RECORD]
          hint = Thread.current[Uniqueness::VALUE_HINT]
          Thread.current[RECORD] = record
          super
        ensure
          Thread.current[RECORD] = previous
          Thread.current[Uniqueness::VALUE_HINT] = hint
        end

        private

        def build_relation(klass, attribute, value)
          relation = super
          return relation unless Uniqueness.reads_events?(klass)
          # An unboundable value (out of the column's range) matches no row.
          return relation if relation.null_relation?

          if lyra_claims?(Thread.current[RECORD], attribute) && !Uniqueness.index_covered?(klass, attribute, options)
            case_insensitive = options.key?(:case_sensitive) && !options[:case_sensitive]
            Uniqueness.lock!(klass, attribute, value, case_insensitive: case_insensitive)
          end
          Thread.current[Uniqueness::VALUE_HINT] =
            { klass: klass, attribute: attribute, value: value,
              case_insensitive: options.key?(:case_sensitive) && !options[:case_sensitive] }
          relation.extending!(Relation)
        end

        # Whether saving +record+ claims its value: a new record, one whose
        # attribute or scope columns change, or any record checked under
        # conditions: (which may read any of its attributes). A persisted
        # record that keeps them holds a value already committed.
        def lyra_claims?(record, attribute)
          return true if record.nil? || !record.persisted? || options[:conditions]

          aliases = record.class.attribute_aliases
          resolve_attributes(record, Array(options[:scope]) + [attribute]).any? do |name|
            record.attribute_changed?(aliases.fetch(name.to_s, name.to_s))
          end
        end
      end

      # A relation's where clause compiled into a test of a record's event
      # attributes (CachedProjection's), answering as SQL does: true, false
      # or nil (unknown, which a WHERE does not select).
      class Predicates
        # An Arel literal out of its column's range (#literal).
        class LiteralOutOfRange < StandardError; end

        STRING_ADAPTERS = /postgres|sqlite/i

        def initialize(klass)
          @klass = klass
          @reader = TypedValues::EventReader.new(klass)
          @lowered = [] # [name, bound text, cell] for each LOWER comparison
        end

        # The AND of +predicates+.
        def compile_all(predicates)
          tests = predicates.map { compile(_1) }
          ->(attributes) { TypedValues.all_of(tests.map { _1.call(attributes) }) }
        end

        # The values the LOWER comparisons need, worked out by the database
        # once for the records to be tested.
        def prepare(records)
          @lowered.each do |name, bound, cell|
            values = records.filter_map { |attributes| text(name, @reader.read(attributes, name)) }.uniq
            lowered = lower_all([bound, *values], name)
            cell[:target] = lowered.first
            cell[:values] = values.zip(lowered.drop(1)).to_h
          end
        end

        private

        def compile(node)
          case node
          when Arel::Nodes::And then compile_all(node.children)
          when Arel::Nodes::Or
            tests = node.children.map { compile(_1) }
            ->(attributes) { TypedValues.any_of(tests.map { _1.call(attributes) }) }
          when Arel::Nodes::Grouping then compile(node.expr)
          when Arel::Nodes::Not then negated(compile(node.expr))
          when Arel::Nodes::Equality then equality(node)
          when Arel::Nodes::NotEqual then not_equal(node)
          when Arel::Nodes::HomogeneousIn then homogeneous_in(node)
          when Arel::Nodes::In then in_list(node, negate: false)
          when Arel::Nodes::NotIn then in_list(node, negate: true)
          when Arel::Nodes::Between then between(node)
          when Arel::Nodes::GreaterThanOrEqual then bounded(node) { |value| value.. }
          when Arel::Nodes::LessThanOrEqual then bounded(node) { |value| ..value }
          when Arel::Nodes::LessThan then bounded(node) { |value| ...value }
          when Arel::Nodes::GreaterThan then greater_than(node)
          else refuse(node)
          end
        end

        # column = value, IS NULL when the bound value is nil (Arel's rule),
        # no row when it is unboundable; LOWER(column) = LOWER(value).
        def equality(node)
          return lower_equality(node) if lower?(node.left) && lower?(node.right)

          name = column(node.left, node)
          return ->(_) { false } if unboundable?(node.right)
          return is_null(name) if node.right.nil?
          return citext_equality(name, node.right, node) if Uniqueness.citext?(@klass, name)

          condition(name, value(node.right, node))
        end

        def not_equal(node)
          name = column(node.left, node)
          return ->(_) { true } if unboundable?(node.right)
          return negated(is_null(name)) if node.right.nil?
          return negated(citext_equality(name, node.right, node)) if Uniqueness.citext?(@klass, name)

          negated(condition(name, value(node.right, node)))
        end

        # IN or NOT IN over the values the attribute's type binds
        # (HomogeneousIn#casted_values: a value it cannot bind, or binds as
        # NULL, is left out); with none, IN (NULL): unknown for every row.
        def homogeneous_in(node)
          name = column(node.attribute, node)
          refuse(node) if Uniqueness.citext?(@klass, name)
          type = @klass.type_for_attribute(name)
          values = node.values.select { type.serializable?(_1) && !type.serialize(_1).nil? }
          return ->(_) { nil } if values.empty?

          test = condition(name, values)
          node.type == :in ? test : negated(test)
        end

        # IN (...) or NOT IN (...) built with Arel: unboundable values are
        # left out (an empty list is 1=0, or 1=1 for NOT IN), and each other
        # is bound as it is, NULL included (x IN (1, NULL) is unknown where
        # x is not 1), unlike a hash condition's list.
        def in_list(node, negate:)
          name = column(node.left, node)
          refuse(node) unless node.right.is_a?(Array)
          refuse(node) if Uniqueness.citext?(@klass, name)
          tests = node.right.reject { unboundable?(_1) }.map { |bound| in_member(name, bound, node) }
          return ->(_) { negate } if tests.empty?

          test = ->(attributes) { TypedValues.any_of(tests.map { _1.call(attributes) }) }
          negate ? negated(test) : test
        end

        # One member of an Arel IN list, compared with =: a value bound as
        # NULL (nil, or one its type serializes to nil) is unknown.
        def in_member(name, bound, node)
          raw = value(bound, node)
          type = @klass.type_for_attribute(name)
          return ->(_) { nil } if raw.nil? || (type.serializable?(raw) && type.serialize(raw).nil?)

          condition(name, raw)
        end

        def between(node)
          name = column(node.left, node)
          refuse(node) unless node.right.is_a?(Arel::Nodes::And) && node.right.children.size == 2
          low, high = node.right.children.map { |bound| ranged_value(bound, node) }
          condition(name, low..high)
        end

        def bounded(node)
          name = column(node.left, node)
          condition(name, yield(ranged_value(node.right, node)))
        end

        # > value: at least value, and not equal to it.
        def greater_than(node)
          name = column(node.left, node)
          bound = ranged_value(node.right, node)
          at_least = condition(name, bound..)
          equal = condition(name, bound)
          ->(attributes) { TypedValues.all_of([at_least.call(attributes), negated(equal).call(attributes)]) }
        end

        def condition(name, value)
          string_comparison!(name)
          compiled = TypedValues.condition(@klass, name, value)
          ->(attributes) { compiled.evaluate(@reader, attributes) }
        end

        def is_null(name)
          ->(attributes) { @reader.read(attributes, name).nil? }
        end

        def negated(test)
          lambda do |attributes|
            result = test.call(attributes)
            result.nil? ? nil : !result
          end
        end

        # LOWER(column) = LOWER(value): the database lowers the value and the
        # values the records hold (prepare), and they are compared here.
        def lower_equality(node)
          name = column(single_argument(node.left, node), node)
          bound = single_argument(node.right, node)
          return ->(_) { false } if unboundable?(bound)
          return is_null(name) if bound.nil?

          lowered(name, database_text(bound, node))
        end

        # A citext column's = is case-insensitive: LOWER on both sides.
        def citext_equality(name, bound, node)
          lowered(name, database_text(bound, node))
        end

        def lowered(name, bound_text)
          string_comparison!(name)
          return ->(_) { nil } if bound_text.nil?

          cell = {}
          @lowered << [name, bound_text, cell]
          lambda do |attributes|
            stored = text(name, @reader.read(attributes, name))
            next nil if stored.nil?

            cell[:values].fetch(stored) == cell[:target]
          end
        end

        # A string comparison is the database's: refused where it may not be
        # Ruby's (a collation of the column's own; MySQL's case-insensitive
        # default collations).
        def string_comparison!(name)
          column = @klass.columns_hash[name]
          return unless column && %i[string text citext].include?(column.type)

          if column.respond_to?(:collation) && column.collation
            raise UnsupportedQuery.new(@klass, "a uniqueness check on #{name}, which has a collation of its own (#{column.collation})")
          end
          adapter = @klass.with_connection(&:adapter_name)
          return if adapter.match?(STRING_ADAPTERS)

          raise UnsupportedQuery.new(@klass, "a uniqueness check comparing strings on #{adapter}")
        end

        # The text LOWER(column) reads for an attribute's value: the text the
        # column holds, a character(n) value without its trailing spaces
        # (its cast to text drops them).
        def text(name, value)
          return nil if value.nil?

          serialized = @klass.type_for_attribute(name).serialize(value)&.to_s
          serialized && TypedValues.schema(@klass).blank_padded.include?(name) ? TypedValues.unpadded(serialized) : serialized
        end

        # LOWER of each of +texts+, as the database computes it. Texts
        # lowered before (per database, in this process) are not sent
        # again; the rest go in one query (PostgreSQL: one array
        # parameter; SQLite: one SELECT of LOWER(...) per 500).
        def lower_all(texts, name = "value") = Uniqueness.lower_texts(@klass, texts, name: name)

        # The column an attribute node names: one of this model's own table.
        def column(node, predicate)
          unless node.is_a?(Arel::Attributes::Attribute) && node.relation.respond_to?(:name) &&
                 node.relation.name.to_s == @klass.table_name.to_s && !node.relation.is_a?(Arel::Nodes::TableAlias)
            refuse(predicate)
          end
          TypedValues.attribute_name(@klass, node.name)
        end

        def lower?(node)
          node.is_a?(Arel::Nodes::NamedFunction) && node.name.to_s.casecmp?("LOWER") && node.expressions.size == 1
        end

        def single_argument(node, predicate)
          refuse(predicate) unless lower?(node)
          node.expressions.first
        end

        def unboundable?(node)
          node.respond_to?(:unboundable?) && node.unboundable?
        end

        # The value a bound node carries, before its type casts it (the
        # condition casts it, as Active Record does). A literal quoted
        # without a type, another column or an expression is refused.
        def value(node, predicate)
          return literal(node) if node.is_a?(Arel::Nodes::Casted)

          bound_attribute(node, predicate).value_before_type_cast
        end

        # A literal Arel quotes through its attribute's type (attr.in([..])):
        # one out of the type's range cannot be quoted, and the query is not
        # run (LiteralOutOfRange).
        def literal(node)
          node.value_for_database
          node.value
        rescue ::RangeError
          raise LiteralOutOfRange
        end

        def ranged_value(node, predicate)
          refuse(predicate) if unboundable?(node)
          value(node, predicate)
        end

        # The text the database is given for a bound value.
        def database_text(node, predicate)
          return literal(node).then { node.value_for_database&.to_s } if node.is_a?(Arel::Nodes::Casted)

          bound_attribute(node, predicate).value_for_database&.to_s
        end

        # The attribute a bound value is (Active Record passes it to Arel as
        # it is, or in a BindParam).
        def bound_attribute(node, predicate)
          bound = node.is_a?(Arel::Nodes::BindParam) ? node.value : node
          refuse(predicate) unless bound.is_a?(ActiveModel::Attribute)
          bound
        end

        def refuse(node)
          described = node.respond_to?(:to_sql) ? (node.to_sql rescue node.class.name) : node.class.name
          raise UnsupportedQuery.new(@klass, "a uniqueness check's condition (#{described.to_s[0, 80]})")
        end
      end

      def self.install!
        validator = ActiveRecord::Validations::UniquenessValidator
        validator.prepend(ValidatorPatch) unless validator.ancestors.include?(ValidatorPatch)
      end
    end
  end
end

# Under Rails the engine installs the validator patch (Lyra::Engine).
if defined?(ActiveSupport)
  ActiveSupport.on_load(:active_record) { Lyra::Projections::Uniqueness.install! } unless defined?(Lyra::Engine)
end
