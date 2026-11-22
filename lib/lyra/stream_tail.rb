# frozen_string_literal: true

module Lyra
  # Whether a record's stream says it was destroyed: the question
  # CrudInterceptor#lyra_lock_aggregate_unless_destroyed! asks, under the lock
  # on the aggregate, before every update and destroy that the record's row
  # lock does not cover (ES-NoProj, ES-Async, ES-Lazy).
  #
  # The record was destroyed when the stream's last replayed event (the last
  # one Lyra::Event.operation_of gives an operation) is a destroy. Events that
  # are not replayed can follow a destroy: an additional domain event
  # (also:, replay: false), an ErasureApplied, a has_and_belongs_to_many link
  # (AssociationLinked) linked into the stream. Before, the check read only
  # the last event, through Rails Event Store, and let a stale copy write the
  # record again after any of them.
  #
  # The operation is recorded in the event's data, not in its type: a
  # destroy can be stored under any name (custom event names, domain events).
  # So the type alone cannot answer. The stream's events are read backward
  # with a query of their id, type and stored data, deserializing nothing,
  # and skipping in SQL the types Lyra never replays (NEVER_REPLAYED: links
  # and erasure records, which a popular record's stream can hold by the
  # hundred). The first event read decides at once when it is positively a
  # replayed create, import or update:
  #
  # - its type ends in Created, Updated or Imported, so operation_of gives it
  #   an operation (the recorded one, else the name's);
  # - its data holds no destroy's operation ("operation" followed by destroy
  #   or deleted, or by a YAML tag, anchor or alias), so the recorded one is
  #   not a destroy;
  # - its data holds no "replay" followed by false.
  #
  # That is the hot path, one query: an update after a create or an update.
  # Data stored in a json or jsonb column comes back as a Hash, and
  # operation_of decides from it directly. Any other event is read through
  # Rails Event Store, by its id, and operation_of decides; one that is not
  # replayed (an additional domain event) sends the check to the event
  # before it. The query reads one event, then pages of PAGE.
  #
  # The shortcut needs RubyEventStore::ActiveRecord::EventRepository (whose
  # models give the tables and the connection), RES's default mapper (one
  # that transforms records on load could change the type or the data that
  # operation_of sees) and a serializer that writes the operation as text
  # next to its key: YAML, JSON or Lyra::EventSerializer. The query is tried
  # once, in the first check, in a savepoint where a transaction is open, so
  # that a failure cannot abort the write. With any other repository, mapper
  # or serializer, or a query that fails (a Rails Event Store whose internals
  # or tables changed), every check reads the stream through Rails Event
  # Store.
  module StreamTail
    # A possible destroy's recorded operation, as YAML (":operation:
    # :destroyed", "operation: !ruby/string:... destroyed", "operation: &1
    # ...", "operation: *1"), JSON ('"operation":"destroyed"') and
    # Lyra::EventSerializer write it: every value Lyra::Event.recorded_operation
    # maps to :destroyed contains "destroy" or "deleted". A match elsewhere in
    # the data (a column named operation, say) only sends the check to the
    # full read.
    MAY_BE_DESTROY = /operation[^0-9A-Za-z!&*]{1,8}(?:destroy|deleted|[!&*])/
    # An additional domain event, never replayed (Lyra::DomainEvents).
    NOT_REPLAYED = /replay[^0-9A-Za-z]{1,8}false/
    # Types operation_of always gives an operation, when their data records
    # none (Lyra::Event.operation_from_name), Destroyed apart.
    REPLAYED_TYPE = /(?:Created|Updated|Imported)\z/
    # Lyra's own events that are never replayed: their data records no
    # operation Lyra::Event.recorded_operation knows ("linked", "unlinked",
    # or none) and their names end in none of operation_from_name's
    # suffixes. No model may store a write under these names
    # (Lyra::DomainEvents, ModelConfig's event_mapping refuse them).
    NEVER_REPLAYED = %w[
      Lyra::Events::AssociationLinked Lyra::Events::AssociationUnlinked Lyra::Events::ErasureApplied
    ].freeze
    # Events read per page after the first.
    PAGE = 50

    # Where the events are read from.
    Source = Struct.new(:stream_klass, :select_from)
    # What operation_of needs of an event: its type and its data.
    Tail = Struct.new(:event_type, :data)

    CONNECTION_ERRORS = [
      ActiveRecord::ConnectionNotEstablished, ActiveRecord::ConnectionTimeoutError,
      (ActiveRecord::ConnectionFailed if defined?(ActiveRecord::ConnectionFailed))
    ].compact.freeze
    RESOLVING = Mutex.new

    class << self
      # True when the last replayed event of +stream_name+ is a destroy. False
      # for an empty stream, or one with no replayed event.
      def destroyed?(stream_name, store = Lyra.config.event_store)
        source = source_for(store)
        return destroyed_by_reading?(stream_name, store) unless source

        before = nil
        limit = 1
        loop do
          rows = event_rows(source, stream_name, before: before, limit: limit)
          rows.each do |_, event_id, type, data|
            operation = operation_of_row(store, event_id, type, data)
            return operation == :destroyed if operation
          end
          return false if rows.size < limit

          before = rows.last.first
          limit = PAGE
        end
      end

      # Of +stream_names+, those whose last replayed event is a destroy, as
      # destroyed? answers for each. On PostgreSQL with the shortcut's source,
      # the last event of every stream is read in one query (per BATCH
      # streams); a stream whose last event does not decide on its own (not
      # positively a replayed create, import or update, nor data that
      # operation_of decides) is asked with destroyed? as before. Elsewhere,
      # destroyed? for each.
      def destroyed_streams(stream_names, store = Lyra.config.event_store)
        names = stream_names.uniq
        return [] if names.empty?

        source = source_for(store)
        batched = source && source.stream_klass.with_connection { _1.adapter_name.match?(/postgres/i) }
        return names.select { destroyed?(_1, store) } unless batched

        destroyed = []
        names.each_slice(BATCH) do |slice|
          last = last_rows(source, slice)
          slice.each do |name|
            row = last[name]
            next unless row # no replayed-kind event: not destroyed, as destroyed? answers

            _, event_id, type, data = row
            operation = data.is_a?(Hash) ? Lyra::Event.operation_of(Tail.new(type, data)) : nil
            operation ||= :updated if replayed_non_destroy?(type, data)
            decided = operation ? operation == :destroyed : destroyed?(name, store)
            destroyed << name if decided
          end
        end
        destroyed
      end

      # Streams read per query by destroyed_streams.
      BATCH = 500

      # { stream => [link id, event_id, event_type, stored data] } of the
      # last event of each of +names+ that has one, the NEVER_REPLAYED types
      # left out.
      def last_rows(source, names)
        source.stream_klass.with_connection do |connection|
          list = names.map { connection.quote(_1) }.join(", ")
          sql = source.select_from.sub(/\ASELECT /, "SELECT DISTINCT ON (s.stream) s.stream, ") +
                " WHERE s.stream IN (#{list}) ORDER BY s.stream, s.id DESC"
          rows = connection.uncached { connection.select_all(sql, "Lyra stream tail") }.cast_values
          rows.to_h { |stream, *rest| [stream, rest] }
        end
      end
      private :last_rows

      # The answer read through Rails Event Store: the stream backward, from
      # its last event, to the first replayed event.
      def destroyed_by_reading?(stream_name, store = Lyra.config.event_store)
        before = nil
        limit = 1
        loop do
          spec = store.read.stream(stream_name).backward.limit(limit)
          spec = spec.from(before) if before
          events = spec.to_a
          events.each do |event|
            operation = Lyra::Event.operation_of(event)
            return operation == :destroyed if operation
          end
          return false if events.size < limit

          before = events.last.event_id
          limit = PAGE
        end
      end

      # [[link id, event_id, event_type, stored data], ...] for the stream's
      # events before link +before+ (all, if nil), newest first, the
      # NEVER_REPLAYED types left out. Newest is what Rails Event Store's
      # backward read returns first: the link with the highest id (Lyra
      # appends with expected_version :any, which records no position).
      def event_rows(source, stream_name, before: nil, limit: 1)
        source.stream_klass.with_connection do |connection|
          sql = +"#{source.select_from} WHERE s.stream = #{connection.quote(stream_name)}"
          sql << " AND s.id < #{Integer(before)}" if before
          sql << " ORDER BY s.id DESC LIMIT #{Integer(limit)}"
          # Read under the lock the caller holds, never from the query cache.
          connection.uncached { connection.select_all(sql, "Lyra stream tail") }.cast_values
        end
      end

      # The operation the event has when replayed, or nil (not replayed).
      def operation_of_row(store, event_id, type, data)
        return Lyra::Event.operation_of(Tail.new(type, data)) if data.is_a?(Hash)
        # Positively replayed, and not a destroy: which one does not matter.
        return :updated if replayed_non_destroy?(type, data)

        Lyra::Event.operation_of(store.read.event!(event_id))
      end

      # True when the stored event is positively a replayed create, import
      # or update (see the module comment).
      def replayed_non_destroy?(type, data)
        return false unless data.is_a?(String) && REPLAYED_TYPE.match?(type)

        data = data.b unless data.encoding == Encoding::BINARY
        !MAY_BE_DESTROY.match?(data) && !NOT_REPLAYED.match?(data)
      end

      # Whether a write may be stored under +event_name+ (a generated
      # Lyra::Events name, or a class's name): not under one of
      # NEVER_REPLAYED's.
      def reserved_name?(event_name)
        name = event_name.to_s
        NEVER_REPLAYED.include?(name) || NEVER_REPLAYED.include?("Lyra::Events::#{name.gsub('::', '')}")
      end

      # The Source for +store+, or nil when the shortcut does not apply.
      # Resolved once per event store, by one thread at a time. A store that
      # could not be resolved for want of a connection is tried again on the
      # next check; any other failure is final for that store, and logged
      # once.
      def source_for(store)
        cached = @source
        return cached.last if cached && cached.first.equal?(store)

        RESOLVING.synchronize do
          cached = @source
          next cached.last if cached && cached.first.equal?(store)

          source = resolve(store)
          @source = [store, source]
          source
        rescue *CONNECTION_ERRORS => e
          warn_once(:connection, e)
          nil
        rescue StandardError => e
          warn_once(:resolve, e)
          @source = [store, nil]
          nil
        end
      end

      def reset!
        @source = nil
        @warned = nil
      end

      private

      def resolve(store)
        repository = active_record_repository(store)
        return nil unless repository && default_mapper?(store) &&
                          literal_serializer?(repository.instance_variable_get(:@serializer))

        # The repository's own models: their tables and their connection,
        # which is the write's (the default models inherit ActiveRecord::Base).
        event_klass = repository.send(:event_klass)
        stream_klass = repository.send(:stream_klass)
        select_from = stream_klass.with_connection do |connection|
          select_from(connection, stream_klass, event_klass).tap { probe!(connection, _1) }
        end
        Source.new(stream_klass, select_from.freeze)
      end

      def select_from(connection, stream_klass, event_klass)
        skipped = NEVER_REPLAYED.map { connection.quote(_1) }.join(", ")
        "SELECT s.id, e.event_id, e.event_type, e.data FROM #{connection.quote_table_name(stream_klass.table_name)} s " \
          "JOIN #{connection.quote_table_name(event_klass.table_name)} e ON e.event_id = s.event_id " \
          "AND e.event_type NOT IN (#{skipped})"
      end

      # Run the query once on the write's connection, in a savepoint when a
      # transaction is open, so that its failure cannot abort the write.
      # Raises if the query fails.
      def probe!(connection, select_from)
        probe = -> { connection.select_all("#{select_from} WHERE s.stream = '' LIMIT 0", "Lyra stream tail probe") }
        connection.transaction_open? ? connection.transaction(requires_new: true) { probe.call } : probe.call
      end

      # The ActiveRecord::EventRepository behind a Rails Event Store client
      # (RailsEventStore::Client wraps it in an InstrumentedRepository), or nil.
      def active_record_repository(store)
        return nil unless defined?(RubyEventStore::ActiveRecord::EventRepository)

        repository = store.instance_variable_get(:@repository)
        while defined?(RubyEventStore::InstrumentedRepository) && repository.is_a?(RubyEventStore::InstrumentedRepository)
          repository = repository.instance_variable_get(:@repository)
        end
        repository.is_a?(RubyEventStore::ActiveRecord::EventRepository) ? repository : nil
      end

      # True when the client's mapper is RES's default, under the wrappers
      # Rails Event Store adds (InstrumentedBatchMapper, BatchMapper,
      # InstrumentedMapper).
      def default_mapper?(store)
        mapper = store.instance_variable_get(:@mapper)
        wrappers = [RubyEventStore::Mappers::InstrumentedBatchMapper, RubyEventStore::Mappers::BatchMapper,
                    RubyEventStore::Mappers::InstrumentedMapper]
        mapper = mapper.instance_variable_get(:@mapper) while wrappers.any? { mapper.instance_of?(_1) }
        mapper.instance_of?(RubyEventStore::Mappers::Default)
      end

      def literal_serializer?(serializer)
        serializer.equal?(::JSON) || serializer.equal?(Lyra::EventSerializer) ||
          serializer.equal?(RubyEventStore::Serializers::YAML)
      end

      def warn_once(kind, error)
        @warned ||= {}
        return if @warned[kind]

        @warned[kind] = true
        message = "Lyra: the destroyed check reads through Rails Event Store - #{error.class}: #{error.message}"
        defined?(Rails) && Rails.logger ? Rails.logger.warn(message) : Kernel.warn(message)
      end
    end
  end
end
