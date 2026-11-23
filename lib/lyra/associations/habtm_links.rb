# frozen_string_literal: true

module Lyra
  module Associations
    # Links and unlinks of has_and_belongs_to_many associations.
    #
    # A HABTM join table has no model of its own: Active Record writes it
    # through an anonymous class (Item::HABTM_Tags), which no interceptor saw,
    # so item.tags << tag wrote the join row and the log never learnt of it. A
    # rebuild lost the association, and DualView did not compare it.
    #
    # Every insert Rails makes into a join table goes through that class's
    # _create_record (tags << tag, tag_ids=, tags.create, an owner saved with
    # new tags), one row at a time, and every delete through a delete_all on
    # one of its relations (tags.delete, tags.clear, tag_ids=, destroying the
    # owner). Each is recorded as an AssociationLinked or AssociationUnlinked
    # event:
    # - appended to the owner's stream, with the association, the join table
    #   and the join rows inserted or deleted ({ "item_id" => 1, "tag_id" => 5 });
    # - linked into the stream of each associated record whose model Lyra
    #   monitors, so either side's stream tells its links. When only the
    #   associated records' model is monitored, the event is appended to the
    #   first of their streams and linked into the others (publish).
    # The events have no row operation, so replaying a record's state ignores
    # them. DualView compares each HABTM association's links with the join
    # table (differences), Rebuild restores join tables from them (rebuild),
    # and Genesis records the links a row already had (import).
    #
    # The join table is read as a set of pairs: a pair linked twice is one
    # link, and unlinking it removes it.
    #
    # Deleting join rows is Rails' association maintenance when the
    # association does it (Lyra::Associations::Maintenance), allowed in
    # strict mode as dependent: :nullify is; the application's own delete_all
    # on the join model, or on a model it declared on the join table
    # (join_model_of), is refused there like any bulk write, and recorded as
    # an unlink where it runs. Its insert_all, insert_all! and upsert_all
    # (insert, insert!, upsert) of join rows likewise: refused in strict
    # mode, recorded as the links the rows written make where they run
    # (insert_all). Before 1.0.0 these went unguarded and unrecorded.
    #
    # The links of a has_many :through over a model Lyra does not monitor
    # are not recorded, from either side: that model's rows are the
    # application's own, written through its callbacks or Rails' delete_all
    # of them, and its table is no join table here (join_model_of) unless a
    # has_and_belongs_to_many whose links Lyra records names it. Monitored,
    # the through model records its rows as any model does.
    module HabtmLinks
      LINKED = "linked"
      UNLINKED = "unlinked"

      # Records has_and_belongs_to_many declarations (HabtmLinks.declared!).
      # Prepended to ActiveRecord::Associations::ClassMethods (install!).
      module Declarations
        def has_and_belongs_to_many(name, scope = nil, **options, &extension)
          result = super
          HabtmLinks.declared!(self, name)
          result
        end
      end

      class << self
        # Whether +klass+ is the join model of a has_and_belongs_to_many.
        def join_model?(klass)
          klass.respond_to?(:left_model) && klass.respond_to?(:right_reflection) &&
            klass.name.to_s.start_with?("HABTM_")
        end

        # The has_and_belongs_to_many join model whose rows +klass+ writes:
        # +klass+ itself when it is one, or, for a model the application
        # declared on a join table whose links Lyra records (and does not
        # monitor itself), the join model of an association on that table:
        # a monitored model's has_and_belongs_to_many, or an unmonitored
        # model's whose associated records' model is monitored (its links
        # are recorded on their streams: publish). Nil otherwise. The latter
        # were not recognised: a model on the join table of an unmonitored
        # owner, whose monitored side had no association back onto the
        # table, deleted the rows with neither the strict guard nor an
        # unlink.
        #
        # A table that is no has_and_belongs_to_many's join table is not
        # one, whatever links its rows make: a has_many :through over a model
        # Lyra does not monitor writes that model's rows through its
        # callbacks, or by Rails' delete_all of them (Maintenance), and Lyra
        # records neither, the through model being an ordinary model of the
        # application's. It is recorded only when that model is monitored
        # (its rows' own events).
        #
        # Every delete_all, insert_all and upsert_all asks
        # (StrictDataAccessRelation), so the answer for a model is kept, until
        # the monitored models change (Configuration#monitor_model, a new
        # configuration, a code reload: reset_join_models!) or a
        # has_and_belongs_to_many is declared (Declarations).
        def join_model_of(klass)
          return klass if join_model?(klass)
          return nil if klass.respond_to?(:lyra_monitored) && klass.lyra_monitored
          return nil unless klass.respond_to?(:table_name) && !klass.abstract_class?

          found = join_cache[:models].compute_if_absent(klass) { find_join_model(klass.table_name) || false }
          found || nil
        end

        # The associations on +join_model+'s table whose owners a row of it
        # can name besides its own: those whose owner's column is neither of
        # its two (the inverse side's owner column is its associated
        # records'), whose links are recorded now. Kept as join_model_of's
        # answers are.
        def other_sides(join_model)
          left, right = columns(join_model)
          found = join_cache[:others].compute_if_absent(join_model) do
            join_models_on(join_model.table_name).reject { [left, right].include?(columns(_1).first) }
          end
          found.select { recorded?(_1) }
        end

        # Forget the join models join_model_of found.
        def reset_join_models!
          @join_models_of = nil
        end

        # A has_and_belongs_to_many +name+ was declared on +owner+
        # (Declarations): its join model is kept, by owner and association
        # (a class reloaded replaces its own), so join_model_of finds the
        # tables of unmonitored owners too.
        def declared!(owner, name)
          join_model = owner.const_get("HABTM_#{name.to_s.camelize}", false)
          @declared ||= Concurrent::Map.new
          @declared[[owner.name || owner.object_id, name.to_s]] = join_model
          @declarations = @declarations.to_i + 1
        rescue NameError
          nil
        end

        # Record has_and_belongs_to_many declarations from now on
        # (Maintenance.install!), and those of the models already loaded (an
        # initializer that loaded models before Active Record's load hooks
        # ran Lyra's): declared_already!.
        def install!
          unless ActiveRecord::Associations::ClassMethods.ancestors.include?(Declarations)
            ActiveRecord::Associations::ClassMethods.prepend(Declarations)
          end
          declared_already!
        end

        # Record the has_and_belongs_to_many of every model loaded now, as
        # declared! records a new one: the classes its name stands for now
        # (one reloaded since, still among Active Record's descendants, would
        # replace the current one's). Returns how many.
        def declared_already!
          ActiveRecord::Base.descendants.sum do |model|
            next 0 if model.abstract_class? || model.name.nil? || join_model?(model)
            next 0 unless model.name.safe_constantize.equal?(model)

            model.reflect_on_all_associations(:has_and_belongs_to_many).count do |reflection|
              declared!(model, reflection.name)
            end
          rescue StandardError
            0
          end
        end

        # Whether deleting +join_model+'s rows is a write strict data access
        # guards: either side's model is monitored (the owner's, or the
        # associated records'). Recording the unlink on the monitored side's
        # stream when only that side is monitored is left to the owner's
        # (recorded?).
        def guarded?(join_model)
          [join_model.left_model, join_model.right_reflection.klass].any? do |side|
            side.respond_to?(:lyra_monitored) && side.lyra_monitored
          end
        rescue NameError
          false
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
        # (StrictDataAccessRelation#delete_all): the unlink of its owner, on
        # the owner's stream, linked into each associated record's.
        #
        # A row can name the owners of other associations on the table too,
        # in columns of their own (a table two owners share, each with its
        # column, where the application filled both on one row): each of
        # those owners gets the unlink Rails' own from its side records, as
        # delete_all_on_table records it (other_sides). It was recorded for
        # the side Rails deleted from only, and the other owner's stream kept
        # a link whose row was gone. A row naming no other owner is recorded
        # as before, and the inverse side of the association (its owner is
        # this side's associated record) is not another owner.
        def delete_all(relation, join_model = relation.klass)
          return yield unless recorded?(join_model)

          left, right = columns(join_model)
          others = other_sides(join_model)
          read = ([left, right] + others.flat_map { columns(_1) }).uniq
          Lyra::BypassEvents.atomically(join_model.left_model) do
            rows = relation.pluck(*read).map { |values| read.zip(Array(values)).to_h }
            result = yield
            rows.group_by { _1[left] }.each do |owner_id, owned|
              publish(join_model, UNLINKED, owner_id, owned.map { |row| { left => row[left], right => row[right] } })
            end
            publish_sides(others, rows, UNLINKED) if others.any?
            result
          end
        end

        # Around a delete_all on a relation of a model the application
        # declared on a join table (StrictDataAccessRelation#delete_all), its
        # own or Rails' through it (a has_many :through over it, its
        # dependent: :delete_all). Several monitored models'
        # has_and_belongs_to_many can share the table: both sides of one
        # association, a self-referential one, or two owners on columns of
        # their own. Each of them whose model is recorded is a side
        # (recorded_sides): the rows deleted are read first, by every side's
        # columns, and each owner a row names in its side's foreign key gets
        # the AssociationUnlinked Rails' own unlink from that side records,
        # on its stream, linked into each associated record's stream, unless
        # that record has an unlink of its own for the same rows (the inverse
        # side of the association is recorded too). A side whose model is
        # not monitored records nothing. It recorded the first model's side
        # only, whichever owners the rows named.
        def delete_all_on_table(relation)
          sides = recorded_sides(relation.klass.table_name)
          return yield if sides.empty?

          columns = sides.flat_map { columns(_1) }.uniq
          Lyra::BypassEvents.atomically(sides.first.left_model) do
            rows = relation.pluck(*columns).map { |values| columns.zip(Array(values)).to_h }
            result = yield
            publish_sides(sides, rows, UNLINKED)
            result
          end
        end

        # Around the application's insert_all, insert_all! or upsert_all on a
        # join model, or on a model it declared on a join table
        # (StrictDataAccessRelation#join_insert; the block runs the write,
        # given the RETURNING to ask for). The links the rows written make
        # are recorded as Rails' own link from each side records them, as
        # delete_all and delete_all_on_table record unlinks: a join model's
        # rows link its owners (its side, and the other owners a row names:
        # other_sides); an application model's rows
        # link every monitored owner they name, of every side whose links are
        # recorded (recorded_sides), each on its stream, linked into the
        # associated records' streams that have none of their own. The rows
        # written are read back by RETURNING (with the columns each side
        # needs: Lyra::BypassEvents.with_returning), the caller getting the
        # result it asked for: the values the association's scope added (an
        # owner's item_tags.insert_all(...) sets its key) are in the event,
        # and a row ON CONFLICT DO NOTHING skipped records nothing.
        #
        # An upsert_all (+conflict+: the columns of its ON CONFLICT) reads the
        # rows its keys name first: a row it updated whose pair a side reads
        # is unchanged records nothing; one whose pair changed is that side's
        # unlink of the old pair and link of the new.
        def insert_all(relation, attributes, returning:, conflict: nil)
          klass = relation.klass
          sides = join_model?(klass) ? [klass].select { recorded?(_1) } + other_sides(klass) : recorded_sides(klass.table_name)
          return yield(returning) if sides.empty?

          columns = sides.flat_map { columns(_1) }.uniq
          keys = Array(conflict)
          Lyra::BypassEvents.atomically(sides.first.left_model) do
            before = keys.empty? ? {} : rows_by_key(relation, attributes, keys, columns)
            result, written = Lyra::BypassEvents.with_returning(klass, returning, (keys + columns).uniq) { |ret| yield ret }
            publish_inserts(sides, Array(written), before, keys)
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

        # The tables of +model_class+'s HABTM associations, which a rebuild
        # clears and restores from their link events.
        def join_tables(model_class) = join_models(model_class).values.map(&:table_name).uniq

        # Remove the rows of +model_class+'s join tables (before the model's
        # table is cleared, which their foreign keys may reference).
        def clear(model_class)
          join_models(model_class).each_value { |join_model| Lyra.projection_write(INTERNAL) { join_model.unscoped.delete_all } }
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

        # What join_model_of and other_sides found, until the monitored
        # models change or a has_and_belongs_to_many is declared.
        def join_cache
          config = Lyra.config
          cache = @join_models_of
          return cache if cache && cache[:config].equal?(config) && cache[:count] == config.monitored_models.size &&
                          cache[:declarations] == @declarations

          @join_models_of = { config: config, count: config.monitored_models.size, declarations: @declarations,
                              models: Concurrent::Map.new, others: Concurrent::Map.new }
        end

        # The join model of a monitored model's has_and_belongs_to_many on
        # +table+, or nil.
        def find_join_model(table) = join_models_on(table).first

        # The join models of the has_and_belongs_to_many on +table+ whose
        # links Lyra records, each once (an STI subclass inherits its
        # parent's): the monitored models' first, then those of unmonitored
        # owners whose associated records' model is monitored
        # (declared_join_models).
        def join_models_on(table)
          (Lyra.config.monitored_models.flat_map { join_models(_1).values } + declared_join_models)
            .select { _1.table_name == table }.uniq
        end

        # The join models of the has_and_belongs_to_many declared on models
        # Lyra does not monitor, linking to records of a model it does
        # (declared!). A class since reloaded or removed is left out.
        def declared_join_models
          return [] unless @declared

          monitored = Lyra.config.monitored_models
          @declared.values.select do |join_model|
            owner = join_model.left_model
            next false unless owner.name && owner.name.safe_constantize.equal?(owner)
            next false if monitored.any? { owner <= _1 }

            target = join_model.right_reflection.klass
            monitored.any? { target <= _1 }
          rescue NameError
            false
          end
        end

        # The sides of +table+ whose unlinks are recorded now (recorded?).
        def recorded_sides(table) = join_models_on(table).select { recorded?(_1) }

        # Each side's links or unlinks (+operation+) of +rows+ (hashes by
        # column; or a callable giving a side's rows), as publish records
        # them, then linked into the associated records' streams that have
        # none of their own for those rows.
        def publish_sides(sides, rows, operation)
          rows_of = rows.respond_to?(:call) ? rows : ->(_) { rows }
          covered = Set.new
          events = sides.flat_map do |join_model|
            left, right = columns(join_model)
            rows_of.call(join_model).select { _1[left] }.group_by { _1[left] }.map do |owner_id, owned|
              pairs = owned.map { |row| { left => row[left], right => row[right] } }.uniq
              event = build_event(join_model, operation, owner_id, pairs, name: association_name(join_model))
              if owner_recorded?(join_model)
                Lyra.append_events(event, stream_name: Lyra.stream_name(join_model.left_model, owner_id))
                covered << [Lyra.stream_name(join_model.left_model, owner_id), left]
              end
              [event, join_model, owner_id, pairs]
            end
          end
          events.each do |event, join_model, owner_id, pairs|
            link_into_targets(event, join_model, owner_id, pairs, covered: covered,
                                                                  append_first: !owner_recorded?(join_model))
          end
        rescue => e
          Lyra::BypassEvents.publish_failed!(e, "has_and_belongs_to_many #{operation}")
        end

        # The rows an upsert's +keys+ name, before it (the attributes given,
        # with the values the relation's scope adds), as hashes of +keys+ and
        # +columns+, by their keys' values. Lyra's own read.
        def rows_by_key(relation, attributes, keys, columns)
          klass = relation.klass
          scope = relation.scope_for_create.transform_keys(&:to_s)
          types = keys.map { klass.type_for_attribute(_1) }
          tuples = Array(attributes).filter_map do |row|
            row = scope.merge(row.to_h.transform_keys(&:to_s))
            next unless keys.all? { row.key?(_1) && !row[_1].nil? }

            keys.each_with_index.map { |key, i| types[i].cast(row[key]) }
          end.uniq
          return {} if tuples.empty?

          wanted = tuples.to_set
          read = (keys + columns).uniq
          found = Lyra::PurposeBoundReads.internal(INTERNAL) do
            klass.unscoped.where(keys.first => tuples.map(&:first).uniq).pluck(*read)
          end
          found.each_with_object({}) do |values, acc|
            row = read.zip(Array(values)).to_h
            tuple = row.values_at(*keys)
            acc[tuple] = row if wanted.include?(tuple)
          end
        end

        # The links and unlinks the rows an insert or upsert wrote make
        # (insert_all): every row an insert wrote, and every row an upsert
        # inserted, links its pair; a row an upsert updated (found in
        # +before+ by its +keys+) unlinks and links only where the side's
        # pair changed.
        def publish_inserts(sides, written, before, keys)
          return publish_sides(sides, written, LINKED) if before.empty?

          old_of = ->(row) { before[row.values_at(*keys)] }
          changed = lambda do |join_model, row|
            old = old_of.(row)
            old && old.values_at(*columns(join_model)) != row.values_at(*columns(join_model))
          end
          publish_sides(sides, ->(side) { written.select { changed.(side, _1) }.map(&old_of) }, UNLINKED)
          publish_sides(sides, ->(side) { written.select { old_of.(_1).nil? || changed.(side, _1) } }, LINKED)
        end

        # Whether +join_model+'s links are recorded: on its owner's stream
        # when the owner's model is monitored, else on the associated
        # records' streams when theirs is (owner_recorded?, targets_recorded?).
        def recorded?(join_model)
          join_model?(join_model) && (owner_recorded?(join_model) || targets_recorded?(join_model))
        end

        def owner_recorded?(join_model) = Lyra::BypassEvents.enabled_for?(join_model.left_model)

        def targets_recorded?(join_model)
          Lyra::BypassEvents.enabled_for?(join_model.right_reflection.klass)
        rescue NameError
          false
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

        # The event on the owner's stream, linked into each associated
        # record's; when the owner's model is not monitored, on the
        # associated records' streams only (the first one's, linked into the
        # others'), as a link made from the other side would be seen there.
        # Before, a link or unlink made from a side Lyra did not monitor was
        # not recorded at all, though the other side's records were.
        def publish(join_model, operation, owner_id, rows)
          owner = join_model.left_model
          event = build_event(join_model, operation, owner_id, rows, name: association_name(join_model))
          if owner_recorded?(join_model)
            Lyra.append_events(event, stream_name: Lyra.stream_name(owner, owner_id))
            link_into_targets(event, join_model, owner_id, rows)
          else
            link_into_targets(event, join_model, owner_id, rows, append_first: true)
          end
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
          metadata = Lyra::BypassEvents.current_metadata
          metadata[:genesis] = true if genesis
          event_class = operation == LINKED ? Lyra::Events::AssociationLinked : Lyra::Events::AssociationUnlinked
          event_class.new(data: data, metadata: Lyra::Privacy.stamp(owner, data, metadata))
        end

        # Link the event into each associated record's stream, if its model is
        # monitored and the stream exists. An empty stream is left alone: a
        # stream that held only links would look imported to Genesis, and the
        # record would never get its Imported event.
        # +covered+: [stream, column] pairs whose stream has an event of its
        # own for the rows naming it in that column (publish_sides).
        # +append_first+: the event is in no stream yet (its owner's model is
        # not monitored); it is appended to the first stream, then linked.
        def link_into_targets(event, join_model, owner_id, rows, covered: nil, append_first: false)
          target = join_model.right_reflection.klass
          return unless target.respond_to?(:lyra_monitored) && target.lyra_monitored

          Lyra::Genesis.first_use(target)
          store = Lyra.config.event_store
          _, right = columns(join_model)
          own_stream = Lyra.stream_name(join_model.left_model, owner_id)
          rows.map { |row| row[right] }.compact.uniq.each do |target_id|
            stream = Lyra.stream_name(target, target_id)
            next if stream == own_stream
            next if covered&.include?([stream, right])
            next unless store.read.stream(stream).limit(1).to_a.any?

            if append_first
              Lyra.append_events(event, stream_name: stream)
              append_first = false
            else
              store.link([event.event_id], stream_name: stream)
            end
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
          Lyra.projection_write(INTERNAL) do
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
