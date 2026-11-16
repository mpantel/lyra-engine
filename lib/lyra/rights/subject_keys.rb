# frozen_string_literal: true

module Lyra
  module Rights
    # A record whose link to its people cannot be read (its row is gone, or
    # its model cannot be queried for it). Raised rather than let a person's
    # restriction or a missing consent go unseen.
    class UnresolvedSubjectError < PamDsl::Error; end

    # PamDsl.subject_key_resolver under Lyra: the keys a subject's rights and
    # consent are recorded and looked up under.
    #
    # - A record: its own key first (Lyra.stream_name: Registration$42), then
    #   the keys of the people it names, by the selection rule of the
    #   subject-access copy (Lyra::Privacy::SubjectLinks), read the other way:
    #   - a belongs_to names the record of its class (the owner of the STI
    #     hierarchy): belongs_to :payer, class_name: "Person" gives Person$7
    #     for payer_id = 7, never Payer$7;
    #   - a polymorphic belongs_to names the class its type column holds;
    #   - a <type>_id column no association owns names the monitored model
    #     of that name (person_id: Person$7), and nothing when there is none;
    #   - a record does not name another record of its own model.
    #   A record loaded without one of these columns (a select that leaves out
    #   payer_id) has them read from its row, in one query Lyra makes as its
    #   own; when they cannot be read, UnresolvedSubjectError. PAM DSL asks for
    #   the keys only when a right is in force or consent is checked.
    # - Anything else: nil, so PAM DSL's default applies (the subject as a
    #   string; none for nil or a model-wide "Model$*").
    module SubjectKeys
      Plan = Struct.new(:associations, :polymorphic, :convention, :columns, keyword_init: true)

      @plans = {}
      @mutex = Mutex.new

      class << self
        def call(subject)
          return nil unless defined?(ActiveRecord::Base) && subject.is_a?(ActiveRecord::Base)
          return [] if aggregate_row?(subject)

          keys_for(subject)
        end

        # The record's own key and its people's keys, own first. A record
        # narrowed from a whole one (ES-NoProj's select) carries the whole
        # one's keys (remember).
        def keys_for(record)
          remembered = record.instance_variable_get(:@lyra_subject_keys)
          return remembered if remembered

          [own_key(record), *person_keys(record)].uniq
        end

        # Give +narrowed+ (a record built with some of +whole+'s columns) the
        # keys of +whole+, so they need not be read again.
        def remember(narrowed, whole)
          narrowed.instance_variable_set(:@lyra_subject_keys, keys_for(whole))
          narrowed
        end

        # A row of an aggregate (select("status, count(*) AS n").group(:status),
        # find_by_sql with a GROUP BY): no key of its own, and columns the
        # table does not have, or the rows of a grouped load. It is not one
        # person's record, so it is not a subject.
        def aggregate_row?(record)
          return false if record.new_record?

          key = Lyra.key_column(record.class)
          return false if record.has_attribute?(key) && !record._read_attribute(key).nil?

          PurposeBoundReads::Context[:lyra_grouped_load] ||
            (record.attribute_names - columns(record.class)).any?
        end

        def own_key(record)
          Lyra.stream_name(record.class, record.id)
        end

        # The keys of the people +record+ names, in the order of its links.
        def person_keys(record)
          model = record.class
          own = Lyra.stream_owner_name(model)
          plan = plan_for(model)
          values = link_values(record, plan)
          keys = []
          plan.associations.each do |fk, type|
            keys << "#{type}$#{values[fk]}" if present?(values[fk]) && type != own
          end
          plan.polymorphic.each do |fk, type_column|
            next unless present?(values[fk]) && present?(values[type_column])

            type = owner_of(values[type_column].to_s)
            keys << "#{type}$#{values[fk]}" unless type == own
          end
          plan.convention.each do |fk, type|
            keys << "#{type}$#{values[fk]}" if present?(values[fk]) && type != own
          end
          keys.uniq
        end

        # +model+'s record +id+, to read its keys from: its row, else (no row:
        # ES-NoProj, a destroyed record) its last state replayed from its
        # stream, as Lyra's own read; nil when it has neither.
        def find_record(model, id)
          PurposeBoundReads.internal(INTERNAL) do
            row = model.unscoped.find_by(Lyra.key_column(model) => id)
            next row if row

            state = Lyra::DualView.new(model, id).event_sourced_state[:state]
            next nil if state.nil? || state.empty?

            attributes = state.transform_keys(&:to_s).slice(*model.column_names)
            attributes[Lyra.key_column(model)] ||= id
            model.instantiate(attributes)
          end
        end

        # The links of +model+'s rows to people: +associations+ and
        # +convention+ as [[column, subject type]], +polymorphic+ as
        # [[id column, type column]] (Rights::Queries reads them).
        def links(model)
          plan_for(model)
        end

        # Forget the cached plans (after a code reload).
        def reset!
          @mutex.synchronize { @plans = {} }
        end

        private

        def present?(value) = !value.nil? && !value.to_s.empty?

        def plan_for(model)
          key = [model, Lyra.config.monitored_models.map(&:name).hash]
          @plans[key] || @mutex.synchronize { @plans[key] ||= build_plan(model) }
        end

        def build_plan(model)
          associations = []
          polymorphic = []
          owned = []
          model.reflect_on_all_associations(:belongs_to).each do |reflection|
            owned << reflection.foreign_key.to_s
            if reflection.polymorphic?
              polymorphic << [reflection.foreign_key.to_s, reflection.foreign_type.to_s]
            else
              target = reflection.class_name.to_s.safe_constantize
              associations << [reflection.foreign_key.to_s, Lyra.stream_owner_name(target)] if active_record?(target)
            end
          rescue StandardError
            next
          end
          columns = columns(model)
          convention = columns.filter_map do |column|
            next unless column.end_with?("_id") && column.length > 3 && !owned.include?(column)

            type = monitored_model_for(column.delete_suffix("_id"))
            [column, type] if type
          end
          link_columns = (associations.map(&:first) + polymorphic.flatten + convention.map(&:first)).uniq
          link_columns &= columns unless columns.empty?
          Plan.new(associations: associations, polymorphic: polymorphic, convention: convention,
                   columns: link_columns).freeze
        end

        # The monitored model whose name, underscored, is +name+ (person for
        # Person, user for Spree::User), by the owner of its table.
        def monitored_model_for(name)
          model = Lyra.config.monitored_models.find { |m| m.name.to_s.demodulize.underscore == name }
          model && Lyra.stream_owner_name(model)
        end

        def owner_of(type_name)
          klass = Lyra.config.monitored_model_named(type_name) || type_name.safe_constantize
          active_record?(klass) ? Lyra.stream_owner_name(klass) : type_name
        end

        def active_record?(klass)
          klass.is_a?(Class) && klass < ActiveRecord::Base
        end

        # The link columns' values: the record's, and those it was loaded
        # without, from its row.
        def link_values(record, plan)
          values = {}
          missing = []
          plan.columns.each do |column|
            if record.has_attribute?(column)
              values[column] = record._read_attribute(column)
            else
              missing << column
            end
          end
          return values if missing.empty? || record.new_record?

          values.merge(missing.zip(load_columns(record, missing)).to_h)
        end

        def load_columns(record, columns)
          model = record.class
          row = Lyra::PurposeBoundReads.internal(INTERNAL) do
            model.unscoped.where(Lyra.key_column(model) => record.id).pick(*columns)
          end
          raise UnresolvedSubjectError, "#{own_key(record)} has no row to read #{columns.join(', ')} from" if row.nil?

          columns.size == 1 ? [row] : row
        rescue UnresolvedSubjectError
          raise
        rescue StandardError => e
          raise UnresolvedSubjectError,
                "#{own_key(record)} was loaded without #{columns.join(', ')}, which name the people it belongs to, " \
                "and they could not be read (#{e.class}: #{e.message}). Select them too, so that their " \
                "restrictions and consent can be checked"
        end

        def columns(model)
          model.table_exists? ? model.column_names : []
        rescue StandardError
          []
        end
      end
    end
  end
end
