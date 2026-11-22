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
    # An event that sets a column of one of the model's unique indexes
    # (UniqueIndexes) is linked the same way into a value stream,
    # "Model!column$<digest>", named by a digest of the value as the index
    # compares it, never by the value itself (an email, an IBAN): the
    # unique-index check of ES-NoProj's, ES-Async's and ES-Lazy's writes
    # reads it (record_ids_in). The checkpoint names the columns whose value
    # streams it covers; one stored
    # before a column was indexed (or before 1.0.0) is caught up from the
    # first event.
    #
    # A lookup by that key reads the reference stream for candidates, rebuilds
    # each with CachedProjection.find and keeps the records that still match:
    # a child moved to another parent stays linked under the old one (streams
    # are append-only), and the match against its current state drops it. A
    # record that matches now has an event that set the key to the value, so
    # the candidates include every match and the answer is exact.
    #
    # Completeness. Links are written while config.reference_links says so
    # (:auto, the default: in ES-NoProj only, so no other mode pays for them;
    # the value streams also in ES-Async and ES-Lazy, whose unique-index
    # check reads them, values_enabled?: there a model without a unique
    # index links nothing, and the foreign keys' checkpoint is left where
    # it was).
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

        # Whether events are linked into their value streams as they are
        # stored (UniqueIndexes: the columns of a model's unique indexes):
        # wherever all links are (enabled?), and in ES-Async and ES-Lazy, whose
        # unique-index check reads the value streams too (their tables lag
        # the event store), while config.reference_links is not false. Only
        # the value streams there: the foreign-key links serve ES-NoProj's
        # reads, which those modes do not make, so a model without a unique
        # index links nothing. ES-Sync checks its table.
        def values_enabled?
          return true if enabled?

          !(Lyra.config.reference_links == false || Lyra.config.reference_links.nil?) &&
            Lyra.event_sourcing_mode? && %i[async lazy].include?(Lyra.config.projection_mode)
        end

        # Named after the class that owns the table (the STI base class), as
        # the record streams are (Lyra.stream_name).
        def stream_name(model_class, foreign_key, value)
          "#{Lyra.stream_owner_name(model_class)}.#{foreign_key}$#{value}"
        end

        # Called by Lyra.append_events after +events+ are stored in
        # +stream_name+: link those that set a foreign key, or, with linking
        # off, note that the model's links fell behind in this process. In
        # ES-Async and ES-Lazy (values_enabled? only) the events that set a
        # column of a unique index are linked into its value streams, and the
        # foreign keys are noted as behind.
        def after_append(events, stream_name, store)
          linking = enabled?
          values = !linking && values_enabled?
          # With linking off, only a model this process took for linked needs
          # noting; otherwise nothing is done, so other modes pay nothing.
          return if !linking && !values && MUTEX.synchronize { ready.empty? }

          model_class = model_for_stream(stream_name)
          return unless model_class

          events = Array(events)
          if linking
            # Columns new to this process (UniqueIndexes.facts): linked from the
            # first event, before this write's own links.
            catch_up(model_class) if unlinked?(model_class)
            link_events(events, model_class, store)
            return
          end
          if values && !UniqueIndexes.columns(model_class).empty?
            catch_up(model_class) if unlinked?(model_class)
            link_events(events, model_class, store, keys: false)
          end
          if values
            # Only a model this process took for linked by its foreign keys
            # (in ES-NoProj, earlier) needs noting.
            return unless MUTEX.synchronize { ready.any? { _1.end_with?("|k") } }

            forget_ready(model_class, keys_only: true) if events.any? { |event| reference_values(model_class, event).any? }
          elsif MUTEX.synchronize { ready.empty? }
            nil
          elsif events.any? { |event| link_streams(model_class, event).any? }
            forget_ready(model_class)
          end
        end

        # Attribute hashes of the records of +model_class+ that match
        # +conditions+, found through a reference stream; nil when the
        # conditions name no single foreign-key value (then the caller
        # considers every record). The caller still applies +conditions+.
        # Under single-table inheritance the links are the table's: kept and
        # looked up for the base class, with its foreign keys (a key only a
        # subclass declares is not indexed, and the caller loads every record);
        # CachedProjection.find_many keeps the records of +model_class+.
        def lookup(model_class, conditions)
          return nil unless enabled? && conditions.is_a?(Hash)

          table = owner(model_class)
          indexed = indexed_conditions(table, conditions)
          return nil if indexed.empty?

          # Without the links caught up (another thread is linking), every
          # record is considered.
          return nil unless catch_up(table)

          # Every condition on an indexed key narrows the candidates: a record
          # that matches them all is in each key's stream, so the streams are
          # intersected (stock_location_id and variant_id together name one
          # stock item, where the location alone names all of them).
          ids = indexed.map { |key, value| candidate_ids(table, key, value) }.reduce(:&)
          records = CachedProjection.find_many(model_class, ids)
          records.sort_by { |attrs| sort_key(attrs[model_class.primary_key.to_s]) }
        end

        # Link the events stored since the model's checkpoint, once per
        # process (and again after an append made while linking was off).
        # Returns the number of events linked.
        #
        # Inside an open transaction (a dependent lookup during a destroy) it
        # runs on a connection of its own, which commits at once: links and
        # checkpoint written in the caller's transaction would vanish with a
        # rollback while this process took the model for linked. Where no
        # second connection can be had (a pinned test connection, a pool with
        # none free) it runs in the caller's transaction, and the model counts
        # as linked only once that transaction commits (Lyra::OwnConnection).
        #
        # One thread per model and process catches up. A caller never waits
        # for it, nor for the catch-up's advisory lock, nor for a connection
        # (unless +wait+: an explicit catch-up, ModeTransition's, the rake
        # task's): when another thread or process is catching up, or the pool
        # has no connection free and the lock is not to be had in the
        # caller's transaction, it returns nil and the caller answers without
        # the links (a lookup from every record). A caller that waited held
        # its transaction, and its locks, while it did: with every connection
        # of the pool taken by writers of a model's first use, the writer
        # that caught up inline kept the advisory lock until it committed,
        # and called catch_up again in the same write, waiting on the Ruby
        # mutex of a thread whose connection waited on that lock; PostgreSQL
        # could not see the cycle, and every writer hung. A thread that
        # caught up inline takes the model for linked until its transaction
        # ends; other threads, once it commits.
        #
        # Returns the number of events linked, 0 when there was nothing to
        # do, nil when it did not catch up.
        def catch_up(model_class, force: false, wait: force)
          model_class = owner(model_class)
          return 0 if !force && (ready?(model_class) || caught_up_here?(model_class))

          mutex = lock_for(model_class)
          if wait
            mutex.lock
          elsif !mutex.try_lock
            return nil
          end
          begin
            return 0 if !force && (ready?(model_class) || caught_up_here?(model_class))

            key = ready_key(model_class, keys: force || enabled?)
            unlinked = take_unlinked(model_class)
            inline = false
            begin
              linked = Lyra::OwnConnection.run(wait_for_connection: wait) do |in_caller_transaction|
                inline = in_caller_transaction
                link_and_checkpoint(model_class, force, unlinked, wait: wait)
              end
            rescue StandardError
              unlinked!(model_class, unlinked) if unlinked.any?
              raise
            end
            if linked.nil?
              unlinked!(model_class, unlinked) if unlinked.any?
              return nil
            end
            mark_ready = -> { MUTEX.synchronize { ready << key } }
            if inline
              caught_up_here!(model_class, key)
              Lyra::OwnConnection.after_commit(&mark_ready)
            else
              mark_ready.call
            end
            linked
          ensure
            mutex.unlock
          end
        end

        # The columns of +model_class+'s unique indexes whose value streams may
        # miss events (new to this process: UniqueIndexes.facts): its next
        # catch-up links them from the first event.
        def unlinked!(model_class, columns)
          name = owner(model_class).name
          MUTEX.synchronize do
            @unlinked ||= {}
            @unlinked[name] = (@unlinked[name] || []) | columns.map(&:to_s)
          end
        end

        # Link every value stream of +model_class+ again, from the first event:
        # after a rolling deploy in which processes running a Lyra without value
        # streams, or reading the indexes before a migration added one, wrote
        # (bin/rails lyra:link_values).
        def relink_values!(model_class)
          table = owner(model_class)
          unlinked!(table, UniqueIndexes.columns(table))
          catch_up(table, wait: true)
        end

        # The ids of the records whose events are linked in every one of
        # +streams+ could be (a superset): those of the stream with the
        # fewest links, whose events are read (each names its record:
        # model_id); none when one of them has no link. One query when no
        # event set the value (two for several streams), one more for the
        # events otherwise. For the unique-index check (UniqueIndexes): its
        # value streams.
        def record_ids_in(model_class, streams)
          stream = streams.one? ? streams.first : fewest_links(streams)
          return [] unless stream

          # Never from the query cache: read under the value's lock, which may
          # have waited for a writer that linked the value since.
          event_ids = ActiveRecord::Base.with_connection do |connection|
            connection.uncached do
              connection.select_values("SELECT event_id FROM event_store_events_in_streams WHERE stream = #{connection.quote(stream)}")
            end
          end
          return [] if event_ids.empty?

          events = Lyra.config.event_store.read.events(event_ids.uniq).to_a
          ids = events.map { |event| event.data[:model_id] || event.data["model_id"] }
          return candidate_streams(owner(model_class), stream) if ids.any?(&:nil?) || ids.size < event_ids.uniq.size

          ids.map(&:to_s).uniq
        end

        # The ids of the records whose events are linked in any of +streams+:
        # one query per 1,000 streams, one per 500 events read (each names its
        # record). For a bulk insert's unique-index check (UniqueIndexes
        # .candidate_records).
        def record_ids_in_any(model_class, streams)
          rows = ActiveRecord::Base.with_connection do |connection|
            streams.each_slice(1_000).flat_map do |slice|
              connection.select_rows(
                "SELECT stream, event_id FROM event_store_events_in_streams WHERE stream IN (#{slice.map { connection.quote(_1) }.join(', ')})"
              )
            end
          end
          return [] if rows.empty?

          ids = []
          unnamed = []
          rows.map(&:last).uniq.each_slice(500) do |event_ids|
            events = Lyra.config.event_store.read.events(event_ids).to_a
            events.each do |event|
              id = event.data[:model_id] || event.data["model_id"]
              id.nil? ? unnamed << event.event_id : ids << id.to_s
            end
            unnamed.concat(event_ids - events.map(&:event_id))
          end
          if unnamed.any?
            rows.each { |stream, event_id| ids.concat(candidate_streams(owner(model_class), stream)) if unnamed.include?(event_id) }
          end
          ids.uniq
        end

        # After +events+ were rewritten in place (Lyra::Erasure), their value
        # stream links follow their new data: the links of the values they
        # held are deleted (no digest of an erased value is kept) and those
        # of the values they hold now inserted, where links are written or
        # the events had some (the rewritten events are behind the
        # checkpoint, and no catch-up would link them again).
        def relink_values(events)
          events.group_by { |event| value_owner(event) }.each do |table, rewritten|
            next unless table && !UniqueIndexes.columns(table).empty?

            ActiveRecord::Base.with_connection do |connection|
              pattern = connection.quote("#{ActiveRecord::Base.sanitize_sql_like(Lyra.stream_owner_name(table))}!%")
              ids = rewritten.map { connection.quote(_1.event_id) }.join(", ")
              deleted = connection.exec_delete(
                "DELETE FROM event_store_events_in_streams WHERE event_id IN (#{ids}) AND stream LIKE #{pattern}", "Lyra value links"
              )
              next unless deleted.positive? || values_enabled?

              pairs = rewritten.flat_map { |event| UniqueIndexes.streams_for(table, set_values(event)).map { [_1, event.event_id] } }
              insert_links(connection, pairs) if pairs.any?
            end
          end
        end

        # Forget which models are linked in this process (tests, truncation).
        def reset!
          MUTEX.synchronize do
            @ready = Set.new
            @unlinked = {}
          end
        end

        # Foreign keys of +model_class+ the index covers.
        def foreign_keys(model_class)
          model_class.reflect_on_all_associations(:belongs_to).map { |r| r.foreign_key.to_s }.uniq
        end

        private

        def ready
          @ready ||= Set.new
        end

        def owner(model_class)
          model_class.respond_to?(:base_class) ? model_class.base_class : model_class
        end

        # Linked, in this process, as the model's foreign keys and unique-index
        # columns are now, under the digest key in use: a column added to an
        # index (or a key rotated) makes it not ready again.
        # Where only the value streams are written (values_enabled? without
        # enabled?: ES-Async, ES-Lazy), a model linked with its foreign keys
        # is ready too; the reverse does not hold.
        def ready?(model_class)
          key = ready_key(model_class)
          also = key.end_with?("|v") ? key.sub(/\|v\z/, "|k") : nil
          MUTEX.synchronize { (ready.include?(key) || (also && ready.include?(also))) && !(@unlinked || {}).key?(model_class.name) }
        end

        # This thread caught the model up inline, in the transaction it is in
        # (caught_up_here!): until that transaction ends.
        def caught_up_here?(model_class)
          (Thread.current[:lyra_links_caught_up] || {}).key?(ready_key(model_class))
        end

        def caught_up_here!(model_class, key)
          here = (Thread.current[:lyra_links_caught_up] ||= {})
          here[key] = true
          transaction = model_class.current_transaction
          forget = -> { here.delete(key) }
          transaction.after_commit(&forget)
          transaction.after_rollback(&forget)
        end

        # Ends in "|k" where the foreign keys are linked too (enabled?), "|v"
        # where only the value streams are.
        def ready_key(model_class, keys: enabled?)
          columns = UniqueIndexes.columns(model_class)
          kind = keys ? "k" : "v"
          columns.empty? ? "#{model_class.name}||#{kind}" : "#{model_class.name}|#{columns.join(',')}|#{ValueDigest.key_id}|#{kind}"
        end

        # +keys_only+: the foreign keys fell behind, the value streams did not.
        def forget_ready(model_class, keys_only: false)
          prefix = "#{owner(model_class).name}|"
          MUTEX.synchronize { ready.delete_if { _1.start_with?(prefix) && (!keys_only || _1.end_with?("|k")) } }
        end

        def unlinked?(model_class)
          MUTEX.synchronize { (@unlinked || {}).key?(owner(model_class).name) }
        end

        def take_unlinked(model_class)
          MUTEX.synchronize { (@unlinked || {}).delete(model_class.name) || [] }
        end

        # The per-model lock of #catch_up.
        def lock_for(model_class)
          MUTEX.synchronize { (@locks ||= {})[model_class.name] ||= Mutex.new }
        end

        # The foreign keys from the checkpoint's position; each unique-index
        # column from its own (columns linked under another digest key, or new to
        # this process, from the first event, their old links deleted), so a
        # column added to an index does not make the foreign keys be read again.
        def link_and_checkpoint(model_class, force, unlinked = [], wait: true)
          ActiveRecord::Base.with_connection do |connection|
            ActiveRecord::Base.transaction do
              lock = "#{LOCK}/#{model_class.name}"
              if wait
                Lyra::AdvisoryLock.xact_lock(connection, lock, purpose: "reference links")
              elsif !Lyra::AdvisoryLock.try_xact_lock(connection, lock, purpose: "reference links")
                next nil
              end
              stored = checkpoint_state(model_class)
              position = force ? 0 : stored[:position]
              upto = connection.select_value("SELECT MAX(id) FROM event_store_events").to_i
              next 0 if upto.zero?

              kid = ValueDigest.key_id
              columns = UniqueIndexes.columns(model_class)
              relinked = columns.select do |column|
                entry = stored[:values][column]
                # No entry: linked, if at all, under a key no checkpoint names.
                force || unlinked.include?(column) || entry.nil? || entry["key"] != kid
              end
              from = columns.to_h do |column|
                entry = stored[:values][column]
                [column, relinked.include?(column) || entry.nil? ? 0 : entry["position"].to_i]
              end
              drop_value_links(connection, model_class, relinked) if relinked.any?
              behind = from.select { |_, at| upto > at }
              current = stored[:values].keys.sort == columns.sort
              # The foreign keys where they are linked (enabled?) or in a
              # forced pass (the switch into ES-NoProj); in ES-Async and
              # ES-Lazy the value streams alone, and the keys' position is
              # kept.
              keys = force || enabled?
              next 0 unless (keys && upto > position) || behind.any? || relinked.any? || !current

              # One read of the events behind, for both kinds of link; none
              # for the foreign keys of a model that has none.
              keys_behind = keys && upto > position && foreign_keys(model_class).any? ? position : nil
              linked = keys_behind || behind.any? ? link_since(connection, model_class, keys_behind, behind, upto) : 0
              store_checkpoint(model_class, keys ? [upto, position].max : stored[:position],
                               columns.to_h { [_1, { "position" => upto, "key" => kid }] })
              linked
            end
          end
        end

        # Delete +columns+' value links (a key rotated, a relink).
        def drop_value_links(connection, model_class, columns)
          columns.each do |column|
            pattern = connection.quote("#{ActiveRecord::Base.sanitize_sql_like("#{Lyra.stream_owner_name(model_class)}!#{column}$")}%")
            connection.exec_delete("DELETE FROM event_store_events_in_streams WHERE stream LIKE #{pattern}", "Lyra value links")
          end
        end

        # Link the model's events up to +upto+: those after +keys_from+ (nil:
        # none) into their foreign-key streams (each stream read, the links
        # already there left out), those after each column's position
        # (+behind+: { column => position }) into the column's value streams
        # (500 links per statement, those already there left as they are).
        # The events are read once, 500 at a time.
        def link_since(connection, model_class, keys_from, behind, upto)
          from = [keys_from, *behind.values].compact.min
          prefix = connection.quote("#{ActiveRecord::Base.sanitize_sql_like(Lyra.stream_prefix(model_class))}%")
          rows = connection.select_rows(<<~SQL.squish)
            SELECT e.id, e.event_id FROM event_store_events e
            JOIN event_store_events_in_streams s ON s.event_id = e.event_id
            WHERE s.stream LIKE #{prefix} AND e.id > #{Integer(from)} AND e.id <= #{Integer(upto)}
            ORDER BY e.id
          SQL
          return 0 if rows.empty?

          store = Lyra.config.event_store
          position = rows.to_h { |id, event_id| [event_id, id.to_i] }
          wanted = Hash.new { |h, k| h[k] = [] }
          pairs = []
          position.keys.each_slice(500) do |ids|
            store.read.events(ids).each do |event|
              at = position[event.event_id]
              if keys_from && at > keys_from
                reference_values(model_class, event).each { |key, value| wanted[stream_name(model_class, key, value)] << event.event_id }
              end
              columns = behind.select { |_, column_at| at > column_at }.keys
              next if columns.empty?

              UniqueIndexes.streams_for(model_class, set_values(event).slice(*columns)).each { pairs << [_1, event.event_id] }
            end
          end

          linked = pairs.each_slice(500).sum { |slice| insert_links(connection, slice) }
          wanted.each do |stream, ids|
            present = store.read.stream(stream).to_a.map(&:event_id).to_set
            missing = ids.uniq.reject { present.include?(_1) }
            next if missing.empty?

            store.link(missing, stream_name: stream)
            linked += missing.size
          end
          linked
        end

        # [[key, value], ...] for the conditions that name one value of an
        # indexed foreign key.
        def indexed_conditions(model_class, conditions)
          keys = foreign_keys(model_class)
          conditions.filter_map do |key, value|
            next unless keys.include?(key.to_s)

            value = value.id if value.is_a?(ActiveRecord::Base)
            next unless value.is_a?(Integer) || value.is_a?(String)

            # As the key's type casts it ("5" and 5 name one stream); a value
            # the type binds as NULL ("abc" on an integer key) names none, and
            # is left to the conditions.
            bound = TypedValues.query_value(model_class.type_for_attribute(key.to_s), value)
            [key.to_s, bound] if bound.is_a?(Integer) || bound.is_a?(String)
          end
        end

        # Ids of the records an event of which set +key+ to +value+: the
        # records whose own streams hold the events linked in the reference
        # stream. One query on the stream table; the events are not read.
        def candidate_ids(model_class, key, value)
          candidate_streams(model_class, stream_name(model_class, key, value))
        end

        # Ids of the records whose own streams hold the events linked in
        # +stream+.
        def candidate_streams(model_class, stream)
          ActiveRecord::Base.with_connection do |connection|
            own = Lyra.stream_prefix(model_class)
            connection.select_values(<<~SQL.squish).map { |found| found.delete_prefix(own) }
              SELECT DISTINCT s.stream FROM event_store_events_in_streams l
              JOIN event_store_events_in_streams s
                ON s.event_id = l.event_id AND s.stream LIKE #{connection.quote("#{ActiveRecord::Base.sanitize_sql_like(own)}%")}
              WHERE l.stream = #{connection.quote(stream)}
            SQL
          end
        end

        # Of +streams+, the one with the fewest links; nil when one has
        # none. One query (the stream table's index on the stream).
        def fewest_links(streams)
          counts = ActiveRecord::Base.with_connection do |connection|
            connection.uncached do
              connection.select_rows(<<~SQL.squish).to_h
                SELECT stream, COUNT(*) FROM event_store_events_in_streams
                WHERE stream IN (#{streams.map { connection.quote(_1) }.join(', ')}) GROUP BY stream
              SQL
            end
          end
          return nil if counts.size < streams.uniq.size

          counts.min_by { |_, count| count.to_i }.first
        end

        # The streams +event+ is linked into: one per foreign key it sets
        # (stream_name), and one per value of a unique index's column it sets
        # (UniqueIndexes.streams_for).
        def link_streams(model_class, event)
          references = reference_values(model_class, event).map { |key, value| stream_name(model_class, key, value) }
          return references if UniqueIndexes.columns(model_class).empty?

          references + UniqueIndexes.streams_for(model_class, set_values(event))
        end

        # { foreign key => value } that +event+ sets, for the model's keys.
        def reference_values(model_class, event)
          set_values(event).slice(*foreign_keys(model_class)).compact
        end

        # The monitored table (its stream owner) whose record an event of a
        # write names (its data's model_class), or nil.
        def value_owner(event)
          data = event.data
          name = data.is_a?(Hash) ? (data[:model_class] || data["model_class"]) : nil
          model = name.to_s.safe_constantize
          return nil unless model.is_a?(Class) && model < ActiveRecord::Base && model.respond_to?(:lyra_monitored)

          owner(model)
        end

        # { attribute => value } that +event+ sets: a create's or an
        # import's attributes, an update's new values.
        def set_values(event)
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
          values
        end

        def link_events(events, model_class, store, keys: true)
          values = !UniqueIndexes.columns(model_class).empty?
          events.each do |event|
            if keys
              reference_values(model_class, event).each do |key, value|
                store.link([event.event_id], stream_name: stream_name(model_class, key, value))
              end
            end
            link_values(event, UniqueIndexes.streams_for(model_class, set_values(event))) if values
          end
        end

        # An event just stored, linked into its value streams in one
        # statement: the rows RES's link inserts, without the existence
        # check and the savepoint it takes for each stream (three round
        # trips per stream on every create of a model with a unique index).
        # The stream table is the one every ES-NoProj read queries.
        def link_values(event, streams)
          return if streams.empty?

          ActiveRecord::Base.with_connection { |connection| insert_links(connection, streams.map { [_1, event.event_id] }) }
        end

        # Insert [stream, event id] links, those already there left as they
        # are; returns how many were inserted.
        def insert_links(connection, pairs)
          now = connection.quote(Time.now.utc)
          rows = pairs.map { |stream, event_id| "(#{connection.quote(stream)}, NULL, #{connection.quote(event_id)}, #{now})" }
          connection.exec_update(
            "INSERT INTO event_store_events_in_streams (stream, position, event_id, created_at) " \
            "VALUES #{rows.join(', ')} ON CONFLICT DO NOTHING", "Lyra value links"
          )
        end


        # The position up to which the model's foreign keys are linked.
        def checkpoint(model_class) = checkpoint_state(model_class)[:position]

        # { position: the foreign keys' position, values: { column =>
        # { "position" =>, "key" => the digest key's id } } }, from the model's
        # last checkpoint (values empty for one stored before 1.0.0's value
        # streams).
        def checkpoint_state(model_class)
          last = Lyra.config.event_store.read.stream("#{CHECKPOINT_PREFIX}#{model_class.name}").last
          return { position: 0, values: {} } unless last

          data = last.data
          values = (data[:values] || data["values"] || {}).to_h do |column, entry|
            [column.to_s, entry.to_h.transform_keys(&:to_s)]
          end
          { position: (data[:position] || data["position"]).to_i, values: values }
        rescue RubyEventStore::EventNotFoundInStream
          { position: 0, values: {} }
        end

        def store_checkpoint(model_class, position, values)
          event = Lyra::Events::ReferenceLinksIndexed.new(data: { model_class: model_class.name, position: position, values: values })
          Lyra.config.event_store.publish(event, stream_name: "#{CHECKPOINT_PREFIX}#{model_class.name}")
        end

        # The monitored model a record stream belongs to ("Model$id"), or nil
        # (Lyra's own streams, reference streams, aggregates of no model).
        def model_for_stream(stream_name)
          name = stream_name.to_s[/\A([A-Z][\w:]*)\$[^$]+\z/, 1]
          return nil unless name

          model_class = name.safe_constantize
          return nil unless model_class.is_a?(Class) && model_class < ActiveRecord::Base
          return nil unless model_class.respond_to?(:lyra_monitored)
          # The stream is the table's; it is monitored when its base class is,
          # or any subclass that monitor_with_lyra was given directly.
          return nil unless model_class.lyra_monitored || model_class.descendants.any?(&:lyra_monitored)

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
