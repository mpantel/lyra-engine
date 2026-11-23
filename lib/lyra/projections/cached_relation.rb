# frozen_string_literal: true

module Lyra
  module Projections
    # Raised when ES-NoProj is asked a query it cannot answer exactly from
    # events. It used to answer such queries anyway, unfiltered or partly
    # filtered; a wrong answer is worse than an error.
    class UnsupportedQuery < StandardError
      # The query was refused at an Arel condition (where(arel_table[:qty]
      # .eq(2))), which CachedRelation#_exec_scope can still evaluate by
      # building the scope as Active Record builds it.
      attr_accessor :arel_condition

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

      # Batch by batch, as Active Record loads them (CachedRelation#batch_slices:
      # by primary key, whatever the relation's order): each batch delivered
      # (checked) in a checking scope of its own, so the subject's rights are
      # read afresh before each (Lyra::Rights.batches). find_each runs
      # through here.
      def find_in_batches(start: nil, finish: nil, batch_size: 1000, error_on_ignore: nil, cursor: model_class.primary_key,
                          order: :asc, &block)
        return super unless block

        slices = batch_slices(of: batch_size, start: start, finish: finish, error_on_ignore: error_on_ignore,
                              cursor: cursor, order: order)
        unless Lyra::PurposeBoundReads.checking?
          slices.each { |slice| block.call(deliver { slice }) }
          return nil
        end

        Lyra::PurposeBoundReads.batch_scopes do |next_batch|
          Lyra::PurposeBoundReads.once do
            slices.each do |slice|
              batch = deliver { slice }
              Lyra::PurposeBoundReads.outside_once { block.call(batch) }
            ensure
              next_batch.call
            end
          end
        end
        nil
      end

      # As ActiveRecord: these load the records.
      def length = deliver { @records.to_a }.length
      def present? = deliver { @records.to_a }.present?
      def blank? = deliver { @records.to_a }.blank?

      # As ActiveRecord: these count or test for existence. With a block,
      # they load the records.
      %i[size empty? ids].each do |name|
        define_method(name) { aggregated { super() } }
      end

      # Kaminari's: of a page, the records the relation selects before the
      # window, counted as any count is.
      def total_count
        refuse_count_without_count!
        return window_source.count if window_source

        aggregated { super() }
      end

      %i[any? none? one? many?].each do |name|
        define_method(name) do |&block|
          next deliver { @records.to_a }.public_send(name, &block) if block

          aggregated { super() }
        end
      end

      # A batch loaded with its records (query_relation) counts and
      # aggregates by its query, as Active Record runs these as SQL whether
      # the relation is loaded or not.
      def count(column_name = nil, &block)
        return deliver { @records.to_a }.count(&block) if block
        return query_relation.count(column_name) if query_relation

        all = column_name.nil? || [:all, "*", "all"].include?(column_name)
        aggregated(all ? [] : [[:value, column_name]]) { super }
      end

      def sum(column_name = nil, &block)
        return deliver { @records.to_a }.sum(&block) if block
        return query_relation.sum(column_name) if query_relation
        return windowed_aggregate(:sum, column_name) if window_source && group_columns.empty?

        aggregated([[:value, column_name]]) { super }
      end

      %i[average minimum maximum].each do |name|
        define_method(name) do |column_name|
          return query_relation.public_send(name, column_name) if query_relation
          return windowed_aggregate(name, column_name) if window_source && group_columns.empty?

          aggregated([[:value, column_name]]) { super(column_name) }
        end
      end

      def calculate(operation, column_name = nil)
        return query_relation.calculate(operation, column_name) if query_relation

        all = operation.to_s == "count" && (column_name.nil? || [:all, "*", "all"].include?(column_name))
        aggregated(all ? [] : [[:value, column_name]]) { super }
      end

      # A Hash of conditions, or an SQL fragment with its binds: what they
      # name is used (the fragment is not evaluated here; see UnsupportedQuery).
      def exists?(conditions = :none)
        return query_relation.exists?(conditions) if query_relation
        if window_source && ![:none, nil, false].include?(conditions) && !window_number(limit_value || 1, "limit").zero?
          return window_matching(conditions).exists?
        end

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
      # A batch loaded with its records writes with its query's
      # (query_relation), as Active Record's update_all and delete_all run
      # the relation's query; destroy_all destroys the records loaded.
      %i[update_all delete_all touch_all destroy_all].each do |name|
        define_method(name) do |*args, **kwargs, &block|
          if name != :destroy_all && (query = query_relation)
            return query.public_send(name, *args, **kwargs, &block)
          end

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

      # It continues the plan: unscope and merge can take it off (they
      # refused, after a where.not).
      def not(conditions)
        relation = inside_query { super }
        relation.continue_plan(self, [:not, conditions]) if conditions.is_a?(Hash) && !relation.equal?(self)
        relation.add_query_terms(conditions_term(conditions))
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

      # The conditions the two sides do not share are the OR (Active Record's
      # or keeps the shared ones as they are): kept as or_terms, for merge.
      def or(other)
        relation = super
        mine = query_terms
        theirs = other.query_terms
        common = mine & theirs
        relation.add_query_terms(theirs)
        relation.add_or_terms((mine - common) + (theirs - common))
      end

      private

      # The records batched without loading them (CachedRelation#batch_records
      # with counting: the sizes of the find_each and find_in_batches
      # enumerators, in_batches' batches of keys) are those a right in force
      # does not leave out, as a count's are, taken out before the limit: a
      # restricted record was counted in the sizes. Batches that load their
      # records keep them, and each is checked as it is delivered (a
      # restricted record raises, as a load of it does in Active Record).
      def batch_kept(records)
        return records if Thread.current[:lyra_cached_delivery]

        Lyra::PurposeBoundReads.rights_kept_records(model_class, lyra_named_fields, records) || records
      end

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
          kept = window_source ? window_kept(named) : Lyra::PurposeBoundReads.rights_kept_records(model_class, named, @records)
          kept ? inside_query { with_records(kept) { yield } } : inside_query { yield }
        end
      end

      # A window's records under a right in force: the window taken from the
      # records of the relation it was taken from that the right does not
      # leave out, as the query's SQL leaves them out before its LIMIT and
      # OFFSET (the window was taken first, and a record left out of it
      # shortened it). nil when the right leaves out none.
      def window_kept(named)
        kept = Lyra::PurposeBoundReads.rights_kept_records(model_class, named, window_source.raw_records.to_a)
        return nil unless kept

        kept = kept.drop(offset_value.nil? ? 0 : window_number(offset_value, "offset"))
        limit_value.nil? ? kept : kept.first(window_number(limit_value, "limit"))
      end

      # SUM, AVG, MIN or MAX of a relation with a limit or offset, as Active
      # Record computes it: one query whose LIMIT and OFFSET apply to its one
      # result row, not to the records. So the aggregate is over every record
      # the relation selects before its window, or, when the window leaves
      # out that row (a limit of 0, an offset), 0 for SUM and nil for the
      # others. It used to be computed over the window's records. The records
      # before the window are counted through their own relation, so that the
      # purpose check and the rights in force apply as to any aggregate.
      def windowed_aggregate(name, column_name)
        if window_leaves_out_one_row?
          aggregated([[:value, column_name]]) { name == :sum ? 0 : nil }
        else
          window_source.public_send(name, column_name)
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

    # A window (CachedRelation#limit, #offset, #page) is taken after the
    # relation's conditions and order, as SQL takes LIMIT and OFFSET after
    # WHERE and ORDER BY, whichever was called first. So a query method
    # called on a window applies to the relation the window was taken from
    # (its window_source), and the window is taken again from the result.
    #
    # How each relation was built, so that a write can build it again from
    # the event store as it is then (CachedRelation#records_now), as Active
    # Record's update_all and delete_all run their query when they are
    # called. A relation holds the records it selected when it was built;
    # writing those wrote a record destroyed since, missed one that matches
    # since, and kept a window (limit, offset) that Active Record takes again.
    #
    # The recipe is [root, steps]: +root+ a Proc that reads the relation it
    # started from afresh (every record of the model, an association's, a
    # foreign-key lookup), set where such a relation is made
    # (EventStoreReader, DeferredRelation, the :through associations), and
    # +steps+ the query methods called on it since, [name, args, kwargs,
    # block], each recorded by the wrapper below when it returns a relation
    # of the same model. A relation made any other way (a copy, a batch's
    # records, a relation of given records) has none, and a write on it
    # writes the records it holds, those its stream does not say destroyed
    # (CachedRelation#locked_records_now). A recipe belongs to the relation it
    # was recorded on: a copy does not inherit it.
    module Rebuildable
      # The query methods: each returns the relation narrowed, ordered,
      # windowed or otherwise derived from this one. Those that return the
      # relation itself unchanged (lock, annotate, all) are no step; a bang
      # method changes it in place, and is one.
      STEPS = %i[create_with create_with! distinct eager_load except extending extending! group in_order_of includes
                 joins left_joins left_outer_joins limit limit! merge merge! narrowed_by none not offset only or order
                 order! padding page per preload readonly references reorder reselect reverse_order reverse_order!
                 rewhere select unscope unscope! unscoped where where! where_associated where_missing
                 without_count].freeze
      LOADS = %i[to_a to_ary each records length present? blank? []].freeze
      QUERY_FINDERS = %i[find find_by find_by! find_sole_by find_or_create_by find_or_create_by! find_or_initialize_by
                         create_or_find_by create_or_find_by!].freeze

      # A module of wrappers for +klass+ (CachedRelation and its subclasses,
      # whose own overrides come before CachedRelation's in the lookup).
      def self.wrappers
        Module.new do
          STEPS.each do |name|
            bang = name.end_with?("!")
            define_method(name) do |*args, **kwargs, &block|
              # A batch loaded with its records (CachedRelation#query_relation):
              # its query is another relation's, as Active Record's
              # load_records keeps the relation's query.
              if !bang && (query = query_relation)
                return query.public_send(name, *args, **kwargs, &block)
              end
              # As Active Record's: a loaded relation cannot be changed in
              # place (where! changed its records).
              raise ActiveRecord::UnmodifiableRelation if bang && loaded_records?

              recipe = rebuild_recipe
              # Copied before the call: what the caller changes afterwards
              # (codes << "a2") does not reach the relation, nor its write.
              step = Rebuildable.step(name, args, kwargs, block) if recipe
              result = super(*args, **kwargs, &block)
              Rebuildable.record(self, result, recipe, step)
              # A lock carries to what is built from the locked relation
              # (Model.lock.where(...)), as Active Record's lock value does.
              if @locking_read && result.is_a?(CachedRelation) && !result.equal?(self)
                result.instance_variable_set(:@locking_read, true)
              end
              result
            end
          end

          # The finders that run their own query on a loaded relation in
          # Active Record (where(...).take, where(...).sole): a batch loaded
          # with its records (query_relation) finds by its query, not among
          # the records it holds. find with a block is Enumerable's, over them.
          QUERY_FINDERS.each do |name|
            define_method(name) do |*args, **kwargs, &block|
              if (name != :find || block.nil?) && (query = query_relation)
                return query.public_send(name, *args, **kwargs, &block)
              end

              super(*args, **kwargs, &block)
            end
          end

          # What loads an Active Record relation: after it, its destroy_all
          # and update work on the records loaded (CachedRelation#loaded_records?).
          LOADS.each do |name|
            define_method(name) do |*args, **kwargs, &block|
              result = super(*args, **kwargs, &block)
              @loaded_records = true unless Thread.current[:lyra_cached_delivery] || (name == :each && block.nil?)
              result
            end
          end

          # A model's scopes and class methods, called on the relation. They
          # are the application's code, run once, when the relation is built,
          # as Active Record runs them: they are no step. What they build is
          # recorded by the query methods they call (the conditions as they
          # evaluated them, Time.now or the ids they plucked included); a
          # result built otherwise has no recipe.
          def method_missing(name, *args, **kwargs, &block)
            result = super
            if result.is_a?(CachedRelation) && !result.equal?(self)
              result.instance_variable_set(:@loaded_records, nil)
            end
            result
          end
        end
      end

      # Stands for a value that cannot be copied safely: the recipe is
      # dropped, and a write on the relation writes the records it holds.
      UNSAFE = Object.new.freeze

      # Steps that do not change which records are selected (methods added,
      # associations to preload, attributes for new records): a relation
      # built again without them selects the same records, so they are not
      # recorded, a block included (extending { ... }).
      NEUTRAL = %i[extending extending! readonly includes preload eager_load references create_with
                   create_with! strict_loading].freeze

      # Steps that take conditions or orders off (unscope, rewhere, except,
      # only) rebuild the relation from its plan (CachedRelation#replay_plan):
      # from where it started (read again: a Proc, or a relation with its own
      # recipe) through the query methods of the plan, each recorded as it
      # runs. The relation they return has that recipe, which is the one
      # kept: recording the step itself would replay it on a relation built
      # again, which has no plan, and the write fell back to the records held
      # when the relation was built.
      PLAN_STEPS = %i[unscope unscope! rewhere except only].freeze

      # [name, args, kwargs], the arguments deep-copied and frozen; nil when
      # one cannot be copied (an object of the application's), or a block was
      # given (the application's code, which a replay would run again).
      # NEUTRAL: :neutral.
      def self.step(name, args, kwargs, block)
        return :neutral if NEUTRAL.include?(name)
        return nil if block

        args = copy(args)
        kwargs = copy(kwargs)
        return nil if args.equal?(UNSAFE) || kwargs.equal?(UNSAFE)

        [name, args, kwargs]
      end

      # A copy of +value+ that changes to the caller's objects do not reach
      # (frozen with +freeze+), or UNSAFE. Immutable values, classes, records,
      # Arel nodes and relations (a CachedRelation is built again from its
      # own recipe; an Active Record relation is copied) are kept as they are.
      def self.copy(value, freeze: true)
        case value
        when nil, true, false, Symbol, Numeric, Module, Date, Time, ActiveSupport::TimeWithZone,
             ActiveSupport::Duration, ActiveRecord::Base, CachedRelation
          value
        when String
          freeze ? (value.frozen? ? value : value.dup.freeze) : value.dup
        when Array
          copied = []
          value.each do |item|
            item = copy(item, freeze: freeze)
            return UNSAFE if item.equal?(UNSAFE)

            copied << item
          end
          freeze ? copied.freeze : copied
        when Hash
          copied = {}
          value.each do |key, item|
            key = copy(key, freeze: true)
            item = copy(item, freeze: freeze)
            return UNSAFE if key.equal?(UNSAFE) || item.equal?(UNSAFE)

            copied[key] = item
          end
          freeze ? copied.freeze : copied
        when Set
          items = copy(value.to_a, freeze: freeze)
          return UNSAFE if items.equal?(UNSAFE)

          freeze ? Set.new(items).freeze : Set.new(items)
        when Range
          first = copy(value.begin, freeze: true)
          last = copy(value.end, freeze: true)
          return UNSAFE if first.equal?(UNSAFE) || last.equal?(UNSAFE)

          Range.new(first, last, value.exclude_end?)
        when ActiveRecord::Relation
          value.spawn
        when Arel::Nodes::Node, Arel::Attributes::Attribute
          value
        else
          UNSAFE
        end
      end

      # +result+ of +step+ called on +receiver+ (whose recipe was +recipe+
      # before the call) gets +recipe+ and the step (none if the step could
      # not be recorded). A result that is the receiver itself is a step only
      # for a bang method; a new relation whose receiver had no recipe keeps
      # what it was given when made.
      def self.record(receiver, result, recipe, step)
        return unless result.is_a?(CachedRelation) && result.model_class == receiver.model_class

        if step == :neutral
          result.instance_variable_set(:@loaded_records, nil) unless result.equal?(receiver)
          result.rebuild_recipe = recipe if recipe
          return
        end
        if step && PLAN_STEPS.include?(step.first)
          result.instance_variable_set(:@loaded_records, nil) unless result.equal?(receiver)
          return
        end

        if result.equal?(receiver)
          name = step ? step.first : nil
          return if name && !name.to_s.end_with?("!")

          result.rebuild_recipe = recipe && step && [recipe[0], recipe[1] + [step]]
        else
          # A new relation has loaded nothing yet (a copy holds the flag).
          result.instance_variable_set(:@loaded_records, nil)
          return unless recipe

          result.rebuild_recipe = step && [recipe[0], recipe[1] + [step]]
        end
      end

      # The relation +recipe+ builds now, or nil when a step does not give a
      # relation. Each step gets a fresh copy of its arguments; a relation
      # among them (merge, or, a subquery) is built again too. A first step
      # that names primary keys reads only those records (keyed).
      def self.rebuild(recipe)
        root, steps = recipe
        relation = keyed(root, steps.first) || root.call
        steps.each do |name, args, kwargs|
          return nil unless relation.is_a?(CachedRelation)

          args = copy(args, freeze: false).map { fresh(_1) }
          kwargs = copy(kwargs, freeze: false).transform_values { fresh(_1) }
          relation = relation.public_send(name, *args, **kwargs)
        end
        relation.is_a?(CachedRelation) ? relation : nil
      end

      def self.fresh(arg)
        case arg
        when CachedRelation
          recipe = arg.rebuild_recipe
          (recipe && rebuild(recipe)) || arg
        when Hash
          arg.any? { |_, value| value.is_a?(CachedRelation) } ? arg.transform_values { fresh(_1) } : arg
        else arg
        end
      end

      # Every record of a model, read again (EventStoreReader.relation).
      AllRecords = Struct.new(:model_class) do
        def call = EventStoreReader.relation(model_class)
      end

      # The records of a model with these primary keys, read again
      # (EventStoreReader.keyed).
      Keyed = Struct.new(:model_class, :ids) do
        def call = EventStoreReader.keyed(model_class, ids)
      end

      # When +root+ is every record of the model and +first+ a where that
      # names primary keys (where(id: 5), where(id: [1, 2])), the records
      # with those keys only: the step that follows selects the same records
      # from them as from every record, at the cost of the records written,
      # not of the model's size.
      def self.keyed(root, first)
        return nil unless root.is_a?(AllRecords) && first && first[0] == :where

        args = first[1]
        conditions = args.empty? ? first[2] : (args.size == 1 && args.first.is_a?(Hash) ? args.first : nil)
        return nil unless conditions.is_a?(Hash)

        key = root.model_class.primary_key
        value = conditions.key?(key) ? conditions[key] : conditions[key.to_sym]
        values = Array(value)
        return nil if value.nil? || values.empty? || !values.all? { _1.is_a?(Integer) || _1.is_a?(String) }

        Keyed.new(root.model_class, values).call
      end
    end

    module CachedRelationWindow
      %i[not where_missing where_associated order reorder reverse_order distinct uniq reselect group joins left_joins
         left_outer_joins create_with rewhere in_order_of].each do |name|
        define_method(name) do |*args, **kwargs, &block|
          return super(*args, **kwargs, &block) unless window_source

          rewindow(window_source.public_send(name, *args, **kwargs, &block))
        end
      end

      # where with no conditions is the chain (where.not, where.missing) of
      # this relation, which comes back here.
      def where(*args, **kwargs, &block)
        return super if window_source.nil? || (args.empty? && kwargs.empty?) || args.first == :chain

        rewindow(window_source.where(*args, **kwargs, &block))
      end

      def select(*args, &block)
        return super if window_source.nil? || block

        rewindow(window_source.select(*args))
      end

      # merge of an Array is of the loaded records (the window's). A limit or
      # offset the other relation has (an event-store relation's window, or
      # an Active Record relation's limit_value and offset_value) replaces
      # this one's, as Active Record's merge takes them; the rest of it is
      # merged into the relation this window was taken from. An Active Record
      # relation's limit used to be taken inside this window.
      def merge(other, *rest)
        relation = other.is_a?(CachedRelation) || other.is_a?(ActiveRecord::Relation)
        window = relation ? merged_window(other) : nil
        return super if window.nil? && (window_source.nil? || !relation)
        return rewindow(window_source.merge(other, *rest)) if window.nil?

        limit, offset, unwindowed = window
        (window_source || self).merge(unwindowed)
                               .windowed_by(limit.nil? ? limit_value : limit, offset.nil? ? offset_value : offset,
                                            pagination: @pagination)
      end

      # Kaminari's Model.page extends the relation with its modules:
      # CachedRelation answers what they define itself (as a page); any
      # other module extends the relation the window was taken from.
      def extending(*modules, &block)
        modules = modules.flatten
        modules << Module.new(&block) if block
        kaminari, others = modules.partition { CachedRelation.kaminari_module?(_1) }
        relation =
          if others.empty? then clone
          elsif window_source then rewindow(window_source.extending(*others))
          else super(*others)
          end
        relation.instance_variable_set(:@pagination, @pagination || {}) if kaminari.any?
        relation
      end

      # unscope(:limit) and unscope(:offset) take the window off; anything
      # else is taken off the relation the window was taken from.
      def unscope(*args)
        return super unless window_source

        window_args, rest = args.flatten.partition { |arg| %w[limit offset].include?(arg.to_s) && !arg.is_a?(Hash) }
        dropped = window_args.map(&:to_s)
        source = rest.empty? ? window_source : window_source.unscope(*rest)
        source.windowed_by(dropped.include?("limit") ? nil : limit_value, dropped.include?("offset") ? nil : offset_value,
                           pagination: @pagination)
      end

      def only(*keeps)
        return super unless window_source

        kept = keeps.flatten.map(&:to_sym)
        window_source.only(*(kept - %i[limit offset]))
                     .windowed_by(kept.include?(:limit) ? limit_value : nil, kept.include?(:offset) ? offset_value : nil,
                                  pagination: @pagination)
      end

      # As Active Record's: two relations with the same window are one query
      # with both conditions (OR) and that window; with different windows,
      # an ArgumentError.
      def or(other)
        theirs = other.is_a?(CachedRelation) ? [other.limit_value, other.offset_value] : nil
        mine = [limit_value, offset_value]
        return super if theirs.nil? || (window_source.nil? && theirs == mine)
        unless theirs == mine
          incompatible = []
          incompatible << :limit unless theirs&.first == mine.first
          incompatible << :offset unless theirs&.last == mine.last
          raise ArgumentError, "Relation passed to #or must be structurally compatible. " \
                               "Incompatible values: #{incompatible.inspect}"
        end

        rewindow(window_source.or(other.window_source))
      end

      private

      # [limit, offset, the other relation without them] when +other+ has a
      # limit or offset, else nil.
      def merged_window(other)
        if other.is_a?(CachedRelation)
          return other.window_source && [other.limit_value, other.offset_value, other.window_source]
        end
        return nil if other.limit_value.nil? && other.offset_value.nil?

        [other.limit_value, other.offset_value, DefaultScopes.built { other.unscope(:limit, :offset) }]
      end

      def rewindow(relation)
        return relation unless relation.is_a?(CachedRelation)

        relation.windowed_by(limit_value, offset_value, pagination: @pagination)
      end
    end

