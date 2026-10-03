# frozen_string_literal: true

module Lyra
  module Projections
    # ActiveRecord::Relation-like wrapper for cached projection results.
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

      def count(column_name = nil, &block)
        if block_given?
          @records.count(&block)
        elsif column_name
          @records.count { |r| r.send(column_name).present? }
        else
          @records.size
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

      def where(conditions = nil, *args)
        return self if conditions.nil?

        # Handle where.not(...) chain
        return WhereChain.new(self) if conditions == :chain

        filtered = @records.select do |record|
          case conditions
          when Hash
            conditions.all? { |key, value| matches_value?(record, key, value) }
          when String
            # SQL string conditions - can't evaluate, return all
            # This is a limitation of the cached approach
            true
          else
            true
          end
        end

        self.class.new(model_class, filtered)
      end

      def not(conditions)
        filtered = @records.reject do |record|
          conditions.all? { |key, value| matches_value?(record, key, value) }
        end
        self.class.new(model_class, filtered)
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

      def joins(*args)
        # Can't actually join - return self to allow chain to continue
        # Note: This may produce incorrect results for complex queries
        self
      end

      def left_joins(*args)
        self
      end

      def left_outer_joins(*args)
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

      def sum(column_name = nil, &block)
        if block_given?
          @records.sum(&block)
        elsif column_name
          @records.sum { |r| r.send(column_name).to_f }
        else
          0
        end
      end

      def average(column_name)
        values = @records.map { |r| r.send(column_name) }.compact
        return nil if values.empty?
        values.sum.to_f / values.size
      end

      def minimum(column_name)
        @records.map { |r| r.send(column_name) }.compact.min
      end

      def maximum(column_name)
        @records.map { |r| r.send(column_name) }.compact.max
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

      def method_missing(method_name, *args, **kwargs, &block)
        return bulk_mutate(method_name, *args, **kwargs) if BULK_MUTATION_METHODS.include?(method_name)

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
            Rails.logger.debug("Lyra::CachedRelation: Could not execute scope #{method_name} - #{e.message}")
            return self
          ensure
            Thread.current[:lyra_bypass_read_override] = nil
          end

          if scope_result.is_a?(ActiveRecord::Relation)
            # Extract where conditions from the scope result
            where_hash = extract_where_conditions(scope_result)
            if where_hash.present?
              return where(where_hash)
            end
          end

          # Fallback: return self to allow chaining
          self
        else
          super
        end
      end

      def extract_where_conditions(relation)
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
            end
          end
        end

        conditions
      rescue => e
        Rails.logger.debug("Lyra::CachedRelation: Could not extract where conditions - #{e.message}")
        {}
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

      # Re-derives a real, scoped AR relation from this relation's own
      # (already-filtered) records and runs the mutation on exactly that set.
      # An empty relation mutates nothing, rather than the id filter
      # collapsing to `where(id: [])`, which some AR versions optimize to "no
      # WHERE at all" for delete_all/update_all -- the same class of bug this
      # method exists to avoid.
      def bulk_mutate(method_name, *args, **kwargs)
        return 0 if @records.empty?

        ids = @records.map { |r| r.public_send(model_class.primary_key) }
        Thread.current[:lyra_bypass_read_override] = true
        model_class.unscoped.where(model_class.primary_key => ids).public_send(method_name, *args, **kwargs)
      ensure
        Thread.current[:lyra_bypass_read_override] = nil
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
        # Attribute doesn't exist on record
        false
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
          # Can't check missing associations in cached mode
          @relation
        end

        def associated(*associations)
          # Can't check associations in cached mode
          @relation
        end
      end
    end
  end
end
