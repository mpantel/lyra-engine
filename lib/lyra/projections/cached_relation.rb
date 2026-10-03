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
    class CachedRelation
      include Enumerable
      include CachedJoins

      attr_reader :model_class, :records

      def initialize(model_class, records = [])
        @model_class = model_class
        @records = records.to_a
      end

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
        @records.find do |record|
          attributes.all? { |key, value| matches_value?(record, key, value) }
        end
      end

      def find_by!(attributes)
        find_by(attributes) || raise(ActiveRecord::RecordNotFound.new(
          "Couldn't find #{model_class.name}", model_class
        ))
      end

      def exists?(conditions = nil)
        case conditions
        when nil, false
          @records.any?
        when Integer, String
          @records.any? { |r| r.id.to_s == conditions.to_s }
        when Hash
          find_by(conditions).present?
        else
          @records.any?
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

        check_hash_conditions!(conditions, "where(#{args.inspect[1..-2][0, 60]})")
        raise UnsupportedQuery.new(model_class, "where(#{args.inspect[1..-2][0, 60]})") if args.size > 1

        own, joined = split_joined_conditions(conditions)
        own = AssociationConditions.rewrite(model_class, own)
        filter_rows do |record, joins|
          own.all? { |key, value| matches_value?(record, key, value) } && joined_match(joins, joined) == true
        end
      end

      # SQL's NOT: a row is kept only when its conditions are definitely
      # false. One with a missing left-join partner under a condition on the
      # joined table is unknown (NULL), and is excluded, as SQL excludes it.
      def not(conditions)
        check_hash_conditions!(conditions, "where.not(#{conditions.inspect[0, 60]})")
        own, joined = split_joined_conditions(conditions)
        own = AssociationConditions.rewrite(model_class, own)
        filter_rows do |record, joins|
          own_match = own.all? { |key, value| matches_value?(record, key, value) }
          combine_and(own_match, joined_match(joins, joined)) == false
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

      def order(*args)
        return self if args.empty?

        sorted = @records.sort do |a, b|
          compare_for_order(a, b, args)
        end

        self.class.new(model_class, sorted)
      end

      def reorder(*args)
        order(*args)
      end

      def reverse_order
        self.class.new(model_class, @records.reverse)
      end

      def limit(count)
        self.class.new(model_class, @records.first(count))
      end

      def offset(count)
        self.class.new(model_class, @records.drop(count))
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

        result = self.class.new(model_class, paginated)
        result.instance_variable_set(:@current_page, @current_page)
        result.instance_variable_set(:@per_page, @per_page)
        result.instance_variable_set(:@total_records, @records.size)
        result
      end

      def distinct
        self.class.new(model_class, @records.uniq)
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
        self.class.new(model_class, [])
      end

      def unscoped
        self
      end

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

      def connection
        model_class.connection
      end

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
        {}
      end

      def limit!(value)
        self.class.new(model_class, @records.first(value))
      end

      def values
        {}
      end

      def extending!(*modules, &block)
        # No-op for cached relation - extensions are for AR scopes
        self
      end

      def extending(*modules, &block)
        self
      end

      def spawn
        self.class.new(model_class, @records.dup)
      end

      def merge(other, *rest)
        # For association scopes, just return self since we already have filtered records
        self
      end

      def merge!(other, *rest)
        self
      end

      def bind_attribute(name, value)
        self
      end

      def rewhere(conditions)
        where(conditions)
      end

      def except(*skips)
        self
      end

      def only(*keeps)
        self
      end

      def where!(conditions)
        # In-place where modification (for AR internal use)
        # Filter records and update @records directly
        return self if conditions.nil?

        @records = @records.select do |record|
          case conditions
          when Hash
            conditions.all? { |key, value| matches_value?(record, key, value) }
          else
            true
          end
        end
        self
      end

      def order!(*args)
        # In-place order modification
        return self if args.empty?
        @records = @records.sort { |a, b| compare_for_order(a, b, args) }
        self
      end

      def reselect(*args)
        self
      end

      def select(*args, &block)
        if block_given?
          # Enumerable select
          self.class.new(model_class, @records.select(&block))
        else
          # AR select (column selection) - return self since we have full records
          self
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
      def sum(column_name = nil, &block)
        return @records.sum(&block) if block_given?
        return 0 unless column_name

        aggregate_values(column_name).sum(0)
      end

      def average(column_name)
        values = aggregate_values(column_name)
        return nil if values.empty?

        if %i[integer decimal].include?(column_type(column_name))
          values.sum(0).to_d / values.size
        else
          values.sum(0).to_f / values.size
        end
      end

      def minimum(column_name)
        aggregate_values(column_name).min
      end

      def maximum(column_name)
        aggregate_values(column_name).max
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
          yield self.class.new(model_class, batch)
        end
      end

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

      def scoping(skip_inherited_scope = false, full = nil, all_queries: nil, &block)
        # Yield self for scoping blocks
        yield self if block_given?
        self
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
      BULK_MUTATION_METHODS = %i[delete_all destroy_all update_all].freeze

      # Inserts and upserts aren't scopes either: they run at once and return
      # an ActiveRecord::Result. Through the scope branch below, the write ran
      # and the caller then got UnsupportedQuery ("not a scope") for a write
      # that had already happened.
      INSERT_METHODS = %i[insert insert! insert_all insert_all! upsert upsert_all].freeze

      def method_missing(method_name, *args, **kwargs, &block)
        return bulk_mutate(method_name, *args, **kwargs) if BULK_MUTATION_METHODS.include?(method_name)
        return insert_through_table(method_name, *args, **kwargs) if INSERT_METHODS.include?(method_name)

        # Try to delegate to model class scopes
        if model_class.respond_to?(method_name)
          # Execute the scope on a bare unscoped relation to get the where conditions
          # This works because scopes add where clauses to the relation
          begin
            # Temporarily bypass Lyra's read overrides so scope calls go through AR
            # Without this, scope lambdas that call `where(...)` would hit our override
            # and return CachedRelation instead of building AR conditions
            Thread.current[:lyra_bypass_read_override] = true
            base_relation = model_class.unscoped
            scope_result = base_relation.public_send(method_name, *args, **kwargs, &block)
          rescue Lyra::StrictDataAccessViolation
            # Don't swallow strict data access violations - these are intentional framework errors
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

          extra = unsupported_clauses(scope_result)
          raise UnsupportedQuery.new(model_class, "scope #{method_name} (it uses #{extra.join(', ')})") if extra.any?

          where_hash = extract_where_conditions(scope_result, strict: true)
          raise UnsupportedQuery.new(model_class, "scope #{method_name}") if where_hash.nil?

          where_hash.empty? ? self : where(where_hash)
        else
          super
        end
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
        @joins ? with_rows(rows, @joins) : self.class.new(model_class, rows.map(&:first))
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

        if Lyra.config.strict_data_access && !Thread.current[:lyra_bypass_strict_access]
          raise Lyra::StrictDataAccessViolation.new(method_name, model_class)
        end

        pk = model_class.primary_key
        case method_name
        when :delete_all
          @records.each do |record|
            Lyra::BypassEvents.publish(model_class, record.public_send(pk), :destroyed,
                                       attributes: record.attributes.except(*Lyra::BypassEvents::TIMESTAMP_COLUMNS),
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
                                       source: "update_all")
          end
        end

        # Rows left in the table from an earlier mode must not disagree with
        # the stream, so apply the same write to them without re-publishing.
        ids = @records.map { |r| r.public_send(pk) }
        Lyra.projection_write do
          Thread.current[:lyra_bypass_read_override] = true
          model_class.unscoped.where(pk => ids).public_send(method_name, *args, **kwargs)
        ensure
          Thread.current[:lyra_bypass_read_override] = nil
        end
        @records.size
      end

      def matches_value?(record, key, value)
        record_value = record.send(key)

        case value
        when Array
          # Handle type coercion for arrays (e.g., array of string IDs vs integer column)
          value.any? { |v| values_match?(record_value, v) }
        when Range
          value.cover?(record_value)
        when nil
          record_value.nil?
        when Regexp
          record_value.to_s.match?(value)
        else
          values_match?(record_value, value)
        end
      rescue NoMethodError
        # ActiveRecord would reject a condition on an unknown column; treating
        # it as "no match" (as this used to) silently empties the answer.
        raise UnsupportedQuery.new(model_class, "a condition on unknown attribute #{key}")
      end

      # Compare values with type coercion for common AR patterns
      def values_match?(record_value, query_value)
        return true if record_value == query_value

        # Handle string/integer coercion (common with params)
        if record_value.is_a?(Integer) && query_value.is_a?(String)
          record_value == query_value.to_i
        elsif record_value.is_a?(String) && query_value.is_a?(Integer)
          record_value.to_i == query_value
        # Handle boolean string coercion
        elsif record_value.in?([true, false]) && query_value.is_a?(String)
          record_value == ActiveModel::Type::Boolean.new.cast(query_value)
        else
          false
        end
      end

      def compare_for_order(a, b, order_args)
        order_args.each do |arg|
          result = compare_single_order(a, b, arg)
          return result unless result == 0
        end
        0
      end

      def compare_single_order(a, b, arg)
        case arg
        when Symbol, String
          compare_values(a.send(arg), b.send(arg))
        when Hash
          arg.each do |column, direction|
            val_a = a.send(column)
            val_b = b.send(column)
            result = compare_values(val_a, val_b)
            result = -result if direction.to_s.downcase == "desc"
            return result unless result == 0
          end
          0
        else
          0
        end
      rescue NoMethodError
        0
      end

      def compare_values(a, b)
        return 0 if a.nil? && b.nil?
        return 1 if a.nil?
        return -1 if b.nil?
        a <=> b || 0
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
