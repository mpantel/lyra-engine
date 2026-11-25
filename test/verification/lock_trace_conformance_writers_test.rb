# frozen_string_literal: true

require "test_helper"
require "timeout"
require_relative "../support/lock_trace"

# Trace conformance for the writers net (Lyra::Verification::ConcurrentWritersNet)
# in Hijack, ES-Sync and ES-NoProj: lock grants and reads recorded from two
# writers of one record, replayed on the net of the mode's configuration with
# Hypothesis H's history clauses at the append (see lock_trace_conformance_test.rb
# for the method).
#
# What the net's one lock stands for:
# - Hijack and ES-Sync: the record's own row, taken FOR NO KEY UPDATE (FOR
#   UPDATE for a destroy) before the append, or by with_lock; where the row is
#   gone, the aggregate's advisory lock;
# - ES-NoProj: the aggregate's advisory lock, which its locking reads take too.
# The stream head (taken under that lock) is the net's check; a refusal has no
# step of its own. Each writer's read is recorded: outside the lock for a plain
# update (so a lost update the code makes, the net makes too), and inside it
# for with_lock, whose reload under the lock is the read the net models.
class LockTraceConformanceWritersTest < Minitest::Test
  TABLE = "lyra_trace_writers"
  N = Lyra::Verification::ConcurrentWritersNet

  def setup
    skip "Requires Rails and PostgreSQL" unless defined?(ActiveRecord::Base) && connection.adapter_name.match?(/postgres/i)

    connection.create_table(TABLE, force: true) do |t|
      t.integer :n, null: false, default: 0
      t.timestamps
    end
    Object.send(:remove_const, :TraceWriter) if Object.const_defined?(:TraceWriter)
    Object.const_set(:TraceWriter, Class.new(ActiveRecord::Base) { self.table_name = TABLE })
    TraceWriter.include Lyra::Interceptors::CrudInterceptor
    TraceWriter.monitor_with_lyra
    clean
    LockTrace.install!
  end

  def teardown
    return unless defined?(TraceWriter)

    Lyra.reset_config!
    clean
    connection.drop_table(TABLE, if_exists: true)
  end

  { hijack: :table, sync: :table, disabled: :events_only }.each do |mode, net_mode|
    define_method(:"test_#{mode}_two_plain_updates") do
      start(mode)
      assert_fits(net_mode, :before_append, %i[update update]) do |id, held, go|
        [actor("w0") { r = TraceWriter.find(id); held << true; go.pop; r.update!(n: r.n + 1) },
         actor("w1", after: held) { r = TraceWriter.find(id); r.update!(n: r.n + 1) }]
      end
      # Both read 0 outside the lock: the code loses an update (not Lyra's fault,
      # a plain read-modify-write), and the replay marks the same one.
      assert_equal 1, TraceWriter.find(@id).n
      assert_equal 1, @net.place(:bad_lost_update).tokens
    end

    define_method(:"test_#{mode}_two_increments_under_with_lock") do
      start(mode)
      assert_fits(net_mode, :before_read, %i[update update]) do |id, held, go|
        [actor("w0") { r = TraceWriter.find(id); r.with_lock { held << true; go.pop; r.update!(n: r.n + 1) } },
         actor("w1", after: held) { r = TraceWriter.find(id); r.with_lock { r.update!(n: r.n + 1) } }]
      end
      assert_equal 2, TraceWriter.find(@id).n
    end

    define_method(:"test_#{mode}_an_update_racing_a_destroy_is_refused") do
      start(mode)
      assert_fits(net_mode, :before_append, %i[destroy update]) do |id, held, go|
        [actor("w0") { TraceWriter.transaction { TraceWriter.find(id).destroy!; held << true; go.pop } },
         actor("w1", after: held) do
           r = TraceWriter.find(id)
           assert_raises(Lyra::RecordDestroyedError) { r.update!(n: 5) }
         end]
      end
    end
  end

  # Controls: the replay rejects what the net forbids.
  def test_the_replay_rejects_two_holders_of_the_lock
    s = LockTrace::Step
    steps = [s.new(1, "w0", :read), s.new(2, "w0", :x), s.new(3, "w1", :read), s.new(4, "w1", :x)]
    result = replay(:table, :before_append, %i[update update], steps)
    assert_equal ["  4 w1 x"], result[:divergences].map { _1[:step] }
  end

  def test_the_replay_rejects_a_commit_before_the_lock
    s = LockTrace::Step
    result = replay(:events_only, :before_append, %i[update update], [s.new(1, "w0", :read), s.new(2, "w0", :commit)])
    assert_equal ["  2 w0 commit"], result[:divergences].map { _1[:step] }
  end

  private

  def start(mode)
    if mode == :hijack
      Lyra.config.enable_hijack!
    else
      Lyra.config.enable_event_sourcing!
      Lyra.config.projection_mode = mode
    end
    Lyra.config.monitor_model(TraceWriter)
    @id = TraceWriter.create!(n: 0).id
    # A record the scenario never touches: a locking read that took the
    # aggregate locks of other records of the model (ES-NoProj's with_lock
    # before the 1.0.1 release) would show a second grant of the net's one lock.
    TraceWriter.create!(n: 0)
  end

  def assert_fits(net_mode, lock, ops)
    held = Queue.new
    go = Queue.new
    steps = LockTrace.record(table: TABLE) do
      threads = yield(@id, held, go)
      sleep 0.3
      go << true
      threads.each { |thread| Timeout.timeout(20) { thread.value } }
    end
    result = replay(net_mode, lock, ops, steps)
    assert_empty result[:divergences], -> { "divergences:\n#{result[:divergences].map { "#{_1[:step]} | enabled: #{_1[:enabled].first(6).join(' ; ')}" }.join("\n")}\ntrace:\n#{steps.join("\n")}" }
    assert result[:done], "every writer reaches its end:\n#{steps.join("\n")}"
    assert_operator result[:fired], :>, 0
  end

  # The writers net of the mode, with H's history clauses at the append; reads
  # recorded before a with_lock are outside the lock and not the net's read.
  def replay(net_mode, lock, ops, steps)
    config = N::Config.new(name: "H1 #{net_mode} #{lock}", mode: net_mode, lock: lock, lock_creates: true, guard: :h1,
                           read_from: net_mode == :events_only ? :stream : :row)
    net = @net = N.new(config, ops, start: :live).net
    read = [/ update: read \d+ from the /, / (create|destroy): begin$/]
    rules = {
      read: lock == :before_read ? [] : read,
      x: [/: lock$/], a: [/: lock$/], h: [/: check passes/], commit: [/: commit/],
      x_none: [], x_busy: [], s: [], other: [], append: []
    }
    silent = [/: refused/, *(lock == :before_read ? read : [])]
    Lyra::Verification::TraceReplay.new(net, actors: ops.each_index.map { "w#{_1}" }, rules: rules, silent: silent, separator: " ").replay(steps)
  end

  def actor(name, after: nil, &block)
    after&.pop
    after&.push(true)
    Thread.new { ActiveRecord::Base.connection_pool.with_connection { LockTrace.as(name, &block) } }.tap { _1.report_on_exception = false }
  end

  def connection = ActiveRecord::Base.connection

  def clean
    %w[event_store_events_in_streams event_store_events].each { connection.execute("DELETE FROM #{_1}") }
    connection.execute("DELETE FROM #{Lyra::StreamHeads::TABLE}") if connection.table_exists?(Lyra::StreamHeads::TABLE)
    Lyra::Projections::LazyProjection.reset!
  end
end
