# frozen_string_literal: true

require "test_helper"
require "timeout"
require_relative "../support/lock_trace"
require_relative "../projections/es_async_locked_reads_test"

# Trace conformance for the concurrency nets: the order in which the code's
# threads are granted Lyra's locks, recorded (test/support/lock_trace.rb) and
# replayed on the net that models them (Lyra::Verification::TraceReplay). Every
# recorded step must fire an enabled transition, and every actor must finish:
# the code takes no lock step the net forbids. The controls check that the
# replay rejects a trace the net forbids. See benchmarks/petri-concurrent-
# writers/TRACE_CONFORMANCE_PLAN.md.
class LockTraceConformanceEsAsyncTest < EsAsyncLockedReadsTest
  EsAsyncLockedReadsTest.instance_methods(false).grep(/^test_/).each { undef_method(_1) }

  N = Lyra::Verification::AsyncLockOrderNet
  # Recorded action => the labels that may fire it, after "<actor>: ". The
  # stream head is not in this net (it is taken under the aggregate lock, so
  # never contended), and an append is fired with its commit, as the net
  # models them.
  RULES = {
    a: [/: takes a$/], s: [/: takes s$/],
    x: [/: takes x$/, /takes the row \(SKIP LOCKED\)/, /: takes the row$/],
    x_busy: [/row taken, lets s go/], h: [], append: [], other: [],
    commit: [/appends \d+ and commits/, /applies \d+ and commits/, /nothing after c \d+, commits/, /writes .* and commits/,
             /writes row and event \d+, moves c, commits/]
  }.freeze
  SILENT = [/: starts$/, /brings the row up to date/, /brings the row up to \d+ \(project_pending\)/, /waits for the row/,
            /finds the row (behind|current)/].freeze

  def setup
    super
    LockTrace.install!
  end

  def test_two_increments_under_with_lock
    assert_fits %i[with_lock_ordered with_lock_ordered] do |held, go|
      [actor("w0") { r = AsyncLockItem.find(@id); r.with_lock { held << true; go.pop; r.update!(n: r.n + 1) } },
       actor("w1", after: held) { r = AsyncLockItem.find(@id); r.with_lock { r.update!(n: r.n + 1) } }]
    end
  end

  def test_two_increments_under_lock_find
    assert_fits %i[with_lock_ordered with_lock_ordered] do |held, go|
      [actor("w0") { AsyncLockItem.transaction { r = AsyncLockItem.lock.find(@id); held << true; go.pop; r.update!(n: r.n + 1) } },
       actor("w1", after: held) { AsyncLockItem.transaction { r = AsyncLockItem.lock.find(@id); r.update!(n: r.n + 1) } }]
    end
  end

  def test_two_increments_under_lock_where
    assert_fits %i[with_lock_ordered with_lock_ordered] do |held, go|
      [actor("w0") { AsyncLockItem.transaction { r = AsyncLockItem.lock.where(id: @id).first; held << true; go.pop; r.update!(n: r.n + 1) } },
       actor("w1", after: held) { AsyncLockItem.transaction { r = AsyncLockItem.lock.where("n >= 0").first; r.update!(n: r.n + 1) } }]
    end
  end

  def test_a_plain_writer_after_a_locking_reader
    assert_fits %i[with_lock_ordered writer] do |held, go|
      [actor("w0") { r = AsyncLockItem.find(@id); r.with_lock { held << true; go.pop; r.update!(n: r.n + 10) } },
       actor("w1", after: held) { AsyncLockItem.find(@id).update!(n: 100) }]
    end
  end

  # A write that skips callbacks (update_all) holding the aggregate lock, and
  # a writer waiting for it: the bypass finds the row current, takes it, writes
  # the row and its event and moves the checkpoint; the writer's job follows.
  def test_a_bypass_write_then_a_writer
    assert_fits %i[bypass writer] do |held, go|
      [actor("w0") { AsyncLockItem.transaction { AsyncLockItem.where(id: @id).update_all(n: 5); held << true; go.pop } },
       actor("w1", after: held) { AsyncLockItem.find(@id).update!(n: 7) }]
    end
  end
  
  # A writer whose job has not run, then an upsert_all of its record: the
  # bypass finds the row behind its log and brings it up to date under the
  # stream lock first (project_pending).
  def test_a_bypass_write_after_a_writer_whose_job_has_not_run
    assert_fits %i[writer bypass] do |held, go|
      [actor("w0") { AsyncLockItem.find(@id).update!(n: 7); held << true },
       actor("w1", after: held) { go.pop; AsyncLockItem.transaction { AsyncLockItem.upsert_all([{ id: @id, n: 5 }], unique_by: :id) } }]
    end
  end

  # The same with an update_all whose SQL reads the row (n = n + 1): it too
  # brings the row up to date under the stream lock before its write, so the
  # pending update counts (Monitor's result, 8).
  def test_an_update_all_expression_after_a_writer_whose_job_has_not_run
    assert_fits %i[writer bypass] do |held, go|
      [actor("w0") { AsyncLockItem.find(@id).update!(n: 7); held << true },
       actor("w1", after: held) { go.pop; AsyncLockItem.transaction { AsyncLockItem.where(id: @id).update_all("n = n + 1") } }]
    end
    assert_equal 8, value
  end

  # A record-level write that skips callbacks (touch) after a writer whose
  # job has not run: from 1.0.1 it takes the bulk write's path (the stream's
  # lock, the row brought up to date, then the write: the net's bypass kind),
  # where before it took the aggregate lock and the row only (record_bypass).
  def test_a_touch_after_a_writer_whose_job_has_not_run
    assert_fits %i[writer bypass] do |held, go|
      [actor("w0") { AsyncLockItem.find(@id).update!(n: 7); held << true },
       actor("w1", after: held) { go.pop; AsyncLockItem.transaction { AsyncLockItem.find(@id).touch } }]
    end
    assert_equal 7, value
  end

  # Controls: the replay rejects what the net forbids.
  def test_the_replay_rejects_two_holders_of_one_aggregate_lock
    s = LockTrace::Step
    result = replay(%i[with_lock_ordered with_lock_ordered], [s.new(1, "w0", :a), s.new(2, "w0", :s), s.new(3, "w1", :a)])
    assert_equal ["  3 w1 a"], result[:divergences].map { _1[:step] }
  end

  def test_the_replay_rejects_the_row_before_the_aggregate_lock
    result = replay(%i[with_lock_ordered with_lock_ordered], [LockTrace::Step.new(1, "w0", :x)])
    assert_equal ["  1 w0 x"], result[:divergences].map { _1[:step] }
  end

  private

  # Runs the block's actors (threads), records their lock steps and the jobs'
  # (run afterwards, in the order they were enqueued), and replays them on the
  # net of +kinds+: fitness 1 and every actor done.
  def assert_fits(kinds)
    held = Queue.new
    go = Queue.new
    steps = LockTrace.record(table: TABLE) do
      threads = yield(held, go)
      sleep 0.3
      go << true
      threads.each { |thread| Timeout.timeout(20) { thread.value } }
      LockTrace.as("j") { value }
    end
    result = replay(kinds, number_jobs(steps, kinds))
    assert_empty result[:divergences], -> { "divergences:\n#{result[:divergences].map { "#{_1[:step]} | enabled: #{_1[:enabled].first(6).join(' ; ')}" }.join("\n")}\ntrace:\n#{steps.join("\n")}" }
    assert result[:done], "every actor reaches its end:\n#{steps.join("\n")}"
    assert_operator result[:fired], :>, 0
  end

  def actor(name, after: nil, &block)
    after&.pop
    after&.push(true) # leave the signal for a later actor
    Thread.new { ActiveRecord::Base.connection_pool.with_connection { LockTrace.as(name, &block) } }.tap { _1.report_on_exception = false }
  end

  # The test's job thread runs every job, one after another, in the order
  # their writers committed: the n-th job is that of the n-th writer with a job
  # (a bypass write has none) to commit.
  def number_jobs(steps, kinds)
    owners = steps.select { _1.action == :commit && _1.actor.match?(/\Aw\d+\z/) }.map { Integer(_1.actor.delete_prefix("w")) }
                  .uniq.select { N::WITH_JOB.include?(kinds[_1]) }
    n = 0
    steps.map do |step|
      next step unless step.actor == "j"

      named = step.dup
      named.actor = "j#{owners.fetch(n, n)}"
      n += 1 if step.action == :commit
      named
    end
  end

  def replay(kinds, steps)
    net = N.new(N::Config.new(name: kinds.join("+"), kinds: kinds, retries: 3, last_pass: :read_first)).net
    actors = kinds.each_index.flat_map { |i| ["w#{i}", ("j#{i}" if N::WITH_JOB.include?(kinds[i]))].compact }
    Lyra::Verification::TraceReplay.new(net, actors: actors, rules: RULES, silent: SILENT).replay(steps)
  end
end
