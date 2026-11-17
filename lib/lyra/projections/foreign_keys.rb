# frozen_string_literal: true

module Lyra
  module Projections
    # Database foreign keys ES-NoProj cannot honour.
    #
    # ES-NoProj (event sourcing, projections disabled) leaves the table of
    # every monitored model empty: its records live in the event log. A
    # database foreign key from a table no monitored model writes into such a
    # table therefore refuses every write there that references a record
    # (PG::ForeignKeyViolation, ActiveRecord::InvalidForeignKey): the row it
    # points at is never inserted. ModeTransition refuses the switch into
    # ES-NoProj while one exists, and the boot warns of it.
    #
    # The other foreign keys never fire in ES-NoProj: one between two
    # monitored tables, or from a monitored table into an unmonitored one,
    # sits on a table that gets no rows.
    #
    # One query per table of each database the monitored models use
    # (connection.foreign_keys), at the switch and at boot only.
    module ForeignKeys
      Blocking = Struct.new(:from_table, :column, :to_table, :name, :referencing_models, keyword_init: true) do
        def to_s
          by = referencing_models.empty? ? "" : ", written by #{referencing_models.join(', ')}"
          "#{from_table}.#{column} -> #{to_table} (constraint #{name}#{by})"
        end
      end

      class << self
        # The foreign keys from a table no model in +models+ writes into one a
        # model in +models+ writes, in each database those models use.
        def blocking(models)
          tabled = models.select { |model| table_of(model) }
          tabled.group_by(&:connection_pool).flat_map do |pool, in_pool|
            monitored = in_pool.map { |model| table_of(model) }.uniq
            pool.with_connection { |connection| blocking_in(connection, monitored) }
          end
        end

        # How to fix +blocking+, for the refusal and the boot warning.
        def remedy(blocking)
          drops = blocking.map { |fk| "remove_foreign_key :#{fk.from_table}, name: #{fk.name.to_s.inspect}" }.uniq
          referencing = blocking.flat_map(&:referencing_models).uniq
          monitor = "monitor the referencing model#{" (#{referencing.join(', ')})" unless referencing.empty?}"
          "Drop the constraint (#{drops.join('; ')}) and keep the reference in the model (belongs_to " \
            "validates that the record exists), or #{monitor}, or use another projection mode."
        end

        def description(blocking)
          "ES-NoProj keeps the records of monitored models in the event store and leaves their tables empty, " \
            "so a database foreign key into one of those tables from a table no monitored model writes refuses " \
            "every write there that references a record: #{blocking.map(&:to_s).join('; ')}."
        end

        private

        def blocking_in(connection, monitored)
          return [] unless connection.supports_foreign_keys?

          known = monitored.flat_map { |table| [table, unqualified(table)] }.uniq
          (connection.tables - known).flat_map do |table|
            connection.foreign_keys(table).filter_map do |fk|
              to_table = fk.to_table.to_s
              next unless known.include?(to_table) || known.include?(unqualified(to_table))

              Blocking.new(from_table: fk.from_table.to_s, column: Array(fk.column).join(", "), to_table: to_table,
                           name: fk.name.to_s, referencing_models: models_of(fk.from_table.to_s))
            end
          end
        end

        def table_of(model)
          return nil if !model.respond_to?(:table_name) || (model.respond_to?(:abstract_class?) && model.abstract_class?)

          model.table_name.presence
        end

        def unqualified(table) = table.to_s.split(".").last

        # The loaded models that write +table+ (none of them monitored).
        def models_of(table)
          ActiveRecord::Base.descendants.filter_map do |model|
            next if model.abstract_class? || model.name.nil?
            next unless (model.table_name rescue nil) == table

            model.base_class.name
          end.uniq.sort
        end
      end
    end
  end
end
