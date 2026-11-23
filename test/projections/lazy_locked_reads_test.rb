# frozen_string_literal: true

require "test_helper"
require "timeout"

# ES-Lazy's locking reads (lock, lock!, with_lock), from 1.0.1: the read under
# the lock returns the record as its stream has it. In 1.0.0 the catch-up ran
# before the lock was granted, so a reader that waited for another writer's
# lock read the row as that catch-up left it, and two increments under
# with_lock could give 1, with no error (the multi-writer net,
# Lyra::Verification::LazyCatchUpNet, finds the same). Now the locking read
# takes the records' aggregate locks and stream heads, replays the records
# that are behind, and reads again.
class LazyLockedReadsTest < Minitest::Test
  TABLE = "lyra_lazy_lock_items"

  def setup
    skip "Requires Rails and PostgreSQL" unless defined?(ActiveRecord::Base) && connection.adapter_name.match?(/postgres/i)

    connection.create_table(TABLE, force: true) do |t|
      t.integer :n, null: false, default: 0
      t.timestamps
    end
    Object.send(:remove_const, :LockItem) if Object.const_defined?(:LockItem)
    Object.const_set(:LockItem, Class.new(ActiveRecord::Base) { self.table_name = TABLE })
    LockItem.include Lyra::Interceptors::CrudInterceptor
    LockItem.monitor_with_lyra
    clean
    Lyra.config.enable_event_sourcing!
    Lyra.config.projection_mode = :lazy
    Lyra.config.monitor_model(LockItem)
    @id = LockItem.create!(n: 0).id
    LockItem.count
  end

  def teardown
    return unless defined?(LockItem)

    Lyra.config.projection_mode = :sync
    Lyra.reset_config!
    clean
    connection.drop_table(TABLE, if_exists: true)
  end

  def test_two_increments_under_with_lock_both_count
    held = Queue.new
    go = Queue.new
    first = thread { r = LockItem.find(@id); r.with_lock { held << true; go.pop; r.update!(n: r.n + 1) } }
    held.pop
    second = thread { r = LockItem.find(@id); r.with_lock { r.update!(n: r.n + 1) } }
    refute second.join(0.3), "the second reader waits for the first's lock"
    go << true
    [first, second].each { |t| Timeout.timeout(20) { t.value } }

    assert_equal 2, value
  end

  def test_two_increments_under_lock_find_both_count
    held = Queue.new
    go = Queue.new
    first = thread do
      LockItem.transaction do
        r = LockItem.lock.find(@id)
        held << true
        go.pop
        r.update!(n: r.n + 1)
      end
    end
    held.pop
    second = thread { LockItem.transaction { r = LockItem.lock.find(@id); r.update!(n: r.n + 1) } }
    sleep 0.3
    go << true
    [first, second].each { |t| Timeout.timeout(20) { t.value } }

    assert_equal 2, value
  end

  # A plain writer, which takes the aggregate lock and the head at its append,
  # waits for a locking reader, and the reader's update counts.
  def test_a_plain_writer_waits_for_a_locking_reader
    held = Queue.new
    go = Queue.new
    reader = thread { r = LockItem.find(@id); r.with_lock { held << true; go.pop; r.update!(n: r.n + 10) } }
    held.pop
    writer = thread { LockItem.find(@id).update!(n: 100) }
    refute writer.join(0.3), "the writer waits at the record's head"
    go << true
    [reader, writer].each { |t| Timeout.timeout(20) { t.value } }

    assert_equal 100, value, "the writer's update, made after the reader's, is the last"
    assert_equal %i[created updated updated], operations
  end

  # Locking readers that update and plain writers together: no deadlock, and
  # every increment under the lock counts.
  def test_locking_readers_and_plain_writers_do_not_deadlock
    # Four threads, one connection each, inside the test pool of five: ES-Lazy's
    # catch-up takes another for itself, and with none free it runs in the
    # reader's transaction instead (the documented fallback, which can deadlock).
    increments = 4
    writers = Array.new(increments) do |i|
      thread do
        if i.even?
          r = LockItem.find(@id)
          r.with_lock { r.update!(n: r.n + 1) }
        else
          LockItem.find(@id).touch
        end
        :ok
      end
    end
    assert_equal [:ok] * increments, writers.map { |t| Timeout.timeout(30) { t.value } }
    assert_equal increments / 2, value
  end

  # The deadlock of 1.0.0 in Olist checkouts at 16 threads: a transaction holds
  # a row and then reads, while another reader's catch-up needs that row. In
  # 1.0.0 the catch-up held its lock to its reader's commit and waited for the
  # row, and the row's holder waited for the catch-up lock. Now each catch-up
  # commits on a connection of its own and leaves a held row for later, so
  # neither waits for the other, and a later read applies the event.
  def test_a_row_holder_that_reads_and_a_catch_up_do_not_deadlock
    other = LockItem.create!(n: 0).id
    LockItem.count
    thread { LockItem.find(@id).update!(n: 5) }.join # committed, not yet on the row
    held = Queue.new
    go = Queue.new
    holder = thread do
      LockItem.transaction do
        # the row, as the application's own SQL holds it (no Lyra hook)
        LockItem.connection.select_value("SELECT n FROM #{TABLE} WHERE id = #{Integer(@id)} FOR UPDATE")
        held << true
        go.pop
        LockItem.where(id: other).pluck(:n)
      end
    end
    held.pop
    begin
      catcher = thread { LockItem.transaction { LockItem.find(other).n } }
      assert_equal 0, Timeout.timeout(10) { catcher.value }, "the catch-up does not wait for the held row"
    ensure
      go << true # a failed test must not leave the row held
    end
    assert_equal [0], Timeout.timeout(10) { holder.value }, "the row's holder does not wait for a catch-up"

    assert_equal 5, value, "the event the held row missed is applied by a later read"
  end

  # A transaction that writes a record and then reads it sees its own write:
  # the catch-up's connection cannot see the uncommitted event, so the reader
  # replays the record in its own transaction.
  def test_a_transaction_reads_its_own_uncommitted_write
    seen = LockItem.transaction do
      LockItem.find(@id).update!(n: 7)
      [LockItem.find(@id).n, LockItem.where(n: 7).count]
    end
    assert_equal [7, 1], seen
    assert_equal 7, value
  end

  # Outside a transaction the lock ends with the statement: nothing to do.
  def test_a_locking_read_outside_a_transaction_reads_as_before
    assert_equal 0, LockItem.lock.find(@id).n
  end

  # Model.lock.where(...), whose keys are not known before it runs: the keys
  # are read first, their aggregate locks taken, then the locking query, so
  # two increments both count.
  def test_two_increments_under_lock_where_both_count
    held = Queue.new
    go = Queue.new
    first = thread do
      LockItem.transaction do
        r = LockItem.lock.where(id: @id).first
        held << true
        go.pop
        r.update!(n: r.n + 1)
      end
    end
    held.pop
    begin
      second = thread { LockItem.transaction { r = LockItem.lock.where("n >= 0").first; r.update!(n: r.n + 1) } }
      refute second.join(0.3), "the second reader waits for the first's lock"
    ensure
      go << true
    end
    [first, second].each { |t| Timeout.timeout(20) { t.value } }

    assert_equal 2, value
  end

  private

  def thread(&block) = Thread.new { ActiveRecord::Base.connection_pool.with_connection(&block) }

  def value
    LockItem.count
    connection.select_value("SELECT n FROM #{TABLE} WHERE id = #{Integer(@id)}")
  end

  def operations
    Lyra.config.event_store.read.stream(Lyra.stream_name(LockItem, @id)).to_a.map { Lyra::Event.operation_of(_1) }
  end

  def clean
    connection.execute("DELETE FROM event_store_events_in_streams")
    connection.execute("DELETE FROM event_store_events")
    connection.execute("DELETE FROM #{Lyra::StreamHeads::TABLE}") if connection.table_exists?(Lyra::StreamHeads::TABLE)
    Lyra::Projections::LazyProjection.reset!
  end

  def connection = ActiveRecord::Base.connection
end
