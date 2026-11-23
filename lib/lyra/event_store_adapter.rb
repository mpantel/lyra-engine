module Lyra
  # An event Lyra had to store could not be stored. #cause is the store's
  # own error.
  #
  # Two failure policies, fixed by mode:
  # - fail-closed (Hijack and every event-sourcing mode): the events are the
  #   record of every change, so the write fails with this error and its
  #   transaction rolls back. Nothing is in the table and nothing in the log.
  # - log-and-continue (Monitor): the table is authoritative, so the write
  #   stands, the failure is logged, and the stream falls behind its row
  #   until Lyra::Repair (bin/rails lyra:repair) brings it back in line.
  #   config.monitor_append_failure = :fail_write gives Monitor the
  #   fail-closed policy instead.
  #
  # There is no in-memory retry queue: the store shares the application's
  # database, so an unreachable store fails the write itself; a queue would
  # be lost with its process, and a retried event could land after a later
  # one in the same stream.
  class EventStoreUnavailableError < StandardError; end

  # Store +events+ (one or several) in +stream_name+, raising
  # EventStoreUnavailableError if the store fails. Every event Lyra writes
  # goes through here.
  def self.append_events(events, stream_name:, store: config.event_store)
    # Each replayed CRUD event first moves its record stream's head, in this
    # transaction: what Hypothesis H excludes is refused here, before anything
    # is stored (Lyra::StreamHeads). Outside the rescue below, so a refusal
    # stays the error the application expects (RecordNotUnique, RecordNotFound).
    if StreamHeads.enabled?
      Array(events).each do |event|
        operation = record_operation(event)
        next unless operation

        # On the record's own database, where Lyra keeps its event store (the
        # same transaction as the append), not necessarily ActiveRecord::Base's.
        model = record_model(event)
        if model
          model.with_connection { StreamHeads.advance!(stream_name, operation, event.event_id, connection: _1) }
        else
          StreamHeads.advance!(stream_name, operation, event.event_id)
        end
      end
    end
    stored = store_events(events, stream_name: stream_name, store: store)
    note_own_writes(events) if Projections::LazyProjection.active?
    stored
  end

  # ES-Lazy, design c: the records this transaction appended events of, which
  # a catch-up on a connection of its own cannot see before the commit, so the
  # transaction's own reads replay them (LazyProjection.own_write!).
  def self.note_own_writes(events)
    Array(events).each do |event|
      next unless record_operation(event)

      model = record_model(event) or next
      data = event.data
      Projections::LazyProjection.own_write!(model, data[:model_id] || data["model_id"], event.event_id)
    end
  end
  private_class_method :note_own_writes

  # The replayed CRUD operation of a record's event (Lyra::EventData), or nil
  # for any other event: domain events added with also:, links, erasures,
  # access-log and rights events.
  def self.record_operation(event)
    data = event.data.is_a?(Hash) ? event.data : {}
    return nil if (data[:model_class] || data["model_class"]).nil? || (data[:model_id] || data["model_id"]).nil?

    Lyra::Event.operation_of(event)
  end

  # The Active Record class an event of a record names, or nil.
  def self.record_model(event)
    data = event.data.is_a?(Hash) ? event.data : {}
    klass = (data[:model_class] || data["model_class"]).to_s.safe_constantize
    klass if klass.is_a?(Class) && klass < ActiveRecord::Base
  end

  def self.store_events(events, stream_name:, store:)
    # Encrypted attributes go to the log as ciphertext, as they go to the row.
    Array(events).each { |event| EncryptedAttributes.seal!(event) }
    store.publish(events, stream_name: stream_name)
    Projections::ReferenceLinks.after_append(events, stream_name, store)
  rescue EventStoreUnavailableError
    raise
  rescue => e
    raise EventStoreUnavailableError, "could not store events in #{stream_name}: #{e.class}: #{e.message}"
  end
  private_class_method :store_events

  # Create one of Lyra's own tables (+name+, defined by the block, given a
  # connection) so that it outlives the caller's transaction. Created inside
  # an open transaction, the table vanished when that transaction rolled back
  # (a failed request, every transactional test) while Lyra remembered it as
  # created, and every later use failed on a missing table. With a
  # transaction open, the table is created on a connection of its own, which
  # commits at once.
  #
  # Two threads or processes can both find the table missing and both create
  # it; the second CREATE then fails (PostgreSQL: a unique violation on
  # pg_type), and the write that triggered it failed with it (the full BPI
  # 2017 replay under ES-Lazy, two threads, lost one write this way). The
  # definition runs in one transaction, so a table that exists is complete,
  # and a failure is ignored once the table exists: someone else made it.
  def self.create_own_table(connection, name, &definition)
    return if connection.table_exists?(name)
    return create_own_table_on(connection, name, &definition) unless connection.transaction_open?

    own = connection.pool.db_config.new_connection
    begin
      create_own_table_on(own, name, &definition) unless own.table_exists?(name)
    ensure
      own.disconnect!
    end
  end

  def self.create_own_table_on(connection, name)
    connection.transaction(requires_new: true) { yield(connection) }
  rescue ActiveRecord::StatementInvalid
    raise unless connection.table_exists?(name)
  end
  private_class_method :create_own_table_on

  # Add to Lyra's own table +name+ the +columns+ (name => [type, options]) it
  # lacks, as when an earlier version created it. Like create_own_table, outside
  # the caller's transaction (on a connection of its own when one is open), so a
  # rollback of the caller's work cannot take a column back while Lyra goes on
  # as if it were there; and safely when two processes add the same column.
  def self.add_own_columns(connection, name, columns)
    missing = columns.reject { |column, _| connection.column_exists?(name, column) }
    return if missing.empty?
    return add_own_columns_on(connection, name, missing) unless connection.transaction_open?

    own = connection.pool.db_config.new_connection
    begin
      add_own_columns_on(own, name, missing)
    ensure
      own.disconnect!
    end
    connection.schema_cache.clear_data_source_cache!(name.to_s)
  end

  def self.add_own_columns_on(connection, name, columns)
    columns.each do |column, (type, options)|
      connection.add_column(name, column, type, **(options || {}), if_not_exists: true)
    rescue ActiveRecord::StatementInvalid
      raise unless connection.column_exists?(name, column)
    end
  end
  private_class_method :add_own_columns_on

end