# A locked relation's records, read in a transaction in ES-NoProj (from
# 1.0.1): before the first read, the records it selects are locked
# (their aggregate locks, which every writer of them takes before its
# append) and read again under the locks, as many times as records
# start to match in between (LazyProjection::SELECTION_RECHECKS), so a
# read-modify-write of them excludes every other writer until the
# transaction ends. find(ids) locks only the ids (locked_find_relation).
# A window (limit, offset) reads as before (the CHANGELOG's known issues).
module CachedRelationLockedSelection
  %i[each to_a records first last take take! first! last! find_by find_by! sole].each do |name|
    define_method(name) do |*args, **kwargs, &block|
      lock_selection!
      super(*args, **kwargs, &block)
    end
  end

  private

  def lock_selection!
    return if @selection_locked || !@locking_read || windowed?
    return unless Lyra::Projections::LazyProjection.orders_locking_reads?
    return unless model_class.with_connection(&:transaction_open?)
    return unless (recipe = rebuild_recipe)

    @selection_locked = true
    locked = []
    fresh = nil
    (Lyra::Projections::LazyProjection::SELECTION_RECHECKS + 1).times do
      fresh = evaluate_relation(recipe) or return
      missing = fresh.to_a.map { record_id(_1) }.uniq - locked
      break if missing.empty?

      Lyra::BypassEvents.check_lock_limit!(model_class, locked.size + missing.size, "locking read")
      Lyra::Projections::LazyProjection.take_aggregate_locks(model_class, missing)
      locked |= missing
    end
    @records = fresh.to_a.select { locked.include?(record_id(_1)) }
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

      # Set on a relation whose records' locks are held and whose streams
      # were read live in the current transaction (update_counters' groups):
      # its bulk write does not take or read them again.
      attr_writer :live_checked
      protected :live_checked=

      # How to build this relation again from the event store (Rebuildable),
      # or nil. Only the relation it was set on has it: a copy (clone, dup,
      # spawn) holds the same ivar, pointing at the original.
      def rebuild_recipe
        @rebuild && @rebuild.first.equal?(self) ? @rebuild.last : nil
      end

      def rebuild_recipe=(recipe)
        @rebuild = recipe && [self, recipe]
      end

      # Whether the application has loaded the records (to_a, each, ...), as
      # Active Record's loaded?: its destroy_all and update then work on
      # those records, not on the query run again.
      def loaded_records? = @loaded_records ? true : false

      # Active Record's loaded? (and loaded): true once the records are
      # loaded (load, to_a, each, records, ...); before, false on a relation
      # made new (Model.all) and nil on one derived from another (where,
      # order, ...; Rebuildable.record) or reset, as Active Record answers.
      def loaded = @loaded_records ? true : @loaded_records
      alias_method :loaded?, :loaded

      # As Active Record's load: the records loaded, as any read delivers
      # them (the purpose check, each record checked, a restricted one
      # raising), each given to the block, and the relation returned. A
      # relation loaded already is not loaded again (nor the block called),
      # as in Active Record. It was refused (UnsupportedQuery).
      def load(&block)
        unless loaded_records?
          loaded = records
          loaded.each(&block) if block
          @loaded_records = true
        end
        self
      end

      # As Active Record's reset: the relation forgets its records and is
      # read again from the event store (Rebuildable), as a relation built at
      # this moment is; it is no longer loaded. A relation that cannot be
      # built again (one of given records) is refused: Active Record runs
      # its query again, and the records it holds are not that query's.
      def reset
        recipe = rebuild_recipe
        fresh = recipe && evaluate_relation(recipe)
        unless fresh
          raise UnsupportedQuery.new(model_class, "reset of a relation that cannot be read again from the event store")
        end

        replace_with!(fresh)
        @loaded_records = nil
        self
      end

      # As Active Record's reload: reset, then load. It was refused.
      def reload
        reset
        load
      end

      # The relation whose query this one's loaded records were selected by
      # (Active Record's load_records): an in_batches batch loaded with its
      # records (load: true, or a batch of a loaded relation). Its query
      # methods, its aggregates (count, sum, exists?, ...) and its
      # update_all, delete_all and touch_all are that relation's, as Active
      # Record runs them as the relation's SQL; its reads (to_a, size, ids,
      # pluck, first, ...) and destroy_all and update are of the records
      # loaded. nil for any other relation. A Proc builds it each time it is
      # asked for (an in_batches(load: true) batch's query, read again from
      # the event store, as Active Record runs it each time).
      def query_relation
        @query_relation.is_a?(Proc) ? @query_relation.call : @query_relation
      end

      # Loaded with its records, its query +query+'s (a relation, or a Proc
      # building it).
      def loaded_with(query)
        @loaded_records = true
        @query_relation = query
        self
      end
      protected :loaded_with

      # This relation selects what +other+ does (a copy made of it): it is
      # built again as +other+ is.
      def inherit_rebuild(other)
        self.rebuild_recipe = other.rebuild_recipe
        self
      end

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
        relation.instance_variable_set(:@negated_columns, @negated_columns) if @negated_columns
        relation.instance_variable_set(:@or_terms, @or_terms) if @or_terms
        relation.instance_variable_set(:@reordering, @reordering) if @reordering
        relation.instance_variable_set(:@distinct, @distinct) if @distinct
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

      # As Active Record's where(id).take (and find_by's where(...).take):
      # on a window, the condition applies before it and the record is the
      # first after its offset (take's limit replaces the window's).
      # find(id), or find(id, id, ...) and find([ids]) as Active Record's
      # find_some: the records with those ids, all of them or RecordNotFound
      # (on a window, as many as its limit and offset leave; in an ordered
      # relation, in its order, else in the order of the ids). Several ids
      # used to be an ArgumentError.
      def find(*args)
        if (fresh = locked_find_relation(args))
          return fresh.find(*args)
        end

        expects_array = args.first.is_a?(Array)
        return [] if expects_array && args.first.empty?

        ids = args.flatten.compact.uniq
        case ids.size
        when 0
          raise ActiveRecord::RecordNotFound.new("Couldn't find #{model_class.name} without an ID", model_class)
        when 1
          record = find_one(ids.first)
          expects_array ? [record] : record
        else
          find_some(ids)
        end
      end

      # A locked relation's find (lock above), in a transaction, in ES-NoProj:
      # the records' aggregate locks, then the relation read again under them.
      # nil where the find reads as it did.
      def locked_find_relation(args)
        return nil unless @locking_read && Lyra::Projections::LazyProjection.orders_locking_reads?

        ids = args.flatten.compact.uniq
        return nil unless ids.any? && ids.all? { _1.is_a?(Integer) || _1.is_a?(String) }
        return nil unless model_class.with_connection(&:transaction_open?)

        Lyra::Projections::LazyProjection.take_aggregate_locks(model_class, ids)
        (recipe = rebuild_recipe) && evaluate_relation(recipe)
      end
      private :locked_find_relation

      def find_one(id)
        record = window_first(@records) { |r| r.id.to_s == id.to_s }
        record || raise(ActiveRecord::RecordNotFound.new(
          "Couldn't find #{model_class.name} with '#{model_class.primary_key}'=#{id}",
          model_class, model_class.primary_key, id
        ))
      end
      private :find_one

      def find_some(ids)
        wanted = ids.map(&:to_s)
        source = (window_source || self).raw_records.select { |record| wanted.include?(record.id.to_s) }
        offset = offset_value.nil? ? 0 : window_number(offset_value, "offset")
        limit = limit_value.nil? ? nil : window_number(limit_value, "limit")
        if ordering.any?
          result = source.drop(offset)
          result = result.first(limit) if limit
          expected = limit && ids.size > limit ? limit : ids.size
          expected = ids.size - offset if offset_value && ids.size - offset < expected
        else
          sliced = ids.slice(offset, limit || ids.size) || []
          by_id = source.to_h { [_1.id.to_s, _1] }
          result = sliced.filter_map { by_id[_1.to_s] }
          expected = sliced.size
        end
        return result if result.size == expected

        raise ActiveRecord::RecordNotFound.new(
          "Couldn't find all #{model_class.name.pluralize} with '#{model_class.primary_key}': (#{ids.join(', ')}) " \
          "(found #{result.size} results, but was looking for #{expected}).",
          model_class, model_class.primary_key, ids
        )
      end
      private :find_some

      def find_by(attributes)
        tests = condition_tests(model_class, attributes)
        window_first(@records) { |record| true.equal?(matches_all?(record, tests)) }
      end

      # The first of +records+ the block accepts; on a window, the first that
      # the relation it was taken from has after the window's offset.
      def window_first(records, &block)
        return records.find(&block) unless window_source

        window_source.raw_records.select(&block).drop(window_number(offset_value || 0, "offset")).first
      end
      private :window_first

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

      # As Active Record: with no argument, whether the relation has a record;
      # exists?(false) and exists?(nil) are false (they used to answer as
      # exists? with no argument). On a window, a limit of 0 has none, and a
      # condition applies before the window (Active Record's exists? keeps
      # only the offset).
      def exists?(conditions = :none)
        return false if conditions.nil? || conditions == false
        return false if !limit_value.nil? && window_number(limit_value, "limit").zero?
        return window_matching(conditions).exists? if window_source && conditions != :none

        case conditions
        when :none
          @records.any?
        when nil, false
          false
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

      # The records exists?(conditions) asks for on a window: those of the
      # relation it was taken from that satisfy them, after its offset.
      def window_matching(conditions)
        matching =
          case conditions
          when Hash then window_source.where(conditions)
          when Integer, String then window_source.where(model_class.primary_key => conditions)
          when Array then window_source.where(*conditions)
          else raise UnsupportedQuery.new(model_class, "exists?(#{conditions.inspect[0, 60]})")
          end
        offset_value.nil? ? matching : matching.offset(offset_value)
      end
      protected :window_matching

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
        relation = filter_rows do |record, joins|
          false.equal?(combine_and(matches_all?(record, tests), joined.empty? ? true : joined_match(joins, joined)))
        end
        negated = conditions.flat_map { |key, value| condition_column_names(key, value) }
        relation.instance_variable_set(:@negated_columns, negated_columns | negated)
        relation
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

      # As Active Record's excluding (and without): where.not(primary key:
      # the ids of the records given, and of the relations given), so a
      # write on it selects at write time as any where.not does
      # (Rebuildable). A record or relation of another model is Active
      # Record's ArgumentError. It used to be Enumerable's excluding, which
      # returned an Array.
      def excluding(*records)
        relations, records = records.partition { _1.is_a?(CachedRelation) || _1.is_a?(ActiveRecord::Relation) }
        records = records.flatten(1).compact
        unless records.all?(model_class) &&
               relations.all? { (_1.is_a?(CachedRelation) ? _1.model_class : _1.model) == model_class }
          raise ArgumentError, "You must only pass a single or collection of #{model_class.name} objects to ##{__callee__}."
        end

        ids = records.map { |record| record.is_a?(model_class) ? record.id : record } + relations.flat_map(&:ids)
        self.not(model_class.primary_key => ids)
      end
      alias_method :without, :excluding

      # An order by a value's position in a list (in_order_of): the record's
      # position, or +otherwise+ for a value not in it.
      PositionOrder = Struct.new(:column, :positions, :type, :otherwise) do
        def sort_reader
          ->(record) { positions.fetch(type.serialize(record.read_attribute(column)), otherwise) }
        end

        def to_s = "in_order_of(#{column})"
      end

      # As Active Record's in_order_of: the records whose +column+ has one of
      # +values+ (unless filter: false), ordered by its position among them
      # (a CASE in Active Record's ORDER BY), after any order the relation has
      # (Active Record's order! adds it), records not among them last. The
      # values are cast as Active Record casts them (an enum's label to its
      # value; one the column cannot hold is left out; nil is a position,
      # IS NULL); none left is none. A column that is not an attribute of the
      # model (an SQL expression, another table's) is refused. It used to be
      # Enumerable's in_order_of, which returned an Array.
      def in_order_of(column, values, filter: true)
        model_class.disallow_raw_sql!([column], permit: model_class.adapter_class.column_name_with_order_matcher)
        return none if values.empty?
        unless (column.is_a?(Symbol) || column.is_a?(String)) && !column.is_a?(Arel::Nodes::SqlLiteral)
          raise UnsupportedQuery.new(model_class, "in_order_of(#{column.inspect[0, 60]})")
        end

        # The model's own table in front of the column ("items.code") is
        # the column, as Active Record's arel_column reads it.
        column = column.to_s.delete_prefix("#{model_class.table_name}.") if column.is_a?(String)
        TypedValues.sort_reader(model_class, column) # refuses what is not an attribute, or is encrypted
        name = TypedValues.attribute_name(model_class, column)
        type = model_class.type_for_attribute(name)
        positions = {}
        kept = []
        values.each do |value|
          serialized = value.nil? || !type.serializable?(value) ? nil : type.serialize(value)
          next if !value.nil? && serialized.nil?

          kept << value
          positions[serialized] = positions.size unless positions.key?(serialized)
        end
        return none if positions.empty?

        # The filter is a where of the column (IS NULL for nil), so that
        # rewhere, unscope and except take it off as in Active Record; the
        # order is a step of the plan (:position), which unscope(:order)
        # takes off. It was a filter they did not see.
        relation = filter ? where(name => kept) : self
        key = PositionOrder.new(name, positions, type, positions.size)
        ordered = relation.send(:sorted_rows, relation.ordering + [{ key => :asc }])
        ordered.continue_plan(relation, [:position, key]).add_query_terms([[:value, [name]]])
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

      # Order arguments as [{ column => :asc/:desc }]: symbols, hashes of a
      # column and asc or desc, "col [ASC|DESC], ..." strings (with this
      # model's table, if any, in front of the column) and Arel orderings of a
      # column of this model's table. Anything else is refused; an unreadable
      # ordering used to compare as equal and leave the result silently
      # unordered, and another table's column ("posts.title", an Arel
      # attribute of another table) or a direction other than asc or desc
      # ("desc nulls last") ordered by this model's column of that name,
      # ascending.
      def order_keys(args)
        args.flatten.flat_map do |arg|
          case arg
          when Symbol then [{ arg => :asc }]
          when Hash
            arg.map do |column, direction|
              direction = direction.to_s.downcase
              raise UnsupportedQuery.new(model_class, "order(#{arg.inspect[0, 60]})") unless %w[asc desc].include?(direction)

              { column.to_sym => direction.to_sym }
            end
          when String
            arg.split(",").map do |part|
              match = part.strip.match(/\A(?:"?(\w+)"?\.)?"?(\w+)"?(?:\s+(asc|desc))?\z/i)
              unless match && (match[1].nil? || match[1] == model_class.table_name.to_s) && model_class.column_names.include?(match[2])
                raise UnsupportedQuery.new(model_class, "order(#{arg.inspect})")
              end

              { match[2].to_sym => (match[3] || "asc").downcase.to_sym }
            end
          when Arel::Nodes::Ordering
            column = own_column(arg.expr)
            raise UnsupportedQuery.new(model_class, "order(#{arg.to_sql})") unless column

            [{ column => arg.descending? ? :desc : :asc }]
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

        # Each record once, in the relation's order (one query's ORDER BY),
        # or else by primary key, as the table returns an unordered query's
        # rows. It used to be this relation's records, then the other's.
        union = spawn_records((@records + other.raw_records.to_a).uniq { |record| record.id })
        union.send(:sorted_by, ordering.any? ? ordering : [{ model_class.primary_key.to_sym => :asc }]).tap do |sorted|
          sorted.ordering = ordering
        end
      end

      # The query terms that are an OR's alternatives (Delivery#or): their
      # columns are not conditions merge can replace one at a time.
      def or_terms = @or_terms || {}.compare_by_identity

      def add_or_terms(terms)
        @or_terms = or_terms.merge(terms.to_h { [_1, true] }.compare_by_identity) if terms.any?
        self
      end

      def reorder(*args)
        keys = args.compact.empty? ? [] : order_keys(args)
        relation = keys.any? ? sorted_by(keys) : spawn_records(@records)
        relation.ordering = keys
        relation.instance_variable_set(:@reordering, true)
        relation
      end

      # Whether reorder made the order (Active Record's reordering_value):
      # merging such a relation replaces the order.
      def reordering? = @reordering ? true : false

      def distinct? = @distinct ? true : false

      def reverse_order
        relation = spawn_records(@records.reverse)
        relation.ordering = ordering.map { |key| key.transform_values { |direction| direction == :desc ? :asc : :desc } }
        relation
      end

      # =========================================================================
      # Windows: limit, offset and pagination (Kaminari's page and per)
      # =========================================================================

      # As SQL's LIMIT and OFFSET: a window of what the relation selects,
      # taken after its conditions and order, whenever they were given. The
      # relation keeps the one it was taken from (window_source), and the
      # query methods called on it after the window (where, order, a scope,
      # merge, ...) are applied to that one, the window then taken again
      # (CachedRelationWindow): Model.limit(2).where(...) is the first two
      # records that satisfy the condition, as in Active Record. They used to
      # filter the two records the limit had kept. A second limit or offset
      # replaces the first, as in Active Record (limit(1).limit(3) is three
      # records; limit(2).offset(1) is records 2 and 3); they used to apply to
      # the window.
      def limit(value)
        window_base.windowed_by(value, offset_value, pagination: @pagination)
      end

      def offset(value)
        window_base.windowed_by(limit_value, value, pagination: @pagination)
      end

      # The values limit and offset were given, as Active Record's (nil when
      # there is none). limit_value used to be the page size, nil after a
      # plain limit.
      attr_reader :limit_value, :offset_value

      # The relation the window was taken from, or nil.
      attr_reader :window_source

      # Whether Kaminari's page made this relation (its per and totals apply).
      # @pagination holds what Kaminari keeps on such a relation (:per, the
      # size per was last given; :max_per_page; :padding), carried to every
      # relation derived from it, as Active Record's spawn carries them.
      def paged? = !@pagination.nil?

      # +limit+ and +offset+ of this relation's records, as a relation that
      # keeps this one as its window_source (nil both: a copy of this one).
      def windowed_by(limit, offset, pagination: nil)
        if limit.nil? && offset.nil?
          return clone.tap { _1.instance_variable_set(:@pagination, pagination&.dup) }
        end

        start = offset.nil? ? 0 : window_number(offset, "offset")
        count = limit.nil? ? nil : window_number(limit, "limit")
        relation =
          if @joins
            rows = @rows.drop(start)
            with_rows(count ? rows.first(count) : rows, @joins)
          else
            records = @records.to_a.drop(start)
            spawn_records(count ? records.first(count) : records)
          end
        relation.windowed = true
        relation.instance_variable_set(:@window_source, self)
        relation.instance_variable_set(:@limit_value, limit)
        relation.instance_variable_set(:@offset_value, offset)
        relation.instance_variable_set(:@pagination, pagination&.dup)
        relation
      end
      protected :windowed_by

      # The relation a new window is taken from: the one this window was
      # taken from, or a copy of this relation (a later bang method on this
      # one must not change the window's).
      def window_base = window_source || clone
      private :window_base

      # The window leaves out the one row an aggregate query returns (Active
      # Record's SUM, AVG, MIN, MAX of a windowed relation).
      def window_leaves_out_one_row?
        (!limit_value.nil? && window_number(limit_value, "limit").zero?) ||
          (!offset_value.nil? && window_number(offset_value, "offset").positive?)
      end
      private :window_leaves_out_one_row?

      # A limit or offset as SQL takes it: an Integer, or a String of one.
      def window_number(value, what)
        Integer(value)
      rescue ArgumentError, TypeError
        raise UnsupportedQuery.new(model_class, "#{what}(#{value.inspect})")
      end
      private :window_number

      # =========================================================================
      # Kaminari 1.2.2's pagination, as its page and PageScopeMethods give it
      # on an Active Record relation. Without Kaminari, the model's sizes are
      # Kaminari's defaults (25 a page, no maximum).
      # =========================================================================

      # page(n): limit(size).offset(size * (n - 1)), size the model's
      # paginates_per (default_per_page), or its max_paginates_per when that
      # is smaller; a page number below 1, nil or one that is not a number is
      # page 1. page(n) without per used to be refused (and before that gave
      # every record); the maximum was not applied.
      def page(num = nil)
        size = max_per_page && default_per_page > max_per_page ? max_per_page : default_per_page
        number = num.to_i - 1
        window_base.windowed_by(size, size * (number.negative? ? 0 : number), pagination: {})
      end

      # On a page, Kaminari's per: nil, a negative or a non-numeric size keeps
      # the page as it is; 0 is limit(0); else the page of that size with the
      # same number, at most max_per_page (the argument, else what
      # max_paginates_per set on the relation, else the model's). Outside a
      # page, the relation as it is.
      def per(num, max_per_page: nil)
        return self unless paged?

        max_per_page ||= @pagination[:max_per_page] || self.max_per_page
        pagination = @pagination.merge(per: (num || default_per_page).to_i)
        size = num.to_i
        return with_pagination(pagination) if size.negative? || !num.to_s.match?(/\A\d/)
        return paginated(size, offset_value, pagination) if size.zero?

        size = max_per_page if max_per_page && max_per_page < size
        paginated(size, window_number(offset_value, "offset") / window_number(limit_value, "limit") * size, pagination)
      end

      # On a page, Kaminari's: the page again with at most +new_max_per_page+
      # records, kept on the relation (the model's maximum is not changed; on
      # a relation that is not a page, Active Record hands it to the model).
      def max_paginates_per(new_max_per_page)
        return model_class.max_paginates_per(new_max_per_page) unless paged?

        with_pagination(@pagination.merge(max_per_page: new_max_per_page))
          .per(@pagination[:per] || default_per_page, max_per_page: new_max_per_page)
      end

      # Kaminari's padding(n): the page n records further on, its current
      # page and total pages counted without them.
      def padding(num)
        num = num.to_i
        raise ArgumentError, "padding must not be negative" if num.negative?

        paginated(limit_value, window_number(offset_value || 0, "offset") + num, @pagination.merge(padding: num))
      end

      # Kaminari's total_pages: the records the relation selects before the
      # window (less the padding), by the page size, at most max_pages. 1 for
      # a relation that is not a page.
      def total_pages
        return 1 unless paged?

        count = [total_count - @pagination.fetch(:padding, 0), 0].max
        size = window_number(limit_value, "limit")
        raise zero_per_page("The number of total pages was incalculable. Perhaps you called .per(0)?") if size.zero?

        pages = (count.to_f / size).ceil
        max_pages && max_pages < pages ? max_pages : pages
      end

      # Kaminari's current_page: (offset - padding) / page size + 1; 1 for a
      # relation that is not a page.
      def current_page
        return 1 unless paged?

        size = window_number(limit_value, "limit")
        raise zero_per_page("Current page was incalculable. Perhaps you called .per(0)?") if size.zero?

        ([window_number(offset_value || 0, "offset") - @pagination.fetch(:padding, 0), 0].max / size) + 1
      end

      def next_page = (current_page + 1 unless last_page? || out_of_range?)
      def prev_page = (current_page - 1 unless first_page? || out_of_range?)
      def first_page? = current_page == 1
      # Of a page without_count, Kaminari's: the last page when it has
      # records and no record follows them; out of range when it has none.
      def last_page? = without_count? ? (!out_of_range? && !next_record?) : current_page == total_pages
      def out_of_range? = without_count? ? to_a.empty? : current_page > total_pages

      # Kaminari's entry_name: the model's human name, pluralized but for a
      # count of 1 (page_entries_info's "Displaying items 1 - 2").
      def entry_name(options = {})
        refuse_outside_page!(:entry_name)
        default = options[:count] == 1 ? model_class.model_name.human : model_class.model_name.human.pluralize
        model_class.model_name.human(options.reverse_merge(default: default))
      end

      # Kaminari's without_count: a page that does not count its relation's
      # records (total_count raises, as Kaminari's does; last_page? and
      # out_of_range? look at the page itself).
      def without_count
        refuse_outside_page!(:without_count)
        with_pagination(@pagination.merge(without_count: true))
      end

      def without_count? = paged? && @pagination[:without_count] ? true : false

      # Kaminari's deprecated current_per_page: limit_value, with its warning.
      def current_per_page
        refuse_outside_page!(:current_per_page)
        ActiveSupport::Deprecation.warn "#current_per_page is deprecated and will be removed in the next major " \
                                        "version. Please use #limit_value instead."
        limit_value
      end

      # What only a Kaminari page answers: on another relation, as on Active
      # Record's, there is no such method.
      PAGE_METHODS = %i[entry_name without_count current_per_page].freeze

      def respond_to?(name, include_all = false)
        PAGE_METHODS.include?(name.to_sym) ? paged? : super
      end

      # The model's Kaminari sizes, as an Active Record relation hands them
      # to its model; Kaminari's defaults without Kaminari.
      def default_per_page
        return model_class.default_per_page if model_class.respond_to?(:default_per_page)

        kaminari_config ? kaminari_config.default_per_page : 25
      end

      def max_per_page
        return model_class.max_per_page if model_class.respond_to?(:max_per_page)

        kaminari_config&.max_per_page
      end

      def max_pages
        return model_class.max_pages if model_class.respond_to?(:max_pages)

        kaminari_config&.max_pages
      end

      # The records the relation selects before the window (the window's own
      # used to be counted). CachedRelationDelivery counts them through
      # window_source, so that the purpose check and the rights in force
      # apply to the count as to any count.
      def total_count
        refuse_count_without_count!
        (window_source || self).raw_records.size
      end

      # Whether +mod+ is (or includes) one of Kaminari's relation modules,
      # which its Model.page extends a relation with. CachedRelation answers
      # what they define itself; extending it with them would replace those
      # answers with ones that run Active Record's queries.
      def self.kaminari_module?(mod)
        return false unless defined?(::Kaminari::PageScopeMethods)

        kaminari = [::Kaminari::PageScopeMethods]
        kaminari << ::Kaminari::ActiveRecordRelationMethods if defined?(::Kaminari::ActiveRecordRelationMethods)
        kaminari.any? { |known| mod == known || mod.include?(known) }
      end

      private

      def paginated(limit, offset, pagination)
        window_base.windowed_by(limit, offset, pagination: pagination)
      end

      def with_pagination(pagination)
        relation = clone
        relation.instance_variable_set(:@pagination, pagination)
        relation
      end

      def kaminari_config
        ::Kaminari.config if defined?(::Kaminari) && ::Kaminari.respond_to?(:config)
      end

      def refuse_outside_page!(name)
        raise NoMethodError.new("undefined method '#{name}' for an instance of #{self.class}", name) unless paged?
      end

      def refuse_count_without_count!
        return unless without_count?

        raise "This scope is marked as a non-count paginable scope and can't be used in combination " \
              "with `#paginate' or `#page_entries_info'. Use #link_to_next_page or #link_to_previous_page instead."
      end

      # Whether a record follows the page (its relation has more than offset
      # plus limit records).
      def next_record?
        return false if limit_value.nil?

        start = offset_value.nil? ? 0 : window_number(offset_value, "offset")
        (window_source || self).raw_records.size > start + window_number(limit_value, "limit")
      end

      def zero_per_page(message)
        defined?(::Kaminari::ZeroPerPageOperation) ? ::Kaminari::ZeroPerPageOperation.new(message) : ZeroDivisionError.new(message)
      end

      public

      # Each record once (a joined relation's rows repeat it). Distinct
      # values of selected columns (SELECT DISTINCT name) are other rows than
      # the records: refused, in either order (they were the records).
      def distinct(value = true)
        unless value
          relation = spawn_records(@records)
          relation.instance_variable_set(:@distinct, nil)
          return relation
        end
        raise UnsupportedQuery.new(model_class, "distinct of selected columns (SELECT DISTINCT)") if selected_columns

        relation = spawn_records(@records.uniq)
        relation.instance_variable_set(:@distinct, true)
        relation
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

        relation =
          if plan
            base, steps = plan
            replay_plan(base, unscoped_steps(base, steps, args))
          else
            unscope_without_plan(args)
          end
        unscope_select_and_group(relation, args)
      end

      # unscope(:select) and unscope(:group): the columns of every record,
      # and no grouping. They used to be left on the relation.
      def unscope_select_and_group(relation, args)
        names = args.reject { _1.is_a?(Hash) }.map(&:to_s)
        drop_select = names.include?("select") && relation.selected_columns
        drop_group = names.include?("group") && relation.group_columns.any?
        return relation unless drop_select || drop_group

        relation = relation.clone.inherit_rebuild(relation) if relation.equal?(self)
        relation.selected_columns = nil if drop_select
        relation.group_columns = [] if drop_group
        relation
      end
      private :unscope_select_and_group

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
            when :not then relation.where.not(arg)
            when :merge then relation.merge(arg)
            when :order then relation.order(*arg)
            when :reorder then relation.reorder(*arg)
            when :position then relation.send(:sorted_rows, relation.ordering + [{ arg => :asc }])
            end
        end
        relation = relation.spawn.inherit_rebuild(relation) if relation.equal?(base)
        relation.plan = [base, steps]
        relation.default_scope_applied = default
        # What the plan does not hold (select, group, create_with) stays as
        # this relation has it, as Active Record keeps it on an unscope(where:).
        relation.selected_columns = selected_columns
        relation.group_columns = group_columns
        relation.create_with_attributes = create_with_attributes
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
              next [kind, value, what] unless kind == :where || kind == :not

              kept = where_columns == :all ? {} : value.reject { |key, condition| unscoped_key?(key, condition, where_columns, args) }
              kept.empty? ? nil : [kind, kept, what]
            end
          elsif other == :order
            steps = steps.reject { |kind, *| kind == :order || kind == :reorder || kind == :position }
          end
          steps = steps.map do |kind, value, what|
            case kind
            when :scope then [kind, DefaultScopes.built { value.unscope(arg) }, what]
            when :merge then [kind, value.unscope(arg), what]
            else [kind, value, what]
            end
          end
        end
        steps
      end
      private :unscoped_steps

      # Whether unscope(where: +columns+) takes off the condition on +key+:
      # one on a column of them, or on a belongs_to association whose key is
      # one of them (where(owner: ann) is a condition on owner_id; it was
      # kept). A condition on several columns at once that names one of them
      # is refused.
      def unscoped_key?(key, condition, columns, args)
        names = key.is_a?(Array) ? key.map { column_of(_1) } : [column_of(key), *condition_column_names(key, condition)]
        hit = (names & columns).any?
        if hit && key.is_a?(Array)
          raise UnsupportedQuery.new(model_class, "unscope(#{args.inspect[1..-2]}) of a condition on several columns at once")
        end

        hit
      end
      private :unscoped_key?

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

        named = base.query_terms.flat_map do |kind, term|
          next [] unless kind == :conditions && term.is_a?(Hash)

          term.flat_map { |key, value| key.is_a?(Array) ? key.map { column_of(_1) } : [column_of(key), *condition_column_names(key, value)] }
        end
        # An SQL fragment of a where (where("qty > ?", 2)) names its columns
        # in its text; unscope(:where) used to leave it on the relation.
        fragments = base.query_terms.filter_map { |kind, term| term if kind == :value && term.is_a?(String) }
        named += fragments.flat_map { |fragment| fragment.scan(/\w+/) & model_class.column_names }
        named += ["an SQL fragment"] if columns == :all && fragments.any?
        hit = columns == :all ? named.uniq : named & columns
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

      # As Active Record's (8.1): the record found, or created as
      # create_or_find_by creates it, so a record a unique index of the table
      # would conflict with is found (and, outside the relation, not found:
      # RecordNotFound) instead of created again. They created it.
      def find_or_create_by(attributes, &block)
        find_by(attributes) || create_or_find_by(attributes, &block)
      end

      def find_or_create_by!(attributes, &block)
        find_by(attributes) || create_or_find_by!(attributes, &block)
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

      # As Active Record's: create, in a savepoint, and when a unique index of
      # the table refuses the record (ActiveRecord::RecordNotUnique, which
      # ES-NoProj raises from the event store: Lyra::Projections
      # ::UniqueIndexes), the record the relation finds with +attributes+
      # (ActiveRecord::RecordNotFound when none: the value was taken by a
      # record the attributes do not select). It looked for a conflict on an
      # index made of the attributes alone before, and a value the block set
      # was created twice.
      def create_or_find_by(attributes, &block)
        create_or_find(attributes) { create(attributes, &block) }
      end

      def create_or_find_by!(attributes, &block)
        create_or_find(attributes) { create!(attributes, &block) }
      end

      def create_or_find(attributes)
        record = nil
        model_class.transaction(requires_new: true) do
          record = yield
          record._last_transaction_return_status || raise(ActiveRecord::Rollback)
        end
        record
      rescue ActiveRecord::RecordNotUnique
        model_class.with_connection(&:transaction_open?) ? rewhere(attributes).take! : find_by!(attributes)
      end
      private :create_or_find

      def create_with(attributes)
        relation = spawn_records(@records)
        relation.plan = plan
        relation.create_with_attributes = attributes.nil? ? {} : create_with_attributes.merge(attributes.to_h.transform_keys(&:to_s))
        relation
      end

      def create_with!(attributes)
        replace_with!(create_with(attributes))
      end

      # As ActiveRecord's relation update: each selected record updated
      # (callbacks and validations run; under ES-NoProj each is an event),
      # or, given an id (or ids), Active Record's model.update(id, ...): the
      # model's record with that id, found and written through the model's
      # own read and write paths (its default scope, the purpose check, an
      # event), whatever this relation selects. It used to look for the id in
      # this relation only (RecordNotFound outside it), which Active Record
      # does not: an application's code behaves as it does in Monitor.
      #
      # The records are those the relation selects when update is called, as
      # Active Record loads them then (records_now): a record destroyed
      # since the relation was built is not updated (it raised
      # RecordDestroyedError), and one that matches since is. Once the
      # application has loaded the records (loaded_records?), Active Record
      # updates those: one destroyed since takes the attributes in memory
      # and writes nothing, as Active Record's update of a row already gone
      # reaches none.
      def update(id = :all, attributes)
        return model_class.update(id, attributes) unless id == :all

        update_each(attributes) { |record| record.update(attributes) }
      end

      def update!(id = :all, attributes)
        return model_class.update!(id, attributes) unless id == :all

        update_each(attributes) { |record| record.update!(attributes) }
      end

      def update_each(attributes)
        return deliver { records_now }.each { |record| yield record } unless loaded_records?

        loaded = records
        checks = events_only? && Lyra.config.lock_aggregate_before_append
        dead = checks ? Lyra::StreamTail.destroyed_streams(loaded.map { record_stream(_1) }).to_set : Set.new
        loaded.each { |record| dead.include?(record_stream(record)) ? record.assign_attributes(attributes) : yield(record) }
      end
      private :update_each

      # As ActiveRecord's: each selected record's counters moved by the
      # given amounts (nil counting as 0), and touch: the timestamps, in
      # one update_all per set of current values, so each record gets the
      # event an update_all writes. It used to bump every record of the
      # model.
      # Nothing to change (no counter, no touch) is Active Record's
      # update_all's ArgumentError; it used to return 0.
      def update_counters(counters)
        counters = counters.dup
        touch = counters.delete(:touch)
        counters = counters.transform_keys(&:to_s)
        unknown = counters.keys - model_class.column_names
        raise UnsupportedQuery.new(model_class, "update_counters(#{unknown.join(', ')})") if unknown.any?

        touched = {}
        if touch
          names = Array.wrap(touch == true ? nil : touch)
          options = names.extract_options!
          touched = model_class.touch_attributes_with_time(*names, **options)
        end
        raise ArgumentError, "Empty list of attributes to change" if counters.empty? && touched.empty?
        return 0 if @records.empty? && rebuild_recipe.nil?

        model_class.transaction do
          # In the events-only store, the records the relation selects now,
          # every one's lock taken first, in one statement, and its counters
          # as its stream has them then (locked_records_now): the values the
          # relation holds may be stale, and an increment of them lost a
          # concurrent write's. Taking the locks group by group, in the order
          # of the values, deadlocked two writers.
          records = events_only? ? locked_records_now(current: true) : @records
          groups = records.group_by { |record| counters.keys.map { |column| record.read_attribute(column) } }
          groups.sum do |values, group|
            updates = counters.keys.zip(values).to_h { |column, value| [column, (value || 0) + counters[column]] }
            batch = spawn_records(group)
            batch.live_checked = true
            batch.update_all(updates.merge(touched))
          end
        end
      end

      # There is no SQL: the relation is answered from the event store.
      def to_sql
        raise UnsupportedQuery.new(model_class, "to_sql (the relation is answered from the event store, not by SQL)")
      end

      # A lock takes no row lock (there are no rows). From 1.0.1 a locked
      # relation's find(ids), in a transaction, takes the records' aggregate
      # locks, which every writer of them takes before its append, and reads
      # the records again under them (find below), so a read-modify-write
      # under the lock sees every committed write and no other writer commits
      # until it ends. 1.0.0 ignored the lock, and two increments could give 1.
      def lock(*_args)
        @locking_read = true
        self
      end

      # Hints for the database, which ES-NoProj reads do not reach.
      %i[annotate optimizer_hints strict_loading].each do |name|
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

      # In place, as Active Record's: it used to return a limited copy and
      # leave the relation as it was.
      def limit!(value)
        replace_with!(limit(value))
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
        kaminari, modules = modules.partition { CachedRelation.kaminari_module?(_1) }
        @pagination ||= {} if kaminari.any?
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
      # order and then the other's. Where the other's conditions name a
      # column this relation's conditions name too, the other's replace this
      # one's, as Active Record's merge replaces them (where(status: "a")
      # .merge(where(status: "b")) is the "b" records); this relation's are
      # taken off as unscope takes them off, or the merge is refused.
      #
      # An ActiveRecord relation of the model is evaluated
      # (CachedRelation#narrowed_by: its where clause, order and limit; what
      # it unscopes is taken off this one first); a relation read from the
      # event store is intersected with this one (joined on either side, the
      # rows of the join). Another model's relation raises UnsupportedQuery.
      #
      # As Active Record: the arguments after the first are its options, and
      # none changes the answer (merge(other, rewhere: true) is merge(other);
      # they used to be merged as more relations); nil or false is an
      # ArgumentError (it used to return this relation); an Array is the
      # loaded records it has too; a Proc is evaluated on the relation.
      def merge(other, *_options)
        case other
        when nil, false then raise ArgumentError, "invalid argument: #{other.inspect}."
        when Array then records & other
        when CachedRelation then merge_events_relation(other)
        when ActiveRecord::Relation then merge_active_record_relation(other)
        when Hash then raise UnsupportedQuery.new(model_class, "merge of a Hash (#{other.keys.join(', ')})")
        else
          return clone.instance_exec(&other) if other.respond_to?(:to_proc)

          raise ArgumentError, "#{other.inspect} is not an ActiveRecord::Relation"
        end
      end

      def merge!(other, *options)
        raise ArgumentError, "#{other.inspect} is not an ActiveRecord::Relation" if other.is_a?(Array)

        merged = merge(other, *options)
        merged.is_a?(CachedRelation) ? replace_with!(merged) : merged
      end

      def bind_attribute(name, value)
        self
      end

      def except(*skips)
        unscope(*skips)
      end

      # As Active Record's: the relation with only the parts named, the rest
      # taken off (only(:where) keeps the conditions and drops the order,
      # limit, select and group; only(:order) keeps the order of every record;
      # only() keeps nothing). The conditions and order are taken off as
      # unscope takes them off (replaying the relation's plan, or refusing
      # what it cannot take back); the window by CachedRelationWindow. A
      # joined relation without its joins is refused (its records are the
      # join's rows). only used to be refused, except only(:joins,
      # :left_outer_joins), which returned the relation unchanged.
      def only(*keeps)
        kept = keeps.flatten.map(&:to_sym)
        if joined_associations.any? && (kept & %i[joins left_outer_joins]).empty?
          raise UnsupportedQuery.new(model_class, "only(#{kept.map(&:inspect).join(', ')}) of a joined relation " \
                                                  "(its records are the rows of the join)")
        end

        drops = []
        drops << :where unless kept.include?(:where)
        drops << :order unless kept.include?(:order)
        drops << :select unless kept.include?(:select)
        drops << :group unless kept.include?(:group)
        relation = unscope(*drops)
        relation = relation.clone.inherit_rebuild(relation) if relation.equal?(self)
        relation.create_with_attributes = {} unless kept.include?(:create_with)
        relation
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

      # In place, as order (its plan kept, and before a window).
      def order!(*args)
        return self if args.empty?

        replace_with!(order(*args))
      end

      # In place, as reverse_order. Active Record's last asks it of the
      # relation it builds (an association's last, through its scope).
      def reverse_order!
        replace_with!(reverse_order)
      end

      # As Active Record's: the selected columns replaced. It used to do
      # nothing, and the records came back with the columns of the first
      # select only.
      def reselect(*args)
        raise ArgumentError, "The method .reselect() must contain arguments." if args.blank?
        raise UnsupportedQuery.new(model_class, "reselect of a distinct relation (SELECT DISTINCT)") if distinct?

        relation = spawn_records(@records)
        relation.plan = plan
        relation.selected_columns = select_names(args)
        relation
      end

      def select(*args, &block)
        if block_given?
          # Enumerable select
          spawn_records(@records.select(&block))
        else
          # AR select (column selection): the records stay whole, for
          # filtering; the ones returned are narrowed to these columns. A
          # second select adds its columns, as Active Record's does (it used
          # to replace the first's).
          raise ArgumentError, "Call `select' with at least one field." if args.blank?
          raise UnsupportedQuery.new(model_class, "select of a distinct relation (SELECT DISTINCT)") if distinct?

          relation = spawn_records(@records)
          relation.plan = plan
          relation.selected_columns = ((selected_columns || []) + select_names(args)).uniq
          relation
        end
      end

      def select_names(args)
        args.flatten.compact.map { |name| name.to_s.split(".").last.delete('"') }
      end
      private :select_names

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
        relation.plan = plan
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

      # A window of a grouped query is a window of its groups (GROUP BY,
      # then LIMIT): refused, rather than grouping the window's records.
      private def aggregate_by_group(operation, column_name)
        if window_source
          raise UnsupportedQuery.new(model_class, "#{operation} of a group with a limit or offset " \
                                                  "(the window would apply to the groups)")
        end

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
      # Batching, as Active Record's: by primary key (or the cursor columns),
      # ascending or as order: says, from start: to finish:, the relation's
      # own order ignored (logged, or ArgumentError with error_on_ignore:).
      # A limit and an offset are taken as Active Record takes them: the
      # batches stop after limit records, and each batch's query skips the
      # offset's records after the last batch (Active Record applies OFFSET
      # to every batch's query). They used to follow the relation's order,
      # and an offset was refused.
      # =========================================================================

      def find_each(start: nil, finish: nil, batch_size: 1000, error_on_ignore: nil, cursor: model_class.primary_key,
                    order: :asc, &block)
        options = { start: start, finish: finish, batch_size: batch_size, error_on_ignore: error_on_ignore,
                    cursor: cursor, order: order }
        unless block
          return enum_for(:find_each, **options) do
            batch_records(start: start, finish: finish, cursor: cursor, order: order, counting: true).size
          end
        end

        find_in_batches(**options) { |records| records.each(&block) }
      end

      def find_in_batches(start: nil, finish: nil, batch_size: 1000, error_on_ignore: nil, cursor: model_class.primary_key,
                          order: :asc)
        options = { start: start, finish: finish, batch_size: batch_size, error_on_ignore: error_on_ignore,
                    cursor: cursor, order: order }
        unless block_given?
          return to_enum(:find_in_batches, **options) do
            total = batch_records(start: start, finish: finish, cursor: cursor, order: order, counting: true).size
            (total - 1).div(batch_size) + 1
          end
        end

        batch_slices(of: batch_size, start: start, finish: finish, error_on_ignore: error_on_ignore,
                     cursor: cursor, order: order).each { |slice| yield slice }
        nil
      end

      # Each batch a relation: of the records of the batch, in the relation's
      # order, with its limit and offset (Active Record's rewhere(cursor =>
      # values)), or with load: true the batch's records, in the batch's
      # order. Without a block, Active Record's BatchEnumerator over this
      # relation (each, each_record, update_all, delete_all, ...); it used to
      # raise LocalJumpError.
      #
      # On a loaded relation (loaded?), as Active Record's: the records
      # loaded, in slices, each batch this relation loaded with its slice
      # (query_relation: its query methods, aggregates and update_all,
      # delete_all and touch_all are this relation's).
      def in_batches(of: 1000, start: nil, finish: nil, load: false, error_on_ignore: nil, cursor: model_class.primary_key,
                     order: :asc, use_ranges: nil, &block)
        cursor = Array(cursor).map(&:to_s)
        check_batch_options!(cursor, start, finish, order)
        ignored_order!(error_on_ignore) if ordering.any?
        unless block
          return ActiveRecord::Batches::BatchEnumerator.new(of: of, start: start, finish: finish, relation: self,
                                                            cursor: cursor, order: order, use_ranges: use_ranges)
        end

        recipe = rebuild_recipe
        if loaded_records?
          loaded_batch_slices(of, start, finish, cursor, order).each do |slice|
            batch = spawn_records(slice)
            batch.rebuild_recipe = recipe
            batch.loaded_with(self)
            yield batch
          end
          return nil
        end

        ranges = !load && (use_ranges || (use_ranges.nil? && batch_scope_empty?))
        refuse_ranges_window! if ranges
        refuse_unordered_offset!("in_batches") if !load && unordered_offset?
        each_batch(of: of, start: start, finish: finish, cursor: cursor, order: order, counting: !load) do |slice, source, range|
          if load
            batch = source.spawn_records(slice)
            batch_recipe(batch, recipe, slice)
            # Active Record's rewhere(cursor => values), loaded with the
            # batch's records: its query, built when first asked for. Its
            # records are read in the cursor's order; its query, with an
            # offset and no order, is refused (unordered_offset?).
            query = batch.rebuild_recipe
            batch.loaded_with(lambda {
              refuse_unordered_offset!("a query of an in_batches(load: true) batch") if unordered_offset?
              fresh = query && evaluate_relation(query)
              next fresh if fresh

              keyed = source.send(:batch_of, slice)
              keyed = keyed.windowed_by(limit_value, offset_value) unless limit_value.nil? && offset_value.nil?
              batch_recipe(keyed, recipe, slice)
              keyed
            })
          else
            keys = ranges ? range : slice
            batch = source.send(:batch_of, keys)
            batch = batch.windowed_by(limit_value, offset_value) unless ranges || (limit_value.nil? && offset_value.nil?)
            batch_recipe(batch, recipe, keys)
          end
          yield batch
        end
        nil
      end

      # Whether this relation has an offset and no order: Active Record's
      # in_batches batch is its rewhere(cursor => values) with the OFFSET and
      # no ORDER BY, so which of the batch's records it skips is the order
      # the database's plan reads them in (an index scan, or the table's
      # physical order after an update), which nothing here can follow.
      def unordered_offset?
        ordering.empty? && !offset_value.nil? && window_number(offset_value, "offset").positive?
      end
      private :unordered_offset?

      def refuse_unordered_offset!(what)
        raise UnsupportedQuery.new(model_class, "#{what} of a relation with an offset and no order (Active Record " \
                                                "skips the offset's records of each batch in the order the database " \
                                                "reads them; give the relation an order)")
      end
      private :refuse_unordered_offset!

      # This relation narrowed to +records+ (a batch).
      def batch_of(records)
        members = records.to_h { |record| [record, true] }.compare_by_identity
        filter_rows { |record, _joins| members.key?(record) }
      end
      private :batch_of

      # Each batch is Active Record's where(primary key => the keys of
      # +records+, those the batch's query selected) on this relation: a
      # write on it selects them again (Rebuildable), so a record of the
      # batch destroyed since, or no longer matching, is not written. On a
      # relation with a limit or offset, the condition is applied before
      # them, as Active Record's rewhere is (the offset skips records of the
      # batch again).
      #
      # A relation that starts from every record of the model starts from
      # the batch's keys instead (Rebuildable::Keyed): the steps then select
      # among them what they select among every record, the window included
      # (it is taken after the condition on the keys), at the cost of the
      # batch's records, not of the model's size.
      def batch_recipe(batch, recipe, records)
        return unless recipe

        ids = records.map { record_id(_1) }
        keys = { model_class.primary_key => ids }
        root = recipe[0].is_a?(Rebuildable::AllRecords) ? Rebuildable::Keyed.new(model_class, Rebuildable.copy(ids)) : recipe[0]
        batch.rebuild_recipe = [root, recipe[1] + [[:where, [Rebuildable.copy(keys)], {}.freeze]]]
      end
      private :batch_recipe

      # Active Record's empty_scope for batches: a relation of the model's
      # every record (to_sql is unscoped.all's).
      def batch_scope_empty?
        window_source.nil? && query_terms.empty? && ordering.empty? && joined_associations.empty? &&
          default_scope_applied.nil? && selected_columns.nil? && group_columns.empty?
      end
      private :batch_scope_empty?

      # Batches as ranges of the cursor (use_ranges: true) on a relation with
      # an offset: Active Record reads each range with the OFFSET and no
      # ORDER BY, so which records it skips is the table's physical order.
      # A limit of 0 makes its OFFSET -1, which the database rejects.
      def refuse_ranges_window!
        if !offset_value.nil? && !window_number(offset_value, "offset").zero?
          raise UnsupportedQuery.new(model_class, "in_batches(use_ranges: true) of a relation with an offset (Active " \
                                                  "Record skips records in the table's physical order)")
        end
        return if limit_value.nil? || window_number(limit_value, "limit").positive?

        raise UnsupportedQuery.new(model_class, "in_batches(use_ranges: true) of a relation with limit(0) (Active " \
                                               "Record's query has OFFSET -1)")
      end
      private :refuse_ranges_window!

      private

      # The batches' records, as Active Record forms them: after its checks
      # of the options (ArgumentError as Active Record's), a lazy enumerator
      # of the slices, each read when the loop reaches it (each_batch). On a
      # loaded relation, the loaded records in slices.
      def batch_slices(of:, start:, finish:, error_on_ignore:, cursor:, order:, counting: false)
        cursor = Array(cursor).map(&:to_s)
        check_batch_options!(cursor, start, finish, order)
        ignored_order!(error_on_ignore) if ordering.any?
        return loaded_batch_slices(of, start, finish, cursor, order).lazy if loaded_records?

        enum_for(:each_batch, of: of, start: start, finish: finish, cursor: cursor, order: order, counting: counting)
          .lazy.map { |slice, _, _| slice }
      end

      # Active Record's batches of a loaded relation: its records (the
      # window's), from +start+ to +finish+, in cursor order, in slices of
      # +of+ (or of the limit, if smaller). Nothing is read again.
      def loaded_batch_slices(of, start, finish, cursor, order)
        directions = cursor.zip(Array(order)).map { |_column, direction| (direction || :asc).to_sym }
        records = @records.to_a
        records = records.select { |record| within_batch_bound?(record, cursor, directions, start, finish) } if start || finish
        records = sort_records(records, cursor.zip(directions).map { |column, direction| { column.to_sym => direction } })
        limit = limit_value.nil? ? nil : window_number(limit_value, "limit")
        size = limit && limit < of ? limit : of
        size.positive? ? records.each_slice(size).to_a : []
      end

      # The records batched, counted (the sizes of the find_each and
      # find_in_batches enumerators): those the relation selects before its
      # window, from +start+ to +finish+, in cursor order (+counting+: those
      # a right in force does not leave out), then its offset and limit, as
      # Active Record counts the relation with the bounds' conditions.
      def batch_records(start:, finish:, cursor:, order:, counting: false)
        cursor = Array(cursor).map(&:to_s)
        source = window_source || self
        records = source.send(:batch_candidates, start: start, finish: finish, cursor: cursor, order: order)
        records = batch_kept(records) if counting
        records = records.drop(window_number(offset_value, "offset")) unless offset_value.nil?
        limit_value.nil? ? records : records.first(window_number(limit_value, "limit"))
      end

      # The records this relation (no window) selects, from +start+ to
      # +finish+, in cursor order.
      def batch_candidates(start:, finish:, cursor:, order:)
        directions = cursor.zip(Array(order)).map { |_column, direction| (direction || :asc).to_sym }
        records = raw_records.to_a
        records = records.select { |record| within_batch_bound?(record, cursor, directions, start, finish) } if start || finish
        sort_records(records, cursor.zip(directions).map { |column, direction| { column.to_sym => direction } })
      end

      # The records a count of the batches keeps: all of them, here.
      def batch_kept(records) = records

      # Active Record's batch loop (batch_on_unloaded_relation): each batch
      # read when the loop reaches it, the records after the last batch's
      # last cursor values, past the offset's records, the batch's size of
      # them: +of+, or what is left of the limit when that is less. It ends
      # with an empty batch, one smaller than +of+ (or the limit), or when the
      # limit's records were given. Yields [the batch's records, the relation
      # they were selected from (its window left out), the records of the
      # batch's range of the cursor (those a right leaves out included)].
      #
      # A relation that can be built again (Rebuildable) is read from the
      # event store for each batch, as Active Record queries each, so a record
      # inserted, changed or deleted during the loop is seen as Active Record
      # sees it; any other gives the records it holds.
      def each_batch(of:, start:, finish:, cursor:, order:, counting:)
        offset = offset_value.nil? ? 0 : window_number(offset_value, "offset")
        limit = limit_value.nil? ? nil : window_number(limit_value, "limit")
        batch_limit = limit && limit < of ? limit : of
        remaining = limit
        reader = rebuild_recipe ? live_batch_reader(start, finish, cursor, order, counting) :
                                  held_batch_reader(start, finish, cursor, order, counting)
        last = nil
        loop do
          size = remaining && remaining < batch_limit ? remaining : batch_limit
          source, slice, range = reader.call(last, offset, size)
          break if slice.empty?

          if cursor.any? { |column| slice.last.read_attribute(column).nil? }
            raise ArgumentError, "Not all of the batch cursor columns were included in the custom select clause " \
                                 "or some columns contain nil."
          end
          yield slice, source, range
          break if slice.size < batch_limit

          if remaining
            remaining -= slice.size
            break unless remaining.positive?
          end
          last = slice.last
        end
      end

      # Reads each batch from the relation built again (keyed_batch_now, or
      # whole_batch_now): the records after +last+'s cursor values, those a
      # right leaves out taken out when +counting+, past +offset+ of them,
      # the next +size+.
      def live_batch_reader(start, finish, cursor, order, counting)
        directions = cursor.zip(Array(order)).map { |_column, direction| (direction || :asc).to_sym }
        recipe = rebuild_recipe
        lambda do |last, offset, size|
          bound = last && cursor.map { |column| last.read_attribute(column) }
          source, every, kept = keyed_batch_now(recipe, bound, offset + size, start, finish, cursor, order, counting) ||
                                whole_batch_now(recipe, bound, start, finish, cursor, order, directions, counting)
          slice = kept.drop(offset).first(size)
          upto = slice.empty? ? -1 : every.index { _1.equal?(slice.last) }
          [source, slice, every.first(upto + 1)]
        end
      end

      # The same over the records this relation holds (it cannot be built
      # again), sorted once.
      def held_batch_reader(start, finish, cursor, order, counting)
        source = window_source || self
        every = source.send(:batch_candidates, start: start, finish: finish, cursor: cursor, order: order)
        kept = counting ? batch_kept(every) : every
        every_at = every.each_with_index.to_h.compare_by_identity
        kept_at = kept.each_with_index.to_h.compare_by_identity
        lambda do |last, offset, size|
          from = last ? kept_at.fetch(last) + 1 : 0
          slice = kept[from + offset, size] || []
          range = slice.empty? ? [] : every[(last ? every_at.fetch(last) + 1 : 0)..every_at.fetch(slice.last)]
          [source, slice, range]
        end
      end

      # A batch from the relation built again whole: [the relation (its
      # window left out), its records after +bound+ in cursor order, the same
      # less those a right leaves out when +counting+]. One that cannot be
      # built again (an UnsupportedQuery now) gives the records it holds,
      # every time: the batches it gave before.
      def whole_batch_now(recipe, bound, start, finish, cursor, order, directions, counting)
        fresh = evaluate_relation(recipe) || self
        fresh = fresh.window_source || fresh
        every = fresh.send(:batch_candidates, start: start, finish: finish, cursor: cursor, order: order)
        every = every.select { |record| after_cursor?(record, cursor, directions, bound) } if bound
        [fresh, every, counting ? fresh.send(:batch_kept, every) : every]
      end

      # The same, read by key, where the relation starts from every record
      # of the model and the cursor is its integer primary key (Active
      # Record's usual batches): the keys of the model's records after
      # +bound+ are listed (one query), and the relation's steps applied to
      # the records of the next keys, a chunk at a time, until +need+ are
      # selected (the offset's and the batch's). So a batch costs about its
      # own records, not the model's size. Of what the steps select from a
      # chunk, only the chunk's records are taken: a step that brings in
      # records of its own (an or, whose other relation is read whole) keeps
      # or leaves out each of the chunk's as it would among every record (an
      # or brought in the other relation's records whatever the chunk and
      # the cursor, so a batch repeated records, and a loop without a limit
      # never ended). Steps that decide a record by the others (distinct,
      # group) are read whole. A window (limit, offset) is taken by the
      # batch loop, from the relation the chunk's window was taken from. nil
      # where this does not apply.
      KEYED_WHOLE_STEPS = %i[distinct uniq group].freeze

      def keyed_batch_now(recipe, bound, need, start, finish, cursor, order, counting)
        pk = model_class.primary_key
        return nil unless recipe[0].is_a?(Rebuildable::AllRecords) && cursor == [pk]
        return nil if recipe[1].any? { |name, *| KEYED_WHOLE_STEPS.include?(name) }

        keys = CachedProjection.stream_versions_for(model_class).keys
        return nil unless keys.all? { _1.match?(/\A\d+\z/) }

        keys = keys.map(&:to_i).sort
        keys.reverse! if Array(order).first.to_s == "desc"
        if bound
          after = Integer(bound.first)
          keys = Array(order).first.to_s == "desc" ? keys.select { _1 < after } : keys.select { _1 > after }
        end
        every = []
        kept = []
        keys.each_slice([need, KEYED_CHUNK].max) do |chunk|
          part_relation = evaluate_relation([Rebuildable::Keyed.new(model_class, chunk), recipe[1]])
          return nil unless part_relation

          part_relation = part_relation.window_source || part_relation
          in_chunk = chunk.to_set
          part = part_relation.send(:batch_candidates, start: start, finish: finish, cursor: cursor, order: order)
                              .select { |record| in_chunk.include?(record_id(record)) }
          every.concat(part)
          kept.concat(counting ? part_relation.send(:batch_kept, part) : part)
          break if kept.size >= need
        end
        # The batch's relation holds them in the relation's order, as one
        # built whole does (by primary key without an order).
        held = ordering.any? ? sort_records(every, ordering) : every.sort_by { record_id(_1) }
        source = spawn_records(held)
        source.windowed = false
        [source, every, kept]
      rescue ArgumentError, TypeError
        nil
      end

      # Keys read at a time by keyed_batch_now.
      KEYED_CHUNK = 500

      # Whether +record+'s cursor values come after +last+ in the cursor's
      # directions.
      def after_cursor?(record, cursor, directions, last)
        cursor.zip(directions, last).each do |column, direction, bound|
          compared = TypedValues.compare(record.read_attribute(column), bound) || 0
          compared = -compared if direction == :desc
          return compared.positive? unless compared.zero?
        end
        false
      end

      # The relation +recipe+ builds now, as Lyra's own read, or nil.
      def evaluate_relation(recipe)
        Lyra::PurposeBoundReads.internal(INTERNAL) { model_class.uncached { Rebuildable.rebuild(recipe) } }
      rescue UnsupportedQuery
        nil
      end

      # Active Record's start: and finish: conditions: the cursor's values
      # at or after +start+ and at or before +finish+, in the cursor's
      # directions (a record with a NULL among them is outside, as SQL's
      # comparison is unknown).
      def within_batch_bound?(record, cursor, directions, start, finish)
        values = cursor.map { |column| record.read_attribute(column) }
        return false if values.any?(&:nil?)

        compare = lambda do |bound|
          cursor.zip(values, Array(bound), directions).each do |column, value, limit, direction|
            limit = model_class.type_for_attribute(column).cast(limit)
            compared = TypedValues.compare(value, limit) || 0
            compared = -compared if direction == :desc
            return compared unless compared.zero?
          end
          0
        end
        (start.nil? || compare.call(start) >= 0) && (finish.nil? || compare.call(finish) <= 0)
      end

      def check_batch_options!(cursor, start, finish, order)
        raise ArgumentError, ":start must contain one value per cursor column" if start && Array(start).size != cursor.size
        raise ArgumentError, ":finish must contain one value per cursor column" if finish && Array(finish).size != cursor.size
        if (Array(model_class.primary_key) - cursor).any?
          indexes = model_class.with_connection { |connection| connection.schema_cache.indexes(model_class.table_name) }
          unless indexes.any? { |index| index.unique && index.where.nil? && (Array(index.columns) - cursor).empty? }
            raise ArgumentError, ":cursor must include a primary key or other unique column(s)"
          end
        end
        return unless (Array(order) - %i[asc desc]).any?

        raise ArgumentError, ":order must be :asc or :desc or an array consisting of :asc or :desc, got #{order.inspect}"
      end

      def ignored_order!(error_on_ignore)
        raise_error = error_on_ignore.nil? ? ActiveRecord.error_on_ignored_order : error_on_ignore
        raise ArgumentError, ActiveRecord::Batches::ORDER_IGNORE_MESSAGE if raise_error

        model_class.logger&.warn(ActiveRecord::Batches::ORDER_IGNORE_MESSAGE) if model_class.respond_to?(:logger)
      end

      public

      prepend CachedRelationDelivery
      prepend CachedRelationWindow
      prepend Rebuildable.wrappers
      prepend CachedRelationLockedSelection

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

      # A scope called on the model (Model.active is all._exec_scope): its
      # body runs on this relation, as Active Record runs it, and its value
      # is the scope's: nil or false is the relation, anything else what the
      # body returned, as Active Record's (a scope whose body returns a
      # count, a record or an Array returns it; it used to return the
      # relation). An Active Record relation of the model it returns is
      # answered from the event store, every record narrowed by it (it is the
      # scope's value in Active Record, whatever relation the scope was
      # called on); it used to be ignored and this relation returned.
      #
      # A body whose where holds an Arel condition (where(arel_table[:qty]
      # .eq(2))) is built as Active Record builds it, and this relation is
      # narrowed by what it built (its where clause, order and limit), as a
      # scope called on a relation is (named_scope): the same scope used to be
      # refused when called on the model and answered on a relation.
      #
      # The body runs with no current scope for the model, as Active
      # Record's _exec_scope runs it (_scoping(nil)): a body that reads the
      # model itself (Model.where(...)) reads every record, not the relation
      # the scope was called on; it used to read that relation.
      def _exec_scope(*args, &block)
        result =
          begin
            self.class.scoped(model_class, nil) { instance_exec(*args, &block) }
          rescue UnsupportedQuery => e
            raise unless e.arel_condition

            built = built_past_reads("a scope") { model_class.unscoped._exec_scope(*args, &block) }
            raise unless built.is_a?(ActiveRecord::Relation) && built.model == model_class

            return narrowed_by_scope(built, "a scope")
          end

        case result
        when nil, false then self
        when ActiveRecord::Relation
          result.model == model_class ? EventStoreReader.relation(model_class).narrowed_by(result, "a scope") : result
        else result
        end
      end

      # The relation a +scoping+ block is running under, per model class, as
      # ActiveRecord's current_scope: inside it the model's own class-level
      # reads (all, where, first, last) answer from that relation instead of
      # from every record of the model. Scope bodies reached through an
      # association (order.payments.completed) run that way.
      # Kept as Active Record keeps its current scope
      # (ActiveSupport::IsolatedExecutionState: per thread, or per fiber under
      # fiber isolation): a fiber or an enumerator inside a scoping block sees
      # the scope, as it does in Active Record. It was fiber-local
      # (Thread.current[]), and they read every record.
      SCOPES_KEY = :lyra_cached_relation_scopes

      def self.scoped_for(model_class)
        (ActiveSupport::IsolatedExecutionState[SCOPES_KEY] || {})[model_class]
      end

      # The block run with +relation+ (nil: none) as +model_class+'s current
      # scope.
      def self.scoped(model_class, relation)
        scopes = (ActiveSupport::IsolatedExecutionState[SCOPES_KEY] ||= {})
        had_previous = scopes.key?(model_class)
        previous = scopes[model_class]
        relation ? scopes[model_class] = relation : scopes.delete(model_class)
        begin
          yield
        ensure
          had_previous ? scopes[model_class] = previous : scopes.delete(model_class)
        end
      end

      # Runs the block with this relation as the model's current scope and
      # returns the block's value, as ActiveRecord does. It used to return the
      # relation itself, which dropped the block's result: a scope called on
      # an association came back unfiltered.
      def scoping(skip_inherited_scope = false, full = nil, all_queries: nil)
        return self unless block_given?

        self.class.scoped(model_class, self) { yield self }
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
            scope_copy.scoping { model_class.public_send(method_name, *args, **kwargs, &block) }
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

      # The copy of this relation a scope body or class method runs on (as
      # Active Record's all hands it current_scope.clone). It selects what
      # this one does, and is built again as this one is (Rebuildable): the
      # query methods the body calls on it are recorded on what it returns,
      # with the values the body used, so a scope chain keeps its recipe and
      # a write never runs the body again.
      def scope_copy
        clone.inherit_rebuild(self)
      end
      private :scope_copy

      def named_scope?(method_name)
        model_class.method(method_name).source_location&.first.to_s.end_with?("/active_record/scoping/named.rb")
      end
      private :named_scope?

      def named_scope(method_name, *args, **kwargs, &block)
        # As Active Record runs a scope called on a relation: the model's
        # scope, with this relation as its current scope, so that its body
        # runs on this relation (_exec_scope), as it runs when the scope is
        # called on the model. A scope answers the same on the model and on a
        # relation, and one whose body returns a value (a count, a record)
        # returns it; it used to be refused on a relation. The current scope
        # is a copy of this relation, as Active Record's all hands the body
        # current_scope.clone: a bang method in the body (limit!) changes the
        # copy, not the relation the scope was called on.
        if events_only? && model_class.respond_to?(:lyra_monitored) && model_class.lyra_monitored &&
           !Thread.current[:lyra_bypass_read_override]
          begin
            return scope_copy.scoping { model_class.public_send(method_name, *args, **kwargs, &block) }
          rescue NoMethodError => e
            raise unless e.receiver.is_a?(CachedRelation)

            raise UnsupportedQuery.new(model_class, "scope #{method_name} (it called #{e.name}, which is not evaluated here)")
          end
        end

        # Elsewhere (Lyra's own reads), built past Lyra's read overrides:
        # scope lambdas that call where build ActiveRecord conditions instead
        # of reading the event store, and this relation is narrowed by them.
        scope_result = built_past_reads(method_name) { model_class.unscoped.public_send(method_name, *args, **kwargs, &block) }
        unless scope_result.is_a?(ActiveRecord::Relation) && scope_result.model == model_class
          raise UnsupportedQuery.new(model_class, "#{method_name}, which is not a scope")
        end

        narrowed_by_scope(scope_result, "scope #{method_name}")
      end
      private :named_scope

      # The block's value, built with Lyra's reads bypassed (an Active Record
      # relation of the model), or UnsupportedQuery if it raised.
      def built_past_reads(what)
        Thread.current[:lyra_bypass_read_override] = true
        yield
      rescue Lyra::StrictDataAccessViolation
        raise
      rescue => e
        # Answering anyway (as this used to, unfiltered) would be wrong.
        raise UnsupportedQuery.new(model_class, "#{what} (it raised #{e.class})")
      ensure
        Thread.current[:lyra_bypass_read_override] = nil
      end
      private :built_past_reads

      # This relation narrowed by +scope+ (an Active Record relation of the
      # model a scope built). A scope that unscopes (with_discarded) takes the
      # default scope off first, as it does on ActiveRecord's relation.
      def narrowed_by_scope(scope, what)
        base = scope.unscope_values.any? ? unscope(*scope.unscope_values) : self
        narrowed = base.narrowed_by(scope, what)
        narrowed = narrowed.spawn if narrowed.equal?(base)
        narrowed.continue_plan(base, [:scope, scope, what])
      end
      private :narrowed_by_scope

      # This relation narrowed as an ActiveRecord relation of the same model
      # selects: its where clause, then its order and limit, as SQL applies
      # them. Anything else it holds (joins, an SQL fragment, a where.not)
      # raises UnsupportedQuery naming +what+, rather than answer with records
      # the relation does not select.
      def narrowed_by(relation, what)
        extra = unsupported_clauses(relation) - %w[order limit]
        raise UnsupportedQuery.new(model_class, "#{what} (it uses #{extra.join(', ')})") if extra.any?

        conditions = extract_where_conditions(relation)
        raise UnsupportedQuery.new(model_class, what) if conditions.nil?

        narrowed = conditions.reduce(self) { |narrowing, hash| narrowing.where(hash) }
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

      # The relation's where clause as hash conditions on this model's own
      # columns, or nil as soon as one predicate is something else, so that the
      # caller refuses rather than filter by a subset of the conditions: an
      # equality or IN whose left side is not a column of this model's table (an
      # SQL literal, a function, another table's column) or whose right side is
      # not a value (another column, an SQL literal, a subquery), a NOT IN, and
      # any other kind of predicate. An equality or IN whose left side was not a
      # column used to be skipped: a scope holding
      # where(Arel.sql("lower(name)").eq("pear")) answered with every record its
      # other conditions selected.
      #
      # A list of hashes, applied one after another (AND): a column named twice
      # (where(qty: 1).where(qty: 2)) starts a new hash; the second condition used
      # to replace the first.
      def extract_where_conditions(relation)
        return [] unless relation.respond_to?(:where_clause)

        where_clause = relation.where_clause
        return [] if where_clause.empty?

        conditions = [{}]
        where_clause.send(:predicates).each do |predicate|
          column, value =
            case predicate
            when Arel::Nodes::Equality
              [own_column(predicate.left), predicate_value(predicate.right)]
            when Arel::Nodes::In
              # column IN (values); a subquery is not a list of values.
              return nil unless predicate.right.is_a?(Array)

              values = predicate.right.map { |v| predicate_value(v) }
              [own_column(predicate.left), values.any? { UNREADABLE_VALUE.equal?(_1) } ? UNREADABLE_VALUE : values]
            when Arel::Nodes::HomogeneousIn
              # IN over an array of same-type scalars: Rails' own form of
              # where(column: [v1, v2, ...]). Its NOT IN form (where.not) is refused.
              return nil unless predicate.type == :in

              [own_column(predicate.attribute), predicate.values]
            else
              return nil
            end
          return nil if column.nil? || UNREADABLE_VALUE.equal?(value)

          conditions << {} if conditions.last.key?(column)
          conditions.last[column] = value
        end
        conditions.reject(&:empty?)
      rescue StandardError
        nil
      end

      # +node+'s column name, when it is a column of this model's table.
      def own_column(node)
        return nil unless node.is_a?(Arel::Attributes::Attribute)
        return nil unless node.relation.respond_to?(:name) && node.relation.name.to_s == model_class.table_name.to_s

        node.name.to_sym
      end

      # A predicate's right side that is not a value (predicate_value).
      UNREADABLE_VALUE = Object.new.freeze

      # Conditions must be a hash: of this model's own attributes, or of a
      # table joined before (see CachedJoins). A SQL fragment or an Arel node
      # cannot be evaluated against cached records, and ignoring it would
      # widen the answer.
      def check_hash_conditions!(conditions, what)
        return if conditions.is_a?(Hash)

        error = UnsupportedQuery.new(model_class, what)
        error.arel_condition = conditions.is_a?(Arel::Nodes::Node)
        raise error
      end

      # Keep the rows the block accepts, as a joined relation if this is one.
      def filter_rows(&block)
        rows = joined_rows.select { |record, joins| block.call(record, joins) }
        @joins ? with_rows(rows, @joins) : spawn_records(rows.map(&:first))
      end

      # The value on a predicate's right side, or UNREADABLE_VALUE when it is not
      # one: another column, an SQL literal, a function, a subquery. Such a right
      # side used to be taken as the value itself, matching nothing.
      def predicate_value(node)
        case node
        when Arel::Nodes::Casted, Arel::Nodes::Quoted then node.value
        when Arel::Nodes::BindParam
          # Rails 7+ bind params
          node.value.respond_to?(:value_before_type_cast) ? node.value.value_before_type_cast : UNREADABLE_VALUE
        when NilClass then nil
        when Arel::Nodes::SqlLiteral, Arel::Nodes::Node, Arel::Attributes::Attribute then UNREADABLE_VALUE
        else node.respond_to?(:value) ? node.value : node
        end
      end

      # This relation's state taken from +other+ (the bang methods).
      def replace_with!(other)
        %i[@records @ordering @query_terms @create_attributes @create_with_attributes @plan @default_scope_applied
           @selected_columns @group_columns @windowed @rows @joins @joined_classes @window_source @limit_value
           @offset_value @pagination @negated_columns @or_terms @reordering @distinct @query_relation].each do |ivar|
          instance_variable_set(ivar, other.instance_variable_get(ivar))
        end
        # It is built again as +other+ is (Rebuildable).
        self.rebuild_recipe = other.rebuild_recipe
        self
      end
      protected :replace_with!

      def merge_events_relation(other)
        unless other.model_class == model_class
          raise UnsupportedQuery.new(model_class, "merge of a #{other.model_class.name} relation")
        end
        if other.window_source
          return merge_events_relation(other.window_source).windowed_by(other.limit_value, other.offset_value)
        end
        raise UnsupportedQuery.new(model_class, "merge of a relation with a limit or offset") if other.windowed?

        if (distinct? || other.distinct?) && (selected_columns || other.selected_columns)
          raise UnsupportedQuery.new(model_class, "merge of a relation with distinct selected columns (SELECT DISTINCT)")
        end

        base = replacing(other.condition_columns, other.negated_columns)
        merged = base.send(:intersect_rows, other)
        merged.add_query_terms(other.query_terms)
        merged.create_attributes = base.create_attributes.merge(other.create_attributes)
        merged.create_with_attributes = base.create_with_attributes.merge(other.create_with_attributes)
        # The other's order follows this one's, or replaces it if the other
        # reorders; its group and select columns are added, and its distinct
        # taken, as Active Record's merge takes them (they were dropped).
        if other.reordering?
          merged = merged.send(:sorted_rows, other.ordering)
          merged.instance_variable_set(:@reordering, true)
        elsif other.ordering.any?
          merged = merged.send(:sorted_rows, base.ordering + other.ordering)
        end
        merged.group_columns = (base.group_columns + other.group_columns).uniq
        merged.selected_columns = ((base.selected_columns || []) + other.selected_columns).uniq if other.selected_columns
        merged = merged.distinct if other.distinct?
        # Its plan: this one's, then the merge (unscope, rewhere and a later
        # merge replay it), while both have one.
        if base.plan && other.plan && base.joined_associations.empty? && other.joined_associations.empty?
          merged.plan = [base.plan[0], base.plan[1] + [[:merge, other]]]
        end
        merged
      end
      private :merge_events_relation

      # The rows of this relation whose records +other+ selects: this
      # relation's rows (with their partners, if it is joined), or, if only
      # +other+ is joined, +other+'s rows of this relation's records, in this
      # relation's order. Both joined to the same associations: the rows both
      # have. Joined to different ones, the rows would be those of both
      # joins: refused.
      def intersect_rows(other)
        pk = model_class.primary_key
        key = ->(record) { record&.read_attribute(record.class.primary_key) }
        mine = joined_associations
        theirs = other.joined_associations
        if theirs.empty?
          keys = other.raw_records.to_a.to_h { |record| [record.read_attribute(pk), true] }
          filter_rows { |record, _joins| keys.key?(record.read_attribute(pk)) }
        elsif mine.empty?
          by_record = other.joined_rows.group_by { |record, _joins| record.read_attribute(pk) }
          rows = @records.flat_map do |record|
            by_record.fetch(record.read_attribute(pk), []).map { |_partner_record, joins| [record, joins] }
          end
          with_rows(rows, theirs)
        elsif mine.transform_values(&:kind) == theirs.transform_values(&:kind)
          keys = other.joined_rows.to_h { |record, joins| [[record.read_attribute(pk), joins.transform_values(&key)], true] }
          filter_rows { |record, joins| keys.key?([record.read_attribute(pk), joins.transform_values(&key)]) }
        else
          raise UnsupportedQuery.new(model_class, "merge of relations joined to different associations " \
                                                  "(#{mine.keys.join(', ')}; #{theirs.keys.join(', ')})")
        end
      end
      private :intersect_rows

      # sorted_by, keeping a joined relation's rows (each record's rows in
      # the order they had).
      def sorted_rows(keys)
        return sorted_by(keys) unless @joins

        position = sort_records(@rows.map(&:first).uniq, keys).each_with_index.to_h.compare_by_identity
        rows = @rows.each_with_index.sort_by { |(record, _joins), index| [position[record], index] }.map(&:first)
        relation = with_rows(rows, @joins)
        relation.ordering = keys
        relation
      end
      private :sorted_rows

      def merge_active_record_relation(other)
        unless other.model == model_class
          raise UnsupportedQuery.new(model_class, "merge of a #{other.model.name} relation")
        end

        base = other.unscope_values.any? ? unscope(*other.unscope_values) : self
        if (others = extract_where_conditions(other))
          columns = Hash.new { |hash, column| hash[column] = [] }
          others.each { |conditions| conditions.each { |column, value| columns[column.to_s] << value } }
          base = base.replacing(columns, Set.new)
        end
        merged = base.narrowed_by(other, "merge(#{other.class.name})")
        merged = merged.reorder(*other.order_values) if other.reordering_value
        merged = merged.spawn if merged.equal?(self)
        merged.continue_plan(base, [:scope, other, "merge(#{other.class.name})"])
        merged.create_with_attributes = create_with_attributes.merge(other.create_with_value.stringify_keys)
        merged
      end
      private :merge_active_record_relation

      # The columns of this model this relation's conditions name (a where,
      # where.not, a scope's, a default scope's, an association's key), each
      # with the values they name: Active Record's merge replaces them where
      # the other relation names them too. A tuple condition (where([:a, :b]
      # => ...)) names each of its columns with TUPLE; a condition on a
      # joined table is not this model's.
      #
      # An OR's alternatives (or_terms) over one column are one condition on
      # it that merge would replace whole (TUPLE, refused); over several
      # columns, Active Record's merge replaces none of them, and they are
      # left out.
      def condition_columns
        alternatives = []
        columns = query_terms.each_with_object(Hash.new { |hash, column| hash[column] = [] }) do |pair, found|
          kind, term = pair
          next unless kind == :conditions && term.is_a?(Hash)

          term.each do |key, value|
            names = key.is_a?(Array) ? key.map { column_of(_1) } : condition_column_names(key, value)
            next alternatives.concat(names) if or_terms.key?(pair)

            names.each { |column| found[column] << (key.is_a?(Array) ? TUPLE : value) }
          end
        end
        columns[alternatives.first] << TUPLE if alternatives.uniq.size == 1
        columns
      end
      protected :condition_columns

      # What condition_columns gives a tuple condition's columns: a condition
      # merge cannot take off one column at a time.
      TUPLE = Object.new.freeze

      # The columns of this model a where.not of this relation names.
      def negated_columns = @negated_columns || Set.new
      protected :negated_columns

      # A condition on a joined table (where(users: { name: ... }),
      # where("users.name" => ...)) names "table.column".
      def condition_column_names(key, value)
        return key.map { column_of(_1) } if key.is_a?(Array)
        if value.is_a?(Hash) && !model_class.column_names.include?(key.to_s)
          joined = model_class.respond_to?(:reflect_on_association) && model_class.reflect_on_association(key)
          table = joined && !joined.polymorphic? ? joined.klass.table_name : key.to_s
          return value.keys.map { "#{table}.#{column_of(_1)}" }
        end

        table, column = key.to_s.include?(".") ? key.to_s.split(".", 2).map { _1.delete('"') } : [nil, key.to_s]
        return ["#{table}.#{column}"] if table && table != model_class.table_name.to_s

        reflection = model_class.respond_to?(:reflect_on_association) && !model_class.column_names.include?(column) &&
                     model_class.reflect_on_association(column)
        return [column] unless reflection && reflection.macro == :belongs_to

        [reflection.foreign_key.to_s, (reflection.foreign_type.to_s if reflection.polymorphic?)].compact
      end
      private :condition_column_names

      # This relation without its conditions on the columns +columns+ (as
      # condition_columns gives them) names with other values, or that either
      # side negates: the other's conditions replace them (merge). Where the
      # two name the same values, the conditions are the same, and stay.
      def replacing(columns, negated)
        mine = condition_columns
        tuple = ->(column) { mine[column].any? { TUPLE.equal?(_1) } || columns[column].any? { TUPLE.equal?(_1) } }
        replaced = (mine.keys & columns.keys).reject do |column|
          !tuple.call(column) && !negated_columns.include?(column) && !negated.include?(column) &&
            mine[column].uniq.to_set == columns[column].uniq.to_set
        end
        return self if replaced.empty?

        if (tupled = replaced.select(&tuple)).any?
          error = UnsupportedQuery.new(model_class, "merge of a relation with a condition on several columns at once, " \
                                                    "or an OR of conditions on one (#{tupled.join(', ')}), which Active " \
                                                    "Record's merge would replace")
          error.instance_variable_set(:@lyra_merge_refusal, true)
          raise error
        end
        # A joined table's condition is part of the join's rows, which no
        # plan replays: refused (it used to be kept with the other's, both).
        if (joined = replaced.select { _1.include?(".") }).any?
          error = UnsupportedQuery.new(model_class, "merge of a relation whose conditions on a joined table " \
                                                    "(#{joined.join(', ')}) replace this relation's, as Active Record's " \
                                                    "merge replaces them")
          error.instance_variable_set(:@lyra_merge_refusal, true)
          raise error
        end
        unscope(where: replaced)
      rescue UnsupportedQuery => e
        raise if replaced.nil? || e.instance_variable_get(:@lyra_merge_refusal)

        raise UnsupportedQuery.new(model_class, "merge of a relation whose conditions on #{replaced.join(', ')} replace " \
                                                "this relation's, as Active Record's merge replaces them, where they " \
                                                "cannot be taken off (#{e.message[/evaluate (.*?) on /, 1]})")
      end
      protected :replacing

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
        # In the events-only store a relation that can be built again is
        # (records_now): it may select records now that it did not hold.
        if @records.empty? && !(events_only? && rebuild_recipe)
          return method_name == :destroy_all ? [] : 0
        end
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

      # A bulk write writes the records the relation selects when it is
      # called, as Active Record's runs its query then (records_now,
      # locked_records_now): a record destroyed since the relation was built
      # (by another relation's delete_all, a destroy, an erasure) is not
      # written, one that matches since is, and a window is taken again.
      # Writing the records held appended an update after a destroy and
      # brought the record back, an erased one included.
      def event_sourced_bulk_mutate(method_name, *args, **kwargs)
        if method_name == :destroy_all
          destroyed = destroy_records_now
          forget_destroyed(destroyed)
          return destroyed
        end

        # One transaction: a failed publish part-way leaves none of them.
        model_class.transaction { publish_bulk_events(method_name, *args, **kwargs) }
      end

      # The records the relation selects now, each destroyed in a transaction
      # of its own, as Active Record's destroy_all loads the records and
      # destroys each; one destroyed in between (its stream read under its
      # lock first) is left out of the writes and of the records returned.
      # The record's destroy then checks again, as every destroy does: its
      # before_destroy callbacks run in between, and may have destroyed it. A
      # destroy that returns false rolls back what its callbacks wrote, as on
      # its own, and its record is returned, as Active Record returns it.
      # Inside a transaction already open the locks add up until it ends, so
      # the limit applies to all of them there. The records are delivered as
      # a load delivers them (the purpose check, rights included): Active
      # Record loads them, and a restricted one raises
      # RestrictedProcessingError before any is destroyed; it was destroyed.
      def destroy_records_now
        targets = deliver { loaded_records? ? @records.to_a : records_now(skip_destroyed: false) }
        checks = Lyra.config.lock_aggregate_before_append
        if checks && model_class.with_connection(&:transaction_open?)
          Lyra::BypassEvents.check_lock_limit!(model_class, targets.size, "destroy_all")
        end
        targets.select do |record|
          live = false
          model_class.transaction do
            next if checks && Lyra::BypassEvents.destroyed_ids(model_class, [record_id(record)], write: "destroy_all").any?

            live = true
            raise ActiveRecord::Rollback unless record.destroy
          end
          live
        end
      end

      # As Active Record's destroy_all, which resets its relation: the
      # relation is read again from the event store (Rebuildable) and is no
      # longer loaded, so it no longer holds the records destroyed (it did,
      # loaded? still true). One that cannot be built again keeps those of
      # its records that were not destroyed.
      def forget_destroyed(destroyed)
        recipe = rebuild_recipe
        fresh = recipe && evaluate_relation(recipe)
        if fresh
          replace_with!(fresh)
        elsif !@joins
          gone = destroyed.select(&:destroyed?).to_set { record_id(_1) }
          @records = @records.reject { gone.include?(record_id(_1)) }
        end
        @loaded_records = nil
      end

      # The records this relation selects now: built again from the event
      # store (Rebuildable) when it can be, as Lyra's own read; else the
      # records it holds, less those whose streams now end in a destroy
      # (+skip_destroyed+, read without a lock: the write each is given
      # takes its own). Not in the events-only store, the records held.
      def records_now(skip_destroyed: true)
        return @records.to_a unless events_only?

        recipe = rebuild_recipe
        rebuilt = recipe && evaluate(recipe)
        return rebuilt if rebuilt

        records = @records.to_a
        return records unless skip_destroyed && Lyra.config.lock_aggregate_before_append

        dead = Lyra::StreamTail.destroyed_streams(records.map { record_stream(_1) }).to_set
        records.reject { |record| dead.include?(record_stream(record)) }
      end

      # The records a bulk write writes: those this relation selects now,
      # each one's aggregate lock taken (and held until the transaction
      # ends) before it is read, so none can be destroyed, or changed, before
      # the write. Built again (Rebuildable): the locks of the records it
      # holds are taken (all or none, Lyra::AdvisoryLock.xact_lock_all), and
      # the selection read; if it holds a record not locked yet (one that
      # matches since), that one is locked and the selection read again, up
      # to REEVALUATIONS times, after which the records not locked are left
      # out, as if they had matched after the write. So the usual write reads
      # its selection once. A record destroyed by then is not in the
      # selection. A relation that cannot be built again writes the records
      # it holds, those whose streams do not end in a destroy, read under the
      # locks (Lyra::BypassEvents.destroyed_ids); +current+: with their values
      # as the event store has them then.
      #
      # More records than config.bulk_write_lock_limit are refused
      # (Lyra::BulkWriteLockLimitError) before any lock is taken or event
      # written. With lock_aggregate_before_append off, as for a single
      # record's write, nothing is locked or checked.
      def locked_records_now(current: false)
        return @records.to_a if @live_checked

        recipe = rebuild_recipe
        locking = Lyra.config.lock_aggregate_before_append
        if recipe && !locking
          records = evaluate(recipe)
          return records if records
        elsif recipe
          locked = Set.new
          lock = lambda do |ids|
            Lyra::BypassEvents.check_lock_limit!(model_class, locked.size + ids.size)
            Lyra::BypassEvents.lock_streams!(model_class, ids)
            locked.merge(ids)
          end
          # The records held, unless an association's were never read.
          unread = defined?(DeferredRelation) && @records.is_a?(DeferredRelation::Records) && !@records.loaded?
          held = unread ? [] : @records.map { record_id(_1) }.uniq
          lock.call(held) if held.any?
          records = nil
          REEVALUATIONS.times do
            records = evaluate(recipe)
            break unless records

            missing = records.map { record_id(_1) }.uniq.reject { locked.include?(_1) }
            return records if missing.empty?

            lock.call(missing)
          end
          # Still a record not locked: read once more, under every lock
          # taken, and leave out those not locked.
          records &&= evaluate(recipe)
          return records.select { locked.include?(record_id(_1)) } if records
        end

        records = @records.to_a
        if locking
          dead = Lyra::BypassEvents.destroyed_ids(model_class, records.map { record_id(_1) }).to_set
          records = records.reject { dead.include?(record_id(_1)) } if dead.any?
        end
        current ? current_records(records) : records
      end

      # How many times a write reads its selection again for records that
      # match since it was read (locked_records_now).
      REEVALUATIONS = 4

      # The records +recipe+ selects now, each once, read past the query
      # cache, as Lyra's own read; nil when it cannot be built again.
      def evaluate(recipe)
        relation =
          begin
            Lyra::PurposeBoundReads.internal(INTERNAL) { model_class.uncached { Rebuildable.rebuild(recipe) } }
          rescue UnsupportedQuery
            nil
          end
        relation && relation.raw_records.to_a.uniq { record_id(_1) }
      end

      # +records+ as their streams have them now, in the same order (read
      # under their locks, none of them destroyed).
      def current_records(records)
        return records if records.empty?

        EventStoreReader.find_many(model_class, records.map { record_id(_1) })
      end

      def record_id(record) = record.public_send(model_class.primary_key)

      def record_stream(record)
        Lyra.stream_name(model_class, record_id(record))
      end

      # +method_name+ applied with +updates+, its events naming +source+
      # (touch_all, which is update_all of the timestamps).
      def bulk_mutate_as(method_name, source, updates)
        @bulk_source = source
        bulk_mutate(method_name, updates)
      ensure
        @bulk_source = nil
      end

      # Rails' own write on an event-backed association scope, this relation
      # marked by its association code (Lyra::Associations::Maintenance): a
      # has_many :through's dependent: :nullify of its through records, the
      # dependent_association bypass, as on a table relation
      # (StrictDataAccessRelation#update_all), or the delete of its through
      # records when records are removed from it. Allowed in strict mode;
      # the nullify's events are named so. The same write made by the
      # application is an update_all or delete_all like any other.
      def publish_bulk_events(method_name, *args, **kwargs)
        kind = case method_name
               when :update_all then :nullify
               when :delete_all then :unlink
               end
        unless kind && Lyra::Associations::Maintenance.claim(kind, self)
          return publish_bulk_events_now(method_name, *args, **kwargs)
        end

        previous = @bulk_source
        # As AssociationInterceptor writes a has_many's nullify.
        @bulk_source ||= "dependent_association" if kind == :nullify
        begin
          Lyra.without_strict_access { publish_bulk_events_now(method_name, *args, **kwargs) }
        ensure
          @bulk_source = previous
        end
      end

      def publish_bulk_events_now(method_name, *args, **kwargs)
        if Lyra.config.strict_data_access && !Thread.current[:lyra_bypass_strict_access]
          raise Lyra::StrictDataAccessViolation.new(method_name, model_class)
        end

        pk = model_class.primary_key
        # The table's unique indexes, as its UPDATE checks them
        # (UniqueIndexes.bulk_update): the records' tuples locked after the
        # records and checked before any event.
        unique = UniqueIndexes.bulk_update(model_class, args.first || kwargs) if method_name == :update_all
        records = locked_records_now
        case method_name
        when :delete_all
          records.each do |record|
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

          unique&.check!(records)
          updates = updates.transform_keys(&:to_s)
          records.each do |record|
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
        return 0 if records.empty?

        ids = records.map { |r| r.public_send(pk) }
        Lyra.projection_write(INTERNAL) do
          Thread.current[:lyra_bypass_read_override] = true
          model_class.unscoped.where(pk => ids).public_send(method_name, *args, **kwargs)
        ensure
          Thread.current[:lyra_bypass_read_override] = nil
        end
        records.size
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
          pairs.map do |column, direction|
            reader = column.is_a?(PositionOrder) ? column.sort_reader : TypedValues.sort_reader(model_class, column)
            [reader, direction.to_s.downcase == "desc"]
          end
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
