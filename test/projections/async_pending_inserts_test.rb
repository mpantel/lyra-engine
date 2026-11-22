# frozen_string_literal: true

require "test_helper"

# insert_all, insert_all! and upsert_all of the key of a record whose last
# event is still waiting for its ES-Async projection job. Monitor's ON
# CONFLICT meets the row the log says is there: a destroyed record has none
# and is created again (a Created after the Destroyed, with the values given
# and the column defaults), a live one conflicts (insert_all skips it,
# insert_all! raises ActiveRecord::RecordNotUnique, upsert_all updates it).
# ES-Async met the row its job had not written yet: the destroyed record's
# row was skipped (insert_all) or the upsert refused, and a record whose
# create was pending, with no row, was inserted with a second Created on its
# stream. The rows of the keys written are now brought up to date with their
# streams first, under the records' aggregate locks
# (AsyncProjectionJob.project_pending), and the pending jobs find nothing
# left to apply. Each scenario runs in every mode, ES-Async with its jobs
# held, and ends as in Monitor; the jobs, run afterwards, leave the table as
# the log has it.
class AsyncPendingInsertsTest < Minitest::Test
  # Runs the block a thread asks for (Thread.current[:api_before_locks])
  # just before a write takes its records' aggregate locks.
  module BeforeLocks
    def lock_streams!(*args, **kwargs)
      if (hook = Thread.current[:api_before_locks])
        Thread.current[:api_before_locks] = nil
        hook.call
      end
      super
    end
  end
  Lyra::BypassEvents.singleton_class.prepend(BeforeLocks)

  # Pauses a projection job once it holds its stream's lock and its row, on
  # a thread that asks for it (Thread.current[:api_pause_projection]); lists
  # the streams projected where asked (Thread.current[:api_projected]).
  module PauseProjection
    def project_stream(*args, **kwargs)
      Thread.current[:api_projected]&.push(args[1])
      if (pause = Thread.current[:api_pause_projection])
        Thread.current[:api_pause_projection] = nil
        pause[:paused] << true
        pause[:go].pop
      end
      super
    end
  end
  Lyra::Projections::AsyncProjectionJob.singleton_class.prepend(PauseProjection)

  TABLE = "lyra_api_items"
  MODES = %i[monitor hijack es_sync es_async es_noproj es_lazy].freeze
  WRITES = %i[insert_all insert_all! upsert_all].freeze

  def setup
    skip "Requires Rails and PostgreSQL" unless defined?(ActiveRecord::Base) && connection.adapter_name.match?(/postgres/i)

    connection.create_table(TABLE, force: true) do |t|
      t.string :code
      t.string :tag, default: "dflt"
      t.timestamps
    end
    Object.send(:remove_const, :ApiItem) if Object.const_defined?(:ApiItem)
    Object.const_set(:ApiItem, Class.new(ActiveRecord::Base) do
      self.table_name = TABLE
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
    end)
    ApiItem.reset_column_information
    Lyra.config.monitor_model(ApiItem)
    clean
  end

  def teardown
    return unless Object.const_defined?(:ApiItem)

    ActiveJob::Base.queue_adapter = @previous_adapter if @previous_adapter
    Lyra.reset_config!
    clean
    connection.drop_table(TABLE, if_exists: true)
  end

  WRITES.each do |write|
    # The record was destroyed, its row still in the table (ES-Async) while
    # the destroy's job waits.
    define_method("test_#{write.to_s.delete('!')}#{'_bang' if write.end_with?('!')}_of_a_destroyed_record_as_in_monitor") do
      outcomes = MODES.filter_map do |mode|
        next if write == :upsert_all && mode == :es_noproj # refused there

        [mode, destroyed_scenario(mode, write)]
      end.to_h

      monitor = outcomes.fetch(:monitor)
      assert_equal %i[created destroyed created], monitor[:operations]
      assert_equal ["new", "dflt"], monitor[:row], "the values given and the column defaults, not the dead row's"
      assert_equal 1, monitor[:returned]
      outcomes.each { |mode, outcome| assert_equal monitor, outcome, mode }
    end

    # The record's create is still waiting for its job: no row yet.
    define_method("test_#{write.to_s.delete('!')}#{'_bang' if write.end_with?('!')}_of_a_record_whose_create_is_pending_as_in_monitor") do
      outcomes = MODES.filter_map do |mode|
        next if write == :upsert_all && mode == :es_noproj

        [mode, pending_create_scenario(mode, write)]
      end.to_h

      monitor = outcomes.fetch(:monitor)
      expected = {
        insert_all: [%i[created], %w[old x], 0],
        insert_all!: [%i[created], %w[old x], ActiveRecord::RecordNotUnique],
        upsert_all: [%i[created updated], %w[new x], 1]
      }.fetch(write)
      assert_equal expected, monitor.values_at(:operations, :row, :returned)
      outcomes.each { |mode, outcome| assert_equal monitor, outcome, mode }
    end
  end

  # An update still waiting for its job: upsert_all starts from the row as
  # the stream has it, and the update's job no longer writes its older
  # value over the upsert's.
  def test_upsert_all_over_a_pending_update_as_in_monitor
    outcomes = (MODES - %i[es_noproj]).to_h do |mode|
      prepare(mode)
      item = ApiItem.create!(code: "old", tag: "x")
      run_jobs
      ApiItem.find(item.id).update!(code: "mid")
      ApiItem.upsert_all([{ id: item.id, code: "new", created_at: STAMP, updated_at: STAMP }])
      run_jobs
      [mode, finish(item.id)]
    end

    monitor = outcomes.fetch(:monitor)
    assert_equal [%i[created updated updated], %w[new x]], monitor.values_at(:operations, :row)
    outcomes.each { |mode, outcome| assert_equal monitor, outcome, mode }
  end

  # The pending job undoes nothing: the write applied the destroy and wrote
  # its own Created, row and event together, so it moved the checkpoint to
  # the Created, the stream's last event. The job finds nothing after it
  # and writes nothing: the destroy is never applied to the new row.
  def test_the_pending_jobs_apply_nothing_after_the_write
    prepare(:es_async)
    item = ApiItem.create!(code: "old", tag: "x")
    run_jobs
    ApiItem.find(item.id).destroy!
    ApiItem.insert_all([{ id: item.id, code: "new", created_at: STAMP, updated_at: STAMP }])
    stream = Lyra.stream_name(ApiItem, item.id)
    events = Lyra.config.event_store.read.stream(stream).to_a
    assert_equal %i[created destroyed created], events.map { Lyra::Event.operation_of(_1) }
    assert_equal events.last.event_id, Lyra::Projections::AsyncCheckpoint.read(connection, stream), "at the Created"

    projected = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      projected << payload[:sql] if payload[:sql].match?(/\A\s*(DELETE|INSERT|UPDATE)\b.*#{TABLE}/i)
    end
    assert_equal 1, run_jobs, "the destroy's job"
    ActiveSupport::Notifications.unsubscribe(subscriber)

    assert_empty projected, "the job writes nothing"
    assert_equal [%w[new dflt]], connection.select_rows("SELECT code, tag FROM #{TABLE}")
    assert_equal events.last.event_id, Lyra::Projections::AsyncCheckpoint.read(connection, stream)
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  # A write that fails (insert_all! of a key taken) takes back the rows it
  # brought up to date and their checkpoints with it: the jobs then apply
  # the events, as before.
  def test_a_failed_write_takes_its_projection_back
    prepare(:es_async)
    item = ApiItem.create!(code: "old", tag: "x")

    assert_raises(ActiveRecord::RecordNotUnique) do
      ApiItem.insert_all!([{ id: item.id, code: "new", created_at: STAMP, updated_at: STAMP }])
    end
    assert_empty connection.select_rows("SELECT id FROM #{TABLE}")
    assert_nil Lyra::Projections::AsyncCheckpoint.read(connection, Lyra.stream_name(ApiItem, item.id))
    run_jobs
    assert_equal [%w[old x]], connection.select_rows("SELECT code, tag FROM #{TABLE}")
  end

  # The keys an insert gives are locked within bulk_write_lock_limit, as
  # ES-NoProj's are: refused before anything is written.
  def test_the_keys_count_against_the_lock_limit
    prepare(:es_async)
    a = ApiItem.create!(code: "a")
    b = ApiItem.create!(code: "b")
    run_jobs
    Lyra.config.bulk_write_lock_limit = 1
    events = event_count

    rows = [a, b].map { { id: _1.id, code: "n", created_at: STAMP, updated_at: STAMP } }
    WRITES.each { |write| assert_raises(Lyra::BulkWriteLockLimitError, write) { ApiItem.public_send(write, rows) } }
    assert_equal events, event_count
    ApiItem.insert_all([{ code: "no key" }, { code: "nor here" }])
    assert_equal events + 2, event_count, "rows that give no key lock nothing"
  end

  # Rows already up to date cost one query, no projection lock.
  def test_rows_up_to_date_are_not_projected_again
    prepare(:es_async)
    item = ApiItem.create!(code: "old", tag: "x")
    run_jobs
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| statements << payload[:sql] }

    ApiItem.insert_all([{ id: item.id, code: "new", created_at: STAMP, updated_at: STAMP }])

    assert_equal 1, statements.count { _1.include?("lyra_async_checkpoints") }
    assert_empty statements.grep(/hashtext\('#{Regexp.escape(Lyra.stream_name(ApiItem, item.id))}'\)/)
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  # A job that commits after upsert_all read the rows its conflict key
  # finds, and before it took their locks: the rows are read again under
  # the locks. From the first read, a destroyed record's upsert was
  # recorded as an update of it, and a created one's as a second create.
  def test_a_job_committing_before_the_upsert_s_locks
    { destroyed: [%i[created destroyed created], %w[new dflt]], created: [%i[created updated], %w[new x]] }.each do |pending, expected|
      prepare(:es_async)
      item = ApiItem.create!(code: "old", tag: "x")
      if pending == :destroyed
        run_jobs
        ApiItem.find(item.id).destroy!
      end
      jobs = take_jobs
      Thread.current[:api_before_locks] = lambda do
        Thread.new { ActiveRecord::Base.connection_pool.with_connection { jobs.each { ActiveJob::Base.execute(_1.stringify_keys) } } }.join
      end

      ApiItem.upsert_all([{ id: item.id, code: "new", created_at: STAMP, updated_at: STAMP }])
      run_jobs
      outcome = finish(item.id)
      assert_equal [*expected, true], outcome.values_at(:operations, :row, :clean), pending
    ensure
      Thread.current[:api_before_locks] = nil
    end
  end

  # A transaction that holds a record's row, then inserts or upserts its key
  # while the record's projection job runs: the job does not wait for the
  # row holding its stream's lock, which the write's projection waits for.
  # Either the writer holds the row first (the job lets its lock go and
  # waits for the row), or the job does (the writer waits for the job).
  # They deadlocked.
  %i[insert_all upsert_all].each do |write|
    %i[writer_first job_first].each do |order|
      define_method("test_#{write}_holding_the_row_against_a_running_job_#{order}") do
        prepare(:es_async)
        item = ApiItem.create!(code: "old")
        run_jobs
        ApiItem.find(item.id).update!(code: "mid")
        job = take_jobs.sole
        errors = Queue.new
        row_held = Queue.new
        pause = { paused: Queue.new, go: Queue.new }
        writer = lambda do
          Thread.new do
            ActiveRecord::Base.connection_pool.with_connection do
              ApiItem.transaction do
                ApiItem.find(item.id).update_columns(tag: "t1")
                row_held << true
                sleep 0.3 # the job, meanwhile, takes its lock and meets the row
                ApiItem.public_send(write, [{ id: item.id, code: "new", created_at: STAMP, updated_at: STAMP }])
              end
            end
          rescue StandardError => e
            errors << e
          end
        end
        runner = lambda do |paused|
          Thread.new do
            Thread.current[:api_pause_projection] = pause if paused
            ActiveRecord::Base.connection_pool.with_connection { ActiveJob::Base.execute(job.stringify_keys) }
          rescue StandardError => e
            errors << e
          end
        end

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        threads =
          if order == :writer_first
            [writer.call, (row_held.pop && runner.call(false))]
          else
            j = runner.call(true)
            pause[:paused].pop # the job holds its stream's lock and the row
            w = writer.call
            sleep 0.2
            pause[:go] << true
            [j, w]
          end
        threads.each(&:join)
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

        assert_empty errors.size.times.map { errors.pop }
        assert_operator elapsed, :<, 5
        expected = write == :upsert_all ? %w[new t1] : %w[mid t1]
        assert_equal expected, connection.select_rows("SELECT code, tag FROM #{TABLE}").first
        assert_equal({}, Lyra::DualView.new(ApiItem, item.id).calculate_differences)
      ensure
        pause[:go] << true if pause
      end
    end
  end

  # A write that wrote its rows and their events from rows up to date moves
  # their checkpoints to those events: the same keys written again find
  # nothing to project. Before, every stream was behind its bypass events,
  # and each such write replayed the last one's onto rows that had them.
  def test_writing_the_same_keys_again_projects_nothing
    prepare(:es_async)
    rows = (1..20).map { |i| { id: 50_000 + i, code: "c#{i}", created_at: STAMP, updated_at: STAMP } }
    ApiItem.insert_all(rows)
    ApiItem.insert_all([{ code: "no key", created_at: STAMP, updated_at: STAMP }])
    projected = Thread.current[:api_projected] = []

    ApiItem.insert_all(rows)
    ApiItem.upsert_all(rows.map { _1.merge(code: "u") })
    ApiItem.upsert_all(rows.map { _1.merge(code: "v") })
    ApiItem.insert_all([{ id: ApiItem.unscoped.find_by!(code: "no key").id, code: "again", created_at: STAMP, updated_at: STAMP }])

    assert_empty projected
    assert_equal %w[v], ApiItem.unscoped.where(id: rows.map { _1[:id] }).distinct.pluck(:code)
    rows.each { assert_equal({}, Lyra::DualView.new(ApiItem, _1[:id]).calculate_differences) }
  ensure
    Thread.current[:api_projected] = nil
  end

  private

  def take_jobs
    jobs = @adapter.enqueued_jobs.dup
    @adapter.enqueued_jobs.clear
    jobs
  end

  STAMP = Time.utc(2026, 1, 2, 3, 4, 5)

  def destroyed_scenario(mode, write)
    prepare(mode)
    item = ApiItem.create!(code: "old", tag: "x")
    run_jobs
    ApiItem.find(item.id).destroy!
    returned = perform(write, item.id)
    run_jobs
    finish(item.id).merge(returned: returned)
  end

  def pending_create_scenario(mode, write)
    prepare(mode)
    item = ApiItem.create!(code: "old", tag: "x")
    returned = perform(write, item.id)
    run_jobs
    finish(item.id).merge(returned: returned)
  end

  # The write, and how many rows it returned (or the error it raised).
  def perform(write, id)
    ApiItem.public_send(write, [{ id: id, code: "new", created_at: STAMP, updated_at: STAMP }]).length
  rescue ActiveRecord::RecordNotUnique => e
    e.class
  end

  # The record's operations, its row, and DualView's verdict.
  def finish(id)
    ApiItem.count if @mode == :es_lazy # caught up
    row = if @mode == :es_noproj # no rows: the record as the event store has it
            ApiItem.find_by(id: id)&.then { [_1.code, _1.tag] }
          else
            connection.select_rows("SELECT code, tag FROM #{TABLE} WHERE id = #{Integer(id)}").first
          end
    clean = @mode == :es_noproj || Lyra::DualView.new(ApiItem, id).calculate_differences == {}
    { operations: operations(id), row: row, clean: clean }
  end

  def prepare(mode)
    clean
    @mode = mode
    case mode
    when :monitor then Lyra.config.enable_monitor!
    when :hijack then Lyra.config.enable_hijack!
    when :es_async
      @previous_adapter ||= ActiveJob::Base.queue_adapter
      @adapter = ActiveJob::QueueAdapters::TestAdapter.new
      @adapter.perform_enqueued_jobs = false
      ActiveJob::Base.queue_adapter = @adapter
      Lyra.config.enable_event_sourcing!
      Lyra.config.projection_mode = :async
      Lyra.config.async_projections_inline = false
    else
      Lyra.config.enable_event_sourcing!
      Lyra.config.projection_mode = { es_sync: :sync, es_noproj: :disabled, es_lazy: :lazy }.fetch(mode)
    end
    Lyra.config.bulk_write_lock_limit = 5_000
  end

  # Run the jobs held so far; returns how many.
  def run_jobs
    return 0 unless @mode == :es_async

    jobs = @adapter.enqueued_jobs.dup
    @adapter.enqueued_jobs.clear
    jobs.each { |job| ActiveJob::Base.execute(job.stringify_keys) }
    jobs.size
  end

  def operations(id)
    Lyra.config.event_store.read.stream(Lyra.stream_name(ApiItem, id)).to_a.map { |e| Lyra::Event.operation_of(e) }
  end

  def event_count = connection.select_value("SELECT count(*) FROM event_store_events").to_i

  def clean
    connection.execute("DELETE FROM #{TABLE}") if connection.table_exists?(TABLE)
    connection.execute("DELETE FROM event_store_events_in_streams")
    connection.execute("DELETE FROM event_store_events")
    Lyra::Projections::AsyncCheckpoint.reset!(connection)
    Lyra::Projections::LazyProjection.reset!(connection)
    Lyra::Projections::CachedProjection.invalidate_all(ApiItem) if Object.const_defined?(:ApiItem)
    Rails.cache.clear
  end

  def connection = ActiveRecord::Base.connection
end
