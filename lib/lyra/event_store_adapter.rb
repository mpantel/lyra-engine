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
    store.publish(events, stream_name: stream_name)
  rescue EventStoreUnavailableError
    raise
  rescue => e
    raise EventStoreUnavailableError, "could not store events in #{stream_name}: #{e.class}: #{e.message}"
  end

  # Create one of Lyra's own tables (+name+, defined by the block, given a
  # connection) so that it outlives the caller's transaction. Created inside
  # an open transaction, the table vanished when that transaction rolled back
  # (a failed request, every transactional test) while Lyra remembered it as
  # created, and every later use failed on a missing table. With a
  # transaction open, the table is created on a connection of its own, which
  # commits at once.
  def self.create_own_table(connection, name)
    return if connection.table_exists?(name)
    return yield(connection) unless connection.transaction_open?

    own = connection.pool.db_config.new_connection
    begin
      yield(own) unless own.table_exists?(name)
    ensure
      own.disconnect!
    end
  end

end
