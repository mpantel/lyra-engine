# frozen_string_literal: true

module Lyra
  module Rights
    # The subject's rights in queries over many people (Lyra::PurposeBoundReads).
    #
    # Condition 6 of Def. 1 is per subject, so a query whose subject is the
    # whole model ("Model$*": an aggregate, pluck, ids, exists?) cannot be
    # checked against one person's restriction. Refusing it would let one
    # person's request stop everyone's statistics; running it as it is would
    # process the restricted person's data. Such a query leaves the restricted
    # subjects out: under a purpose, when a request in force would refuse a
    # read of a subject's record (PamDsl::Policy#rights_violations: a
    # restriction of all of the subject's data, or of a field the query names,
    # and no Art. 18(2) exception of the purpose that applies; a pending
    # objection's restriction of this purpose; an upheld objection to it), the
    # query runs with that subject's rows excluded:
    #
    # - a record key (EnfArticle$7): the record's own key column NOT IN (...);
    # - a person key (Payer$7) the model links to (Rights::SubjectKeys: a
    #   belongs_to, a polymorphic belongs_to, a <type>_id column of a
    #   monitored model): (payer_id IS NULL OR payer_id NOT IN (...)), and for
    #   a polymorphic link (owner_id IS NULL OR owner_type IS NULL OR
    #   owner_type NOT IN ('Payer', <its STI subclasses>) OR owner_id NOT IN
    #   (...)), so rows that name no one are kept, as SQL's NOT IN alone would
    #   not keep them. The type column may hold an STI subclass's name; the
    #   subclasses are those loaded (eager loading, as in production).
    #
    # ES-NoProj's relations (Projections::CachedRelation) hold their records
    # in memory: a record is left out when any of its keys (its own, and its
    # people's, by the same resolver) is refused; a record whose links cannot
    # be read raises Rights::UnresolvedSubjectError (fail closed).
    #
    # A join, subquery or CTE that reaches a model with such a subject is
    # refused rather than filtered (refuse_reaching!): the excluded rows would
    # have to be traced through the join.
    #
    # In audit mode nothing is left out: the query runs whole and the log says
    # how many restricted subjects it may include. With nothing in force
    # anywhere, none of this does any work beyond the store's any_active? (a
    # clock read, once its scope has read the rights).
    #
    # Model.lyra_processable gives a batch job the records the purpose in
    # scope may process: the same exclusion, for every field the policy
    # declares unless fields: names the ones the job reads, in every
    # enforcement mode.
    module Queries
      # The subjects a query on +model+ leaves out: +own+ (ids of the model's
      # own records), +links+ ([[column, ids]]), +polymorphic+
      # ([[id column, type column, type, ids]]) and +keys+ (the subject keys).
      Exclusion = Struct.new(:model, :own, :links, :polymorphic, :keys, keyword_init: true) do
        # The condition the rows kept satisfy.
        def arel
          table = model.arel_table
          conditions = []
          conditions << table[Lyra.key_column(model)].not_in(own) if own.any?
          links.each { |column, ids| conditions << table[column].eq(nil).or(table[column].not_in(ids)) }
          polymorphic.each do |column, type_column, type, ids|
            conditions << table[column].eq(nil).or(table[type_column].eq(nil))
                                       .or(table[type_column].not_in(Queries.type_names(type)))
                                       .or(table[column].not_in(ids))
          end
          conditions.reduce { |all, condition| all.and(condition) }
        end

        # The condition as SQL, compiled once (a list of hundreds of ids is
        # costly to build and compile on every query).
        def sql
          @sql ||= Arel.sql("(#{arel.to_sql})")
        end

        def keeps?(record)
          !SubjectKeys.keys_for(record).intersect?(keys)
        end
      end

      class << self
        # The names a polymorphic type column may hold for the owner +type+:
        # its own and its STI subclasses'.
        def type_names(type)
          klass = type.to_s.safe_constantize
          return [type.to_s] unless klass.is_a?(Class) && klass < ActiveRecord::Base

          ([klass] + klass.descendants).map(&:name).compact.uniq
        end

        # Is any request in force anywhere (PamDsl's store)?
        def in_force?
          PamDsl.rights_store.any_active?
        end

        # The Exclusion for a query on +model+ naming +field_names+ under
        # +purpose+ (default: the one in scope), or nil when no subject is
        # left out. +audit+: in audit mode, log and return nil.
        def exclusion(model, field_names, purpose: PurposeBoundReads.current, audit: true)
          return nil unless purpose && in_force?

          policy = pam_policy(model)
          return nil unless policy

          refused = refused_keys(model, policy, purpose, field_names)
          return nil if refused.empty?

          if audit && policy.enforcement_mode == :audit
            PamDsl.logger.warn("Lyra: #{model.name} query under purpose '#{purpose}' includes the rows of " \
                               "#{refused.size} restricted subject#{'s' unless refused.size == 1} (audit mode: " \
                               "not left out)")
            return nil
          end

          built(model, refused)
        end

        # +relation+ (an Active Record relation) leaving out the restricted
        # subjects, or nil when there are none.
        def filter(relation, field_names)
          exclusion = exclusion(relation.klass, field_names)
          exclusion && relation.where(exclusion.sql)
        end

        # The records of +records+ a query on +model+ keeps, or nil when it
        # keeps them all.
        def kept_records(model, field_names, records)
          exclusion = exclusion(model, field_names)
          exclusion && records.select { |record| exclusion.keeps?(record) }
        end

        # Model.lyra_processable: +relation+ without the records the purpose
        # in scope may not process (for +fields+, default every declared
        # field). Any relation with no purpose in scope.
        def processable(relation, fields = nil)
          model = relation.respond_to?(:model_class) ? relation.model_class : relation.klass
          policy = PurposeBoundReads.current && pam_policy(model)
          return relation unless policy

          fields = fields.nil? ? policy.fields.keys : Array(fields).map(&:to_sym)
          exclusion = exclusion(model, fields, audit: false)
          return relation unless exclusion

          if relation.is_a?(Projections::CachedRelation)
            relation.lyra_select_records { |record| exclusion.keeps?(record) }
          else
            relation.where(exclusion.sql)
          end
        end

        # A join, subquery or CTE reaching +model+ (naming +field_names+ of
        # it) under the purpose in scope: refused when it would reach a
        # subject left out of a query on +model+, as Condition 6 refuses a
        # read (strict mode raises, audit mode logs).
        def refuse_reaching!(model, field_names)
          purpose = PurposeBoundReads.current
          return unless purpose && in_force?

          policy = pam_policy(model)
          return unless policy

          key = refused_keys(model, policy, purpose, field_names).first
          policy.validate_rights!(field_names, purpose, subject: key) if key
        end

        private

        def pam_policy(model)
          return nil unless model.respond_to?(:lyra_monitored) && model.lyra_monitored

          policy = Lyra::Privacy.policy_for(model)
          policy.respond_to?(:pam_policy) ? policy.pam_policy : nil
        end

        CACHE_MUTEX = Mutex.new

        # The keys in force that a query on +model+ can reach, and whose
        # requests would refuse it. Remembered per (model, policy, purpose,
        # fields) for as long as the store's snapshot is the same object
        # (Store#snapshot_token): a change to the rights in force, here or
        # read from another process, starts afresh. Not remembered for a
        # purpose with the :consent exception (consent can change without
        # the rights changing), nor while this connection's transaction has
        # rights of its own.
        def refused_keys(model, policy, purpose, field_names)
          fields = Array(field_names).map(&:to_sym).uniq.sort
          store = PamDsl.rights_store
          token = store.respond_to?(:snapshot_token) ? store.snapshot_token : nil
          declared = policy.purposes[purpose.to_sym]
          return compute_refused(model, policy, purpose, fields) if token.nil? || declared&.continues_under_restriction?(:consent)

          cache_key = [model, policy.object_id, purpose.to_sym, fields]
          cache = @refused_cache
          unless cache && cache[:token].equal?(token)
            cache = CACHE_MUTEX.synchronize { @refused_cache = { token: token, entries: {} } }
          end
          cached = cache[:entries][cache_key]
          return cached if cached

          refused = compute_refused(model, policy, purpose, fields).freeze
          CACHE_MUTEX.synchronize { cache[:entries][cache_key] = refused }
          refused
        end

        # build, remembered with the refused keys it was built from (a frozen
        # array refused_keys remembers, so the same object while the snapshot
        # is).
        def built(model, refused)
          cache = @refused_cache
          return build(model, refused) unless refused.frozen? && cache

          cache_key = [:built, model, refused.object_id]
          cached = cache[:entries][cache_key]
          return cached if cached

          exclusion = build(model, refused)
          return nil unless exclusion

          exclusion.sql
          CACHE_MUTEX.synchronize { cache[:entries][cache_key] = exclusion }
        end

        # One pass over the requests in force: those that could cover the
        # access, by subject, each subject then decided on its own requests
        # (the :consent exception asks its consent).
        def compute_refused(model, policy, purpose, fields)
          declared = policy.purposes[purpose.to_sym] || PamDsl::Purpose.new(purpose.to_sym)
          types = reachable_types(model)
          requests = PamDsl::Rights.in_force_requests(PamDsl.rights_store)
          candidates = PamDsl::Rights.applicable(requests, policy, declared, fields).map(&:subject_key).uniq
          return [] if candidates.empty?

          by_key = requests.group_by(&:subject_key)
          candidates.select do |key|
            type, = Rights.split_key(key)
            type && (types.nil? || types.include?(type)) &&
              PamDsl::Rights.violations_among(by_key.fetch(key, []), policy, declared, fields, key).any?
          end
        end

        # The subject types whose keys a row of +model+ can name: its own,
        # and its links' (nil when a polymorphic link can name any).
        def reachable_types(model)
          plan = SubjectKeys.links(model)
          return nil if plan.polymorphic.any?

          [Lyra.stream_owner_name(model), *plan.associations.map(&:last), *plan.convention.map(&:last)].uniq
        end

        def build(model, keys)
          own_type = Lyra.stream_owner_name(model)
          plan = SubjectKeys.links(model)
          own = []
          by_type = Hash.new { |hash, type| hash[type] = [] }
          keys.each do |key|
            type, id = Rights.split_key(key)
            type == own_type ? own << id : by_type[type] << id
          end
          links = (plan.associations + plan.convention).filter_map do |column, type|
            [column, by_type[type]] if type != own_type && by_type.key?(type)
          end
          polymorphic = plan.polymorphic.flat_map do |column, type_column|
            by_type.filter_map { |type, ids| [column, type_column, type, ids] unless type == own_type }
          end
          # Keys of types no column of the model holds name none of its rows.
          return nil if own.empty? && links.empty? && polymorphic.empty?

          Exclusion.new(model: model, own: own, links: links, polymorphic: polymorphic, keys: keys)
        end
      end
    end
  end
end
