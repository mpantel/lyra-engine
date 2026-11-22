# frozen_string_literal: true

module Lyra
  module Projections
    # A model's default scopes in ES-NoProj reads.
    #
    # Active Record builds every read of a table from the model's default
    # scopes (Model.all is default_scoped; an association reads through
    # scope_for_association), unless the read runs under a scope of its own:
    # Model.unscoped { ... } sets an empty current scope, and a default scope
    # being built is not applied to itself. ES-NoProj reads, rebuilt from the
    # event log, used to leave the default scopes out, so soft-deleted records
    # (default_scope { where(deleted_at: nil) }, as paranoia, discard and
    # Solidus use) were read back.
    #
    # The relation Active Record would read through is built here as Active
    # Record builds it (past Lyra's read overrides: no SQL runs) and the
    # event-store records are narrowed by it (CachedRelation#narrowed_by): its
    # where clause, order and limit. A scope narrowed_by cannot evaluate (an
    # SQL string, a join, an ordering by an expression) raises
    # UnsupportedQuery on the read: answering without it would return the
    # records it leaves out. ModeTransition refuses the switch into ES-NoProj
    # for such a model up front (unevaluable).
    #
    # A model without default scopes costs one check per read and nothing
    # else; its reads are as before.
    module DefaultScopes
      class << self
        # Whether +klass+ has default scopes, as Active Record asks it
        # (scope_attributes?): declared ones, or a default_scope class method.
        def any?(klass)
          klass.default_scopes.any? || klass.respond_to?(:default_scope)
        end

        # The Active Record relation a class-level read of +klass+ selects
        # through, as Active Record's all builds it: the current scope when one
        # is set (Model.unscoped { ... } sets an empty one), otherwise the
        # default scopes. nil when the read selects every record.
        def read_scope(klass, all_queries: nil)
          current = klass.current_scope
          if current.is_a?(ActiveRecord::Relation)
            return nil if current.model == klass && bare?(current)

            return built { current.model == klass ? current : klass.unscoped.merge(current) }
          end
          return nil if !any?(klass) || klass.send(:ignore_default_scope?)

          scope = built { klass.default_scoped(all_queries: all_queries) }
          bare?(scope) ? nil : scope
        end

        # The default scopes of +klass+ as Active Record applies them to the
        # +reflection+ of +owner+ (scope_for_association), less what the
        # association's own scope unscopes (-> { with_discarded }). nil when
        # they select every record.
        def for_association(klass, reflection, owner)
          return nil unless any?(klass)

          remembered([:association, klass, reflection]) do
            scope = built do
              default = klass.scope_for_association
              unscoped = reflection.scope ? association_unscopes(klass, reflection, owner) : []
              unscoped.any? ? default.unscope(*unscoped) : default
            end
            bare?(scope) ? nil : scope
          end
        end

        # Run the block remembering in +store+ the default scopes it builds
        # (for_association, for_through): run again with the same store, it
        # uses them instead of running the scopes' bodies again. A :through
        # association's relation is built again this way for a write
        # (Rebuildable), so the application's default scopes run once, when
        # the relation is built, as Active Record's do. An association read
        # through it for another owner shares its model's scope, as the
        # owner seldom changes what a default scope unscopes.
        def remembering(store)
          previous = Thread.current[REMEMBERED]
          Thread.current[REMEMBERED] = store
          yield
        ensure
          Thread.current[REMEMBERED] = previous
        end

        REMEMBERED = :lyra_default_scopes_remembered

        def remembered(key)
          store = Thread.current[REMEMBERED]
          return yield unless store
          return store[key] if store.key?(key)

          store[key] = yield
        end
        private :remembered

        # The default scopes of the target of a :through +reflection+ of
        # +owner+ as Active Record's join applies them: less what any scope
        # evaluated on the target's table unscopes, the source association's
        # (belongs_to :variant, -> { with_discarded }) as well as the through
        # association's own (has_one :x, -> { with_discarded }, through: ...).
        # Active Record evaluates both with the owner (AssociationScope's
        # add_constraints). nil when they select every record.
        def for_through(reflection, owner)
          remembered([:through, reflection]) do
            klass = reflection.klass
            return nil unless any?(klass)

            scope = built do
              unscoped = reflection.constraints.flat_map do |constraint|
                relation = klass.unscoped
                item = relation.instance_exec(owner, &constraint) || relation
                item.respond_to?(:unscope_values) ? item.unscope_values : []
              end
              default = klass.scope_for_association
              unscoped.any? ? default.unscope(*unscoped) : default
            end
            bare?(scope) ? nil : scope
          end
        end

        # +relation+ (event-store records) narrowed by +scope+, an Active
        # Record relation of the same model. The result's plan starts from
        # +base+ (the records before any condition: +relation+ itself, or a
        # Proc building them) and +steps+ (conditions +relation+ already
        # applied), then the default scope, so that a later unscope
        # (Model.with_discarded) or rewhere can take conditions off again
        # (CachedRelation#unscope).
        def narrow(relation, scope, what = nil, base: relation, steps: [])
          narrowed = scope ? relation.narrowed_by(scope, what || description(relation.model_class)) : relation
          narrowed = narrowed.spawn.inherit_rebuild(relation) if narrowed.equal?(relation) && !base.equal?(relation)
          default = scope ? [[:scope, scope, :default]] : []
          narrowed.plan = [base, default + steps]
          narrowed.default_scope_applied = scope
          narrowed
        end

        # Whether +record+ is among those +scope+ selects (a find by key).
        def admits?(klass, record, scope)
          return true unless scope

          Lyra::PurposeBoundReads.internal(INTERNAL) do
            CachedRelation.new(klass, [record]).narrowed_by(scope, description(klass)).to_a.any?
          end
        end

        # The first record matching +attributes+ that +scope+ selects, in its
        # order. Without an order or a limit any match will do, as SQL's
        # LIMIT 1 without ORDER BY: the store's own find_by answers, and only
        # a match the scope leaves out sends the read to every match.
        def find_by(klass, attributes, scope)
          return EventStoreReader.find_by(klass, attributes) unless scope

          what = description(klass)
          # A primary key names one record: the scope's order cannot choose
          # between matches, and the store answers by key.
          unordered = (scope.order_values.empty? && scope.limit_value.nil?) || pins_primary_key?(klass, attributes)
          if unordered
            CachedRelation.new(klass, []).narrowed_by(scope, what) # refuses what it cannot evaluate, before any read
            record = EventStoreReader.find_by(klass, attributes)
            return record if record.nil? || admits?(klass, record, scope)
            return nil if pins_primary_key?(klass, attributes)
          end
          Lyra::PurposeBoundReads.internal(INTERNAL) do
            EventStoreReader.where(klass, attributes).narrowed_by(scope, what).first
          end
        end

        # The monitored +models+ whose default scope ES-NoProj cannot
        # evaluate, with the reason, as [model, message] pairs. A scope that
        # cannot be built here (it needs a request's context) is left to the
        # read.
        def unevaluable(models)
          models.filter_map do |model|
            next unless model.respond_to?(:default_scopes) && any?(model)

            scope = begin
              built { model.default_scoped }
            rescue StandardError
              next
            end
            begin
              CachedRelation.new(model, []).narrowed_by(scope, description(model))
              nil
            rescue UnsupportedQuery => e
              [model, e.message]
            end
          end
        end

        # Model.unscoped from application code (Lyra's read overrides apply)
        # rather than from Active Record's internals or Lyra's own, which
        # build relations on it (association scopes, uniqueness validation,
        # counter caches) or read the table on purpose.
        # +locations+ are the caller's frames; frames of the model's own
        # unscoped (an application's def self.unscoped = super, a gem's
        # override) are passed over, so that ActiveRecord's internal call
        # through such an override still counts as ActiveRecord's.
        def application_caller?(locations)
          location = Array(locations).find { |frame| frame.base_label != "unscoped" }
          path = location&.path
          return false if path.nil?

          internal_paths.none? { |prefix| path.start_with?(prefix) }
        end

        # Whether +path+ is a file of ActiveRecord itself.
        def active_record_path?(path) = path.start_with?(internal_paths.first)

        def description(klass) = "the default scope of #{klass.name}"

        # Runs the block past Lyra's read overrides: relations built in it
        # are ActiveRecord's own (no SQL runs until one is loaded).
        def built
          previous = Thread.current[:lyra_bypass_read_override]
          Thread.current[:lyra_bypass_read_override] = true
          yield
        ensure
          Thread.current[:lyra_bypass_read_override] = previous
        end

        private

        # What the association's scope unscopes, evaluated on every read as
        # ActiveRecord evaluates it: a scope may decide at run time
        # (-> { Current.admin? ? with_deleted : all }).
        def association_unscopes(klass, reflection, owner)
          reflection.scope_for(klass.unscoped, owner).unscope_values
        end

        def pins_primary_key?(klass, attributes)
          key = klass.primary_key
          return false unless key.is_a?(String) && attributes.is_a?(Hash)

          value = attributes[key] || attributes[key.to_sym]
          !value.nil? && !value.is_a?(Array) && !value.is_a?(Range)
        end

        # A relation with nothing to narrow by: no conditions, order or limit.
        def bare?(scope)
          scope.where_clause.empty? && scope.order_values.empty? && scope.limit_value.nil? &&
            scope.offset_value.nil? && scope.joins_values.empty? && scope.left_outer_joins_values.empty? &&
            !scope.distinct_value && scope.group_values.empty? && scope.from_clause.empty?
        end

        def internal_paths
          @internal_paths ||= [
            "#{File.dirname(ActiveRecord::Scoping::Default::ClassMethods.instance_method(:unscoped).source_location.first, 2)}/",
            "#{File.expand_path('..', __dir__)}/"
          ].freeze
        end
      end
    end
  end
end
