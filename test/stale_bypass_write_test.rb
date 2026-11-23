# frozen_string_literal: true

require "test_helper"

# Writes that skip callbacks on a record destroyed since it was read. Active
# Record's reach no row and record nothing: update_columns and touch return
# false, delete returns the frozen record, update_all and delete_all count
# only the rows they reach. Where the event store can hold a destroy whose
# row is not gone (ES-NoProj, which has no rows; ES-Async, before the
# destroy's projection job runs), these appended an update after the
# Destroyed and brought the record back, or a second Destroyed
# (Lyra::BypassEvents.checks_streams?).
class StaleBypassWriteTest < Minitest::Test
  # Pauses a bulk write before it takes its records' aggregate locks, on a
  # thread that asks for it (Thread.current[:sbp_pause_before_locks]).
  module PauseBeforeLocks
    def lock_streams!(*args, **kwargs)
      if (pause = Thread.current[:sbp_pause_before_locks])
        Thread.current[:sbp_pause_before_locks] = nil
        pause[:paused] << true
        pause[:go].pop
      end
      super
    end
  end
  Lyra::BypassEvents.singleton_class.prepend(PauseBeforeLocks)

  # Pauses an ES-Lazy write right after the catch-up it begins with, on a
  # thread that asks for it (Thread.current[:sbp_pause_after_catch_up]).
  module PauseAfterCatchUp
    def before_read(*args, **kwargs)
      result = super
      if (pause = Thread.current[:sbp_pause_after_catch_up])
        Thread.current[:sbp_pause_after_catch_up] = nil
        pause[:paused] << true
        pause[:go].pop
      end
      result
    end
  end
  Lyra::Projections::LazyProjection.singleton_class.prepend(PauseAfterCatchUp)

  TABLE = "lyra_sbp_items"
  PARENTS = "lyra_sbp_parents"

  def setup
    skip "Requires Rails and PostgreSQL" unless defined?(ActiveRecord::Base) && connection.adapter_name.match?(/postgres/i)

    connection.create_table(TABLE, force: true) do |t|
      t.string :code
      t.string :tag
      t.integer :sbp_parent_id
      t.timestamps
    end
    connection.create_table(PARENTS, force: true) do |t|
      t.string :name
      t.timestamps
    end
    Object.send(:remove_const, :SbpItem) if Object.const_defined?(:SbpItem)
    Object.const_set(:SbpItem, Class.new(ActiveRecord::Base) do
      self.table_name = TABLE
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
    end)
    Object.send(:remove_const, :SbpParent) if Object.const_defined?(:SbpParent)
    Object.const_set(:SbpParent, Class.new(ActiveRecord::Base) do
      self.table_name = PARENTS
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
      has_many :items, class_name: "SbpItem", dependent: :nullify
    end)
    [SbpItem, SbpParent].each do |model|
      model.reset_column_information
      Lyra.config.monitor_model(model)
    end
    clean
  end

  def teardown
    return unless Object.const_defined?(:SbpItem)

    ActiveJob::Base.queue_adapter = @previous_adapter if @previous_adapter
    Lyra.reset_config!
    clean
    connection.drop_table(TABLE, if_exists: true)
    connection.drop_table(PARENTS, if_exists: true)
  end

  # Monitor and Hijack: a stale copy's delete of a row another write
  # deleted records nothing (a second Destroyed before), as Active Record's
  # delete reaches no row; it returns the frozen record.
  def test_a_stale_copy_s_delete_records_nothing_where_the_rows_are_the_store
    %i[monitor hijack es_sync].each do |mode|
      clean
      use(mode)
      item = SbpItem.create!(code: "a", tag: "x")
      stale = SbpItem.find(item.id)
      SbpItem.where(id: item.id).delete_all
      assert_same stale, stale.delete, mode
      assert stale.frozen?, mode
      assert_equal %i[created destroyed], operations(item.id), mode

      live = SbpItem.create!(code: "b", tag: "x")
      SbpItem.find(live.id).delete
      assert_equal %i[created destroyed], operations(live.id), mode
    end
  end

  # ES-Async: dependent: :nullify leaves a child whose destroy is waiting
  # for its job as it is: no event (it brought the child back), no write.
  def test_es_async_nullify_leaves_out_a_child_whose_destroy_is_pending
    pending_jobs
    parent = SbpParent.create!(name: "p")
    kept = SbpItem.create!(code: "k", sbp_parent_id: parent.id)
    gone = SbpItem.create!(code: "g", sbp_parent_id: parent.id)
    run_jobs
    SbpItem.find(gone.id).destroy!

    SbpParent.find(parent.id).destroy!
    assert_equal %i[created updated], operations(kept.id)
    assert_equal %i[created destroyed], operations(gone.id)
    rows = connection.select_rows("SELECT code, sbp_parent_id FROM #{TABLE} ORDER BY code").to_h
    assert_equal({ "g" => parent.id, "k" => nil }, rows)
  end

  # ES-Async: the bulk write reads the streams of the rows it locked in one
  # query, not one per row.
  def test_es_async_bulk_write_reads_the_streams_in_one_query
    pending_jobs
    6.times { |i| SbpItem.create!(code: "a#{i}", tag: "x") }
    run_jobs
    reads = 0
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      reads += 1 if payload[:name] == "Lyra stream tail"
    end
    assert_equal 6, SbpItem.unscoped.update_all(tag: "u")
    assert_equal 1, reads
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  # ES-Async: a bulk write and a write that skips callbacks on one of its
  # records take the record's locks in the same order, the aggregate lock
  # first (Lyra::AdvisoryLock): one waits for the other. The bulk write
  # took the rows first and deadlocked.
  def test_es_async_bulk_write_waits_for_a_write_holding_the_record
    pending_jobs
    item = SbpItem.create!(code: "a", tag: "x")
    run_jobs
    holding = Queue.new
    release = Queue.new
    single = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        SbpItem.transaction do
          SbpItem.find(item.id).update_columns(tag: "single")
          holding << true
          release.pop
        end
      end
    end
    holding.pop
    bulk = Thread.new { ActiveRecord::Base.connection_pool.with_connection { SbpItem.unscoped.where(id: item.id).update_all(tag: "bulk") } }
    sleep 0.3
    assert bulk.alive?, "the bulk write waits"
    release << true
    single.join
    assert_equal 1, bulk.value
    assert_equal "bulk", SbpItem.unscoped.find(item.id).tag
  ensure
    release&.push(true)
    single&.join
    bulk&.join
  end

  # ES-Async under load: bulk writes against writes that skip callbacks,
  # and against a transaction that writes one record through callbacks and
  # then another by update_all: no deadlock.
  def test_es_async_bulk_and_single_writes_do_not_deadlock
    pending_jobs
    ids = 5.times.map { |i| SbpItem.create!(code: "a#{i}", tag: "x").id }
    run_jobs
    errors = Queue.new
    stop = false
    bulk = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        n = 0
        until stop
          begin
            SbpItem.unscoped.where(id: ids).update_all(tag: "b#{n += 1}")
          rescue StandardError => e
            errors << "bulk #{e.class}"
          end
        end
      end
    end
    single = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        60.times do |n|
          SbpItem.find(ids.sample).update_columns(tag: "s#{n}")
        rescue StandardError => e
          errors << "single #{e.class}"
        end
      end
    end
    mixed = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        60.times do |n|
          SbpItem.transaction do
            SbpItem.find(ids.first).update!(code: "c#{n}")
            SbpItem.unscoped.where(id: ids.last).update_all(tag: "t#{n}")
          end
        rescue StandardError => e
          errors << "mixed #{e.class}"
        end
      end
    end
    [single, mixed].each(&:join)
    stop = true
    bulk.join
    assert_empty(errors.size.times.map { errors.pop })
  ensure
    stop = true
    [bulk, single, mixed].compact.each(&:join)
  end

  # A stale copy's update_columns and touch, in Monitor and ES-NoProj: the
  # same results, and no event.
  def test_a_stale_copy_writes_nothing_as_in_active_record
    runs = %i[monitor es_noproj].map do |mode|
      clean
      use(mode)
      item = SbpItem.create!(code: "a", tag: "x")
      stale = SbpItem.find(item.id)
      other = SbpItem.find(item.id)
      SbpItem.find(item.id).destroy!
      before = event_count
      [stale.update_columns(tag: "u"), stale.tag, other.touch, event_count - before, operations(item.id),
       SbpItem.exists?(item.id)]
    end
    assert_equal runs.first, runs.last
    assert_equal [false, "u", false, 0, %i[created destroyed], false], runs.last
  end

  # A stale copy's delete in ES-NoProj: Active Record's frozen record, and
  # no second Destroyed.
  def test_a_stale_copy_deletes_nothing
    use(:es_noproj)
    item = SbpItem.create!(code: "a", tag: "x")
    stale = SbpItem.find(item.id)
    SbpItem.find(item.id).destroy!

    assert_same stale, stale.delete
    assert stale.frozen?
    assert_equal %i[created destroyed], operations(item.id)
  end

  # A live record is written as before.
  def test_a_live_record_is_written_as_before
    use(:es_noproj)
    item = SbpItem.create!(code: "a", tag: "x")
    assert SbpItem.find(item.id).update_columns(tag: "u")
    assert SbpItem.find(item.id).touch
    assert_equal "u", SbpItem.find(item.id).tag
    SbpItem.find(item.id).delete
    assert_equal %i[created updated updated destroyed], operations(item.id)
    refute SbpItem.exists?(item.id)
  end

  # ES-Async: the destroy is in the store, its row still in the table
  # until the projection job runs. update_all and delete_all leave that row
  # out, as Active Record's reach no row of a destroyed record (from 1.0.1
  # they apply the pending destroy first, which deletes it); a stale copy's
  # update_columns records nothing.
  def test_es_async_bulk_writes_leave_out_a_row_whose_destroy_is_pending
    pending_jobs
    a = SbpItem.create!(code: "a", tag: "x")
    b = SbpItem.create!(code: "b", tag: "x")
    run_jobs
    stale = SbpItem.find(b.id)
    SbpItem.find(b.id).destroy!
    assert_equal %w[a b], SbpItem.unscoped.order(:code).pluck(:code), "the destroy's job has not run"

    assert_equal 1, SbpItem.unscoped.update_all(tag: "u")
    assert_equal 1, SbpItem.unscoped.where(code: %w[a b]).touch_all
    refute stale.update_columns(tag: "v")
    assert_equal "v", stale.tag, "set in memory, as on a row already gone"
    # From 1.0.1 the bulk write first applies the events the jobs have not
    # (AsyncProjectionJob.project_pending): b's destroy deletes its row, so
    # nothing writes it without an event.
    assert_nil connection.select_value("SELECT tag FROM #{TABLE} WHERE id = #{Integer(b.id)}"),
               "the pending destroy applied, the row is not written without an event"
    assert_same stale, stale.delete
    assert_equal 1, connection.select_value("SELECT count(*) FROM #{TABLE}").to_i, "b's row went with its destroy"
    assert_equal %i[created destroyed], operations(b.id)
    assert_equal %i[created updated updated], operations(a.id)

    assert_equal 1, SbpItem.unscoped.delete_all
    assert_equal %i[created destroyed], operations(b.id)
    assert_equal %i[created updated updated destroyed], operations(a.id)
    run_jobs
    assert_empty SbpItem.unscoped.pluck(:code)
  end

  # The locks count against bulk_write_lock_limit there too.
  def test_es_async_bulk_writes_keep_to_the_lock_limit
    pending_jobs
    2.times { |i| SbpItem.create!(code: "a#{i}", tag: "x") }
    run_jobs
    Lyra.config.bulk_write_lock_limit = 1
    before = event_count

    assert_raises(Lyra::BulkWriteLockLimitError) { SbpItem.unscoped.update_all(tag: "u") }
    assert_equal before, event_count
    assert_equal %w[x x], SbpItem.unscoped.pluck(:tag)
    assert_equal 1, SbpItem.unscoped.where(code: "a0").update_all(tag: "u")
  end

  # ES-Lazy brings the table up to date before a bulk write: a destroyed
  # record's row is gone by then.
  def test_es_lazy_bulk_writes_do_not_reach_a_destroyed_record
    Lyra.config.enable_event_sourcing!
    Lyra.config.projection_mode = :lazy
    a = SbpItem.create!(code: "a", tag: "x")
    b = SbpItem.create!(code: "b", tag: "x")
    relation = SbpItem.where(tag: "x")
    relation.to_a
    SbpItem.find(b.id).destroy!

    assert_equal 1, relation.update_all(tag: "u")
    assert_equal %i[created destroyed], operations(b.id)
    assert_equal %i[created updated], operations(a.id)
  end

  # ES-Lazy: a destroy committed after the catch-up a bulk write began with
  # (here, while the write waits before its locks) is in the tables it
  # writes: the write brings them up to date again under its locks, and
  # reads the streams. It wrote the row and appended an update after the
  # destroy.
  def test_es_lazy_bulk_write_sees_a_destroy_committed_after_its_catch_up
    use(:es_lazy)
    a = SbpItem.create!(code: "a", tag: "x")
    b = SbpItem.create!(code: "b", tag: "x")
    SbpItem.unscoped.to_a # caught up
    pause = { paused: Queue.new, go: Queue.new }
    bulk = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Thread.current[:sbp_pause_before_locks] = pause
        SbpItem.unscoped.update_all(tag: "u")
      end
    end
    pause[:paused].pop
    destroyer = Thread.new { ActiveRecord::Base.connection_pool.with_connection { SbpItem.find(b.id).destroy! } }
    destroyer.join
    pause[:go] << true

    assert_equal 1, bulk.value
    assert_equal %i[created destroyed], operations(b.id)
    assert_equal %i[created updated], operations(a.id)
  ensure
    pause&.dig(:go)&.push(true)
    bulk&.join
  end

  # ES-Lazy: a write committed by another connection after the catch-up a
  # bulk write began with, and before the bulk write's locks, is in the row
  # the bulk write writes (the record is replayed onto its row under the
  # lock): it was lost under it, or read from the stale row. As Monitor
  # orders them: the other write, then this one.
  def test_es_lazy_bulk_write_starts_from_a_write_committed_after_its_catch_up
    cases = {
      "update_all(tag: x)" => [->(id) { SbpItem.where(id: id).update_all(tag: "x") },
                               ->(id) { SbpItem.find(id).update!(tag: "u") }, [1, "x", %i[created updated updated]]],
      "update_all(SQL)" => [->(id) { SbpItem.where(id: id).update_all("tag = tag || '1'") },
                            ->(id) { SbpItem.find(id).update!(tag: "u") }, [1, "u1", %i[created updated updated]]],
      "update_all after a destroy" => [->(id) { SbpItem.where(id: id).update_all(tag: "z") },
                                       ->(id) { SbpItem.find(id).destroy! }, [0, nil, %i[created destroyed]]],
      "delete_all after a destroy" => [->(id) { SbpItem.where(id: id).delete_all },
                                       ->(id) { SbpItem.find(id).destroy! }, [0, nil, %i[created destroyed]]],
      "update_columns after a write" => [->(id) { SbpItem.find(id).update_columns(tag: "x") },
                                         ->(id) { SbpItem.find(id).update!(tag: "u") }, [true, "x", %i[created updated updated]]]
    }
    cases.each do |name, (write, other, expected)|
      clean
      use(:es_lazy)
      item = SbpItem.create!(code: "a", tag: "a")
      SbpItem.find(item.id) # caught up
      pause = { paused: Queue.new, go: Queue.new }
      writer = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          Thread.current[:sbp_pause_after_catch_up] = pause
          write.call(item.id)
        end
      end
      pause[:paused].pop
      Thread.new { ActiveRecord::Base.connection_pool.with_connection { other.call(item.id) } }.join
      pause[:go] << true
      result = writer.value
      final = SbpItem.where(id: item.id).pluck(:tag).first
      assert_equal expected, [result, final, operations(item.id)], name
    ensure
      pause&.dig(:go)&.push(true)
      writer&.join
    end
  end

  # ES-Lazy under load: bulk writes, writes that skip callbacks, writes
  # through callbacks and catch-ups from another connection: no deadlock.
  def test_es_lazy_bulk_single_and_catch_up_do_not_deadlock
    use(:es_lazy)
    ids = 5.times.map { |i| SbpItem.create!(code: "a#{i}", tag: "x").id }
    errors = Queue.new
    stop = false
    loop_on = lambda do |name, &body|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          n = 0
          until stop
            begin
              body.call(n += 1)
            rescue StandardError => e
              errors << "#{name} #{e.class}: #{e.message[0, 400]}"
            end
          end
        end
      end
    end
    threads = [
      loop_on.call("bulk") { |n| SbpItem.unscoped.where(id: ids).update_all(tag: "b#{n}") },
      loop_on.call("catch-up") { |_| Lyra::Projections::LazyProjection.catch_up! }
    ]
    finite = [
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          60.times do |n|
            SbpItem.find(ids.sample).update_columns(tag: "s#{n}")
          rescue StandardError => e
            errors << "single #{e.class}: #{e.message[0, 400]}"
          end
        end
      end,
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          60.times do |n|
            SbpItem.find(ids.sample).update!(code: "c#{n}")
          rescue StandardError => e
            errors << "callback #{e.class}: #{e.message[0, 400]}"
          end
        end
      end
    ]
    finite.each(&:join)
    stop = true
    threads.each(&:join)
    # A catch-up writes rows in the log's order, and a bulk write locks its
    # rows in the table's: those two can still meet on rows alone (no lock
    # of Lyra's in the cycle), rarely, as before 1.0.0. Every cycle through
    # an aggregate or catch-up lock is a failure.
    errors = errors.size.times.map { errors.pop }
    assert_empty(errors.select { _1.include?("advisory lock") || !_1.include?("Deadlocked") })
  ensure
    stop = true
    (threads.to_a + finite.to_a).each(&:join)
  end

  # upsert_all on a record destroyed whose row the destroy's job has not
  # deleted yet: ON CONFLICT updated the row and appended an Updated after
  # the Destroyed (the record read as live in the log; the job then deleted
  # the row, and find raised); then it was refused. The row is now brought
  # up to date with the stream first (gone), and the upsert inserts, as
  # Active Record's does where the row is gone: a Created after the
  # Destroyed, with the column defaults for what it does not name. The
  # destroy's job, run after, leaves the new row alone.
  def test_es_async_upsert_all_creates_again_a_record_whose_destroy_is_pending
    pending_jobs
    a = SbpItem.create!(code: "a", tag: "x")
    b = SbpItem.create!(code: "b", tag: "x", sbp_parent_id: 7)
    run_jobs
    SbpItem.find(b.id).destroy!

    SbpItem.upsert_all([upsert_row(a.id, "a2"), upsert_row(b.id, "b2")])
    assert_equal %i[created updated], operations(a.id)
    assert_equal %i[created destroyed created], operations(b.id), "inserted again, as where the row is gone"
    assert_nil SbpItem.unscoped.find(b.id).sbp_parent_id, "not the dead row's values"
    run_jobs
    assert_equal %w[a2 b2], SbpItem.unscoped.order(:code).pluck(:code)
    [a, b].each { assert_equal({}, Lyra::DualView.new(SbpItem, _1.id).calculate_differences) }
  end

  # The upsert's locks count against bulk_write_lock_limit.
  def test_es_async_upsert_all_keeps_to_the_lock_limit
    pending_jobs
    a = SbpItem.create!(code: "a", tag: "x")
    b = SbpItem.create!(code: "b", tag: "x")
    run_jobs
    Lyra.config.bulk_write_lock_limit = 1
    before = event_count

    assert_raises(Lyra::BulkWriteLockLimitError) { SbpItem.upsert_all([upsert_row(a.id, "a2"), upsert_row(b.id, "b2")]) }
    assert_equal before, event_count
    assert_equal %w[a b], SbpItem.unscoped.order(:code).pluck(:code)
    SbpItem.upsert_all([upsert_row(a.id, "a2")])
    assert_equal %i[created updated], operations(a.id)
  end

  # ES-Lazy: a destroy committed after the catch-up the upsert began with
  # is not in the table the upsert writes; the stream, read under the lock,
  # has it. Refused, as in ES-Async. A destroy caught up before is gone from
  # the table, and the upsert inserts.
  def test_es_lazy_upsert_all_sees_a_destroy_committed_after_its_catch_up
    use(:es_lazy)
    a = SbpItem.create!(code: "a", tag: "x")
    b = SbpItem.create!(code: "b", tag: "x")
    SbpItem.unscoped.to_a # caught up
    pause = { paused: Queue.new, go: Queue.new }
    upsert = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Thread.current[:sbp_pause_after_catch_up] = pause
        SbpItem.upsert_all([upsert_row(b.id, "b2")])
        :written
      rescue Lyra::RecordDestroyedError => e
        e
      end
    end
    pause[:paused].pop
    Thread.new { ActiveRecord::Base.connection_pool.with_connection { SbpItem.find(b.id).destroy! } }.join
    before = event_count
    pause[:go] << true

    assert_kind_of Lyra::RecordDestroyedError, upsert.value
    assert_equal before, event_count
    assert_equal %i[created destroyed], operations(b.id)

    SbpItem.upsert_all([upsert_row(a.id, "a2"), upsert_row(b.id, "b3")])
    assert_equal %i[created updated], operations(a.id)
    assert_equal %i[created destroyed created], operations(b.id)
    assert_equal %w[a2 b3], SbpItem.unscoped.order(:code).pluck(:code)
  ensure
    pause&.dig(:go)&.push(true)
    upsert&.join
  end

  # The smallest limit (1) never refuses a write of one record: each takes
  # one aggregate lock.
  def test_the_smallest_lock_limit_allows_every_single_record_write
    %i[es_noproj es_lazy es_async].each do |mode|
      clean
      mode == :es_async ? pending_jobs : use(mode)
      Lyra.config.bulk_write_lock_limit = 1
      item = SbpItem.create!(code: "a", tag: "x")
      run_jobs if mode == :es_async

      assert SbpItem.find(item.id).update_columns(tag: "c"), mode
      assert SbpItem.find(item.id).touch, mode
      SbpItem.upsert_all([upsert_row(item.id, "u")]) unless mode == :es_noproj
      assert_equal 1, SbpItem.where(id: item.id).update_all(tag: "b"), mode
      SbpItem.find(item.id).delete
      expected = %i[created updated updated] + (mode == :es_noproj ? [] : %i[updated]) + %i[updated destroyed]
      assert_equal expected, operations(item.id), mode
    end
  end

  # ES-NoProj refuses upsert_all whatever the stream holds, as before.
  def test_es_noproj_upsert_all_is_still_refused
    use(:es_noproj)
    a = SbpItem.create!(code: "a", tag: "x")
    SbpItem.find(a.id).destroy!

    assert_raises(Lyra::Projections::UnsupportedQuery) { SbpItem.upsert_all([upsert_row(a.id, "a2")]) }
    assert_equal %i[created destroyed], operations(a.id)
  end

  private

  def upsert_row(id, code)
    { id: id, code: code, tag: "u", created_at: Time.current, updated_at: Time.current }
  end

  def use(mode)
    case mode
    when :es_noproj
      Lyra.config.enable_event_sourcing!
      Lyra.config.projection_mode = :disabled
    when :es_sync
      Lyra.config.enable_event_sourcing!
      Lyra.config.projection_mode = :sync
    when :hijack
      Lyra.config.enable_hijack!
    when :es_lazy
      Lyra.config.enable_event_sourcing!
      Lyra.config.projection_mode = :lazy
    else
      Lyra.config.enable_monitor!
      Lyra.config.projection_mode = :sync
    end
  end

  # ES-Async with its projection jobs held until run_jobs.
  def pending_jobs
    @previous_adapter = ActiveJob::Base.queue_adapter
    @adapter = ActiveJob::QueueAdapters::TestAdapter.new
    @adapter.perform_enqueued_jobs = false
    ActiveJob::Base.queue_adapter = @adapter
    Lyra.config.enable_event_sourcing!
    Lyra.config.projection_mode = :async
    Lyra.config.async_projections_inline = false
  end

  def run_jobs
    jobs = @adapter.enqueued_jobs.dup
    @adapter.enqueued_jobs.clear
    jobs.each { |job| ActiveJob::Base.execute(job.stringify_keys) }
  end

  def operations(id)
    Lyra.config.event_store.read.stream(Lyra.stream_name(SbpItem, id)).to_a.map { |e| Lyra::Event.operation_of(e) }
  end

  def event_count
    connection.select_value("SELECT count(*) FROM event_store_events").to_i
  end

  def clean
    connection.execute("DELETE FROM #{TABLE}") if connection.table_exists?(TABLE)
    connection.execute("DELETE FROM #{PARENTS}") if connection.table_exists?(PARENTS)
    connection.execute("DELETE FROM event_store_events_in_streams")
    connection.execute("DELETE FROM event_store_events")
    Lyra::Projections::CachedProjection.invalidate_all(SbpItem) if Object.const_defined?(:SbpItem)
    Rails.cache.clear
  end

  def connection = ActiveRecord::Base.connection
end
