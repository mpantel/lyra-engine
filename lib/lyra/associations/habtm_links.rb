# frozen_string_literal: true

module Lyra
  module Associations
    # Links and unlinks of has_and_belongs_to_many associations (#21).
    #
    # A HABTM join table has no model of its own: Active Record writes it
    # through an anonymous class (Item::HABTM_Tags), which no interceptor saw,
    # so item.tags << tag wrote the join row and the log never learnt of it. A
    # rebuild lost the association, and DualView did not compare it.
    #
    # Every insert into a join table goes through that class's _create_record
    # (tags << tag, tag_ids=, tags.create, an owner saved with new tags), and
    # every delete through a delete_all on one of its relations (tags.delete,
    # tags.clear, tag_ids=, destroying the owner). Each is recorded as an
    # AssociationLinked or AssociationUnlinked event:
    # - appended to the owner's stream, with the association, the join table
    #   and the join rows inserted or deleted ({ "item_id" => 1, "tag_id" => 5 });
    # - linked into the stream of each associated record whose model Lyra
    #   monitors, so either side's stream tells its links.
    # The events have no row operation, so replaying a record's state ignores
    # them. DualView compares each HABTM association's links with the join
    # table (differences), Rebuild restores join tables from them (rebuild),
    # and Genesis records the links a row already had (import).
    #
    # The join table is read as a set of pairs: a pair linked twice is one
    # link, and unlinking it removes it.
    module HabtmLinks
      LINKED = "linked"
      UNLINKED = "unlinked"

      class << self
        # Whether +klass+ is the join model of a has_and_belongs_to_many.
        def join_model?(klass)
          klass.respond_to?(:left_model) && klass.respond_to?(:right_reflection) &&
            klass.name.to_s.start_with?("HABTM_")
        end

        # Around the INSERT of a join row (WriteHooks#_create_record).
        def create(record)
          join_model = record.class
          return yield unless recorded?(join_model)

          # ES-Lazy: the owner's row may not be projected yet, and the join
          # row can reference it by foreign key.
          Lyra::Projections::LazyProjection.before_read(join_model.left_model)
          result = yield
          left, right = columns(join_model)
          publish(join_model, LINKED, record[left], [{ left => record[left], right => record[right] }])
          result
        end

        # Around a delete_all on a join model's relation
        # (StrictDataAccessRelation#delete_all).
        def delete_all(relation)
          join_model = relation.klass
          return yield unless recorded?(join_model)

          left, right = columns(join_model)
          Lyra::BypassEvents.atomically(join_model.left_model) do
            pairs = relation.pluck(left, right)
            result = yield
            pairs.group_by(&:first).each do |owner_id, owned|
              publish(join_model, UNLINKED, owner_id, owned.map { |l, r| { left => l, right => r } })
            end
            result
          end
        end

        # The links of each of +model_class+'s HABTM associations that differ
        # between the join table and the record's stream, as DualView reports
        # attributes: { "tags" => { crud: [ids], event_sourced: [ids] } }.
        def differences(model_class, id)
          joins = join_models(model_class)
          return {} if joins.empty?

          events = Lyra.config.event_store.read.stream(Lyra.stream_name(model_class, id)).to_a
          joins.each_with_object({}) do |(name, join_model), out|
            in_table = linked_ids_in_table(join_model, id)
            in_log = linked_ids_in_log(join_model, id, events)
            out[name.to_s] = { crud: in_table, event_sourced: in_log } unless in_table == in_log
          end
        end

        # Remove the rows of +model_class+'s join tables (before the model's
        # table is cleared, which their foreign keys may reference).
        def clear(model_class)
          join_models(model_class).each_value { |join_model| Lyra.projection_write { join_model.unscoped.delete_all } }
        end

        # Bring +model_class+'s join tables to what the link events say, in
        # the log's order. Returns the number of events applied.
        def rebuild(model_class)
          tables = join_models(model_class).values.to_h { |join_model| [join_model.table_name, join_model] }
          return 0 if tables.empty?

          applied = 0
          Lyra.config.event_store.read.of_type([Lyra::Events::AssociationLinked, Lyra::Events::AssociationUnlinked]).each do |event|
            join_model = tables[value(event.data, :join_table)] or next
            apply(join_model, event)
            applied += 1
          end
          applied
        end

        # Genesis: one AssociationLinked event per HABTM association holding
        # the links the row already has, in the row's own stream (the
        # associated records' streams get their own when they are imported).
        def import(model_class, id, stream_name)
          join_models(model_class).each do |name, join_model|
            left, right = columns(join_model)
            targets = linked_ids_in_table(join_model, id, cast: false)
            next if targets.empty?

            event = build_event(join_model, LINKED, id, targets.map { |t| { left => id, right => t } }, name: name, genesis: true)
            Lyra.append_events(event, stream_name: stream_name)
          end
        end

        private

        def recorded?(join_model)
          join_model?(join_model) && Lyra::BypassEvents.enabled_for?(join_model.left_model)
        end

        # The join model of each of +model_class+'s HABTM associations, by name.
        def join_models(model_class)
          return {} unless model_class.respond_to?(:reflect_on_all_associations)

          model_class.reflect_on_all_associations(:has_and_belongs_to_many).to_h do |reflection|
            # Defined on the class that declared the association (an STI
            # subclass inherits it).
            [reflection.name, model_class.const_get("HABTM_#{reflection.name.to_s.camelize}")]
          end
        end

        # The owner's has_and_belongs_to_many reflection +join_model+ serves.
        def reflection_for(join_model)
          join_model.left_model.reflect_on_all_associations(:has_and_belongs_to_many)
                    .find { |reflection| "HABTM_#{reflection.name.to_s.camelize}" == join_model.name }
        end

        def association_name(join_model) = reflection_for(join_model)&.name

        # [owner's column, associated record's column] in the join table, as
        # the association writes them (the join model's own left_side
        # association does not carry the owner's foreign_key option).
        def columns(join_model)
          reflection = reflection_for(join_model)
          [reflection.foreign_key.to_s, reflection.association_foreign_key.to_s]
        end

        def publish(join_model, operation, owner_id, rows)
          owner = join_model.left_model
          event = build_event(join_model, operation, owner_id, rows, name: association_name(join_model))
          Lyra.append_events(event, stream_name: Lyra.stream_name(owner, owner_id))
          link_into_targets(event, join_model, owner_id, rows)
        rescue => e
          Lyra::BypassEvents.publish_failed!(e, "has_and_belongs_to_many #{operation}")
        end

        def build_event(join_model, operation, owner_id, rows, name:, genesis: false)
          owner = join_model.left_model
          _, right = columns(join_model)
          data = {
            model_class: owner.name,
            model_id: owner_id,
            operation: operation,
            association: name.to_s,
            join_table: join_model.table_name,
            target_class: join_model.right_reflection.klass.name,
            target_ids: rows.map { |row| row[right] },
            rows: rows,
            timestamp: Time.current
          }
          metadata = { correlation_id: Lyra::Correlation.current_id, causation_id: Lyra::Causation.current_id }.compact
          metadata[:genesis] = true if genesis
          event_class = operation == LINKED ? Lyra::Events::AssociationLinked : Lyra::Events::AssociationUnlinked
          event_class.new(data: data, metadata: Lyra::Privacy.stamp(owner, data, metadata))
        end

        # Link the event into each associated record's stream, if its model is
        # monitored and the stream exists. An empty stream is left alone: a
        # stream that held only links would look imported to Genesis, and the
        # record would never get its Imported event.
        def link_into_targets(event, join_model, owner_id, rows)
          target = join_model.right_reflection.klass
          return unless target.respond_to?(:lyra_monitored) && target.lyra_monitored

          Lyra::Genesis.first_use(target)
          store = Lyra.config.event_store
          _, right = columns(join_model)
          own_stream = Lyra.stream_name(join_model.left_model, owner_id)
          rows.map { |row| row[right] }.compact.uniq.each do |target_id|
            stream = Lyra.stream_name(target, target_id)
            next if stream == own_stream
            next unless store.read.stream(stream).limit(1).to_a.any?

            store.link([event.event_id], stream_name: stream)
          end
        end

        def linked_ids_in_table(join_model, id, cast: true)
          left, right = columns(join_model)
          ids = join_model.unscoped.where(left => id).distinct.pluck(right)
          cast ? ids.map(&:to_s).sort : ids
        end

        # The ids linked to record +id+ after replaying the link events of its
        # stream that concern +join_model+'s table, from either side.
        def linked_ids_in_log(join_model, id, events)
          left, right = columns(join_model)
          table = join_model.table_name
          linked = Set.new
          events.each do |event|
            operation = value(event.data, :operation).to_s
            next unless [LINKED, UNLINKED].include?(operation) && value(event.data, :join_table) == table

            Array(value(event.data, :rows)).each do |row|
              row = row.to_h.transform_keys(&:to_s)
              next unless row[left].to_s == id.to_s

              operation == LINKED ? linked << row[right].to_s : linked.delete(row[right].to_s)
            end
          end
          linked.to_a.sort
        end

        def apply(join_model, event)
          left, right = columns(join_model)
          rows = Array(value(event.data, :rows)).map { |row| row.to_h.transform_keys(&:to_s).slice(left, right) }
          Lyra.projection_write do
            rows.each do |row|
              existing = join_model.unscoped.where(row)
              if value(event.data, :operation).to_s == LINKED
                join_model.insert_all([row]) unless existing.exists?
              else
                existing.delete_all
              end
            end
          end
        end

        def value(data, key)
          data[key] || data[key.to_s]
        end
      end
    end
  end

  module Events
    class AssociationLinked < Lyra::Event; end
    class AssociationUnlinked < Lyra::Event; end
  end
end
