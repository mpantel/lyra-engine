# frozen_string_literal: true

require "test_helper"
require "petri_flow"

# ES-Async's lock orders for one record (Lyra::Verification::AsyncLockOrderNet).
class AsyncLockOrderNetTest < Minitest::Test
  N = Lyra::Verification::AsyncLockOrderNet

  def explore(kinds, last_pass: :read_first) = N.explore(N::Config.new(name: kinds.join("+"), kinds: kinds, retries: 1, last_pass: last_pass))

  # A job's last pass reads before it takes the row, and a bypass write that
  # found the row current takes no stream lock. Still the row never ends behind
  # its log: the bypass found the checkpoint current under the aggregate lock,
  # so no writer appends until it commits, and the job then finds nothing
  # after its checkpoint to apply (or the bypass waits for the job's stream
  # lock). Taking the row first changes nothing here.
  def test_no_mix_leaves_the_row_behind_its_log
    [%i[writer writer bypass bypass], %i[writer bypass bypass bypass], %i[writer writer writer bypass],
     %i[writer writer with_lock bypass]].each do |kinds|
      %i[read_first row_first].each do |lp|
        assert_nil explore(kinds, last_pass: lp)[:diverged_at_rest], "#{kinds.inspect} #{lp}"
      end
    end
  end

  def test_writers_and_bypass_writes_alone_do_not_deadlock
    [%i[writer writer bypass bypass], %i[writer writer writer bypass], %i[ryw writer bypass]].each do |kinds|
      assert_nil explore(kinds)[:deadlock], kinds.inspect
    end
  end

  # The row before the aggregate lock (with_lock, then a write) against the
  # aggregate lock before the row (a bypass write, or read-your-writes after a
  # plain write): a wait cycle PostgreSQL breaks.
  def test_the_row_before_the_aggregate_lock_can_deadlock
    [%i[with_lock bypass], %i[ryw with_lock]].each { |kinds| refute_nil explore(kinds)[:deadlock], kinds.inspect }
  end

  # The fix (1.0.1): a locking read takes the aggregate lock, then the stream's,
  # then the row, and brings the row up to date. Every mix above that
  # deadlocked is then clean.
  def test_the_ordered_locking_read_does_not_deadlock
    [%i[with_lock_ordered bypass], %i[ryw with_lock_ordered], %i[ryw_with_lock_ordered with_lock_ordered writer],
     %i[ryw_with_lock_ordered ryw_with_lock_ordered writer], %i[writer with_lock_ordered with_lock_ordered bypass],
     %i[ryw_with_lock_ordered bypass writer]].each do |kinds|
      result = explore(kinds)
      assert_nil result[:deadlock], kinds.inspect
      assert_nil result[:diverged_at_rest], kinds.inspect
    end
  end

  # ReadYourWrites inside with_lock (the row, then the stream) against a job's
  # last pass (the stream, then the row).
  def test_read_your_writes_under_with_lock_can_deadlock_with_a_last_pass
    refute_nil explore(%i[ryw_with_lock with_lock writer])[:deadlock]
  end

  # A record-level write that skips callbacks, as it was before 1.0.1 (the
  # aggregate lock and the row, no stream lock, the checkpoint unmoved),
  # against a job's last pass that read the stream first: the job writes its
  # older value over the write and the row stays behind its log (the Olist
  # shipments). As it writes from 1.0.1, the bulk write's path (:bypass), never.
  def test_a_record_level_bypass_write_without_the_stream_lock_leaves_the_row_behind
    straight = ->(kinds) { N.explore(N::Config.new(name: kinds.join("+"), kinds: kinds, retries: 0, last_pass: :read_first)) }
    before = straight.(%i[writer record_bypass])
    assert before[:diverged_at_rest], "the row behind its log: #{before.inspect}"
    assert_nil straight.(%i[writer bypass])[:diverged_at_rest]
    assert_nil explore(%i[writer bypass])[:diverged_at_rest]
  end
end
