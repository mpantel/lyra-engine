# frozen_string_literal: true

require "test_helper"

# An event store whose event_id columns are uuid, as some Rails Event Store
# schemas have them (Solidus's), where Lyra's own tables keep event ids as
# strings. PostgreSQL compares no uuid column with a string column, so every
# query that joins the two must cast (Lyra::StreamHeads, AsyncCheckpoint). The
# suite's own schema keeps event_id as a string, which is how ES-Async's
# rows-behind check could fail on every locking read in Solidus with no test
# failing. Here the event store's tables are in a schema of their own, first in
# the connection's search path, so the shared tables are left as they are.
class UuidEventIdsTest < Minitest::Test
  SCHEMA = "lyra_uuid_events"

  def setup
    skip "Requires Rails and PostgreSQL" unless defined?(ActiveRecord::Base) && connection.adapter_name.match?(/postgres/i)

    @search_path = connection.schema_search_path
    connection.execute("DROP SCHEMA IF EXISTS #{SCHEMA} CASCADE")
    connection.execute("CREATE SCHEMA #{SCHEMA}")
    connection.execute(<<~SQL)
      CREATE TABLE #{SCHEMA}.event_store_events (
        id bigserial PRIMARY KEY, event_id uuid NOT NULL UNIQUE, event_type varchar NOT NULL,
        metadata bytea, data bytea NOT NULL, created_at timestamp(6) NOT NULL, valid_at timestamp(6));
      CREATE TABLE #{SCHEMA}.event_store_events_in_streams (
        id bigserial PRIMARY KEY, stream varchar NOT NULL, position integer, event_id uuid NOT NULL,
        created_at timestamp(6) NOT NULL);
      CREATE UNIQUE INDEX ON #{SCHEMA}.event_store_events_in_streams (stream, event_id);
      CREATE UNIQUE INDEX ON #{SCHEMA}.event_store_events_in_streams (stream, position);
      CREATE INDEX ON #{SCHEMA}.event_store_events_in_streams (stream, id);
      CREATE TABLE #{SCHEMA}.uuid_items (id bigserial PRIMARY KEY, n integer NOT NULL DEFAULT 0,
        created_at timestamp(6) NOT NULL, updated_at timestamp(6) NOT NULL);
    SQL
    use_schema("#{SCHEMA}, #{@search_path}")

    Object.send(:remove_const, :UuidItem) if Object.const_defined?(:UuidItem)
    Object.const_set(:UuidItem, Class.new(ActiveRecord::Base) { self.table_name = "uuid_items" })
    UuidItem.include Lyra::Interceptors::CrudInterceptor
    UuidItem.monitor_with_lyra
    Lyra.config.monitor_model(UuidItem)
  end

  def teardown
    return unless @search_path

    ActiveJob::Base.queue_adapter = @previous_adapter if @previous_adapter
    Lyra.reset_config!
    use_schema(@search_path)
    connection.execute("DROP SCHEMA IF EXISTS #{SCHEMA} CASCADE")
    Object.send(:remove_const, :UuidItem) if Object.const_defined?(:UuidItem)
  end

  def test_the_event_store_here_has_uuid_event_ids
    assert_equal :uuid, connection.columns("event_store_events_in_streams").find { _1.name == "event_id" }.type
  end

  # The stream heads match their event across the two types (create, update,
  # destroy, and a second create refused).
  def test_stream_heads_in_es_sync
    Lyra.config.enable_event_sourcing!
    Lyra.config.projection_mode = :sync
    item = UuidItem.create!(n: 1)
    item.update!(n: 2)
    assert_raises(Lyra::StreamHeads::LiveKeyError) { UuidItem.create!(id: item.id, n: 9) }
    item.destroy!

    assert_equal %i[created updated destroyed], operations(item.id)
  end

  # ES-Async's locking read checks which rows are behind their jobs: the query
  # that failed on uuid event ids.
  def test_a_locking_read_in_es_async
    Lyra.config.enable_event_sourcing!
    Lyra.config.projection_mode = :async
    Lyra.config.async_projections_inline = false
    @previous_adapter = ActiveJob::Base.queue_adapter
    adapter = ActiveJob::QueueAdapters::TestAdapter.new
    adapter.perform_enqueued_jobs = false
    ActiveJob::Base.queue_adapter = adapter
    item = UuidItem.create!(n: 0)
    run_jobs(adapter)
    UuidItem.find(item.id).update!(n: 1) # its job held: the row lags
    reader = UuidItem.find(item.id)
    reader.with_lock { reader.update!(n: reader.n + 1) }
    run_jobs(adapter)

    assert_equal 2, connection.select_value("SELECT n FROM uuid_items WHERE id = #{Integer(item.id)}").to_i
  end

  # ES-Lazy's checkpoint keeps the id of the event at its position, and
  # compares it with the store's.
  def test_the_es_lazy_checkpoint
    Lyra.config.enable_event_sourcing!
    Lyra.config.projection_mode = :lazy
    item = UuidItem.create!(n: 3)
    assert_equal 3, UuidItem.find(item.id).n
    UuidItem.find(item.id).update!(n: 4)
    assert_equal 4, UuidItem.find(item.id).n
  end

  private

  # Point the connection at +path+, and forget what Lyra and Active Record
  # remembered of the tables found on the old one.
  def use_schema(path)
    connection.schema_search_path = path
    connection.schema_cache.clear!
    ActiveRecord::Base.descendants.each { _1.reset_column_information if _1.respond_to?(:reset_column_information) }
    [Lyra::StreamHeads, Lyra::Projections::AsyncCheckpoint, Lyra::Projections::LazyProjection].each do |mod|
      mod.instance_variable_set(:@event_match, nil)
      mod.instance_variable_set(:@table_ready, nil)
    end
    Lyra::Projections::LazyProjection.reset!
  end

  def run_jobs(adapter)
    until (jobs = adapter.enqueued_jobs.dup).empty?
      adapter.enqueued_jobs.clear
      jobs.each { |job| ActiveJob::Base.execute(job.stringify_keys) }
    end
  end

  def operations(id)
    Lyra.config.event_store.read.stream(Lyra.stream_name(UuidItem, id)).to_a.filter_map { Lyra::Event.operation_of(_1) }
  end

  def connection = ActiveRecord::Base.connection
end
