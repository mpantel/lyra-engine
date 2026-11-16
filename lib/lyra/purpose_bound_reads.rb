# frozen_string_literal: true

module Lyra
  # A read of a model with a privacy policy, made for a declared purpose, is
  # checked against the policy: every declared attribute the read uses must
  # be allowed for that purpose (Def. 1, through the policy's
  # validate_access!). Using a declared attribute the purpose does not need
  # is refused, as data minimisation (Art. 5(1)(c)) asks. With the access log
  # on (config.record_access_events), each checked read is recorded.
  #
  # The policy decides which attributes are checked; the purpose comes from
  # where the read is made:
  #
  #   Lyra.with_purpose(:invoicing) { Registration.select(:id, :vat_number, :address).find(id) }
  #
  #   class PaymentsController < ApplicationController
  #     lyra_purpose :payment_processing                  # around every action
  #     lyra_purpose :invoicing, only: :invoice
  #   end
  #
  #   class ExportJob < ApplicationJob
  #     lyra_purpose :audit_trail
  #   end
  #
  # No configuration turns it on: any monitored model with a policy is
  # checked wherever a purpose is in scope. A read with no purpose follows
  # config.reads_without_purpose: :allow (the default; nothing breaks when a
  # policy is added), :audit (allowed, logged, and recorded as an audited
  # access when the access log is on), or :deny (refused with
  # PurposeRequiredError: privacy by default, once every read path declares
  # its purpose).
  #
  # What the policy enforces on a violation is its enforcement mode: strict
  # raises the policy error from the read, audit logs it and lets the read
  # through.
  #
  # What a read uses (from Lyra 1.0.0). A query uses every declared attribute
  # it names, whatever it returns: its select or pluck list, the aggregated
  # column, group, where, having and order, the conditions of find_by and
  # exists?, the filter of a bulk write (update_all, delete_all, touch_all,
  # delete_by, destroy_by), and a subquery inside any of them. A filter is a
  # use: where(name: "Ann").exists? tells whether someone is called Ann. A
  # count with no column (count, count(:all), size) names nothing and is not
  # checked; count(:name) uses name. The values a write sets are not reads.
  #
  # The check is split by what can be known:
  #
  # - A record load (where(...).first, find_by, to_a) has the attributes its
  #   query names checked before it runs, without the consent step (PAM's
  #   validate_fields!), then each record returned checked as before,
  #   consent included, for what it holds and what the query named. A
  #   purpose whose consent the policy requires can still load the records
  #   of the people who consented, by attributes it may use.
  # - Everything else (aggregates, exists?, ids, pluck, pick, bulk writes)
  #   reads many people at once. Its subject is the model ("Registration$*")
  #   and it is checked whole: under a purpose that rests on consent it is
  #   refused, since no one person's consent can be checked; load the
  #   records instead.
  #
  # A joined model's declared attributes (where(users: { email: ... }) after
  # joins(:user), a "users.email" inside a fragment, or a column only the
  # joined model has) are checked against that model's own policy, subject
  # "User$*". A subquery or CTE reads other people: what it names is checked
  # whole, subject "Model$*", even on the queried model. A query is checked,
  # and recorded, once: the cursor queries of find_each and in_batches, and
  # the queries Active Record runs inside another, are not checked again (the
  # application's own block inside the loop is, each time), and a refused
  # check is never remembered. The rule is the same for Active Record's
  # relations and for ES-NoProj's (Projections::CachedRelation), whose
  # association readers, records, enumerators and inspect are checked as
  # loads.
  #
  # The subject's rights (Arts. 18 and 21, with PAM DSL; from 1.0.0). Each
  # record checked meets Condition 6: a restricted person's record raises, as
  # a non-consenting one does, and a load that names no declared field is
  # checked for a restriction of all of the subject's data or an objection
  # to the purpose (validate_rights!). A model-wide read (aggregates, ids,
  # pluck, pick, exists?, cache_version) leaves the restricted subjects out,
  # in both read paths, and a join, subquery or CTE reaching one is refused
  # (Lyra::Rights::Queries); Model.lyra_processable is the scope for batch
  # jobs. Bulk writes are not filtered: writes are not checked under a
  # restriction in 1.0.0. A purpose block, and each batch of a batch loop, is
  # a checking scope (Lyra::Rights.scope): its first check reads the rights
  # afresh. With nothing in force all this costs the store's any_active?, and
  # with checking? false nothing at all.
  #
  # The purpose follows the code into the fibers it creates (an Enumerator's,
  # relation.to_enum.next) and stays in its thread: see Context.
  #
  # Lyra's own reads (projections, bypass-event snapshots, Genesis, DualView's
  # comparisons for Lyra, mode checks, repair, erasure, ES-NoProj's join
  # partners) are not data processing for a purpose and are not checked.
  # Neither is Rails' uniqueness validation, which is part of writing the
  # record (so valid? alone can answer whether a value is taken), nor an
  # association's dependent: handling when a record is destroyed (for
  # :destroy, the lookup of the dependents), which is part of destroying it.
  # find_or_create_by is the application's own lookup and is checked, as are
  # its own where(fk: id).delete_all and collection writes
  # (user.articles.delete(article)).
  #
  # Limits. Attributes are found by walking the relation's Arel, and an SQL
  # string fragment by its "table.column" pairs and, for the rest, the
  # queried model's declared names as words (quoted literals left out). So:
  # - SQL written by hand (connection.select_*, execute, Arel handed to the
  #   connection) names no model and is not checked (find_by_sql's records
  #   are, as loads);
  # - a raw JOIN string is not read, and an unqualified word in a fragment
  #   is taken for the queried model's (or a joined model's) column;
  # - database views, functions and triggers are outside the ORM;
  # - a form the walk does not reach (a custom Arel node) is not checked;
  # - a load under a consent purpose that finds nothing tells that no
  #   matching record exists; the attributes it filtered on are ones the
  #   purpose may use.
  module PurposeBoundReads
    MODES = %i[allow audit deny].freeze

    class PurposeRequiredError < StandardError; end

    # Where the purpose and the check's own state are kept. Thread.current[]
    # is fiber-local, so an Enumerator's fiber (relation.to_enum.next,
    # find_each.next) ran without the purpose of the code that made it. Ruby's
    # fiber storage (Fiber[]) is inherited by the fibers created under it, and
    # each fiber's assignments are its own; it is also copied into a new
    # thread, so each value carries the thread that set it and is ignored in
    # any other: a pooled thread started inside a purpose does not keep it.
    module Context
      def self.[](key)
        entry = Fiber[key]
        entry[1] if entry && entry[0].equal?(Thread.current)
      end

      def self.[]=(key, value)
        Fiber[key] = value.nil? ? nil : [Thread.current, value].freeze
      end

      # +value+ for +key+ while the block runs, restored after.
      def self.with(key, value)
        previous = self[key]
        self[key] = value
        yield
      ensure
        self[key] = previous
      end
    end

    class << self
      def current
        Context[:lyra_purpose]
      end

      # A purpose block is a checking scope: the subject's rights (Arts. 18
      # and 21) and consent are read afresh at its first check
      # (Lyra::Rights.scope).
      def with_purpose(purpose, &block)
        return Context.with(:lyra_purpose, purpose&.to_sym, &block) unless defined?(Lyra::Rights.scope)

        Lyra::Rights.scope { Context.with(:lyra_purpose, purpose&.to_sym, &block) }
      end

      # Lyra's own reads, not checked. Only Lyra's own call sites may call it
      # (they pass Lyra::INTERNAL): application code that could would read a
      # declared field under :deny.
      # A refused call raises before it touches the flag, so it leaves the
      # block it was called in as it was.
      def internal(token = nil, &block)
        raise InternalApiError, "PurposeBoundReads.internal is for Lyra's own reads" unless token.equal?(INTERNAL)

        Context.with(:lyra_internal_read, true, &block)
      end

      # Whether Lyra's own reads are in progress (PurposeBoundReads.internal).
      def internal?
        Context[:lyra_internal_read] ? true : false
      end

      # Whether reads are checked here at all: a purpose is in scope or reads
      # without one are not simply allowed, and the read is not Lyra's own.
      # Every hook asks first and returns when it is false, before it looks
      # at the query: with no purpose and the default :allow (every
      # benchmark), a query costs this and nothing more.
      def checking?
        return false if Context[:lyra_purpose].nil? && Lyra.config.reads_without_purpose == :allow
        return false if Context[:lyra_internal_read] || Thread.current[:lyra_projection_write]

        !Lyra.config.disabled_mode?
      end

      # after_find on monitored models, and every record ES-NoProj returns:
      # the declared attributes the record holds, and those the query that
      # loaded it named (+named+, or the query being instantiated), checked
      # with the record as the subject, consent included.
      def check(record, named = nil)
        return unless checking?

        policy = Lyra::Privacy.policy_for(record.class)
        return unless policy.loaded?

        declared = policy.declared_fields.map(&:to_s)
        fields = ((record.attribute_names & declared) | (query_names_for(record, named) & declared)).map(&:to_sym)
        # A load that names no declared field reads nothing a field
        # restriction covers, but it is still processing of the record: a
        # restriction of all of its subjects' data, or an objection to the
        # purpose, refuses it (Condition 6 alone; with nothing in force, the
        # store's any_active? and no more).
        if fields.empty?
          policy.validate_rights!([], current, subject: record) if current
          return
        end

        if current
          policy.validate_access!(fields, current, subject: record)
        else
          without_purpose("#{record.class.name} #{record.id}", record, policy, fields)
        end
      end

      # Check what a query names, before it runs. +named+ is
      # { model => [attribute names] } (named_fields_of). +kind+ is :load for
      # a record load (the queried model's attributes checked without the
      # consent step; each record returned is checked after) or :all for
      # anything else (subject Model$*, consent included). +whole+ holds what
      # the query's subqueries and CTEs name: they read other people, so they
      # are checked as :all whatever the kind, as is a joined model (no
      # record of it is returned).
      #
      # Then, with a right in force: a joined model (+joined+, or one whose
      # attributes the query names), a subquery or a CTE that reaches a
      # subject whose restriction or objection covers the access is refused
      # (Lyra::Rights::Queries.refuse_reaching!): only the queried model's
      # own rows can be left out of a query.
      def check_query(model_class, named, kind, whole = {}, joined: [], opaque: false)
        own_names = named
        if kind == :all
          named = named.merge(whole) { |_, mine, theirs| mine | theirs }
        else
          whole.each { |klass, names| check_fields(model_class, klass, names, :all) }
        end
        named.each { |klass, names| check_fields(model_class, klass, names, kind) }
        refuse_reaching(model_class, own_names, whole, joined, opaque) if current
      end

      # Is a right (Arts. 18, 21) in force anywhere? A clock read once the
      # scope has read the rights; false without PAM DSL.
      def rights_in_force?
        defined?(Lyra::Rights::Queries) ? Lyra::Rights::Queries.in_force? : false
      end

      # +relation+ (a model-wide read naming +names+) leaving out the
      # subjects a right in force keeps out of it, or nil when it leaves out
      # no one (Lyra::Rights::Queries).
      def rights_filtered(relation, names)
        return nil unless current && monitored?(relation.klass) && rights_in_force?

        Lyra::Rights::Queries.filter(relation, names.result.fetch(relation.klass, []))
      end

      # The Lyra::Rights::Queries::Exclusion a model-wide read of +model+
      # (naming +fields+) would apply under the purpose in scope, or nil.
      def rights_exclusion(model, fields = [])
        return nil unless current && monitored?(model) && rights_in_force?

        Lyra::Rights::Queries.exclusion(model, fields)
      end

      # Run the filtered form of a query already checked, as Lyra's own: it
      # is not checked, filtered or recorded again.
      def run_filtered(&block)
        internal(INTERNAL, &block)
      end

      # The +records+ of +model_class+ that a model-wide read naming +named+
      # ({ model => names }) keeps, or nil when it keeps them all
      # (ES-NoProj's relations).
      def rights_kept_records(model_class, named, records)
        return nil unless current && rights_in_force?

        Lyra::Rights::Queries.kept_records(model_class, (named || {}).fetch(model_class, []), records)
      end

      # Model.lyra_processable (Lyra::Rights::Queries.processable).
      def processable(relation, fields = nil)
        return relation unless current && defined?(Lyra::Rights::Queries)

        Lyra::Rights::Queries.processable(relation, fields)
      end

      NO_BATCH_SCOPE = -> {}

      # A batch loop under checking: each batch is a checking scope of its
      # own (Lyra::Rights.batches). The block gets the callable that ends a
      # batch's scope and begins the next one's.
      def batch_scopes(&block)
        return yield(NO_BATCH_SCOPE) unless defined?(Lyra::Rights.batches)

        Lyra::Rights.batches(&block)
      end

      # The attribute names an ActiveRecord relation's query names, by model:
      # { ReadUser => ["name", ...], ... }. Every name is listed; the check
      # keeps the declared ones. What its subqueries name is not included
      # (query_names gives both).
      def named_fields_of(relation, extra = nil)
        query_names(relation, extra).result
      end

      # The NamedFields of +relation+ and of +extra+ (columns the call adds).
      def query_names(relation, extra = nil)
        NamedFields.new.relation(relation).value(extra, relation.klass)
      end

      # The names a hash of conditions (find_by, exists?, where) uses, by
      # model, without building a relation.
      def named_in_conditions(model_class, conditions)
        NamedFields.new.conditions(conditions, model_class)
      end

      # Run a query hook: check what +relation+ names (and +extra+, columns
      # or conditions the call adds) as +kind+, then the query. Identical
      # checks of Active Record's own queries inside it are made once (with
      # around: false, the check only: the query runs application callbacks).
      def checked_query(relation, kind, extra = nil, around: true)
        names = query_names(relation, extra)
        unless around
          once { check_query(relation.klass, names.result, kind, names.whole, joined: names.joined_classes, opaque: names.opaque?) }
          return yield names
        end

        once do
          check_query(relation.klass, names.result, kind, names.whole, joined: names.joined_classes, opaque: names.opaque?)
          yield names
        end
      end

      # Class-level find_by and find_by!: the condition keys, checked as a
      # load before the query; the record found is checked with them.
      def checked_finder(model_class, conditions)
        return yield unless conditions.is_a?(Hash) && checking?

        names = named_in_conditions(model_class, conditions)
        named = names.result
        once do
          check_query(model_class, named, :load, names.whole)
          with_query_names(model_class, named[model_class]) { yield }
        end
      end

      # Identical checks inside the block that pass (or pass with a logged
      # violation, in audit mode) are made, and recorded, once: for the
      # queries Active Record runs inside one query and the cursor queries of
      # one batch loop. A refused check is not remembered.
      def once
        return yield if Context[:lyra_checked_queries]

        Context.with(:lyra_checked_queries, {}) { yield }
      end

      # The application's block inside a batch loop is its own code: its
      # queries are checked and recorded each time.
      def outside_once(&block)
        Context.with(:lyra_checked_queries, nil, &block)
      end

      # The names of the query whose records are being instantiated, for
      # check (after_find).
      def with_query_names(model_class, names, &block)
        return yield if names.blank?

        Context.with(:lyra_query_names, (Context[:lyra_query_names] || []) + [[model_class, names]], &block)
      end

      def validate_mode!(mode)
        mode = mode&.to_sym
        return mode if MODES.include?(mode)

        raise ArgumentError, "Unknown reads_without_purpose #{mode.inspect}. Must be one of: #{MODES.join(', ')}"
      end

      private

      def check_fields(model_class, klass, names, kind)
        return unless monitored?(klass)

        policy = Lyra::Privacy.policy_for(klass)
        return unless policy.loaded?

        fields = (names & policy.declared_fields.map(&:to_s)).uniq.map(&:to_sym)
        return if fields.empty?

        purpose = current
        split = kind == :load && (klass <= model_class || model_class <= klass)
        key = [klass, split, purpose, fields.sort, policy.name]
        return if already_checked?(key)

        subject = "#{Lyra.stream_prefix(klass)}*"
        if purpose.nil?
          without_purpose("#{klass.name} (query)", subject, policy, fields)
        elsif split
          policy.validate_fields!(fields, purpose, subject: subject) unless policy.field_violations(fields, purpose).empty?
        else
          policy.validate_access!(fields, purpose, subject: subject)
        end
        remember(key)
      end

      def monitored?(klass)
        klass.respond_to?(:lyra_monitored) && klass.lyra_monitored
      end

      def refuse_reaching(model_class, named, whole, joined, opaque = false)
        related = ->(klass) { klass <= model_class || model_class <= klass }
        reached = (named.keys.reject(&related) + whole.keys + Array(joined).reject(&related)).uniq.select { monitored?(_1) }
        refuse_opaque(model_class) if opaque && rights_in_force?
        return if reached.empty? || !rights_in_force?

        reached.each do |klass|
          Lyra::Rights::Queries.refuse_reaching!(klass, (named[klass] || []) | (whole[klass] || []))
        end
      end

      # An SQL fragment reads FROM or JOIN something Lyra cannot name, while a
      # right is in force for a model the purpose reads: what it reaches
      # cannot be told, so it is refused (fail closed).
      def refuse_opaque(model_class)
        return unless Lyra.config.monitored_models.any? { |model| Lyra::Rights::Queries.exclusion(model, [], audit: false) }

        raise PamDsl::RestrictedProcessingError,
              "A query on #{model_class.name} reads, in SQL written as a string, a FROM or JOIN Lyra cannot read, " \
              "while a restriction of processing or an objection is in force for purpose '#{current}': which " \
              "subjects it reaches cannot be told, so it is refused. Name the tables it reads plainly " \
              "(FROM table [alias], JOIN table [alias]) or use Active Record's joins and subqueries"
      end

      def already_checked?(key)
        Context[:lyra_checked_queries]&.key?(key)
      end

      def remember(key)
        checked = Context[:lyra_checked_queries]
        checked[key] = true if checked
      end

      def query_names_for(record, named)
        return named.to_a if named

        stack = Context[:lyra_query_names]
        return [] if stack.blank?

        stack.flat_map { |klass, names| record.is_a?(klass) ? names : [] }
      end

      def without_purpose(label, subject, policy, fields)
        error = PurposeRequiredError.new(
          "#{label}: read of #{fields.join(', ')} with no declared purpose (Lyra.with_purpose or lyra_purpose)"
        )
        denied = Lyra.config.reads_without_purpose == :deny
        record_access(policy, fields, subject, denied ? :denied : :audited, error)
        raise error if denied

        Rails.logger.warn("Lyra: #{error.message}")
      end

      def record_access(policy, fields, record, outcome, error)
        return unless defined?(Lyra::AccessLog) && defined?(PamDsl::Enforcement::Access)
        return unless Lyra::AccessLog.record?(policy)

        Lyra::AccessLog.call(PamDsl::Enforcement::Access.new(
          policy: policy.name, purpose: :none, legal_basis: nil, fields: fields, subject: record,
          outcome: outcome, violations: [error], at: Time.now
        ))
      end
    end

    # The attribute names a query names, by model (PurposeBoundReads
    # .query_names). Arel nodes are walked by compiling them with a visitor
    # that notes every attribute (its table gives the model) and every SQL
    # literal; bound values are not names. Symbols and "table.column" strings
    # are columns; any other string is a fragment: its "table.column" pairs
    # belong to that table's model, its other words to the queried model.
    # A column named without its table that the queried model does not have
    # belongs to the joined model that has it, as SQL resolves it. A
    # condition on a belongs_to association is one on its foreign key (and
    # type). What a subquery or a CTE names goes to #whole: it reads other
    # people, whatever its model.
    class NamedFields
      QUOTED_LITERAL = /'(?:[^']|'')*'/
      IDENTIFIER = /[A-Za-z_][A-Za-z0-9_]*/
      COLUMN = /\A\s*(?:"?(\w+)"?\s*\.\s*)?"?(\w+)"?\s*\z/
      QUALIFIED = /"?([A-Za-z_]\w*)"?\s*\.\s*"?([A-Za-z_]\w*)"?/

      # A table an SQL fragment reads: FROM or JOIN, the table, and an alias.
      TABLE_REF = /\b(FROM|JOIN)\s+"?([A-Za-z_][\w.]*)"?(?:\s+(?:AS\s+)?"?([A-Za-z_]\w*)"?)?/i
      NOT_ALIASES = %w[on where inner left right full outer cross natural join using group order limit having
                       union select set and or lateral offset window for].freeze

      def initialize
        @names = Hash.new { |hash, model| hash[model] = [] }
        @whole = Hash.new { |hash, model| hash[model] = [] }
        @joined = {}
        @aliases = {}
        @reached = []
        @opaque = false
        @depth = 0
      end

      # An SQL fragment read FROM or JOIN something it could not name: the
      # tables it reaches are not known (checks fail closed on it).
      def opaque?
        @opaque
      end

      def result
        @names.reject { |_, names| names.empty? }.transform_values(&:uniq)
      end

      # The models joined into the query (joins, left_joins, eager_load, an
      # SQL JOIN string) or read by a subquery written as SQL.
      def joined_classes
        (@joined.values.flatten + @reached).uniq
      end

      # What the query's subqueries and CTEs name.
      def whole
        @whole.reject { |_, names| names.empty? }.transform_values(&:uniq)
      end

      def relation(relation)
        model = relation.klass
        joined(model, joined_models(model, relation.joins_values + relation.left_outer_joins_values +
                                           (relation.eager_loading? ? relation.includes_values + relation.eager_load_values : [])))
        # JOINs written as SQL first: their tables and aliases name the
        # columns the rest of the query uses.
        (relation.joins_values + relation.left_outer_joins_values).each do |join|
          sql = join.is_a?(Arel::Nodes::StringJoin) ? join.left : join
          fragment(sql.to_s, model, join: true) if sql.is_a?(String) || sql.is_a?(Arel::Nodes::SqlLiteral)
        end
        relation.select_values.each { value(_1, model) }
        relation.group_values.each { value(_1, model) }
        relation.order_values.each { value(_1, model) }
        arel(relation.where_clause.ast, model) unless relation.where_clause.empty?
        arel(relation.having_clause.ast, model) unless relation.having_clause.empty?
        nested { value(relation.from_clause.value, model) } unless relation.from_clause.empty?
        (relation.joins_values + relation.left_outer_joins_values).each do |join|
          arel(join, model) if Arel.arel_node?(join) && !join.is_a?(Arel::Nodes::StringJoin)
        end
        nested { relation.with_values.each { value(_1, model) } } if relation.respond_to?(:with_values)
        self
      end

      # The models joined to +model+ in this query, for its unqualified
      # columns.
      def joined(model, models)
        @joined[model] = ((@joined[model] || []) + models).uniq if models.any?
        self
      end

      def value(value, model)
        case value
        when nil, true, false, Numeric then nil
        when ActiveRecord::Relation then nested { relation(value) }
        when Lyra::Projections::CachedRelation then nested { merge(value.lyra_query_names) }
        when Symbol then column(model, value.to_s)
        when String then string(value, model)
        when Hash then value.each { |key, column| value(key, model).value(column, model) }
        when Array then value.each { value(_1, model) }
        else arel(value, model) if Arel.arel_node?(value)
        end
        self
      end

      # Hash conditions: a column, "table.column", a belongs_to association
      # (its foreign key), or a table (or association) with a hash of its
      # columns; a relation as a value is a subquery.
      def conditions(conditions, model)
        return value(conditions, model) unless conditions.is_a?(Hash)

        conditions.each do |key, condition|
          if condition.is_a?(Hash)
            model_for(key.to_s, model).each { |other| condition.each_key { |column| add(other, column.to_s) } }
          else
            string(key.to_s, model)
            association_keys(model, key)
          end
          value(condition, model) if condition.is_a?(ActiveRecord::Relation) || condition.is_a?(Lyra::Projections::CachedRelation)
        end
        self
      end

      # Another query's names, all of them (#value nests it: a subquery).
      def merge(other)
        other.result.each { |model, names| names.each { add(model, _1) } }
        other.whole.each { |model, names| nested { names.each { add(model, _1) } } }
        self
      end

      private

      def add(model, name)
        return if name.to_s == "*"

        (@depth.positive? ? @whole : @names)[model] << name.to_s
      end

      def nested
        @depth += 1
        yield
      ensure
        @depth -= 1
      end

      # A column named without its table: the queried model's, else the
      # joined model's that has it.
      def column(model, name)
        name = model_column(model, name)
        columns = column_names(model)
        others = @joined[model]
        return add(model, name) if others.nil? || columns.nil? || columns.include?(name)

        owners = others.select { |other| column_names(other)&.include?(name) }
        owners.empty? ? add(model, name) : owners.each { add(_1, name) }
      end

      def string(string, model)
        match = string.match(COLUMN)
        return fragment(string, model) unless match
        return column(model, match[2]) unless match[1]

        qualified(match[1], match[2], model)
      end

      def qualified(table, name, model)
        targets = model_for(table, model)
        return column(model, name) if targets.empty?

        targets.each { |target| add(target, model_column(target, name)) }
      end

      # The fragment's "table.column" pairs, then its other words, outside
      # quoted literals (only declared names count). From 1.0.0 the tables it
      # reads (FROM, JOIN, with their aliases) are read too: an alias names
      # its table's model, a JOIN string joins that model, and the words of a
      # subquery written as SQL that are columns of the tables it reads
      # belong to those tables' models, read whole (other people). A FROM or
      # JOIN whose table cannot be read makes the query opaque.
      def fragment(sql, model, join: false)
        text = sql.to_s.gsub(QUOTED_LITERAL, " ")
        others = table_references(text, model)
        subquery = !join && text.match?(/\bSELECT\b/i)
        reached = subquery ? others : others.reject { |other| other <= model || model <= other }
        if join
          joined(model, reached)
        elsif reached.any?
          @reached |= reached
          reached.each { |other| nested { add(other, Lyra.key_column(other)) } }
        end

        rest = text.gsub(QUALIFIED) do
          table = ::Regexp.last_match(1)
          name = ::Regexp.last_match(2).downcase
          inner = subquery && model_for(table, model).intersect?(reached)
          inner ? nested { qualified(table, name, model) } : qualified(table, name, model)
          " "
        end
        rest.scan(IDENTIFIER).each do |word|
          word = word.downcase
          owners = subquery ? reached.select { |other| column_names(other)&.include?(word) } : []
          owners.each { |other| nested { add(other, word) } }
          column(model, word) if owners.empty? || column_names(model)&.include?(word)
        end
      end

      # The monitored models of the tables +text+ reads FROM or JOIN,
      # remembering their aliases; marks the query opaque when a FROM or JOIN
      # names nothing it can read.
      def table_references(text, model)
        refs = text.scan(TABLE_REF)
        @opaque = true if refs.empty? && text.match?(/\b(FROM|JOIN)\b/i)
        refs.flat_map do |_keyword, table, alias_name|
          table = table.split(".").last.downcase
          models = table == model.table_name ? [model] : Lyra.config.monitored_models.select { |m| (m.table_name == table rescue false) }
          if alias_name && !NOT_ALIASES.include?(alias_name.downcase) && models.any?
            @aliases[alias_name.downcase] = models
          end
          models
        end.uniq
      end

      def association_keys(model, key)
        return unless model.respond_to?(:reflect_on_association)

        reflection = model.reflect_on_association(key.to_s.to_sym)
        return unless reflection&.belongs_to?

        Array(reflection.foreign_key).each { add(model, _1.to_s) }
        add(model, reflection.foreign_type.to_s) if reflection.polymorphic?
      end

      # The classes of the associations a joins/left_joins/eager_load spec
      # names, nested ones included; polymorphic ones are skipped.
      def joined_models(model, specs)
        Array(specs).flat_map do |spec|
          case spec
          when Symbol, String
            klass = association_class(model, spec)
            klass ? [klass] : []
          when Hash
            spec.flat_map do |name, inner|
              klass = association_class(model, name)
              klass ? [klass, *joined_models(klass, inner)] : []
            end
          when Array then joined_models(model, spec)
          else []
          end
        end
      end

      def association_class(model, name)
        reflection = model.reflect_on_association(name.to_s.to_sym) if model.respond_to?(:reflect_on_association)
        reflection.klass if reflection && !reflection.polymorphic?
      rescue StandardError
        nil
      end

      def column_names(model)
        model.respond_to?(:column_names) ? model.column_names : nil
      rescue StandardError
        nil
      end

      def arel(node, model)
        found = model.with_connection { |connection| Recorder.for(connection).found(node) }
        found.each do |kind, item, inner|
          handle = -> { kind == :fragment ? string(item, model) : attribute(item, model) }
          inner ? nested(&handle) : handle.call
        end
      end

      def attribute(attribute, model)
        table = attribute.relation
        table = table.relation while table.is_a?(Arel::Nodes::TableAlias) && table.relation.is_a?(Arel::Table)
        klass = table.instance_variable_get(:@klass) if table.is_a?(Arel::Table)
        targets = if klass then [klass]
                  elsif table.respond_to?(:name) then model_for(table.name.to_s, model)
                  else [model]
                  end
        targets = [model] if targets.empty?
        targets.each { |target| add(target, attribute.name) }
      end

      def model_column(model, name)
        model.respond_to?(:attribute_aliases) ? (model.attribute_aliases[name] || name) : name
      end

      # The models a table name (or an association name) stands for in a
      # query on +model+: the model itself, the class of its association, or
      # the monitored models on that table.
      def model_for(name, model)
        aliased = @aliases[name.to_s.downcase]
        return aliased if aliased
        return [model] if name == model.table_name

        reflection = model.reflect_on_association(name.to_sym) || model.reflect_on_association(name.singularize.to_sym)
        reflection ||= model.reflect_on_all_associations.find { |r| !r.polymorphic? && (r.klass.table_name == name rescue false) }
        return [reflection.klass] if reflection && !reflection.polymorphic?

        Lyra.config.monitored_models.select { |monitored| monitored.table_name == name rescue false }
      end

      # Compiles an Arel node as the connection would, noting the attributes
      # and SQL literals it meets.
      module Recording
        # [kind, item, inside a subquery?] for every attribute and literal.
        def found(node)
          @found = []
          @depth = 0
          accept(node, Arel::Collectors::SQLString.new)
          @found
        end

        private

        def visit_Arel_Nodes_SelectStatement(o, collector)
          @depth += 1
          super
        ensure
          @depth -= 1
        end

        def visit_Arel_Attributes_Attribute(o, collector)
          @found << [:attribute, o, @depth.positive?]
          super
        end

        def visit_Arel_Nodes_SqlLiteral(o, collector)
          @found << [:fragment, o.to_s, @depth.positive?]
          super
        end

        def visit_Arel_Nodes_BoundSqlLiteral(o, collector)
          @found << [:fragment, o.sql_with_placeholders, @depth.positive?]
          super
        end
      end

      module Recorder
        CLASSES = {}
        MUTEX = Mutex.new

        def self.for(connection)
          visitor_class = connection.visitor.class
          klass = CLASSES[visitor_class] || MUTEX.synchronize do
            CLASSES[visitor_class] ||= Class.new(visitor_class) { include Recording }
          end
          klass.new(connection)
        end
      end
    end

    # lyra_purpose for controllers (around_action) and jobs (around_perform).
    module ControllerMethods
      def lyra_purpose(purpose, **options)
        around_action(**options) { |_controller, action| Lyra.with_purpose(purpose, &action) }
      end
    end

    module JobMethods
      def lyra_purpose(purpose)
        around_perform { |_job, block| Lyra.with_purpose(purpose, &block) }
      end
    end

    # The query hooks on ActiveRecord::Relation (Model.count and the other
    # class-level forms are delegated to it). Installed above Lyra's bulk-write
    # hooks (StrictDataAccessRelation), so a refused write is refused before
    # anything is snapshotted or published.
    module RelationCheck
      def calculate(operation, column_name = nil, *rest, **options, &block)
        return super unless PurposeBoundReads.checking?

        column = column_name unless operation.to_s == "count" && [nil, :all, "*", "all"].include?(column_name)
        PurposeBoundReads.checked_query(self, :all, column) do |names|
          filtered = PurposeBoundReads.rights_filtered(self, names)
          next super unless filtered

          PurposeBoundReads.run_filtered { filtered.calculate(operation, column_name, *rest, **options, &block) }
        end
      end

      def exists?(conditions = :none)
        return super unless PurposeBoundReads.checking?

        scope = conditions.is_a?(Hash) || conditions.is_a?(Array) ? where(conditions) : self
        PurposeBoundReads.checked_query(scope, :all) do |names|
          filtered = PurposeBoundReads.rights_filtered(self, names)
          next super unless filtered

          PurposeBoundReads.run_filtered { filtered.exists?(conditions) }
        end
      end

      def ids
        return super unless PurposeBoundReads.checking?

        PurposeBoundReads.checked_query(self, :all) do |names|
          filtered = PurposeBoundReads.rights_filtered(self, names)
          next super unless filtered

          PurposeBoundReads.run_filtered { filtered.ids }
        end
      end

      def pluck(*column_names)
        return super unless PurposeBoundReads.checking?

        PurposeBoundReads.checked_query(self, :all, column_names) do |names|
          filtered = PurposeBoundReads.rights_filtered(self, names)
          next super unless filtered

          PurposeBoundReads.run_filtered { filtered.pluck(*column_names) }
        end
      end

      # A count and the latest timestamp of the relation's rows: an aggregate
      # over its filter (cache_key_with_version asks it too).
      def cache_version(timestamp_column = :updated_at)
        return super unless PurposeBoundReads.checking?

        PurposeBoundReads.checked_query(self, :all, timestamp_column) do |names|
          filtered = PurposeBoundReads.rights_filtered(self, names)
          next super unless filtered

          PurposeBoundReads.run_filtered { filtered.cache_version(timestamp_column) }
        end
      end

      # The filter is a use; so is every column the SET expressions read
      # ("email = name", email: arel_table[:name]). The values written are not.
      def update_all(updates)
        return super unless PurposeBoundReads.checking?

        PurposeBoundReads.checked_query(self, :all, RelationCheck.set_reads(updates)) { super }
      end

      def delete_all
        return super unless PurposeBoundReads.checking?

        PurposeBoundReads.checked_query(self, :all) { super }
      end

      # Checked as a filtered write; its records are then loaded (and checked)
      # and destroyed with the application's callbacks, outside the check.
      def destroy_all
        return super unless PurposeBoundReads.checking?

        PurposeBoundReads.checked_query(self, :all, around: false) { super }
      end

      # The columns a bulk insert returns are read back, from everyone it
      # wrote (subject Model$*).
      %i[insert_all insert_all! upsert_all].each do |name|
        define_method(name) do |attributes, returning: nil, **options, &block|
          if returning && PurposeBoundReads.checking?
            names = PurposeBoundReads::NamedFields.new.value(returning, klass)
            PurposeBoundReads.once { PurposeBoundReads.check_query(klass, names.result, :all) }
          end
          super(attributes, returning: returning, **options, &block)
        end
      end

      # The batch loop's own queries (its cursor's plucks, each batch's load)
      # are checked and recorded once; the application's block is its own code.
      # Each batch is a checking scope (find_each and find_in_batches run
      # through here): the rights are read afresh before the next batch loads.
      def in_batches(*args, **options, &block)
        return super unless block && PurposeBoundReads.checking?

        PurposeBoundReads.batch_scopes do |next_batch|
          PurposeBoundReads.once do
            super(*args, **options) do |batch|
              PurposeBoundReads.outside_once { block.call(batch) }
            ensure
              next_batch.call
            end
          end
        end
      end

      # The columns an update_all's SET expressions read: Arel values, and the
      # words of an SQL string other than the columns it assigns.
      def self.set_reads(updates)
        case updates
        when Hash then updates.values.select { Arel.arel_node?(_1) }
        when String then Arel.sql(updates.gsub(/"?\b\w+"?\s*=(?!=)/, " "))
        when Array then updates.first.is_a?(String) ? set_reads(updates.first) : nil
        end
      end

      private

      # A record load (load, load_async, eager loads): what the query names,
      # without the consent step, and what its subqueries name, whole. Each
      # record is checked by after_find.
      def exec_main_query(*args, **options)
        return super unless PurposeBoundReads.checking?

        names = PurposeBoundReads.query_names(self)
        @lyra_query_names = names.result
        PurposeBoundReads.once do
          PurposeBoundReads.check_query(klass, @lyra_query_names, :load, names.whole, joined: names.joined_classes, opaque: names.opaque?)
          super
        end
      end

      # The rows of a grouped load are aggregates, not one person's records
      # (Rights::SubjectKeys.aggregate_row?).
      def instantiate_records(*args, **options, &block)
        return super unless PurposeBoundReads.checking? && @lyra_query_names

        PurposeBoundReads.with_query_names(klass, @lyra_query_names[klass]) do
          next super if group_values.empty?

          PurposeBoundReads::Context.with(:lyra_grouped_load, true) { super }
        end
      end
    end

    # Rails' uniqueness check runs exists? on the validated attribute as part
    # of saving the record: a write, not a read for a purpose.
    module UniquenessExemption
      def validate_each(record, attribute, value)
        Lyra::PurposeBoundReads.internal(INTERNAL) { super }
      end
    end

    # What Rails does to a record's dependents when it is destroyed (an
    # association's dependent: option) is part of destroying it, as a
    # uniqueness check is part of saving it. :delete_all, :nullify, :delete
    # and the restrict options run as Lyra's own work: their query on the
    # dependents' key is not a read for a purpose. For :destroy, only the
    # lookup of the dependents is: each is then destroyed as the application
    # destroys a record, with its own callbacks.
    module DependentExemption
      def handle_dependency
        if %i[destroy destroy_async].include?(options[:dependent])
          Lyra::PurposeBoundReads.internal(INTERNAL) { load_target }
          super
        else
          Lyra::PurposeBoundReads.internal(INTERNAL) { super }
        end
      end
    end

    def self.install!
      ActiveRecord::Relation.prepend(RelationCheck) unless ActiveRecord::Relation.ancestors.include?(RelationCheck)
      validator = ActiveRecord::Validations::UniquenessValidator
      validator.prepend(UniquenessExemption) unless validator.ancestors.include?(UniquenessExemption)
      [ActiveRecord::Associations::HasManyAssociation, ActiveRecord::Associations::HasOneAssociation,
       ActiveRecord::Associations::BelongsToAssociation].each do |association|
        association.prepend(DependentExemption) unless association.ancestors.include?(DependentExemption)
      end
    end
  end

  def self.with_purpose(purpose, &block) = PurposeBoundReads.with_purpose(purpose, &block)
end

if defined?(ActiveSupport)
  ActiveSupport.on_load(:action_controller) { extend Lyra::PurposeBoundReads::ControllerMethods }
  ActiveSupport.on_load(:active_job) { extend Lyra::PurposeBoundReads::JobMethods }
  # Under Rails the engine installs the query hooks, after the bulk-write
  # hooks, so that they run first (Lyra::Engine).
  ActiveSupport.on_load(:active_record) { Lyra::PurposeBoundReads.install! } unless defined?(Lyra::Engine)
end
