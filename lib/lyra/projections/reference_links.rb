# frozen_string_literal: true

module Lyra
  module Projections
    # An index of references kept inside the event store, for ES-NoProj.
    #
    # Without tables, a lookup by any attribute but the primary key has to
    # consider every record of the model (CachedProjection.all). Active Record
    # makes such lookups itself: deleting a record with dependent associations
    # finds the children by their foreign key, once per association, and each
    # loaded every cached record of the child model.
    #
    # When an event sets a belongs_to foreign key (a create or import with the
    # key among its attributes, an update that changes it), it is also linked
    # into a reference stream, "Model.foreign_key$value", the way Rails Event
    # Store's LinkByMetadata links by a metadata key. A link is a row in the
    # store's own stream table; the event is not copied, no table is added, and
    # the index is append-only, rebuildable from the events.
    #
    # A lookup by that key reads the reference stream for candidates, rebuilds
    # each with CachedProjection.find and keeps the records that still match:
    # a child moved to another parent stays linked under the old one (streams
    # are append-only), and the match against its current state drops it. A
    # record that matches now has an event that set the key to the value, so
    # the candidates include every match and the answer is exact.
    #
    # Completeness. Links are written while config.reference_links says so
    # (:auto, the default: in ES-NoProj only, so no other mode pays for them).
    # The switch into ES-NoProj (Lyra::ModeTransition.to!) links every event
    # of every monitored model first, so the index is complete when the mode
    # starts. As a safety net, events written while linking was off are also
    # linked on first use: per model and
    # process, before its first lookup, the events since the model's
    # checkpoint (a ReferenceLinksIndexed event in "$lyra_reference_links$Model")
    # are linked and a new checkpoint is stored. An append in this process
    # while linking is off marks the model for that again. A lookup it cannot
    # answer from links (no single-valued foreign-key condition) returns nil,
    # and the caller loads every record as before.
    module ReferenceLinks
      CHECKPOINT_PREFIX = "$lyra_reference_links$"
      LOCK = "lyra_reference_links"
      MUTEX = Mutex.new

      class << self
        # Whether events are linked as they are stored.
        def enabled?
          case Lyra.config.reference_links
          when true then !Lyra.disabled_mode?
          when false, nil then false
          else Lyra.event_sourcing_mode? && Lyra.config.projection_mode == :disabled
          end
        end

        def stream_name(model_class, foreign_key, value)
          "#{model_class.name}.#{foreign_key}$#{value}"
        end

        # Called by Lyra.append_events after +events+ are stored in
        # +stream_name+: link those that set a foreign key, or, with linking
        # off, note that the model's links fell behind in this process.
        def after_append(events, stream_name, store)
          linking = enabled?
          # With linking off, only a model this process took for linked needs
          # noting; otherwise nothing is done, so other modes pay nothing.
          return if !linking && MUTEX.synchronize { ready.empty? }

          model_class = model_for_stream(stream_name)
          return unless model_class

          if linking
            link_events(Array(events), model_class, store)
          else
            if Array(events).any? { |event| reference_values(model_class, event).any? }
              MUTEX.synchronize { ready.delete(model_class.name) }
            end
          end
        end

        # Attribute hashes of the records of +model_class+ that match
        # +conditions+, found through a reference stream; nil when the
        # conditions name no single foreign-key value (then the caller
        # considers every record). The caller still applies +conditions+.
        def lookup(model_class, conditions)
          return nil unless enabled? && conditions.is_a?(Hash)

          key, value = indexed_condition(model_class, conditions)
          return nil unless key

          catch_up(model_class)
          ids = candidate_ids(model_class, key, value)
          records = ids.filter_map { |id| CachedProjection.find(model_class, id) }
          records.sort_by { |attrs| sort_key(attrs[model_class.primary_key.to_s]) }
        end

        # Link the events stored since the model's checkpoint, once per
        # process (and again after an append made while linking was off).
        # Returns the number of events linked.
        #
        # Inside an open transaction (a dependent lookup during a destroy) it
        # runs on a connection of its own, which commits at once: links and
        # checkpoint written in the caller's transaction would vanish with a
        # rollback while this process took the model for linked.
        def catch_up(model_class, force: false)
          return 0 if !force && ready?(model_class)

          linked = on_own_connection { link_and_checkpoint(model_class, force) }
          MUTEX.synchronize { ready << model_class.name }
          linked
        end

        # Forget which models are linked in this process (tests, truncation).
        def reset!
          MUTEX.synchronize { @ready = Set.new }
        end

        # Foreign keys of +model_class+ the index covers.
        def foreign_keys(model_class)
          model_class.reflect_on_all_associations(:belongs_to).map { |r| r.foreign_key.to_s }.uniq
        end

        private

        def ready
          @ready ||= Set.new
        end

        def ready?(model_class)
          MUTEX.synchronize { ready.include?(model_class.name) }
        end

        def on_own_connection(&block)
          return yield unless ActiveRecord::Base.connection.transaction_open?

          Thread.new { ActiveRecord::Base.connection_pool.with_connection(&block) }.value
        end

        def link_and_checkpoint(model_class, force)
          connection = ActiveRecord::Base.connection
          ActiveRecord::Base.transaction do
            Lyra::AdvisoryLock.xact_lock(connection, "#{LOCK}/#{model_class.name}", purpose: "reference links")
            position = force ? 0 : checkpoint(model_class)
            upto = connection.select_value("SELECT MAX(id) FROM event_store_events").to_i
            next 0 unless upto > position

            linked = link_since(model_class, position, upto)
            store_checkpoint(model_class, upto)
            linked
          end
        end

        def indexed_condition(model_class, conditions)
          keys = foreign_keys(model_class)
          conditions.each do |key, value|
            next unless keys.include?(key.to_s)

            value = value.id if value.is_a?(ActiveRecord::Base)
            return [key.to_s, value] if value.is_a?(Integer) || value.is_a?(String)
          end
          nil
        end

        def candidate_ids(model_class, key, value)
          Lyra.config.event_store.read.stream(stream_name(model_class, key, value)).to_a.map do |event|
            data = event.data
            (data[:model_id] || data["model_id"]).to_s
          end.uniq
        rescue RubyEventStore::EventNotFoundInStream
          []
        end

        # { foreign key => value } that +event+ sets, for the model's keys.
        def reference_values(model_class, event)
          data = event.data
          values =
            case Lyra::Event.operation_of(event)
            when :created, :imported
              attrs = data[:attributes] || data["attributes"] || {}
              attrs.to_h.transform_keys(&:to_s)
            when :updated
              changes = data[:changes] || data["changes"] || {}
              changes.to_h.to_h { |field, change| [field.to_s, change.is_a?(Array) ? change.last : change] }
            else
              {}
            end
          values.slice(*foreign_keys(model_class)).compact
        end

        def link_events(events, model_class, store)
          events.each do |event|
            reference_values(model_class, event).each do |key, value|
              store.link([event.event_id], stream_name: stream_name(model_class, key, value))
            end
          end
        end

        def link_since(model_class, position, upto)
          connection = ActiveRecord::Base.connection
          prefix = connection.quote("#{ActiveRecord::Base.sanitize_sql_like("#{model_class.name}$")}%")
          event_ids = connection.select_values(<<~SQL.squish)
            SELECT e.event_id FROM event_store_events e
            JOIN event_store_events_in_streams s ON s.event_id = e.event_id
            WHERE s.stream LIKE #{prefix} AND e.id > #{Integer(position)} AND e.id <= #{Integer(upto)}
            ORDER BY e.id
          SQL
          return 0 if event_ids.empty?

          store = Lyra.config.event_store
          wanted = Hash.new { |h, k| h[k] = [] }
          event_ids.each_slice(500) do |ids|
            store.read.events(ids).each do |event|
              reference_values(model_class, event).each do |key, value|
                wanted[stream_name(model_class, key, value)] << event.event_id
              end
            end
          end

          linked = 0
          wanted.each do |stream, ids|
            present = store.read.stream(stream).to_a.map(&:event_id).to_set
            missing = ids.uniq.reject { present.include?(_1) }
            next if missing.empty?

            store.link(missing, stream_name: stream)
            linked += missing.size
          end
          linked
        end

        def checkpoint(model_class)
          last = Lyra.config.event_store.read.stream("#{CHECKPOINT_PREFIX}#{model_class.name}").last
          last ? (last.data[:position] || last.data["position"]).to_i : 0
        rescue RubyEventStore::EventNotFoundInStream
          0
        end

        def store_checkpoint(model_class, position)
          event = Lyra::Events::ReferenceLinksIndexed.new(data: { model_class: model_class.name, position: position })
          Lyra.config.event_store.publish(event, stream_name: "#{CHECKPOINT_PREFIX}#{model_class.name}")
        end

        # The monitored model a record stream belongs to ("Model$id"), or nil
        # (Lyra's own streams, reference streams, aggregates of no model).
        def model_for_stream(stream_name)
          name = stream_name.to_s[/\A([A-Z][\w:]*)\$[^$]+\z/, 1]
          return nil unless name

          model_class = name.safe_constantize
          return nil unless model_class.is_a?(Class) && model_class < ActiveRecord::Base
          return nil unless model_class.respond_to?(:lyra_monitored) && model_class.lyra_monitored

          model_class
        end

        def sort_key(id)
          id.to_s.match?(/\A\d+\z/) ? [0, id.to_i] : [1, id.to_s]
        end
      end
    end
  end

  module Events
    # A reference-link checkpoint: every event of the model up to +position+
    # (event_store_events.id) is linked (Lyra::Projections::ReferenceLinks).
    class ReferenceLinksIndexed < Lyra::Event; end
  end
end
