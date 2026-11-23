# frozen_string_literal: true

require "test_helper"
require "timeout"
require_relative "../support/lock_trace"
require_relative "../projections/lazy_locked_reads_test"

# Trace conformance for ES-Lazy's lock order (Lyra::Verification::
# LazyLockOrderNet): lock grants recorded from ES-Lazy's locking-read
# scenarios, replayed on the net (see lock_trace_conformance_test.rb for the
# method). A catch-up runs on a connection of its own, in a thread the
# recorder does not follow, as the net leaves it out (it takes no lock a writer
# holds, and skips a held row).
class LockTraceConformanceLazyTest < LazyLockedReadsTest
  LazyLockedReadsTest.instance_methods(false).grep(/^test_/).each { undef_method(_1) }

  N = Lyra::Verification::LazyLockOrderNet
  RULES = {
    a: [/: takes a$/], x: [/: takes x$/], h: [/: takes h$/], s: [], other: [], x_busy: [], append: [],
    commit: [/: commits \d+/]
  }.freeze
  SILENT = [/replays \(row \d+ -> \d+\) and reads/, /catches up on its own connection/].freeze

  def setup
    super
    LockTrace.install!
  end

  def test_two_increments_under_with_lock
    assert_fits %i[with_lock_a_first with_lock_a_first] do |held, go|
      [actor("w0") { r = LockItem.find(@id); r.with_lock { held << true; go.pop; r.update!(n: r.n + 1) } },
       actor("w1", after: held) { r = LockItem.find(@id); r.with_lock { r.update!(n: r.n + 1) } }]
    end
  end

  def test_two_increments_under_lock_find
    assert_fits %i[with_lock_a_first with_lock_a_first] do |held, go|
      [actor("w0") { LockItem.transaction { r = LockItem.lock.find(@id); held << true; go.pop; r.update!(n: r.n + 1) } },
       actor("w1", after: held) { LockItem.transaction { r = LockItem.lock.find(@id); r.update!(n: r.n + 1) } }]
    end
  end

  def test_a_plain_writer_after_a_locking_reader
    assert_fits %i[with_lock_a_first plain] do |held, go|
      [actor("w0") { r = LockItem.find(@id); r.with_lock { held << true; go.pop; r.update!(n: r.n + 10) } },
       actor("w1", after: held) { LockItem.find(@id).update!(n: 100) }]
    end
  end

  # A write that skips callbacks (update_all): the aggregate lock, its rows,
  # the head; a plain writer waits for it.
  def test_a_bulk_write_then_a_plain_writer
    assert_fits %i[bulk plain] do |held, go|
      [actor("w0") { LockItem.transaction { LockItem.where(id: @id).update_all(n: 5); held << true; go.pop } },
       actor("w1", after: held) { LockItem.find(@id).update!(n: 7) }]
    end
  end
  
  # A writer that reads its own record again before it commits: its event is
  # not visible to the catch-up's connection, so it replays it onto the row
  # itself, which takes the row.
  def test_a_writer_that_reads_its_own_write_then_a_plain_writer
    assert_fits %i[writes_then_reads plain] do |held, go|
      [actor("w0") { LockItem.transaction { LockItem.find(@id).update!(n: 3); LockItem.find(@id); held << true; go.pop } },
       actor("w1", after: held) { LockItem.find(@id).update!(n: 7) }]
    end
  end

  def test_the_replay_rejects_the_row_before_the_aggregate_lock
    result = replay(%i[with_lock_a_first with_lock_a_first], [LockTrace::Step.new(1, "w0", :x)])
    assert_equal ["  1 w0 x"], result[:divergences].map { _1[:step] }
  end

  private

  def assert_fits(kinds)
    held = Queue.new
    go = Queue.new
    steps = LockTrace.record(table: TABLE) do
      threads = yield(held, go)
      sleep 0.3
      go << true
      threads.each { |thread| Timeout.timeout(20) { thread.value } }
    end
    result = replay(kinds, steps)
    assert_empty result[:divergences], -> { "divergences:\n#{result[:divergences].map { "#{_1[:step]} | enabled: #{_1[:enabled].first(6).join(' ; ')}" }.join("\n")}\ntrace:\n#{steps.join("\n")}" }
    assert result[:done], "every actor reaches its end:\n#{steps.join("\n")}"
    assert_operator result[:fired], :>, 0
  end

  def actor(name, after: nil, &block)
    after&.pop
    after&.push(true)
    Thread.new { ActiveRecord::Base.connection_pool.with_connection { LockTrace.as(name, &block) } }.tap { _1.report_on_exception = false }
  end

  def replay(kinds, steps)
    net = N.new(N::Config.new(name: kinds.join("+"), kinds: kinds)).net
    Lyra::Verification::TraceReplay.new(net, actors: kinds.each_index.map { "w#{_1}" }, rules: RULES, silent: SILENT).replay(steps)
  end
end
