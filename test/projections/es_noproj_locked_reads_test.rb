# frozen_string_literal: true

require "test_helper"
require "timeout"

# ES-NoProj's locking reads (lock!, with_lock, lock.find), from 1.0.1. ES-NoProj
# keeps no rows, so a row lock locks nothing: in 1.0.0 two increments under
# with_lock could both read 0 and give 1, with no error. Now the read takes
# the records' aggregate locks first, which every writer of them takes before
# its append, and then reads their streams, as ES-Lazy's locking reads do.
class EsNoprojLockedReadsTest < Minitest::Test
  TABLE = "lyra_noproj_lock_items"

  def setup
    skip "Requires Rails and PostgreSQL" unless defined?(ActiveRecord::Base) && connection.adapter_name.match?(/postgres/i)

    connection.create_table(TABLE, force: true) do |t|
      t.integer :n, null: false, default: 0
      t.timestamps
    end
    Object.send(:remove_const, :NoprojLockItem) if Object.const_defined?(:NoprojLockItem)
    Object.const_set(:NoprojLockItem, Class.new(ActiveRecord::Base) { self.table_name = TABLE })
    NoprojLockItem.include Lyra::Interceptors::CrudInterceptor
    NoprojLockItem.monitor_with_lyra
    clean
    Lyra.config.enable_event_sourcing!
    Lyra.config.projection_mode = :disabled
    Lyra.config.monitor_model(NoprojLockItem)
    @id = NoprojLockItem.create!(n: 0).id
  end

  def teardown
    return unless defined?(NoprojLockItem)

    Lyra.config.projection_mode = :sync
    Lyra.reset_config!
    clean
    connection.drop_table(TABLE, if_exists: true)
  end

  def test_two_increments_under_with_lock_both_count
    held = Queue.new
    go = Queue.new
    first = thread { r = NoprojLockItem.find(@id); r.with_lock { held << true; go.pop; r.update!(n: r.n + 1) } }
    held.pop
    begin
      second = thread { r = NoprojLockItem.find(@id); r.with_lock { r.update!(n: r.n + 1) } }
      refute second.join(0.3), "the second reader waits for the first's lock"
    ensure
      go << true
    end
    [first, second].each { |t| Timeout.timeout(20) { t.value } }

    assert_equal 2, value
  end

  def test_two_increments_under_lock_find_both_count
    held = Queue.new
    go = Queue.new
    first = thread do
      NoprojLockItem.transaction do
        r = NoprojLockItem.lock.find(@id)
        held << true
        go.pop
        r.update!(n: r.n + 1)
      end
    end
    held.pop
    begin
      second = thread { NoprojLockItem.transaction { r = NoprojLockItem.lock.find(@id); r.update!(n: r.n + 1) } }
      refute second.join(0.3), "the second reader waits for the first's lock"
    ensure
      go << true
    end
    [first, second].each { |t| Timeout.timeout(20) { t.value } }

    assert_equal 2, value
  end

  # A plain writer waits for a locking reader, and the reader's update counts.
  def test_a_plain_writer_waits_for_a_locking_reader
    held = Queue.new
    go = Queue.new
    reader = thread { r = NoprojLockItem.find(@id); r.with_lock { held << true; go.pop; r.update!(n: r.n + 10) } }
    held.pop
    begin
      writer = thread { NoprojLockItem.find(@id).update!(n: 100) }
      refute writer.join(0.3), "the writer waits at the record's aggregate lock"
    ensure
      go << true
    end
    [reader, writer].each { |t| Timeout.timeout(20) { t.value } }

    assert_equal 100, value
  end

  # Locking readers and plain writers together: no deadlock, every increment
  # under the lock counts.
  def test_locking_readers_and_plain_writers_do_not_deadlock
    writers = Array.new(6) do |i|
      thread do
        r = NoprojLockItem.find(@id)
        i.even? ? r.with_lock { r.update!(n: r.n + 1) } : r.touch
        :ok
      end
    end
    assert_equal [:ok] * 6, writers.map { |t| Timeout.timeout(30) { t.value } }
    assert_equal 3, value
  end

  # Model.lock.where(...): the selection's records locked before its first
  # read, and read again under the locks, so two increments both count.
  def test_two_increments_under_lock_where_both_count
    held = Queue.new
    go = Queue.new
    first = thread do
      NoprojLockItem.transaction do
        r = NoprojLockItem.lock.where(id: @id).first
        held << true
        go.pop
        r.update!(n: r.n + 1)
      end
    end
    held.pop
    begin
      second = thread { NoprojLockItem.transaction { r = NoprojLockItem.where(n: 0..).lock.to_a.first; r.update!(n: r.n + 1) } }
      refute second.join(0.3), "the second reader waits for the first's lock"
    ensure
      go << true
    end
    [first, second].each { |t| Timeout.timeout(20) { t.value } }

    assert_equal 2, value
  end

  private

  def thread(&block) = Thread.new { ActiveRecord::Base.connection_pool.with_connection(&block) }.tap { _1.report_on_exception = false }

  def value = NoprojLockItem.find(@id).n

  def clean
    connection.execute("DELETE FROM event_store_events_in_streams")
    connection.execute("DELETE FROM event_store_events")
    connection.execute("DELETE FROM #{Lyra::StreamHeads::TABLE}") if connection.table_exists?(Lyra::StreamHeads::TABLE)
    connection.execute("DELETE FROM #{TABLE}") if connection.table_exists?(TABLE)
  end

  def connection = ActiveRecord::Base.connection
end
