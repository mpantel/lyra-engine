# frozen_string_literal: true

require "test_helper"
require "timeout"
require_relative "lazy_locked_reads_test"

# ES-Lazy's catch-up where no second connection can be had (1.0.1): the
# fallback runs it in the reader's transaction, which then holds the
# catch-up lock to its commit. Two ways that hung, with no error, before:
# - the same transaction read again once a connection was free, and its
#   catch-up on that connection waited for the lock its own transaction held;
# - another reader, holding a record the fallback's transaction then wrote,
#   caught up on a connection of its own and waited for the lock, while its
#   transaction waited for it in Ruby, where PostgreSQL saw no cycle.
# Now a transaction that holds the lock catches up in place, and the wait on a
# connection of its own is bounded (LazyProjection::OWN_LOCK_WAIT), after
# which the catch-up runs in the reader's transaction, where a cycle is a
# deadlock PostgreSQL detects.
class LazyFallbackTest < LazyLockedReadsTest
  LazyLockedReadsTest.instance_methods(false).grep(/^test_/).each { undef_method(_1) }

  def test_the_fallback_is_warned_of_once
    Lyra::Projections::LazyProjection.reset_fallback_warning!
    logged = StringIO.new
    previous = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(logged)
    other = LockItem.create!(n: 0).id
    LockItem.find(other)
    2.times do |i|
      LockItem.find(other).update!(n: i + 1) # pending
      pool.release_connection
      blockers = fill_pool(leave: 1)
      Thread.new { pool.with_connection { LockItem.transaction { LockItem.find(other).n } } }.join(10)
      release(blockers)
    end
    assert_equal 1, logged.string.scan("found no free connection in the pool").size, logged.string
  ensure
    Rails.logger = previous
  end

  def test_a_transaction_that_fell_back_reads_again_without_waiting_for_itself
    other = LockItem.create!(n: 0).id
    LockItem.find(other)
    first_read = Queue.new
    go = Queue.new
    reader = Thread.new do
      pool.with_connection do
        LockItem.transaction do
          LockItem.find(other) # nothing pending yet
          first_read << true
          go.pop
          LockItem.find(other).n # pending: caught up in this transaction (the pool is full)
          LockItem.find(@id).update!(n: 1)
          go.pop
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          LockItem.find(other).n # pending again, a connection free: in place, at once
          @second_read = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        end
      end
    end
    first_read.pop
    LockItem.find(other).update!(n: 1) # pending for the reader
    pool.release_connection
    blockers = fill_pool
    go << true
    sleep 0.3
    release(blockers)
    # Another event the reader has not seen, from a write that does not catch
    # up itself (every catch-up now waits for the reader's commit).
    Lyra.config.event_store.publish(RubyEventStore::Event.new(data: {}), stream_name: "LazyFallbackProbe$1")
    pool.release_connection
    go << true
    assert Timeout.timeout(10) { reader.value }, "the reader finishes"
    assert_equal 1, LockItem.find(other).n
    assert_operator @second_read, :<, 0.5, "not after a bounded wait for its own lock"
  ensure
    unstick(reader)
  end

  def test_a_fallback_and_an_own_connection_catch_up_do_not_hang
    other = LockItem.create!(n: 0).id
    LockItem.find(other)
    held = Queue.new
    go = Queue.new
    waiting = Queue.new
    holder = Thread.new do
      pool.with_connection do
        LockItem.transaction do
          LockItem.find(@id).update!(n: 5)
          held << true
          go.pop
          LockItem.find(other).n # catches up on a connection of its own
        end
        :ok
      rescue ActiveRecord::Deadlocked
        :deadlocked
      end
    end
    held.pop
    LockItem.find(other).update!(n: 1) # pending
    pool.release_connection
    blockers = fill_pool(leave: 1)
    fallback = Thread.new do
      pool.with_connection do
        LockItem.transaction do
          LockItem.find(other).n # no free connection: caught up here, the lock held
          waiting << true
          LockItem.find(@id).update!(n: 9) # waits for the holder's aggregate lock
        end
        :ok
      rescue ActiveRecord::Deadlocked
        :deadlocked
      end
    end
    waiting.pop
    sleep 0.3
    release(blockers)
    go << true
    results = [holder, fallback].map { |thread| Timeout.timeout(15) { thread.value } }
    assert_operator results.count(:ok), :>=, 1, results.inspect
    assert_operator results.count(:deadlocked), :<=, 1, results.inspect
  ensure
    unstick(holder, fallback)
  end

  private

  def pool = ActiveRecord::Base.connection_pool

  # A failure here is a hang: end the stuck threads' connections, so the
  # teardown is not left waiting for their locks.
  def unstick(*threads)
    stuck = threads.compact.select(&:alive?)
    return if stuck.empty?

    ActiveRecord::Base.connection.execute("SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = current_database() AND pid <> pg_backend_pid()")
    stuck.each { _1.join(5) || _1.kill }
    pool.disconnect!
  end

  # Threads holding every free connection but +leave+.
  def fill_pool(leave: 0)
    free = pool.size - pool.connections.count(&:in_use?) - leave
    release = Queue.new
    threads = Array.new([free, 0].max) { Thread.new { pool.with_connection { |c| c.select_value("SELECT 1"); release.pop } } }
    sleep 0.2
    [threads, release]
  end

  def release((threads, queue))
    threads.size.times { queue << true }
    threads.each(&:join)
  end
end
