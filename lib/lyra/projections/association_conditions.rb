# frozen_string_literal: true

module Lyra
  module Projections
    # Rewrites hash conditions the way ActiveRecord does before ES-NoProj
    # evaluates them against cached records:
    #
    # - a belongs_to association becomes its foreign key:
    #   where(program: program) => where(program_id: program.id), and a
    #   polymorphic one its type and id columns;
    # - a record given as a column value becomes its id:
    #   where(program_id: program) => where(program_id: program.id).
    #
    # Without this, ES-NoProj evaluated where(program: x) by loading each
    # cached record's association (one query per record, about 10,000 for
    # one count in the mode-comparison benchmark) and comparing objects. And
    # find_by(program: x) compared against a "program" attribute the record
    # does not have, so it silently found nothing.
    #
    # Conditions ActiveRecord itself only accepts with a join (a has_many or
    # has_one association) raise UnsupportedQuery, as do polymorphic values
    # of more than one type, which cannot be expressed as independent column
    # conditions.
    module AssociationConditions
      module_function

      def rewrite(model_class, conditions)
        return conditions unless conditions.is_a?(Hash)

        conditions.each_with_object({}) do |(key, value), rewritten|
          reflection = model_class.reflect_on_association(key.to_s.to_sym) if model_class.respond_to?(:reflect_on_association)

          if reflection.nil?
            rewritten[key] = record_ids(value)
          elsif !reflection.belongs_to?
            raise UnsupportedQuery.new(model_class, "a condition on the #{reflection.macro} association #{key}")
          elsif reflection.polymorphic?
            rewritten.merge!(polymorphic(model_class, reflection, value))
          else
            rewritten[reflection.foreign_key.to_s] = association_keys(reflection, value)
          end
        end
      end

      # A record (or records) given where a column value is expected stands
      # for its primary key.
      def record_ids(value)
        case value
        when ActiveRecord::Base then value.id
        when Array then value.map { |v| v.is_a?(ActiveRecord::Base) ? v.id : v }
        else value
        end
      end

      def association_keys(reflection, value)
        key = reflection.association_primary_key.to_s
        pick = ->(v) { v.is_a?(ActiveRecord::Base) ? v.read_attribute(key) : v }
        value.is_a?(Array) ? value.map(&pick) : pick.call(value)
      end

      def polymorphic(model_class, reflection, value)
        type_column = reflection.foreign_type.to_s
        id_column = reflection.foreign_key.to_s
        return { type_column => nil, id_column => nil } if value.nil?

        values = Array(value)
        unless values.all? { _1.is_a?(ActiveRecord::Base) }
          raise UnsupportedQuery.new(model_class, "a condition on the polymorphic #{reflection.name} without records")
        end

        types = values.map { _1.class.polymorphic_name }.uniq
        if types.size > 1
          raise UnsupportedQuery.new(model_class, "a condition on the polymorphic #{reflection.name} over several types")
        end

        ids = values.map(&:id)
        { type_column => types.first, id_column => value.is_a?(Array) ? ids : ids.first }
      end
    end
  end
end
