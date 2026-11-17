# frozen_string_literal: true

module Lyra
  module Projections
    # Raised when ES-NoProj is asked a query it cannot answer exactly from
    # events. It used to answer such queries anyway, unfiltered or partly
    # filtered; a wrong answer is worse than an error.
    class UnsupportedQuery < StandardError
      def initialize(model_class, what)
        name = model_class.respond_to?(:name) ? model_class.name : model_class.to_s
        super(
          "ES-NoProj cannot evaluate #{what} on #{name} from the event store, and will not guess " \
          "(an unfiltered or partly filtered answer would be wrong). Use a projected mode " \
          "(projection_mode :sync or :async), or projection_mode :lazy, which runs real SQL " \
          "on a table brought up to date from the event log before each query."
        )
      end
    end

    # ActiveRecord::Relation-like wrapper for cached projection results.
    #
    # It answers exactly or raises UnsupportedQuery: it evaluates hash
    # conditions, ordering, limits and scopes made of hash conditions in Ruby,
    # and refuses SQL fragments, joins, conditions it cannot read and scopes it
    # cannot reduce to conditions.
    #
    # Enables method chaining on cached results so that code written for
    # ActiveRecord works transparently in disabled projections mode.
    #
    # Usage:
    #   relation = CachedRelation.new(User, records)
    #   relation.where(status: "active").order(:name).limit(10)
    #
    # What an ES-NoProj query returns to the application, and what it uses
    # (Lyra::PurposeBoundReads): the same rule as ActiveRecord's relations.
    #
    # A query here filters eagerly, so each relation keeps what its query
    # named (query_terms: the conditions of where, where.not and where!, the
    # order keys, a subquery's own terms; select and group are kept already)
    # and the check is made when the answer is asked for:
    #
    # - a record load (to_a, first, find_by, each, length, ...) has its named
    #   attributes checked without the consent step, then returns records
    #   narrowed to the selected columns, each checked against its policy,
    #   consent included, for what it holds and what the query named;
    # - an aggregate, exists?, ids, pluck, pick, a bulk write or in_batches is
    #   checked whole, subject Model$*.
    #
    # Only the outermost call checks: the relations a query builds inside
    # itself (a group's aggregates, exists? through find_by, a subquery while
    # a where filters) are its machinery, not deliveries.
    module CachedRelationDelivery
      %i[to_a to_ary [] first last second third take take! first! last!].each do |name|
        define_method(name) do |*args, **kwargs, &block|
          deliver { super(*args, **kwargs, &block) }
        end
      end

      # With a block (and no id), Enumerable's find over the records the
      # relation loads, as Active Record does: each checked first.
      def find(*args, &block)
        return deliver { @records.to_a }.find(*args, &block) if block

        deliver { super }
      end

      # select with a block is Enumerable's over the loaded records, as in
      # Active Record, and returns an Array: the block sees only records the
      # purpose check delivered (narrowed to the selection, each checked,
      # consent included). It used to see the cached records, unchecked.
      def select(*args, &block)
        return super unless block

        deliver { @records.to_a }.select(&block)
      end

      def find_by(*args, **kwargs, &block)
        deliver(conditions_term(args.first || kwargs)) { super }
      end

      def find_by!(*args, **kwargs, &block)
        deliver(conditions_term(args.first || kwargs)) { super }
      end

      # Without a block, an Enumerator over the checked records, as
      # ActiveRecord's each over its loaded records.
      def each(&block)
        return super if Thread.current[:lyra_cached_delivery]
        return to_enum(:each) { size } unless block

        deliver { @records.to_a }.each(&block)
      end

      # Batch by batch, as Active Record loads them: each batch delivered
      # (checked) in a checking scope of its own, so the subject's rights are
      # read afresh before each (Lyra::Rights.batches).
      def find_in_batches(batch_size: 1000, &block)
        return deliver { @records.to_a }.each_slice(batch_size) unless block
        return deliver { @records.to_a }.each_slice(batch_size, &block) unless Lyra::PurposeBoundReads.checking?

        Lyra::PurposeBoundReads.batch_scopes do |next_batch|
          Lyra::PurposeBoundReads.once do
            @records.each_slice(batch_size) do |slice|
              batch = deliver { slice }
              Lyra::PurposeBoundReads.outside_once { block.call(batch) }
            ensure
              next_batch.call
            end
          end
        end
      end

      def find_each(batch_size: 1000, &block)
        return super unless block && Lyra::PurposeBoundReads.checking?

        find_in_batches(batch_size: batch_size) { |batch| batch.each(&block) }
      end

      # As ActiveRecord: these load the records.
      def length = deliver { @records.to_a }.length
      def present? = deliver { @records.to_a }.present?
      def blank? = deliver { @records.to_a }.blank?

      # As ActiveRecord: these count or test for existence. With a block,
      # they load the records.
      %i[size empty? total_count ids].each do |name|
        define_method(name) { aggregated { super() } }
      end

      %i[any? none? one? many?].each do |name|
        define_method(name) do |&block|
          next deliver { @records.to_a }.public_send(name, &block) if block

          aggregated { super() }
        end
      end

      def count(column_name = nil, &block)
        return deliver { @records.to_a }.count(&block) if block

        all = column_name.nil? || [:all, "*", "all"].include?(column_name)
        aggregated(all ? [] : [[:value, column_name]]) { super }
      end

      def sum(column_name = nil, &block)
        return deliver { @records.to_a }.sum(&block) if block

        aggregated([[:value, column_name]]) { super }
      end

      %i[average minimum maximum].each do |name|
        define_method(name) do |column_name|
          aggregated([[:value, column_name]]) { super(column_name) }
        end
      end

      def calculate(operation, column_name = nil)
        all = operation.to_s == "count" && (column_name.nil? || [:all, "*", "all"].include?(column_name))
        aggregated(all ? [] : [[:value, column_name]]) { super }
      end

      # A Hash of conditions, or an SQL fragment with its binds: what they
      # name is used (the fragment is not evaluated here; see UnsupportedQuery).
      def exists?(conditions = nil)
        terms = case conditions
                when Hash then conditions_term(conditions)
                when Array then conditions.first.is_a?(String) ? [[:value, conditions.first]] : []
                else []
                end
        aggregated(terms) { super }
      end

      def pluck(*column_names)
        aggregated([[:value, column_names]]) { super }
      end

      def pick(*column_names)
        aggregated([[:value, column_names]]) { super }
      end

      # Bulk writes (method_missing below runs them): their filter is a use,
      # and so is what update_all's SET expressions read.
      %i[update_all delete_all touch_all destroy_all].each do |name|
        define_method(name) do |*args, **kwargs, &block|
          unless Thread.current[:lyra_cached_delivery]
            reads = name == :update_all ? Lyra::PurposeBoundReads::RelationCheck.set_reads(args.first || kwargs) : nil
            query_check(:all, reads ? [[:value, reads]] : [])
          end
          super(*args, **kwargs, &block)
        end
      end

      # Checked once for the relation; the application's block is its own
      # code, checked each time.
      def in_batches(*args, **kwargs, &block)
        return super unless block && Lyra::PurposeBoundReads.checking?

        Lyra::PurposeBoundReads.batch_scopes do |next_batch|
          Lyra::PurposeBoundReads.once do
            query_check(:all)
            super(*args, **kwargs) do |batch|
              Lyra::PurposeBoundReads.outside_once { block.call(batch) }
            ensure
              next_batch.call
            end
          end
        end
      end

      # As ActiveRecord's records: the records the query loads, checked.
      def records
        deliver { @records.to_a }
      end

      # As ActiveRecord's: it loads the records (each shown is checked).
      def inspect
        shown = deliver { @records.to_a.first(11) }
        entries = shown.first(10).map(&:inspect)
        entries << "..." if shown.size > 10
        "#<#{self.class.name} [#{entries.join(', ')}]>"
      end

      def to_s
        inspect
      end

      # Filtering: what it names is recorded on the relation it returns.
      # Relations evaluated while it filters (a subquery) are part of it.
      def where(*args, **kwargs)
        relation = inside_query { super }
        conditions = args.empty? ? kwargs : args.first
        return relation if conditions.blank? || conditions == :chain || !relation.is_a?(CachedRelation) || relation.equal?(self)

        relation.continue_plan(self, [:where, conditions]) if conditions.is_a?(Hash)
        relation.add_query_terms(conditions.is_a?(String) ? [[:value, conditions]] : conditions_term(conditions))
      end

      def not(conditions)
        inside_query { super }.add_query_terms(conditions_term(conditions))
      end

      def order(*args)
        relation = super
        return relation if args.empty? || relation.equal?(self)

        relation.continue_plan(self, [:order, args])
        relation.add_query_terms([[:value, args]])
      end

      def reorder(*args)
        relation = super
        relation.continue_plan(self, [:reorder, args])
        args.compact.empty? ? relation : relation.add_query_terms([[:value, args]])
      end

      def order!(*args)
        super
        args.empty? ? self : add_query_terms!([[:value, args]])
      end

      def or(other)
        super.add_query_terms(other.query_terms)
      end

      private

      def conditions_term(conditions)
        conditions.present? ? [[:conditions, conditions]] : []
      end

      # Nested deliveries inside the block are the query's own work.
      def inside_query
        previous = Thread.current[:lyra_cached_delivery]
        Thread.current[:lyra_cached_delivery] = true
        yield
      ensure
        Thread.current[:lyra_cached_delivery] = previous
      end

      def query_check(kind, extra_terms = [])
        return unless Lyra::PurposeBoundReads.checking?

        names = lyra_query_names(extra_terms)
        named = names.result
        Lyra::PurposeBoundReads.check_query(model_class, named, kind, names.whole, joined: joined_classes)
        named
      end

      # An aggregate, exists?, pluck: checked whole, then run as one query,
      # over the records a right in force does not leave out
      # (Lyra::Rights::Queries; a record whose people cannot be read raises).
      def aggregated(extra_terms = [])
        return yield if Thread.current[:lyra_cached_delivery]
        return yield unless Lyra::PurposeBoundReads.checking?

        Lyra::PurposeBoundReads.once do
          named = query_check(:all, extra_terms)
          kept = Lyra::PurposeBoundReads.rights_kept_records(model_class, named, @records)
          kept ? inside_query { with_records(kept) { yield } } : inside_query { yield }
        end
      end

      # The block run with +records+ as this relation's records.
      def with_records(records)
        saved = @records
        @records = records
        yield
      ensure
        @records = saved
      end

      # A record load: its named attributes checked first, then each record.
      def deliver(extra_terms = [])
        return yield if Thread.current[:lyra_cached_delivery]

        named = query_check(:load, extra_terms)
        names = named ? named.fetch(model_class, []) : []
        result = inside_query { yield }
        case result
        when Array then result.map { |record| delivered(record, names) }
        when ActiveRecord::Base then delivered(result, names)
        else result
        end
      end

      def delivered(record, names)
        return record unless record.is_a?(ActiveRecord::Base)

        if selected_columns
          whole = record
          values = record.attributes_before_type_cast.slice(*selected_columns)
          record = Lyra::PurposeBoundReads.internal(INTERNAL) { model_class.instantiate(values) }
          # Its people, read from the whole record before it was narrowed
          # (the table under ES-NoProj has no row to read them from).
          if Lyra::PurposeBoundReads.rights_in_force?
            Lyra::PurposeBoundReads.internal(INTERNAL) { Lyra::Rights::SubjectKeys.remember(record, whole) }
          end
        end
        Lyra::PurposeBoundReads.check(record, names)
        record
      end
    end

    class CachedRelation
      include Enumerable
      include CachedJoins

      attr_reader :model_class
      # Columns a select(...) asked for: the records returned are narrowed to
      # them, as SQL would return them, so that a purpose-bound read checks
      # what the query selected (Lyra::PurposeBoundReads). Carried through
      # every relation derived from this one.
      attr_accessor :selected_columns
      # Equality conditions of where clauses: the attributes a record created
      # through this relation gets (scope_for_create), as on ActiveRecord.
      attr_writer :create_attributes

      def create_attributes = @create_attributes || {}

      # The equality conditions on +table_name+, as ActiveRecord's
      # where_values_hash gives them. A has_many :through or
      # has_and_belongs_to_many write reads them to build its join row; only
      # those on the model's own table are known here.
      def where_values_hash(table_name = model_class.table_name)
        table_name.to_s == model_class.table_name.to_s ? create_attributes.stringify_keys : {}
      end

      # Columns of a group(...): the aggregates return a hash per group.
      attr_writer :group_columns

      def group_columns = @group_columns || []

      # What the query this relation answers named, as [kind, term] pairs
      # (CachedRelationDelivery records them): [:conditions, hash] or
      # [:value, columns or an SQL fragment]. Carried through every relation
      # derived from this one, for the purpose check.
      attr_writer :query_terms

      def query_terms = @query_terms || []

      # The order the records are in, as [{ column => :asc/:desc }]: an
      # order adds to it and reorder replaces it, as in ActiveRecord (a
      # default scope's order comes first). Carried through every relation
      # derived from this one.
      attr_writer :ordering

      def ordering = @ordering || []

      # The default scope (an ActiveRecord relation) these records were
      # narrowed by (DefaultScopes.narrow), carried through every relation
      # derived from this one.
      attr_accessor :default_scope_applied

      # How the records were selected, while that was conditions and orders
      # only: [base, steps]. +base+ is the relation (or a Proc building it)
      # the selection started from; +steps+ are [:scope, relation, what] (a
      # default scope, or an ActiveRecord relation merged in), [:where, hash],
      # [:order, args] and [:reorder, args]. unscope and rewhere replay it
      # without what they take off, as ActiveRecord rebuilds its query.
      # where, order, reorder and merge carry it on; any other query method
      # (limit, where.not, an SQL fragment, a join) leaves it behind, and an
      # unscope after it that would change the answer is refused.
      attr_accessor :plan

      # This relation's plan: +source+'s plus +step+ (nothing if +source+
      # has none).
      def continue_plan(source, step)
        @plan = source.plan && [source.plan[0], source.plan[1] + [step]]
        self
      end

      # A limit, offset or page was applied: what the relation holds is a
      # window of its selection.
      attr_writer :windowed

      def windowed? = @windowed ? true : false

      # Attributes create_with gives a record built through the relation.
      attr_writer :create_with_attributes

      def create_with_attributes = @create_with_attributes || {}

      def initialize(model_class, records = [])
        @model_class = model_class
        @records = records.to_a
      end

      # A relation over +records+ that keeps this one's selection.
      def spawn_records(records)
        relation = self.class.new(model_class, records)
        relation.selected_columns = selected_columns
        relation.create_attributes = create_attributes
        relation.group_columns = group_columns
        relation.query_terms = query_terms
        relation.joined_classes = joined_classes
        relation.ordering = ordering
        relation.default_scope_applied = default_scope_applied
        relation.windowed = windowed?
        relation.create_with_attributes = create_with_attributes
        relation.extending!(*extensions) if extensions.any?
        relation
      end

      # The models joined into this relation's query, kept when a later call
      # (group, order) builds a relation without the joined rows: a column
      # named without its table may be theirs.
      attr_writer :joined_classes

      def joined_classes
        ((@joined_classes || []) + joined_associations.values.map { _1.reflection.klass }).uniq
      end

      # This relation, with +terms+ added to what its query named.
      def add_query_terms(terms)
        @query_terms = query_terms + terms if terms.any?
        self
      end
      alias_method :add_query_terms!, :add_query_terms

      # The attribute names this relation's query names (and +extra_terms+),
      # by model, as Lyra::PurposeBoundReads.named_fields_of gives them for
      # an ActiveRecord relation: its conditions (a condition on a joined
      # table counts for that table's model), order keys, group and select
      # columns, and a subquery's own.
      def lyra_named_fields(extra_terms = [])
        lyra_query_names(extra_terms).result
      end

      # The same as a Lyra::PurposeBoundReads::NamedFields, with what this
      # relation's subqueries name (#whole).
      def lyra_query_names(extra_terms = [])
        named = Lyra::PurposeBoundReads::NamedFields.new
        named.joined(model_class, joined_classes)
        (query_terms + extra_terms).each do |kind, term|
          kind == :conditions ? named.conditions(term, model_class) : named.value(term, model_class)
        end
        named.value(group_columns, model_class).value(selected_columns, model_class)
      end

      # A relation over the records the block selects, keeping this one's
      # selection (Model.lyra_processable under ES-NoProj).
      def lyra_select_records(&block)
        spawn_records(@records.select(&block))
      end

      # The records as they are, for Lyra's own relations (records is the
      # application's, checked).
      def raw_records
        @records
      end
      protected :raw_records

      # =========================================================================
      # Enumerable / Array-like interface
      # =========================================================================

      def each(&block)
        @records.each(&block)
      end

      def to_a
        @records.dup
      end

      def to_ary
        to_a
      end

      def [](index)
        @records[index]
      end

      def size
        @records.size
      end

      def length
        size
      end

      # COUNT(*) or COUNT(column): SQL counts the non-NULL values of a column,
      # so "" and false count (present? would drop them).
      def count(column_name = nil, &block)
        return aggregate_by_group(:count, column_name) if group_columns.any? && !block

        if block_given?
          @records.count(&block)
        elsif column_name.nil? || [:all, "*"].include?(column_name) || column_name.to_s == "all"
          @records.size
        else
          aggregate_values(column_name).size
        end
      end

      def empty?
        @records.empty?
      end

      def any?(&block)
        block_given? ? @records.any?(&block) : @records.any?
      end

      def none?(&block)
        block_given? ? @records.none?(&block) : @records.none?
      end

      def one?(&block)
        block_given? ? @records.one?(&block) : @records.one?
      end

      def many?
        @records.size > 1
      end

      def present?
        @records.present?
      end

      def blank?
        @records.blank?
      end

      # =========================================================================
      # Finder methods
      # =========================================================================

      def first(limit = nil)
        limit ? @records.first(limit) : @records.first
      end

      def last(limit = nil)
        limit ? @records.last(limit) : @records.last
      end

      def second
        @records[1]
      end

      def third
        @records[2]
      end

      def take(limit = nil)
        limit ? @records.first(limit) : @records.first
      end

      def take!
        take || raise(ActiveRecord::RecordNotFound.new("Couldn't find #{model_class.name}", model_class))
      end

      def first!
        first || raise(ActiveRecord::RecordNotFound.new("Couldn't find #{model_class.name}", model_class))
      end

      def last!
        last || raise(ActiveRecord::RecordNotFound.new("Couldn't find #{model_class.name}", model_class))
      end

      def find(id)
        record = @records.find { |r| r.id.to_s == id.to_s }
        record || raise(ActiveRecord::RecordNotFound.new(
          "Couldn't find #{model_class.name} with '#{model_class.primary_key}'=#{id}",
          model_class, model_class.primary_key, id
        ))
      end

      def find_by(attributes)
        tests = condition_tests(model_class, attributes)
        @records.find { |record| true.equal?(matches_all?(record, tests)) }
      end

      def find_by!(attributes)
        find_by(attributes) || raise(ActiveRecord::RecordNotFound.new(
          "Couldn't find #{model_class.name}", model_class
        ))
      end

      # As ActiveRecord's: the one record, RecordNotFound when there is none
      # and SoleRecordExceeded when there are more.
      def sole
        found, undesired = first(2)
        raise ActiveRecord::RecordNotFound.new("Couldn't find #{model_class.name}", model_class) if found.nil?
        raise ActiveRecord::SoleRecordExceeded.new(model_class) if undesired

        found
      end

      def find_sole_by(attributes)
        where(attributes).sole
      end

      def exists?(conditions = nil)
        case conditions
        when nil, false
          @records.any?
        when Integer, String
          @records.any? { |r| r.id.to_s == conditions.to_s }
        when Hash
          find_by(conditions).present?
        when Array
          # exists?(["title = ?", x]): a fragment, as where takes it (or refuses it).
          where(*conditions).any?
        else
          # It used to answer whether any record exists, ignoring the condition.
          raise UnsupportedQuery.new(model_class, "exists?(#{conditions.inspect[0, 60]})")
        end
      end

      # =========================================================================
      # Query methods (return new CachedRelation for chaining)
      # =========================================================================

      # where with no arguments returns the chain (where.not, where.missing,
      # where.associated), as ActiveRecord's does; where(nil) is a no-op.
      def where(*args)
        return WhereChain.new(self) if args.empty? || args.first == :chain

        conditions = args.first
        return self if conditions.nil?

        if conditions.is_a?(String) && simple_fragment?(conditions, args.size - 1)
          return fragment_filter(conditions, args.drop(1))
        end

        check_hash_conditions!(conditions, "where(#{args.inspect[1..-2][0, 60]})")
        raise UnsupportedQuery.new(model_class, "where(#{args.inspect[1..-2][0, 60]})") if args.size > 1

        own, joined = split_joined_conditions(conditions)
        own = AssociationConditions.rewrite(model_class, own)
        tests = condition_tests(model_class, own)
        joined = compile_joined(joined)
        relation = filter_rows do |record, joins|
          true.equal?(matches_all?(record, tests)) && (joined.empty? || true.equal?(joined_match(joins, joined)))
        end
        scalars = own.select { |key, value| model_class.column_names.include?(key.to_s) && !value.is_a?(Array) && !value.is_a?(Range) && !value.is_a?(Hash) }
        relation.create_attributes = create_attributes.merge(scalars.transform_keys(&:to_s)) if scalars.any?
        relation
      end

      # The SQL fragments evaluated here: "col OP ?" terms, one bound value
      # each, joined all by AND or all by OR (no parentheses), where OP is =,
      # !=, <>, <, <=, >, >=, LIKE or ILIKE and col a column of this model.
      # That covers search boxes ("firstname ILIKE ? OR email ILIKE ?") and
      # date filters ("registered_at >= ?"). Any other fragment is refused.
      FRAGMENT_TERM = /\A\s*"?(\w+)"?\s*(<=|>=|<>|!=|=|<|>|\bi?like\b)\s*\?\s*\z/i

      def simple_fragment?(fragment, binds)
        joiner, terms = fragment_terms(fragment)
        joiner && terms.size == binds && binds.positive? &&
          terms.all? { |term| (m = term.match(FRAGMENT_TERM)) && model_class.column_names.include?(m[1]) }
      end

      def fragment_terms(fragment)
        ors = fragment.split(/\bOR\b/i)
        ands = fragment.split(/\bAND\b/i)
        return [nil, []] if ors.size > 1 && ands.size > 1

        ors.size > 1 ? [:or, ors] : [:and, ands]
      end

      def fragment_filter(fragment, values)
        joiner, terms = fragment_terms(fragment)
        tests = terms.map { |term| term.match(FRAGMENT_TERM) }.zip(values).map do |match, value|
          fragment_test(match[1], match[2].downcase, value)
        end
        filter_rows do |record, _joins|
          results = tests.map { |test| test.call(record) }
          joiner == :or ? results.any? : results.all?
        end
      end

      # A predicate on one record. NULL on either side is unknown, so false.
      def fragment_test(column, op, value)
        if op.end_with?("like")
          TypedValues.fragment_value(model_class, column, nil) # refuses a pattern on a ciphertext
          regexp = like_regexp(value.to_s, case_insensitive: op == "ilike")
          return ->(record) { (v = record.read_attribute(column)) && regexp.match?(v.to_s) }
        end

        bound = TypedValues.fragment_value(model_class, column, value)
        read = TypedValues.comparable_reader(model_class, column)
        lambda do |record|
          v = read.call(record)
          next false if v.nil? || bound.nil?

          cmp = TypedValues.compare(v, bound)
          next false if cmp.nil?

          case op
          when "=" then cmp.zero?
          when "!=", "<>" then !cmp.zero?
          when "<" then cmp.negative?
          when "<=" then cmp <= 0
          when ">" then cmp.positive?
          when ">=" then cmp >= 0
          end
        end
      end

      # SQL LIKE: % any run, _ any one character, \ escapes; the rest literal.
      def like_regexp(pattern, case_insensitive:)
        source = pattern.scan(/\\.|%|_|[^\\%_]+/).map do |piece|
          case piece
          when "%" then ".*"
          when "_" then "."
          else Regexp.escape(piece.start_with?("\\") ? piece[1..] : piece)
          end
        end.join
        Regexp.new("\\A#{source}\\z", case_insensitive ? Regexp::IGNORECASE | Regexp::MULTILINE : Regexp::MULTILINE)
      end

      # SQL's NOT: a row is kept only when its conditions are definitely
      # false. One with a missing left-join partner under a condition on the
      # joined table is unknown (NULL), and is excluded, as SQL excludes it.
      def not(conditions)
        check_hash_conditions!(conditions, "where.not(#{conditions.inspect[0, 60]})")
        own, joined = split_joined_conditions(conditions)
        own = AssociationConditions.rewrite(model_class, own)
        tests = condition_tests(model_class, own)
        joined = compile_joined(joined)
        filter_rows do |record, joins|
          false.equal?(combine_and(matches_all?(record, tests), joined.empty? ? true : joined_match(joins, joined)))
        end
      end

      # where.missing(:assoc): records with no partner (a left join).
      def where_missing(*associations)
        names = associations.flatten.map(&:to_sym)
        left_joins(*names).send(:filter_rows) { |_record, joins| names.all? { joins[_1].nil? } }
      end

      # where.associated(:assoc): records with a partner (an inner join,
      # so a has_many repeats the record per partner, as ActiveRecord does).
      def where_associated(*associations)
        joins(*associations)
      end

      # As in ActiveRecord, an order adds to the one the relation has (a
      # default scope's order, an earlier order call); reorder replaces it.
      def order(*args)
        return self if args.empty?

        sorted_by(ordering + order_keys(args))
      end

      def sorted_by(keys)
        relation = spawn_records(sort_records(@records, keys))
        relation.ordering = keys
        relation
      end
      private :sorted_by

      # Order arguments as [{ column => :asc/:desc }]: symbols, hashes,
      # "col [ASC|DESC], ..." strings and Arel orderings of a column. Anything
      # else is refused; an unreadable ordering used to compare as equal and
      # leave the result silently unordered.
      def order_keys(args)
        args.flatten.flat_map do |arg|
          case arg
          when Symbol then [{ arg => :asc }]
          when Hash then arg.map { |column, direction| { column.to_sym => direction.to_s.downcase.to_sym } }
          when String
            arg.split(",").map do |part|
              match = part.strip.match(/\A"?(?:\w+"?\.)?"?(\w+)"?(?:\s+(asc|desc))?\z/i)
              raise UnsupportedQuery.new(model_class, "order(#{arg.inspect})") unless match && model_class.column_names.include?(match[1])

              { match[1].to_sym => (match[2] || "asc").downcase.to_sym }
            end
          when Arel::Nodes::Ordering
            raise UnsupportedQuery.new(model_class, "order(#{arg.to_sql})") unless arg.expr.respond_to?(:name)

            [{ arg.expr.name.to_sym => arg.descending? ? :desc : :asc }]
          else raise UnsupportedQuery.new(model_class, "order(#{arg.inspect[0, 60]})")
          end
        end
      end

      # SQL's OR of two relations over the same model: the records of either,
      # each once, in this one's order and then the other's.
      def or(other)
        unless other.is_a?(CachedRelation) && other.model_class == model_class
          raise UnsupportedQuery.new(model_class, "or(#{other.class})")
        end

        spawn_records((@records + other.raw_records.to_a).uniq { |record| record.id })
      end

      def reorder(*args)
        keys = args.compact.empty? ? [] : order_keys(args)
        return sorted_by(keys) if keys.any?

        relation = spawn_records(@records)
        relation.ordering = []
        relation
      end

      def reverse_order
        relation = spawn_records(@records.reverse)
        relation.ordering = ordering.map { |key| key.transform_values { |direction| direction == :desc ? :asc : :desc } }
        relation
      end

      def limit(count)
        spawn_records(@records.first(count)).tap { _1.windowed = true }
      end

      def offset(count)
        spawn_records(@records.drop(count)).tap { _1.windowed = true }
      end

      # =========================================================================
      # Pagination support (Kaminari/WillPaginate compatibility)
      # =========================================================================

      def page(num)
        @current_page = [num.to_i, 1].max
        @per_page ||= 25
        self
      end

      def per(num)
        @per_page = num.to_i
        paginated_records
      end

      def total_pages
        return 1 if @per_page.nil? || @per_page <= 0
        (@records.size.to_f / @per_page).ceil
      end

      def current_page
        @current_page || 1
      end

      def total_count
        @records.size
      end

      def limit_value
        @per_page
      end

      def offset_value
        return 0 unless @current_page && @per_page
        (@current_page - 1) * @per_page
      end

      private def paginated_records
        return self unless @current_page && @per_page

        start_idx = (@current_page - 1) * @per_page
        paginated = @records[start_idx, @per_page] || []

        result = spawn_records(paginated)
        result.windowed = true
        result.instance_variable_set(:@current_page, @current_page)
        result.instance_variable_set(:@per_page, @per_page)
        result.instance_variable_set(:@total_records, @records.size)
        result
      end

      def distinct
        spawn_records(@records.uniq)
      end

      def uniq
        distinct
      end

      # =========================================================================
      # Eager loading (no-ops for cached records - data is already in memory)
      # =========================================================================

      def preload(*args)
        # Associations are already loaded or don't exist in cache
        # This is a no-op but allows the chain to continue
        self
      end

      def includes(*args)
        # Same as preload - no-op for cached records
        self
      end

      def eager_load(*args)
        # Same as preload - no-op for cached records
        self
      end

      def references(*args)
        self
      end

      # =========================================================================
      # Scoping methods
      # =========================================================================

      def all
        self
      end

      def none
        spawn_records([])
      end

      # As Model.unscoped: under ES-NoProj every record of a monitored model,
      # from the event store, with no default scope.
      def unscoped
        return self unless events_only? && model_class.respond_to?(:lyra_monitored) && model_class.lyra_monitored

        EventStoreReader.relation(model_class)
      end

      # unscope(where: :deleted_at), unscope(:where), unscope(:order), and the
      # scopes made of them (paranoia's with_deleted, discard's
      # with_discarded). While the relation was selected by conditions and
      # orders only (its plan), the selection is replayed without what is
      # taken off, the default scope included, as ActiveRecord rebuilds its
      # query: Model.with_discarded, Model.where(...).with_discarded,
      # author.books.where(...).with_discarded. After another query method
      # (a limit, where.not, an SQL fragment) an unscope that would change
      # the answer is refused rather than answered short: the records it
      # would bring back are no longer in the relation.
      def unscope(*args)
        args = args.flatten
        return self if args.empty?

        if plan
          base, steps = plan
          return replay_plan(base, unscoped_steps(base, steps, args))
        end

        unscope_without_plan(args)
      end

      # As ActiveRecord's: the conditions on these columns are replaced
      # (unscope, then where), the default scope's included.
      def rewhere(conditions)
        raise UnsupportedQuery.new(model_class, "rewhere(#{conditions.inspect[0, 60]})") unless conditions.is_a?(Hash)
        return self if conditions.empty?

        unscope(where: conditions.keys).where(conditions)
      end

      def unscope!(*args)
        replace_with!(unscope(*args))
      end

      # The plan's base with +steps+ applied.
      def replay_plan(base, steps)
        relation = base.is_a?(Proc) ? base.call : base
        default = nil
        steps.each do |kind, arg, what|
          relation =
            case kind
            when :scope
              default = arg if what == :default
              relation.narrowed_by(arg, what == :default ? DefaultScopes.description(model_class) : what)
            when :where then relation.where(arg)
            when :order then relation.order(*arg)
            when :reorder then relation.reorder(*arg)
            end
        end
        relation = relation.spawn if relation.equal?(base)
        relation.plan = [base, steps]
        relation.default_scope_applied = default
        relation
      end
      private :replay_plan

      # +steps+ without what unscope(*args) takes off. A condition the base
      # itself was read with (an association's foreign key) cannot be taken
      # off here, and is refused.
      def unscoped_steps(base, steps, args)
        args.each do |arg|
          where_columns, other = unscope_target(arg)
          if where_columns
            check_base_conditions!(base, where_columns, args)
            steps = steps.filter_map do |kind, value, what|
              next [kind, value, what] unless kind == :where

              kept = where_columns == :all ? {} : value.reject { |key, _| where_columns.include?(column_of(key)) }
              kept.empty? ? nil : [kind, kept, what]
            end
          elsif other == :order
            steps = steps.reject { |kind, *| kind == :order || kind == :reorder }
          end
          steps = steps.map do |kind, value, what|
            kind == :scope ? [kind, DefaultScopes.built { value.unscope(arg) }, what] : [kind, value, what]
          end
        end
        steps
      end
      private :unscoped_steps

      # [columns, nil] for a where unscope (:all for every condition), or
      # [nil, the clause] for another.
      def unscope_target(arg)
        case arg
        when :where, "where" then [:all, nil]
        when Hash
          raise UnsupportedQuery.new(model_class, "unscope(#{arg.inspect})") unless arg.keys.map(&:to_sym) == [:where]

          [Array(arg.values.first).map { |column| column_of(column) }, nil]
        else [nil, arg.to_sym]
        end
      end
      private :unscope_target

      def column_of(key) = key.to_s.split(".").last.delete('"')
      private :column_of

      def check_base_conditions!(base, columns, args)
        return if base.is_a?(Proc)

        named = base.query_terms.flat_map { |kind, term| kind == :conditions && term.is_a?(Hash) ? term.keys.map { column_of(_1) } : [] }
        hit = columns == :all ? named : named & columns
        return if hit.empty?

        raise UnsupportedQuery.new(model_class, "unscope(#{args.inspect[1..-2]}) of #{hit.join(', ')}, which already " \
                                                "selected the relation's records (an association's key, or a condition " \
                                                "before a limit, where.not or SQL fragment)")
      end
      private :check_base_conditions!

      # Without a plan: what the unscope would change must not be in the
      # relation already. An order can be dropped (records are kept in key
      # order, as an unordered query may return them).
      def unscope_without_plan(args)
        relation = self
        args.each do |arg|
          where_columns, other = unscope_target(arg)
          if default_scope_applied
            rest = DefaultScopes.built { default_scope_applied.unscope(arg) }
            if rest.where_clause != default_scope_applied.where_clause || rest.order_values != default_scope_applied.order_values
              raise UnsupportedQuery.new(model_class, "unscope(#{args.inspect[1..-2]}) after other query methods " \
                                                      "(the records the default scope leaves out are not in the relation " \
                                                      "any more: unscope first, as in #{model_class.name}.unscope(...).where(...))")
            end
          end
          if where_columns
            check_base_conditions!(self, where_columns, args)
          elsif other == :order && ordering.any?
            relation = relation.reorder(model_class.primary_key => :asc)
            relation.ordering = []
          elsif %i[limit offset].include?(other) && windowed?
            raise UnsupportedQuery.new(model_class, "unscope(:#{other}) after a #{other}")
          end
        end
        relation
      end
      private :unscope_without_plan

      def readonly(value = true)
        self
      end

      # =========================================================================
      # AR internal methods for association scope building
      # These are needed for belongs_to/has_many association loading
      # =========================================================================

      def alias_tracker
        @alias_tracker ||= ActiveRecord::Associations::AliasTracker.create(
          model_class.connection_pool, table.name, []
        )
      end

      def table
        model_class.arel_table
      end

      # As ActiveRecord::Relation delegates them to its model. Lyra's own code
      # uses with_connection: connection leases one to the thread until it ends.
      def connection
        model_class.connection
      end

      def with_connection(...)
        model_class.with_connection(...)
      end

      # ActiveRecord::Relation's value readers that its own code (calculations
      # on an association proxy, eager-loading checks) asks a scope for. This
      # relation holds loaded records: nothing is eager loaded, preloaded,
      # included or referenced.
      %i[eager_load_values includes_values preload_values references_values select_values
         order_values having_values].each do |reader|
        define_method(reader) { [] }
      end

      def group_values = group_columns.map(&:to_sym)

      def eager_loading? = false

      def distinct_value = false

      def joins_values
        []
      end

      def left_outer_joins_values
        []
      end

      def where_clause
        ActiveRecord::Relation::WhereClause.empty
      end

      def klass
        model_class
      end

      def scope_for_create
        create_attributes.merge(create_with_attributes)
      end

      # Records created through the relation take its equality conditions
      # (an association's foreign key) and create_with's attributes, as on
      # ActiveRecord; they are created through the model, so under ES-NoProj
      # the write is an event.
      def new(attributes = nil, &block)
        model_class.new(scope_for_create.merge((attributes || {}).to_h.transform_keys(&:to_s)), &block)
      end
      alias_method :build, :new

      def create(attributes = nil, &block)
        new(attributes, &block).tap(&:save)
      end

      def create!(attributes = nil, &block)
        new(attributes, &block).tap(&:save!)
      end

      def find_or_initialize_by(attributes, &block)
        find_by(attributes) || new(attributes, &block)
      end

      def find_or_create_by(attributes, &block)
        find_by(attributes) || create(attributes, &block)
      end

      def find_or_create_by!(attributes, &block)
        find_by(attributes) || create!(attributes, &block)
      end

      # As ActiveRecord's: the first record the relation selects, or one
      # built or created with its equality conditions. They used to run on
      # a bare relation of the model, creating records without them.
      def first_or_initialize(attributes = nil, &block)
        first || new(attributes, &block)
      end

      def first_or_create(attributes = nil, &block)
        first || create(attributes, &block)
      end

      def first_or_create!(attributes = nil, &block)
        first || create!(attributes, &block)
      end

      # As ActiveRecord: create, and when a unique index of the table would
      # refuse the record (a record of the model, any of them, already has
      # its values), the record the relation finds instead. The event store
      # enforces no index, so the would-be violation is looked for first;
      # without such an index a record is created, as ActiveRecord creates
      # one.
      def create_or_find_by(attributes, &block)
        unique_conflict?(attributes) ? find_by!(attributes) : create(attributes, &block)
      end

      def create_or_find_by!(attributes, &block)
        unique_conflict?(attributes) ? find_by!(attributes) : create!(attributes, &block)
      end

      def unique_conflict?(attributes)
        values = scope_for_create.merge(attributes.to_h.transform_keys(&:to_s))
        indexes = model_class.with_connection { |connection| connection.schema_cache.indexes(model_class.table_name) }
        indexes.any? do |index|
          next false unless index.unique && index.columns.is_a?(Array) && index.where.nil? && (index.columns - values.keys).empty?

          conditions = index.columns.to_h { |column| [column, values[column]] }
          Lyra::PurposeBoundReads.internal(INTERNAL) { EventStoreReader.where(model_class, conditions).exists? }
        end
      end
      private :unique_conflict?

      def create_with(attributes)
        relation = spawn_records(@records)
        relation.plan = plan
        relation.create_with_attributes = attributes.nil? ? {} : create_with_attributes.merge(attributes.to_h.transform_keys(&:to_s))
        relation
      end

      def create_with!(attributes)
        @create_with_attributes = attributes.nil? ? {} : create_with_attributes.merge(attributes.to_h.transform_keys(&:to_s))
        self
      end

      # As ActiveRecord's relation update: each selected record updated
      # (callbacks and validations run; under ES-NoProj each is an event),
      # or, given an id, that record of the relation.
      def update(id = :all, attributes)
        return find(id).tap { _1.update(attributes) } unless id == :all

        records.each { |record| record.update(attributes) }
      end

      def update!(id = :all, attributes)
        return find(id).tap { _1.update!(attributes) } unless id == :all

        records.each { |record| record.update!(attributes) }
      end

      # As ActiveRecord's: each selected record's counters moved by the
      # given amounts (nil counting as 0), and touch: the timestamps, in
      # one update_all per set of current values, so each record gets the
      # event an update_all writes. It used to bump every record of the
      # model.
      def update_counters(counters)
        counters = counters.dup
        touch = counters.delete(:touch)
        counters = counters.transform_keys(&:to_s)
        unknown = counters.keys - model_class.column_names
        raise UnsupportedQuery.new(model_class, "update_counters(#{unknown.join(', ')})") if unknown.any?
        return 0 if @records.empty? || counters.empty?

        touched = touch ? model_class.touch_attributes_with_time(*(touch == true ? [] : Array(touch))) : {}
        groups = @records.group_by { |record| counters.keys.map { |column| record.read_attribute(column) } }
        model_class.transaction do
          groups.sum do |values, group|
            updates = counters.keys.zip(values).to_h { |column, value| [column, (value || 0) + counters[column]] }
            spawn_records(group).update_all(updates.merge(touched))
          end
        end
      end

      # There is no SQL: the relation is answered from the event store.
      def to_sql
        raise UnsupportedQuery.new(model_class, "to_sql (the relation is answered from the event store, not by SQL)")
      end

      # Hints for the database, which ES-NoProj reads do not reach. A lock
      # takes no row lock: writes take Lyra's aggregate lock.
      %i[lock annotate optimizer_hints strict_loading].each do |name|
        define_method(name) { |*_args| self }
      end

      # As ActiveRecord defines them: where, then the bulk write. They went
      # through the scope branch of method_missing and were refused.
      def delete_by(*args)
        where(*args).delete_all
      end

      def destroy_by(*args)
        where(*args).destroy_all
      end

      def limit!(value)
        spawn_records(@records.first(value))
      end

      def values
        {}
      end

      # Association and scope extensions, as ActiveRecord::Relation has them:
      # the relation is extended with the modules (and a block's methods), and
      # extensions lists them. ActiveRecord's collection proxy asks an
      # association's scope for its extensions; under ES-NoProj that scope is
      # this relation, and Solidus's price lookup (variant.prices) failed on it.
      # extending used to drop the modules silently.
      def extensions
        @extensions || []
      end

      def extending!(*modules, &block)
        modules = modules.flatten
        modules << Module.new(&block) if block
        return self if modules.empty?

        @extensions = extensions + modules
        modules.each { |mod| extend(mod) }
        self
      end

      def extending(*modules, &block)
        spawn_records(@records).extending!(*modules, &block)
      end

      def spawn
        spawn_records(@records.dup)
      end

      # As ActiveRecord's merge: the records both select, in this relation's
      # order and then the other's. An ActiveRecord relation of the model is
      # evaluated (CachedRelation#narrowed_by: its where clause, order and
      # limit; what it unscopes is taken off this one first); a relation read
      # from the event store is intersected with this one. Anything else
      # (another model's relation, joins, a window of the other's records)
      # raises UnsupportedQuery. It used to return this relation unchanged,
      # and a bulk write after it acted on every record.
      def merge(other, *rest)
        merged =
          case other
          when nil then self
          when CachedRelation then merge_events_relation(other)
          when ActiveRecord::Relation then merge_active_record_relation(other)
          else raise UnsupportedQuery.new(model_class, "merge(#{other.class})")
          end
        rest.empty? ? merged : merged.merge(*rest)
      end

      def merge!(other, *rest)
        replace_with!(merge(other, *rest))
      end

      def bind_attribute(name, value)
        self
      end

      def except(*skips)
        unscope(*skips)
      end

      def only(*keeps)
        self
      end

      def where!(conditions, *rest)
        # In-place where (ActiveRecord's internals build relations with it).
        # Hash conditions only: anything else used to be ignored, keeping
        # every record.
        return self if conditions.blank?
        unless conditions.is_a?(Hash) && rest.empty?
          raise UnsupportedQuery.new(model_class, "where!(#{[conditions, *rest].inspect[1..-2][0, 60]})")
        end

        replace_with!(where(conditions))
      end

      def order!(*args)
        # In-place order modification
        return self if args.empty?
        keys = ordering + order_keys(args)
        @records = sort_records(@records, keys)
        @ordering = keys
        self
      end

      def reselect(*args)
        self
      end

      def select(*args, &block)
        if block_given?
          # Enumerable select
          spawn_records(@records.select(&block))
        else
          # AR select (column selection): the records stay whole, for
          # filtering; the ones returned are narrowed to these columns.
          relation = spawn_records(@records)
          relation.selected_columns = args.flatten.map { |name| name.to_s.split(".").last.delete('"') }
          relation
        end
      end

      # =========================================================================
      # Aggregations
      # =========================================================================

      # Aggregates follow SQL (and ActiveRecord's casting of its results), and
      # are computed from the records the streams produce, never the table:
      # - NULLs are ignored; SUM of nothing is 0, AVG/MIN/MAX of nothing nil.
      # - SUM keeps the column's type (Integer, BigDecimal, Float); there is
      #   no rounding through Float. AVG is a BigDecimal for integer and
      #   decimal columns and a Float for float columns, as ActiveRecord
      #   returns them.
      # - Only plain columns: an SQL expression ("price * quantity") cannot be
      #   evaluated here and raises UnsupportedQuery.
      # AVG keeps more digits than the database, which rounds a numeric
      # quotient to its own scale (PostgreSQL: about 16 significant digits).
      # MIN/MAX on strings compare by Ruby's byte order, which can differ from
      # the database collation.
      # SQL's GROUP BY with an aggregate, as ActiveRecord returns it: a hash
      # from the group's value (an array of values for several columns) to
      # the aggregate over its records. Solidus sums stock per variant and
      # stock location this way.
      def group(*columns)
        relation = spawn_records(@records)
        relation.group_columns = group_columns + columns.flatten.map { |c| c.to_s.split(".").last.delete('"') }
        relation
      end

      def sum(column_name = nil, &block)
        return aggregate_by_group(:sum, column_name) if group_columns.any? && !block
        return @records.sum(&block) if block_given?
        return 0 unless column_name

        aggregate_values(column_name).sum(0)
      end

      def average(column_name)
        return aggregate_by_group(:average, column_name) if group_columns.any?

        values = aggregate_values(column_name)
        return nil if values.empty?

        if %i[integer decimal].include?(column_type(column_name))
          values.sum(0).to_d / values.size
        else
          values.sum(0).to_f / values.size
        end
      end

      def minimum(column_name)
        return aggregate_by_group(:minimum, column_name) if group_columns.any?

        aggregate_values(column_name).min
      end

      def maximum(column_name)
        return aggregate_by_group(:maximum, column_name) if group_columns.any?

        aggregate_values(column_name).max
      end

      private def aggregate_by_group(operation, column_name)
        @records.group_by do |record|
          values = group_columns.map { |column| record.read_attribute(column) }
          values.size == 1 ? values.first : values
        end.transform_values do |records|
          self.class.new(model_class, records).public_send(operation, column_name)
        end
      end

      def calculate(operation, column_name = nil)
        case operation.to_s
        when "count" then count(column_name)
        when "sum" then sum(column_name)
        when "average", "avg" then average(column_name)
        when "minimum", "min" then minimum(column_name)
        when "maximum", "max" then maximum(column_name)
        else raise UnsupportedQuery.new(model_class, "calculate(#{operation.inspect})")
        end
      end

      def pluck(*column_names)
        @records.map do |record|
          if column_names.size == 1
            record.send(column_names.first)
          else
            column_names.map { |col| record.send(col) }
          end
        end
      end

      def ids
        pluck(:id)
      end

      def pick(*column_names)
        record = first
        return nil unless record

        if column_names.size == 1
          record.send(column_names.first)
        else
          column_names.map { |col| record.send(col) }
        end
      end

      # =========================================================================
      # Batching (simplified - all records are in memory)
      # =========================================================================

      def find_each(batch_size: 1000, &block)
        each(&block)
      end

      def find_in_batches(batch_size: 1000)
        @records.each_slice(batch_size) do |batch|
          yield batch
        end
      end

      def in_batches(of: 1000)
        @records.each_slice(of) do |batch|
          yield spawn_records(batch)
        end
      end

      prepend CachedRelationDelivery

      # =========================================================================
      # Inspection
      # =========================================================================

      def inspect
        "#<#{self.class.name} [#{@records.map(&:inspect).join(', ')}]>"
      end

      def to_s
        inspect
      end

      # =========================================================================
      # Scope support - AR calls _exec_scope for named scopes
      # =========================================================================

      # Called by AR when executing scopes
      # Rails passes scope arguments and the scope body block
      def _exec_scope(*args, &block)
        # Execute the scope block in our context
        # The block typically calls methods like `where`, `order`, etc.
        result = instance_exec(*args, &block)

        # Return the result if it's a CachedRelation, otherwise self
        result.is_a?(CachedRelation) ? result : self
      end

      # The relation a +scoping+ block is running under, per model class, as
      # ActiveRecord's current_scope: inside it the model's own class-level
      # reads (all, where, first, last) answer from that relation instead of
      # from every record of the model. Scope bodies reached through an
      # association (order.payments.completed) run that way.
      SCOPES_KEY = :lyra_cached_relation_scopes

      def self.scoped_for(model_class)
        (Thread.current[SCOPES_KEY] || {})[model_class]
      end

      # Runs the block with this relation as the model's current scope and
      # returns the block's value, as ActiveRecord does. It used to return the
      # relation itself, which dropped the block's result: a scope called on
      # an association came back unfiltered.
      def scoping(skip_inherited_scope = false, full = nil, all_queries: nil)
        return self unless block_given?

        scopes = (Thread.current[SCOPES_KEY] ||= {})
        had_previous = scopes.key?(model_class)
        previous = scopes[model_class]
        scopes[model_class] = self
        begin
          yield self
        ensure
          had_previous ? scopes[model_class] = previous : scopes.delete(model_class)
        end
      end

      def _scoping(skip_inherited_scope = false, full = nil, all_queries: nil, &block)
        scoping(skip_inherited_scope, full, all_queries: all_queries, &block)
      end

      # Allow method_missing for scope delegation
      def respond_to_missing?(method_name, include_private = false)
        model_class.respond_to?(method_name) || super
      end

      # Bulk mutations must act on exactly the records this relation has
      # already been filtered down to (@records) -- not on a query rebuilt
      # from model_class.unscoped, which the scope-delegation branch below
      # does deliberately (see its comment) because that branch exists to
      # resolve *named scopes*, whose where clauses live only on the class,
      # not on any relation instance.
      #
      # delete_all/destroy_all/update_all are relation-instance methods, not
      # scopes: model_class.respond_to?(:delete_all) is true (AR delegates it
      # from the class to Model.all), so without this check they fell into
      # that same branch and ran unscoped -- deleting or updating every row
      # in the table, silently, regardless of any #where this relation was
      # built from. Getting this wrong doesn't raise; it destroys data the
      # caller never selected.
      # touch_all is update_all of the timestamp columns (as Rails defines
      # it). Left out, it went through the scope branch, which touched every
      # row of the table (an unscoped touch_all, publishing an event for each)
      # and then raised UnsupportedQuery: records the caller never selected
      # changed in the log, which ES-NoProj reads as the truth.
      BULK_MUTATION_METHODS = %i[delete_all destroy_all update_all touch_all].freeze

      # Inserts and upserts aren't scopes either: they run at once and return
      # an ActiveRecord::Result. Through the scope branch below, the write ran
      # and the caller then got UnsupportedQuery ("not a scope") for a write
      # that had already happened.
      INSERT_METHODS = %i[insert insert! insert_all insert_all! upsert upsert_all].freeze

      def method_missing(method_name, *args, **kwargs, &block)
        return bulk_mutate(method_name, *args, **kwargs) if BULK_MUTATION_METHODS.include?(method_name)
        return insert_through_table(method_name, *args, **kwargs) if INSERT_METHODS.include?(method_name)

        # A class attribute (class_attribute :x defines x and x=) holds
        # configuration, not a query: answer it, as a relation delegates it to
        # its class. Scope lambdas read them (discard's with_discarded reads
        # discard_column; Solidus's variant.prices uses it).
        if args.empty? && kwargs.empty? && block.nil? && !method_name.to_s.end_with?("=", "!", "?") &&
           model_class.respond_to?(method_name) && model_class.respond_to?(:"#{method_name}=")
          return model_class.public_send(method_name)
        end

        # Active Record's own class methods and relation methods that this
        # class does not evaluate (sole, find_sole_by, invert_where,
        # find_by_sql, a bang query method, ...): refused before anything
        # runs. They used to run on a bare relation of the model, past this
        # relation's conditions: update and update_counters wrote to every
        # record, first_or_create! created one without the conditions.
        if active_record_method?(method_name)
          return model_class.public_send(method_name, *args, **kwargs, &block) if MODEL_READERS.include?(method_name)

          raise UnsupportedQuery.new(model_class, "#{method_name} on a relation")
        end

        return super unless model_class.respond_to?(method_name)

        # A named scope: its relation is built as ActiveRecord builds it
        # (past Lyra's reads; building runs no query) and this relation is
        # narrowed by it.
        return named_scope(method_name, *args, **kwargs, &block) if named_scope?(method_name)

        # Any other class method of the model runs with this relation as the
        # model's current scope, as ActiveRecord runs it on a relation: its
        # reads and writes (where, update_all) act on this relation's
        # records. That holds only where the model's reads answer from the
        # scope (a monitored model under ES-NoProj); elsewhere they would
        # read the table, and the call is refused before it runs.
        unless events_only? && model_class.respond_to?(:lyra_monitored) && model_class.lyra_monitored &&
               !Thread.current[:lyra_bypass_read_override]
          raise UnsupportedQuery.new(model_class, "#{method_name}, which is not a scope")
        end

        result =
          begin
            scoping { model_class.public_send(method_name, *args, **kwargs, &block) }
          rescue NoMethodError => e
            raise unless e.receiver.is_a?(CachedRelation)

            raise UnsupportedQuery.new(model_class, "#{method_name} (it called #{e.name}, which is not evaluated here)")
          end
        result.is_a?(ActiveRecord::Relation) ? narrowed_by(result, method_name.to_s) : result
      end

      # Readers of the model a scope body may ask its relation for.
      MODEL_READERS = %i[arel_table table_name primary_key column_names columns_hash attribute_names connection
                         sanitize_sql sanitize_sql_like sanitize_sql_array predicate_builder type_for_attribute
                         name base_class].freeze

      def active_record_method?(method_name)
        unless model_class.respond_to?(method_name)
          return ActiveRecord::Relation.method_defined?(method_name) || ActiveRecord::Relation.private_method_defined?(method_name)
        end

        path = model_class.method(method_name).source_location&.first
        path.nil? || (DefaultScopes.active_record_path?(path) && !path.end_with?("/scoping/named.rb"))
      end
      private :active_record_method?

      def named_scope?(method_name)
        model_class.method(method_name).source_location&.first.to_s.end_with?("/active_record/scoping/named.rb")
      end
      private :named_scope?

      def named_scope(method_name, *args, **kwargs, &block)
        begin
          # Built past Lyra's read overrides: scope lambdas that call where
          # build ActiveRecord conditions instead of reading the event store.
          Thread.current[:lyra_bypass_read_override] = true
          scope_result = model_class.unscoped.public_send(method_name, *args, **kwargs, &block)
        rescue Lyra::StrictDataAccessViolation
          raise
        rescue => e
          # Answering anyway (as this used to, unfiltered) would be wrong.
          raise UnsupportedQuery.new(model_class, "#{method_name} (it raised #{e.class})")
        ensure
          Thread.current[:lyra_bypass_read_override] = nil
        end

        unless scope_result.is_a?(ActiveRecord::Relation)
          raise UnsupportedQuery.new(model_class, "#{method_name}, which is not a scope")
        end

        # A scope that unscopes (with_discarded) takes the default scope
        # off first, as it does on ActiveRecord's relation.
        base = scope_result.unscope_values.any? ? unscope(*scope_result.unscope_values) : self
        narrowed = base.narrowed_by(scope_result, "scope #{method_name}")
        narrowed = narrowed.spawn if narrowed.equal?(base)
        narrowed.continue_plan(base, [:scope, scope_result, "scope #{method_name}"])
      end
      private :named_scope

      # This relation narrowed as an ActiveRecord relation of the same model
      # selects: its where clause, then its order and limit, as SQL applies
      # them. Anything else it holds (joins, an SQL fragment, a where.not)
      # raises UnsupportedQuery naming +what+, rather than answer with records
      # the relation does not select.
      def narrowed_by(relation, what)
        extra = unsupported_clauses(relation) - %w[order limit]
        raise UnsupportedQuery.new(model_class, "#{what} (it uses #{extra.join(', ')})") if extra.any?

        where_hash = extract_where_conditions(relation, strict: true)
        raise UnsupportedQuery.new(model_class, what) if where_hash.nil?

        narrowed = where_hash.empty? ? self : where(where_hash)
        narrowed = narrowed.order(*relation.order_values) if relation.order_values.any?
        narrowed = narrowed.limit(relation.limit_value) if relation.limit_value
        narrowed
      end

      # Clauses of a scope's relation, other than its where clause, that this
      # class cannot reproduce. Ignoring any of them would change the answer.
      def unsupported_clauses(relation)
        {
          "joins" => relation.joins_values.any? || relation.left_outer_joins_values.any?,
          "order" => relation.order_values.any?,
          "group" => relation.group_values.any?,
          "having" => !relation.having_clause.empty?,
          "limit" => !relation.limit_value.nil?,
          "offset" => !relation.offset_value.nil?,
          "distinct" => relation.distinct_value,
          "select" => relation.select_values.any?,
          "from" => !relation.from_clause.empty?
        }.select { |_, used| used }.keys
      end

      # Hash conditions only; with strict: true, returns nil as soon as one
      # predicate is something it cannot read, so the caller refuses rather
      # than filter by a subset of the conditions.
      def extract_where_conditions(relation, strict: false)
        # Try to extract hash conditions from the relation's where clause
        return {} unless relation.respond_to?(:where_clause)

        where_clause = relation.where_clause
        return {} if where_clause.empty?

        # Rails 7+ stores conditions in predicates
        # Try to convert Arel predicates to a hash
        conditions = {}
        where_clause.send(:predicates).each do |predicate|
          case predicate
          when Arel::Nodes::Equality
            # Simple equality: column = value
            if predicate.left.respond_to?(:name)
              column = predicate.left.name.to_sym
              value = extract_predicate_value(predicate.right)
              conditions[column] = value
            end
          when Arel::Nodes::In
            # IN clause: column IN (values)
            if predicate.left.respond_to?(:name)
              column = predicate.left.name.to_sym
              values = predicate.right.map { |v| extract_predicate_value(v) }
              conditions[column] = values
            end
          when Arel::Nodes::HomogeneousIn
            # IN clause over an array of same-type scalars -- Rails' own
            # optimization of `where(column: [v1, v2, ...])`, and what
            # `where(id: [...])` compiles to whenever the array has more than
            # one element. Without this branch, any such condition falls
            # through unrecognized, and this method silently omits it from
            # `conditions` -- collapsing the scope to unfiltered if it was
            # the only condition.
            if predicate.type == :in && predicate.attribute.respond_to?(:name)
              conditions[predicate.attribute.name.to_sym] = predicate.values
            elsif strict
              return nil
            end
          else
            return nil if strict
          end
        end

        conditions
      rescue => e
        return nil if strict

        Rails.logger.debug("Lyra::CachedRelation: Could not extract where conditions - #{e.message}")
        {}
      end

      # Conditions must be a hash: of this model's own attributes, or of a
      # table joined before (see CachedJoins). A SQL fragment or an Arel node
      # cannot be evaluated against cached records, and ignoring it would
      # widen the answer.
      def check_hash_conditions!(conditions, what)
        raise UnsupportedQuery.new(model_class, what) unless conditions.is_a?(Hash)
      end

      # Keep the rows the block accepts, as a joined relation if this is one.
      def filter_rows(&block)
        rows = joined_rows.select { |record, joins| block.call(record, joins) }
        @joins ? with_rows(rows, @joins) : spawn_records(rows.map(&:first))
      end

      def extract_predicate_value(node)
        case node
        when Arel::Nodes::Casted
          node.value
        when Arel::Nodes::BindParam
          # Rails 7+ bind params
          node.value.value_before_type_cast
        when NilClass
          nil
        else
          node.respond_to?(:value) ? node.value : node
        end
      end

      # This relation's state taken from +other+ (the bang methods).
      def replace_with!(other)
        %i[@records @ordering @query_terms @create_attributes @create_with_attributes @plan @default_scope_applied
           @selected_columns @group_columns @windowed @rows @joins @joined_classes].each do |ivar|
          instance_variable_set(ivar, other.instance_variable_get(ivar))
        end
        self
      end
      protected :replace_with!

      def merge_events_relation(other)
        unless other.model_class == model_class
          raise UnsupportedQuery.new(model_class, "merge of a #{other.model_class.name} relation")
        end
        raise UnsupportedQuery.new(model_class, "merge of a relation with a limit or offset") if other.windowed?
        raise UnsupportedQuery.new(model_class, "merge of a joined relation") if other.joined_associations.any? || joined_associations.any?

        pk = model_class.primary_key
        keys = other.raw_records.to_a.to_h { |record| [record.read_attribute(pk), true] }
        merged = spawn_records(@records.select { |record| keys.key?(record.read_attribute(pk)) })
        merged.add_query_terms(other.query_terms)
        merged.create_attributes = create_attributes.merge(other.create_attributes)
        merged.create_with_attributes = create_with_attributes.merge(other.create_with_attributes)
        merged = merged.send(:sorted_by, ordering + other.ordering) if other.ordering.any?
        merged
      end
      private :merge_events_relation

      def merge_active_record_relation(other)
        unless other.model == model_class
          raise UnsupportedQuery.new(model_class, "merge of a #{other.model.name} relation")
        end

        base = other.unscope_values.any? ? unscope(*other.unscope_values) : self
        merged = base.narrowed_by(other, "merge(#{other.class.name})")
        merged = merged.spawn if merged.equal?(self)
        merged.continue_plan(base, [:scope, other, "merge(#{other.class.name})"])
        merged.create_with_attributes = create_with_attributes.merge(other.create_with_value.stringify_keys)
        merged
      end
      private :merge_active_record_relation

      private

      # The non-NULL values of a plain column, typed by the model's attribute.
      def aggregate_values(column_name)
        column = aggregate_column(column_name)
        @records.map { |record| record.read_attribute(column) }.compact
      end

      def aggregate_column(column_name)
        name = column_name.to_s.delete('"')
        name = name.delete_prefix("#{model_class.table_name}.")
        return name if model_class.column_names.include?(name)

        raise UnsupportedQuery.new(model_class, "an aggregate over #{column_name.inspect}")
      end

      def column_type(column_name)
        model_class.type_for_attribute(aggregate_column(column_name)).type
      end

      # Re-derives a real, scoped AR relation from this relation's own
      # (already-filtered) records and runs the mutation on exactly that set.
      # An empty relation mutates nothing, rather than the id filter
      # collapsing to `where(id: [])`, which some AR versions optimize to "no
      # WHERE at all" for delete_all/update_all -- the same class of bug this
      # method exists to avoid.
      def bulk_mutate(method_name, *args, **kwargs)
        return 0 if @records.empty?
        if method_name == :touch_all && events_only?
          # One time for every row, as Rails's touch_all gives: update_all of
          # the touched columns. With a table, touch_all itself runs below, on
          # the selected rows only, and publishes through the relation.
          updates = model_class.touch_attributes_with_time(*args, time: kwargs[:time])
          return bulk_mutate_as(:update_all, "touch_all", updates)
        end
        return event_sourced_bulk_mutate(method_name, *args, **kwargs) if events_only?

        ids = @records.map { |r| r.public_send(model_class.primary_key) }
        Thread.current[:lyra_bypass_read_override] = true
        model_class.unscoped.where(model_class.primary_key => ids).public_send(method_name, *args, **kwargs)
      ensure
        Thread.current[:lyra_bypass_read_override] = nil
      end

      # Send an insert or upsert to the table relation, where
      # StrictDataAccessRelation records it (or rejects upsert_all in the
      # events-only store), and hand back its real result or error.
      def insert_through_table(method_name, *args, **kwargs)
        Thread.current[:lyra_bypass_read_override] = true
        model_class.unscoped.public_send(method_name, *args, **kwargs)
      ensure
        Thread.current[:lyra_bypass_read_override] = nil
      end

      # Event sourcing with projections disabled: the records exist only in
      # the event stream, so a SQL bulk write would match no rows and the
      # records would reappear on the next read. Here the events are the
      # write.
      def events_only?
        return false if Thread.current[:lyra_projection_write]

        Lyra.event_sourcing_mode? && Lyra.config.projection_mode == :disabled
      end

      def event_sourced_bulk_mutate(method_name, *args, **kwargs)
        return @records.each(&:destroy) if method_name == :destroy_all

        # One transaction: a failed publish part-way leaves none of them.
        model_class.transaction { publish_bulk_events(method_name, *args, **kwargs) }
      end

      # +method_name+ applied with +updates+, its events naming +source+
      # (touch_all, which is update_all of the timestamps).
      def bulk_mutate_as(method_name, source, updates)
        @bulk_source = source
        bulk_mutate(method_name, updates)
      ensure
        @bulk_source = nil
      end

      def publish_bulk_events(method_name, *args, **kwargs)
        if Lyra.config.strict_data_access && !Thread.current[:lyra_bypass_strict_access]
          raise Lyra::StrictDataAccessViolation.new(method_name, model_class)
        end

        pk = model_class.primary_key
        case method_name
        when :delete_all
          @records.each do |record|
            Lyra::BypassEvents.publish(model_class, record.public_send(pk), :destroyed,
                                       attributes: record.attributes,
                                       source: "delete_all")
          end
        when :update_all
          updates = args.first || kwargs
          unless updates.is_a?(Hash)
            raise ArgumentError, "update_all needs a Hash of column values in event sourcing mode " \
                                 "with projections disabled; a SQL fragment can't be applied to event-stream records"
          end

          updates = updates.transform_keys(&:to_s)
          @records.each do |record|
            changes = updates.each_with_object({}) do |(column, new_value), acc|
              old_value = record.read_attribute(column)
              acc[column] = [old_value, new_value] unless old_value == new_value
            end
            next if changes.empty?

            Lyra::BypassEvents.publish(model_class, record.public_send(pk), :updated,
                                       attributes: changes.transform_values(&:last), changes: changes,
                                       source: @bulk_source || "update_all")
          end
        end

        # Rows left in the table from an earlier mode must not disagree with
        # the stream, so apply the same write to them without re-publishing.
        ids = @records.map { |r| r.public_send(pk) }
        Lyra.projection_write(INTERNAL) do
          Thread.current[:lyra_bypass_read_override] = true
          model_class.unscoped.where(pk => ids).public_send(method_name, *args, **kwargs)
        ensure
          Thread.current[:lyra_bypass_read_override] = nil
        end
        @records.size
      end

      # The conditions of a hash on +klass+'s records, compiled once: each
      # value bound as Active Record binds it (Lyra::Projections::TypedValues).
      def condition_tests(klass, conditions)
        conditions.map { |key, value| TypedValues.condition(klass, key, value) }
      end

      # Whether +record+ satisfies every one of +tests+ (condition_tests), as
      # SQL decides it on the table: true, false or nil (unknown, a NULL
      # compared).
      def matches_all?(record, tests)
        TypedValues.all_hold(tests, TypedValues::RecordReader, record)
      rescue ActiveModel::MissingAttributeError => e
        # A record narrowed by select lacks the column a condition reads.
        raise UnsupportedQuery.new(model_class, "a condition on a column not selected (#{e.message[0, 80]})")
      end

      # +records+ in the order +keys+ ({ column => :asc/:desc }, or a
      # column) gives, ties in the order they had. Each record's sort values
      # are read once, not on every comparison.
      def sort_records(records, keys)
        plan = keys.flat_map do |key|
          pairs = key.is_a?(Hash) ? key.to_a : [[key, :asc]]
          pairs.map { |column, direction| [TypedValues.sort_reader(model_class, column), direction.to_s.downcase == "desc"] }
        end
        return records.dup if plan.empty?

        readers = plan.map(&:first)
        descending = plan.map(&:last)
        decorated = records.each_with_index.map { |record, index| [readers.map { _1.call(record) }, index, record] }
        decorated.sort! do |(a, index_a, _), (b, index_b, _)|
          result = index_a <=> index_b
          a.each_index do |i|
            compared = compare_values(a[i], b[i])
            next if compared.zero?

            result = descending[i] ? -compared : compared
            break
          end
          result
        end
        decorated.map(&:last)
      end

      # NULLs last ascending (first descending), as PostgreSQL orders them;
      # booleans false before true.
      def compare_values(a, b)
        return 0 if a.nil? && b.nil?
        return 1 if a.nil?
        return -1 if b.nil?
        TypedValues.compare(a, b) || 0
      end

      # =========================================================================
      # WhereChain for where.not(...) support
      # =========================================================================

      class WhereChain
        def initialize(relation)
          @relation = relation
        end

        def not(conditions)
          @relation.not(conditions)
        end

        def missing(*associations)
          @relation.where_missing(*associations)
        end

        def associated(*associations)
          @relation.where_associated(*associations)
        end
      end
    end
  end
end
