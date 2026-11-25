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
    # Four threads, one connection each, inside the test pool of five: as in
    # lazy_locked_reads_test.
    writers = Array.new(4) do |i|
      thread do
        r = NoprojLockItem.find(@id)
        i.even? ? r.with_lock { r.update!(n: r.n + 1) } : r.touch
        :ok
      end
    end
    assert_equal [:ok] * 4, writers.map { |t| Timeout.timeout(30) { t.value } }
    assert_equal 2, value
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

  # Rails reads lock!, with_lock and reload(lock: true) through
  # all.lock.find_by!(id: ...) (Persistence#_find_record): the read locks the
  # record it reads, not every record of the model (1.0.1 locked them all).
  def test_with_lock_locks_only_its_own_record
    others = Array.new(4) { NoprojLockItem.create!(n: 5).id }
    record = NoprojLockItem.find(@id)
    streams = aggregate_locks_during { record.with_lock { record.update!(n: record.n + 1) } }

    assert_equal [Lyra.stream_name(NoprojLockItem, @id)], streams.uniq, "only the record's own aggregate lock"
    assert_equal 1, value
    others.each { assert_equal 5, NoprojLockItem.find(_1).n }
  end

  # 1.0.1 counted every record of the model against the lock limit, so a
  # with_lock on a model larger than bulk_write_lock_limit was refused.
  def test_with_lock_on_a_model_larger_than_the_lock_limit
    4.times { NoprojLockItem.create!(n: 1) }
    Lyra.config.bulk_write_lock_limit = 3
    record = NoprojLockItem.find(@id)
    record.with_lock { record.update!(n: record.n + 1) }

    assert_equal 1, value
  ensure
    Lyra.config.bulk_write_lock_limit = 5_000
  end

  def test_lock_find_by_locks_only_the_records_it_selects
    match = NoprojLockItem.create!(n: 7).id
    3.times { NoprojLockItem.create!(n: 9) }
    streams = aggregate_locks_during { NoprojLockItem.transaction { NoprojLockItem.lock.find_by!(n: 7) } }

    assert_equal [Lyra.stream_name(NoprojLockItem, match)], streams.uniq
  end

  # The code against Lyra::Verification::MultiRecordLockNet: a transaction
  # that writes one record and then reads another under with_lock takes the
  # aggregate locks the net's released read takes, in its order (and not the
  # campaign's, which also locked the third record).
  def test_aggregate_lock_order_across_records_follows_the_net
    skip "PetriFlow not available" unless defined?(Lyra::Verification::MultiRecordLockNet)

    ids = [@id] + Array.new(2) { NoprojLockItem.create!(n: 0).id }
    program = [[:write, 1], [:lock_read, 0]]
    streams = aggregate_locks_during do
      NoprojLockItem.transaction do
        NoprojLockItem.find(ids[1]).update!(n: 1)
        r = NoprojLockItem.find(ids[0])
        r.with_lock { r.update!(n: r.n + 1) }
      end
    end
    net = Lyra::Verification::MultiRecordLockNet.new(
      Lyra::Verification::MultiRecordLockNet::Config.new(name: "trace", records: 3, programs: [], read: :own)
    )
    expected = net.aggregate_lock_order(program).map { Lyra.stream_name(NoprojLockItem, ids[_1]) }

    assert_equal expected, streams.uniq
  end

  private

  # The streams whose aggregate locks the block takes, in the order taken.
  def aggregate_locks_during
    streams = []
    sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      next unless payload[:sql].to_s.include?("pg_advisory")

      key = payload[:sql][/hashtext\('([^']*)'\)/, 1] ||
            Array(payload[:binds]).map { _1.respond_to?(:value) ? _1.value.to_s : _1.to_s }.first.to_s
      streams << key.delete_prefix("lyra_aggregate/") if key.start_with?("lyra_aggregate/")
    end
    yield
    streams
  ensure
    ActiveSupport::Notifications.unsubscribe(sub)
  end

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
