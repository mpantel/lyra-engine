# frozen_string_literal: true

module Lyra
  module Projections
    # In-memory joins for ES-NoProj (CachedRelation).
    #
    # joins(:program).where(programs: { available: true }) is evaluated the
    # way SQL would evaluate it, from data Lyra already has:
    #
    # - A joined relation holds rows, each a record with its partner per
    #   joined association, so a later condition on the joined table can
    #   filter them.
    # - An inner join drops records without a partner. A left join keeps them
    #   with a missing partner, which behaves like SQL NULL: it matches only
    #   conditions that ask for nil, and a where.not on the joined table
    #   excludes it.
    # - A has_many or has_one join repeats the record once per partner, as
    #   SQL does, so count agrees with ActiveRecord; distinct removes the
    #   repeats.
    # - Partners come from the joined model's own read path: its event
    #   streams (through the stamped cache) when it is an ES-NoProj model,
    #   otherwise one SQL query on its table for the keys that are needed.
    #
    # Not supported, and raised as UnsupportedQuery rather than guessed:
    # SQL-string joins, nested joins (joins(program: :policy)), :through,
    # polymorphic and scoped associations, a condition on a table that was
    # not joined first, and conditions nested more than one level.
    module CachedJoins
      Join = Struct.new(:name, :reflection, :kind)

      def joins(*args)
        join_associations(args, :inner, "joins")
      end

      def left_joins(*args)
        join_associations(args, :left, "left_joins")
      end

      def left_outer_joins(*args)
        join_associations(args, :left, "left_outer_joins")
      end

      # Rows as [record, { association name => partner or nil }].
      def joined_rows
        @rows || @records.map { |record| [record, {}] }
      end

      def joined_associations
        @joins || {}
      end

      private

      def with_rows(rows, joins)
        relation = self.class.new(model_class, rows.map(&:first))
        relation.instance_variable_set(:@rows, rows)
        relation.instance_variable_set(:@joins, joins)
        relation
      end

      def join_associations(args, kind, what)
        args.flatten.reduce(self) do |relation, name|
          unless name.is_a?(Symbol) || name.is_a?(String)
            raise UnsupportedQuery.new(model_class, "#{what}(#{name.inspect})")
          end

          relation.send(:join_one, name.to_sym, kind, what)
        end
      end

      def join_one(name, kind, what)
        reflection = join_reflection(name, what)
        rows = joined_rows
        partners = partners_for(reflection, rows.map(&:first))

        joined = rows.flat_map do |record, joins|
          matches = partners.fetch(join_key(reflection, record), [])
          if matches.empty?
            kind == :left ? [[record, joins.merge(name => nil)]] : []
          else
            matches.map { |partner| [record, joins.merge(name => partner)] }
          end
        end

        with_rows(joined, joined_associations.merge(name => Join.new(name, reflection, kind)))
      end

      def join_reflection(name, what)
        reflection = model_class.respond_to?(:reflect_on_association) && model_class.reflect_on_association(name)
        unsupported = ->(why) { raise UnsupportedQuery.new(model_class, "#{what}(:#{name}) (#{why})") }
        unsupported.call("not an association") unless reflection
        unsupported.call("a :through association") if reflection.through_reflection?
        unsupported.call("a polymorphic association") if reflection.polymorphic?
        unsupported.call("an association with a scope") if reflection.scope
        unsupported.call(reflection.macro.to_s) unless %i[belongs_to has_many has_one].include?(reflection.macro)
        reflection
      end

      # The value that pairs a record with its partners.
      def join_key(reflection, record)
        if reflection.belongs_to?
          record.read_attribute(reflection.foreign_key)
        else
          record.read_attribute(reflection.active_record_primary_key)
        end
      end

      # { join key => [partner, ...] } for the given records.
      def partners_for(reflection, records)
        key_column = reflection.belongs_to? ? reflection.association_primary_key.to_s : reflection.foreign_key.to_s
        keys = records.map { join_key(reflection, _1) }.compact.uniq
        return {} if keys.empty?

        read_partners(reflection.klass, key_column => keys).group_by { _1.read_attribute(key_column) }
      end

      def read_partners(klass, conditions)
        if events_only_model?(klass)
          EventStoreReader.where(klass, conditions).to_a
        else
          begin
            previous = Thread.current[:lyra_bypass_read_override]
            Thread.current[:lyra_bypass_read_override] = true
            klass.unscoped.where(conditions).to_a
          ensure
            Thread.current[:lyra_bypass_read_override] = previous
          end
        end
      end

      def events_only_model?(klass)
        klass.respond_to?(:lyra_monitored) && klass.lyra_monitored &&
          Lyra.event_sourcing_mode? && Lyra.config.projection_mode == :disabled
      end

      # Split hash conditions into this model's own and those on a joined
      # table ({ programs: { available: true } }), resolving each joined key
      # to the association it names (by association name or table name).
      def split_joined_conditions(conditions)
        own = {}
        joined = {}
        conditions.each do |key, value|
          if value.is_a?(Hash)
            joined[joined_name_for(key)] = value
          else
            own[key] = value
          end
        end
        [own, joined]
      end

      def joined_name_for(key)
        name = joined_associations.keys.find do |assoc|
          assoc.to_s == key.to_s || joined_associations[assoc].reflection.klass.table_name == key.to_s
        end
        return name if name

        raise UnsupportedQuery.new(model_class, "a condition on #{key}, which is not joined " \
                                                "(join it with joins or left_joins before the condition)")
      end

      # Whether a row's partners match the joined conditions, as SQL would
      # decide it: true, false, or nil (unknown, a missing partner under a
      # condition that is not IS NULL).
      def joined_match(joins, joined_conditions)
        joined_conditions.reduce(true) do |result, (name, conditions)|
          partner = joins[name]
          klass = joined_associations[name].reflection.klass
          rewritten = AssociationConditions.rewrite(klass, conditions)
          if rewritten.values.any? { _1.is_a?(Hash) }
            raise UnsupportedQuery.new(model_class, "conditions nested more than one level on #{name}")
          end

          outcome =
            if partner.nil?
              rewritten.values.all? { |v| v.nil? || (v.is_a?(Array) && v.include?(nil)) } ? true : nil
            else
              rewritten.all? { |column, v| matches_value?(partner, column, v) }
            end
          combine_and(result, outcome)
        end
      end

      def combine_and(left, right)
        return false if left == false || right == false
        return nil if left.nil? || right.nil?

        true
      end
    end
  end
end
