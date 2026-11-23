# frozen_string_literal: true

require "test_helper"

# ES-Lazy: the check before a read catches up when an event above the
# checkpoint, or the event of a gap listed below it, is visible to that read
# (ids are assigned before commit: such an id is a gap until its transaction
# commits). No more than that: LazyProjection's comment lists the limits.
#
# The fast path before a read took the tables for up to date while the gaps
# had been re-checked within GAP_RECHECK in the process, whether or not a
# gap's event had committed since. A thread missed its own committed write,
# and a read-modify-write on that read lost it without an error.
#
# The order of events is made with queues and pipes, not with sleeps.
# +just_rechecked!+ stands for "the gaps were re-checked a moment ago", so no
# test depends on running within GAP_RECHECK.
class LazyVisibleEventsTest < Minitest::Test
  LazyProjection = Lyra::Projections::LazyProjection
  TIMEOUT = 20

  def setup
    skip "Requires PostgreSQL" unless defined?(ActiveRecord::Base) && ActiveRecord::Base.connection.adapter_name.match?(/postgres/i)

    Object.send(:remove_const, :VisibleArticle) if Object.const_defined?(:VisibleArticle)
    Object.const_set(:VisibleArticle, Class.new(ActiveRecord::Base) do
      self.table_name = "articles"
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
    end)

    @open = []
    clean
    Lyra.config.enable_event_sourcing!
    Lyra.config.projection_mode = :lazy
    Lyra.config.monitor_model(VisibleArticle)
    @base = article("0")
    VisibleArticle.count
    # Less the ids of earlier tests' events, which a fresh checkpoint watches.
    raw_write("UPDATE #{LazyProjection::TABLE} SET gaps = '{}'")
  end

  def teardown
    return unless @open

    @open.each(&:abandon)
    Lyra.config.projection_mode = :sync
    clean
  end

  # A thread's own committed write

  def test_a_thread_sees_its_own_committed_create
    writer = open_write(after: ->(id) { VisibleArticle.find_by(id: id)&.title }) { article("mine").id }
    pass_the_open_ids!

    assert_equal "mine", writer.commit, "the thread missed the create it had committed"
  end

  def test_a_thread_does_not_lose_its_own_committed_update
    id = @base.id
    increment = lambda do |*|
      seen = VisibleArticle.find(id)
      seen.update!(title: (seen.title.to_i + 1).to_s)
    end
    writer = open_write(after: increment, &increment)
    pass_the_open_ids!
    writer.commit

    assert_equal "2", VisibleArticle.find(id).title, "two increments from 0, by one thread"
  end

  def test_a_thread_does_not_lose_its_own_committed_update_under_a_row_lock
    id = @base.id
    increment = lambda do |*|
      ActiveRecord::Base.transaction do
        seen = VisibleArticle.lock.find(id)
        seen.update!(title: (seen.title.to_i + 1).to_s)
      end
    end
    writer = open_write(after: increment) { VisibleArticle.find(id).update!(title: "1") }
    pass_the_open_ids!
    writer.commit

    assert_equal "2", VisibleArticle.find(id).title, "two increments from 0, the second under a row lock"
  end

  def test_a_thread_sees_its_own_committed_destroy
    id = @base.id
    writer = open_write(after: ->(_) { VisibleArticle.find_by(id: id) }) { VisibleArticle.find(id).destroy! }
    pass_the_open_ids!

    assert_nil writer.commit, "the thread still found the record it had destroyed"
  end

  def test_a_thread_sees_its_own_committed_write_in_its_next_transaction
    read = ->(id) { ActiveRecord::Base.transaction { VisibleArticle.find_by(id: id)&.title } }
    writer = open_write(after: read) { article("mine").id }
    pass_the_open_ids!

    assert_equal "mine", writer.commit
  end

  def test_a_transaction_sees_its_own_uncommitted_write_below_the_checkpoint
    wrote = Queue.new
    go = Queue.new
    writer = in_thread do
      ActiveRecord::Base.transaction do
        id = article("mine").id
        wrote << true
        take(go)
        VisibleArticle.find_by(id: id)&.title
      end
    end
    take(wrote)
    pass_the_open_ids!
    go << true

    assert_equal "mine", value_of(writer)
  end

  # Writes that skip callbacks start with a catch-up

  def test_update_all_after_the_threads_own_committed_create_writes_it
    write = ->(id) { VisibleArticle.where(id: id).update_all(title: "changed") }
    writer = open_write(after: write) { article("mine").id }
    pass_the_open_ids!

    assert_equal 1, writer.commit, "update_all matched nothing, and the change was lost"
    assert_equal "changed", VisibleArticle.find(writer.written).title
  end

  def test_update_columns_after_the_threads_own_committed_create_writes_it
    writer = open_write(after: ->(record) { record.update_columns(title: "changed") }) { article("mine") }
    pass_the_open_ids!

    assert writer.commit, "update_columns matched no row"
    assert_equal "changed", VisibleArticle.find(writer.written.id).title
  end

  # Another connection's committed write

  def test_another_connections_committed_create_below_the_checkpoint_is_seen
    writer = open_write { article("theirs").id }
    pass_the_open_ids!
    writer.commit

    assert_equal "theirs", VisibleArticle.find_by(id: writer.written)&.title
  end

  def test_another_connections_committed_update_below_the_checkpoint_is_seen
    writer = open_write { VisibleArticle.find(@base.id).update!(title: "theirs") }
    pass_the_open_ids!
    writer.commit

    assert_equal "theirs", VisibleArticle.find(@base.id).title
  end

  def test_an_application_transaction_sees_a_write_committed_during_it_below_the_checkpoint
    writer = open_write { article("theirs").id }
    pass_the_open_ids!

    seen = ActiveRecord::Base.transaction do
      VisibleArticle.count
      writer.commit
      just_rechecked!
      VisibleArticle.find_by(id: writer.written)&.title
    end
    assert_equal "theirs", seen
  end

  def test_every_kind_of_read_sees_a_write_committed_below_the_checkpoint
    reads = {
      count: -> { VisibleArticle.where(title: "theirs").count },
      pluck: -> { VisibleArticle.where(title: "theirs").pluck(:id).size },
      exists: -> { VisibleArticle.where(title: "theirs").exists? ? 1 : 0 },
      to_a: -> { VisibleArticle.where(title: "theirs").to_a.size }
    }
    reads.each do |kind, read|
      writer = open_write { article("theirs").id }
      pass_the_open_ids!
      writer.commit

      assert_equal 1, read.call, "#{kind} missed the committed write"
      VisibleArticle.find(writer.written).destroy!
    end
  end

  def test_a_forced_catch_up_applies_a_write_committed_below_the_checkpoint
    writer = open_write { article("theirs").id }
    pass_the_open_ids!
    writer.commit

    # The mode check, leaving ES-Lazy, with the process configured for the target mode.
    Lyra.config.projection_mode = :sync
    LazyProjection.catch_up!(force: true)

    assert_equal "theirs", raw("SELECT title FROM articles WHERE id = #{writer.written}")
  end

  # Another process's committed write

  def test_another_processs_committed_write_below_the_checkpoint_is_seen
    worker = in_process do |pause|
      id = ActiveRecord::Base.transaction do
        article("theirs").id.tap { pause.call }
      end
      id.to_s
    end
    worker.paused
    pass_the_open_ids!
    id = worker.finish

    assert_equal "theirs", VisibleArticle.find_by(id: id)&.title
  end

  def test_a_process_sees_its_own_committed_write_passed_by_another_processs_catch_up
    worker = in_process do |pause|
      id = ActiveRecord::Base.transaction do
        article("mine").id.tap { pause.call }
      end
      just_rechecked!
      VisibleArticle.find_by(id: id)&.title.to_s
    end
    worker.paused
    pass_the_open_ids!

    assert_equal "mine", worker.finish, "the process missed the create it had committed"
  end

  # Gaps

  def test_several_gaps_are_each_seen_once_committed
    writers = %w[a b c].map { |title| open_write { article(title).id } }
    pass_the_open_ids!
    assert_operator gaps.size, :>=, 3

    committed = []
    [1, 2, 0].each do |i|
      writers[i].commit
      committed << %w[a b c][i]
      just_rechecked!
      assert_equal committed.sort, VisibleArticle.where(title: %w[a b c]).pluck(:title).sort
      assert_equal 3 - committed.size, gaps.size, "only the gaps still open stay listed"
    end
  end

  def test_the_gap_of_a_rolled_back_transaction_hides_no_committed_write
    lost = open_write { article("rolled back").id }
    kept = open_write { article("kept").id }
    pass_the_open_ids!
    lost.rollback
    kept.commit

    assert_equal "kept", VisibleArticle.find_by(id: kept.written)&.title
    assert_nil VisibleArticle.find_by(id: lost.written)
    assert_equal 1, gaps.size, "the rolled-back id is still watched"
  end

  def test_gaps_that_are_not_consecutive_are_each_seen
    first = open_write { article("first").id }
    article("between")
    second = open_write { article("second").id }
    pass_the_open_ids!
    second.commit

    assert_equal "second", VisibleArticle.find_by(id: second.written)&.title
    first.commit
    just_rechecked!
    assert_equal "first", VisibleArticle.find_by(id: first.written)&.title
  end

  def test_a_gap_below_the_first_event_of_a_fresh_checkpoint_is_seen
    clean
    writer = open_write { article("first").id }
    pass_the_open_ids!
    writer.commit

    assert_equal "first", VisibleArticle.find_by(id: writer.written)&.title
  end

  # A read with only invisible gaps takes the catch-up lock no more often
  # than the re-check every GAP_RECHECK does.

  def test_reads_with_only_open_gaps_take_no_catch_up_lock
    open_write { article("in flight").id }
    pass_the_open_ids!

    sql = statements { 20.times { VisibleArticle.count } }

    assert_empty sql.grep(catch_up_lock)
  end

  def test_a_read_with_an_open_gap_costs_one_query_more
    open_write { article("in flight").id }
    pass_the_open_ids!

    sql = statements { VisibleArticle.find(@base.id) }

    assert_equal 3, sql.size, "the log's check, the gap's and the read itself; issued:\n#{sql.join("\n")}"
  end

  def test_reads_with_only_a_rolled_back_gap_take_the_lock_once_per_recheck
    open_write { article("rolled back").id }.tap { pass_the_open_ids! }.rollback

    sql = statements { 20.times { VisibleArticle.count } }
    assert_empty sql.grep(catch_up_lock)

    LazyProjection.instance_variable_set(:@gaps_checked_at, nil) # due for a re-check
    sql = statements do
      VisibleArticle.count
      just_rechecked!
      19.times { VisibleArticle.count }
    end
    assert_equal 1, sql.grep(catch_up_lock).size
  end

  def test_a_read_whose_gap_another_reader_filled_meanwhile_takes_no_lock
    writer = open_write { article("theirs").id }
    pass_the_open_ids!
    gap = gaps.keys.first
    writer.commit
    # An open gap whose id begins with the filled one's digits, so that the
    # one still listed is not taken for the other.
    still_open = { gap => Time.now.to_i, "#{gap}000000".to_i => Time.now.to_i }
    raw_write("UPDATE #{LazyProjection::TABLE} SET gaps = '#{JSON.generate(still_open)}'")

    seen = nil
    fill = lambda do
      # Another connection's catch-up, between this read's statements.
      filled = value_of(in_thread do
        LazyProjection.instance_variable_set(:@gaps_checked_at, nil)
        LazyProjection.catch_up!
      end)
      assert_equal 1, filled
      just_rechecked!
    end
    sql = statements(after_first: /SELECT c\.position/, run: fill) { seen = VisibleArticle.find_by(id: writer.written)&.title }

    assert_equal "theirs", seen
    assert_empty sql.grep(catch_up_lock), "nothing was left to fill"
  end

  # Catch-ups in flight

  def test_a_read_waits_for_an_uncommitted_catch_up_that_fills_a_visible_gap
    writer = open_write { article("theirs").id }
    pass_the_open_ids!
    writer.commit
    LazyProjection.instance_variable_set(:@gaps_checked_at, nil)
    # A catch-up under way that has filled the gap and not committed. (A
    # reader's catch-up inside its transaction commits at once on a connection
    # of its own from 1.0.1, so the holder runs the catch-up's own steps.)
    holder = open_write do
      Thread.current[:lyra_lazy_catching_up] = true
      LazyProjection.send(:lock!, ActiveRecord::Base.connection)
      LazyProjection.send(:apply_pending, ActiveRecord::Base.connection)
    end

    pid = Queue.new
    reader = in_thread do
      pid << raw("SELECT pg_backend_pid()").to_i
      VisibleArticle.find_by(id: writer.written)&.title
    end
    wait_until_waiting(reader, take(pid))
    holder.commit

    assert_equal "theirs", value_of(reader)
  end

  def test_a_read_sees_a_gaps_event_after_the_catch_up_that_filled_it_rolled_back
    writer = open_write { article("theirs").id }
    pass_the_open_ids!
    writer.commit
    LazyProjection.instance_variable_set(:@gaps_checked_at, nil)
    ActiveRecord::Base.transaction do
      VisibleArticle.count # fills the gap
      raise ActiveRecord::Rollback
    end
    just_rechecked!

    assert_equal "theirs", VisibleArticle.find_by(id: writer.written)&.title
  end

  def test_a_commit_between_a_catch_ups_reads_is_seen_by_that_catch_up
    writer = open_write { article("theirs").id }
    article("later id")

    statements(after_first: /WHERE id > /, run: -> { writer.commit }) { VisibleArticle.count }

    assert_equal "theirs", raw("SELECT title FROM articles WHERE id = #{writer.written}")
  end

  def test_a_commit_after_a_catch_up_rechecked_its_gap_is_seen_by_the_next_read
    writer = open_write { article("theirs").id }
    article("later id")

    statements(after_first: /UPDATE #{LazyProjection::TABLE}/o, run: -> { writer.commit }) { VisibleArticle.count }
    just_rechecked!

    assert_equal "theirs", VisibleArticle.find_by(id: writer.written)&.title
  end

  # REPEATABLE READ: what is visible is what the transaction's snapshot has.

  def test_repeatable_read_sees_a_write_committed_before_its_snapshot
    writer = open_write { article("theirs").id }
    pass_the_open_ids!
    writer.commit

    seen = ActiveRecord::Base.transaction(isolation: :repeatable_read) { VisibleArticle.find_by(id: writer.written)&.title }
    assert_equal "theirs", seen
  end

  def test_repeatable_read_takes_no_lock_for_a_write_committed_after_its_snapshot
    writer = open_write { article("theirs").id }
    pass_the_open_ids!

    seen = :unread
    sql = nil
    ActiveRecord::Base.transaction(isolation: :repeatable_read) do
      VisibleArticle.count # the snapshot
      writer.commit
      sql = statements { seen = VisibleArticle.find_by(id: writer.written) }
    end

    assert_nil seen
    assert_empty sql.grep(catch_up_lock)
    just_rechecked!
    assert_equal "theirs", VisibleArticle.find_by(id: writer.written)&.title
  end

  # The query cache (a request, a job): nothing that decides or does a
  # catch-up comes from it.

  def test_the_query_cache_does_not_hide_a_write_committed_above_the_checkpoint
    seen = ActiveRecord::Base.cache do
      VisibleArticle.count
      id = value_of(in_thread { article("theirs").id })
      VisibleArticle.find_by(id: id)&.title
    end

    assert_equal "theirs", seen
  end

  def test_the_query_cache_does_not_hide_a_write_committed_below_the_checkpoint
    writer = open_write { article("theirs").id }
    pass_the_open_ids!

    seen = ActiveRecord::Base.cache do
      VisibleArticle.count
      writer.commit
      just_rechecked!
      VisibleArticle.find_by(id: writer.written)&.title
    end
    assert_equal "theirs", seen
  end

  def test_a_locking_read_under_the_query_cache_starts_from_a_committed_update
    id = @base.id
    seen = ActiveRecord::Base.cache do
      VisibleArticle.count
      value_of(in_thread { VisibleArticle.find(id).update!(title: "theirs") })
      ActiveRecord::Base.transaction { VisibleArticle.lock.find(id).title }
    end

    assert_equal "theirs", seen
  end

  def test_a_repeated_query_under_the_query_cache_sees_what_its_own_catch_up_applied
    id = @base.id
    seen = ActiveRecord::Base.cache do
      VisibleArticle.find(id)
      value_of(in_thread { VisibleArticle.find(id).update!(title: "theirs") })
      VisibleArticle.find(id).title
    end

    assert_equal "theirs", seen
  end

  def test_the_catch_up_lock_is_never_answered_from_the_query_cache
    open_write { article("rolled back").id }.tap { pass_the_open_ids! }.rollback

    sql = statements do
      ActiveRecord::Base.cache do
        2.times do |i|
          LazyProjection.instance_variable_set(:@gaps_checked_at, nil) # due for a re-check
          VisibleArticle.where(title: i.to_s).count
        end
      end
    end

    assert_equal 2, sql.grep(catch_up_lock).size, "a second catch-up ran on the first one's answer, without the lock"
  end

  def test_refresh_records_does_not_replay_a_stream_from_the_query_cache
    id = @base.id
    stream = Lyra.stream_name(VisibleArticle, id)
    ActiveRecord::Base.cache do
      Lyra.config.event_store.read.stream(stream).to_a
      value_of(in_thread { VisibleArticle.find(id).update!(title: "theirs") })
      ActiveRecord::Base.transaction { LazyProjection.refresh_records(VisibleArticle, [id]) }
    end

    assert_equal "theirs", raw("SELECT title FROM articles WHERE id = #{id}")
  end

  private

  def article(title) = VisibleArticle.create!(title: title, body: "x", status: "draft")

  def raw(sql) = ActiveRecord::Base.connection.uncached { ActiveRecord::Base.connection.select_value(sql) }

  def raw_write(sql) = ActiveRecord::Base.connection.execute(sql)

  def gaps = LazyProjection.checkpoint.last

  # Another event commits and is applied, so the ids of the writes still open
  # are gaps below the checkpoint, re-checked a moment ago.
  def pass_the_open_ids!
    article("later id")
    VisibleArticle.count
    refute_empty gaps, "the open write's id is watched as a gap"
    just_rechecked!
  end

  def just_rechecked!
    LazyProjection.instance_variable_set(:@gaps_checked_at, Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3_600)
  end

  def catch_up_lock = /pg_(try_)?advisory_xact_lock(_shared)?\(hashtext\('#{LazyProjection::LOCK}'\)\)/o

  # The SQL this thread sends in the block (query cache hits excluded).
  # +run+ is called once, after the first statement that matches +after_first+.
  def statements(after_first: nil, run: nil)
    seen = []
    thread = Thread.current
    ran = false
    subscription = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      next unless Thread.current == thread
      next if payload[:name].to_s == "SCHEMA" || payload[:cached]

      seen << payload[:sql].to_s
      if after_first && !ran && payload[:sql].to_s.match?(after_first)
        ran = true
        run.call
      end
    end
    yield
    flunk "no statement matched #{after_first.inspect}" if after_first && !ran
    seen
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription)
  end

  def in_thread(&block)
    Thread.new { ActiveRecord::Base.connection_pool.with_connection { block.call } }.tap { |t| t.report_on_exception = false }
  end

  def take(queue) = queue.pop(timeout: TIMEOUT) || flunk("nothing within #{TIMEOUT} s")

  def value_of(thread)
    flunk "a thread did not end within #{TIMEOUT} s" unless thread.join(TIMEOUT)
    thread.value
  end

  # A write in a transaction of another connection, open until commit or
  # rollback. +commit+ returns what +after+ returned: run by the same thread,
  # once committed, with what the write returned.
  OpenWrite = Struct.new(:thread, :go, :written) do
    def commit = finish(:commit)
    def rollback = finish(:rollback)

    def abandon
      go << :rollback
      thread.join(TIMEOUT) || thread.kill
    rescue StandardError
      nil # the test has reported it
    end

    private

    def finish(how)
      go << how
      raise "the writer did not end within #{TIMEOUT} s" unless thread.join(TIMEOUT)

      thread.value
    end
  end

  def open_write(after: nil, &write)
    wrote = Queue.new
    go = Queue.new
    thread = in_thread do
      written = nil
      committed = false
      ActiveRecord::Base.transaction do
        written = write.call
        wrote << [written]
        raise ActiveRecord::Rollback unless go.pop == :commit

        committed = true
      end
      after&.call(written) if committed
    rescue StandardError => e
      wrote << e
      raise
    end
    answer = take(wrote)
    raise answer if answer.is_a?(Exception)

    OpenWrite.new(thread, go, answer.first).tap { @open << _1 }
  end

  # A forked process, which runs the block and answers with its string. The
  # block can pause (say so, and wait until +finish+).
  Worker = Struct.new(:pid, :input, :output) do
    def paused
      line = answer
      raise "the process did not pause: #{line.inspect}" unless line == "paused"
    end

    def finish
      input.puts "go"
      line = answer
      raise line unless line.to_s.start_with?("done ")

      stop
      line.delete_prefix("done ")
    end

    def abandon
      return if input.closed?

      stop
    end

    private

    def answer
      raise "no answer from the process within #{TIMEOUT} s" unless output.wait_readable(TIMEOUT)

      output.gets&.chomp
    end

    def stop
      input.close
      output.close
      Process.wait(pid)
    end
  end

  def in_process
    skip "Requires fork" unless Process.respond_to?(:fork)

    child_in, input = IO.pipe
    output, child_out = IO.pipe
    pid = fork do
      input.close
      output.close
      pause = lambda do
        child_out.puts "paused"
        child_out.flush
        raise "abandoned" unless child_in.gets
      end
      begin
        child_out.puts "done #{yield(pause)}"
      rescue StandardError => e
        child_out.puts "failed #{e.class}: #{e.message.lines.first}" rescue nil
      end
      child_out.flush rescue nil
      exit!(0)
    end
    child_in.close
    child_out.close
    Worker.new(pid, input, output).tap { @open << _1 }
  end

  # Until the session +pid+ waits for the catch-up lock. A condition polled,
  # not a time waited for.
  def wait_until_waiting(reader, pid)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + TIMEOUT
    until raw("SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND NOT granted AND pid = #{pid}").to_i.positive?
      flunk "the read went on without waiting: #{value_of(reader).inspect}" unless reader.alive?
      flunk "no reader waits on the catch-up lock" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      Thread.pass
    end
  end

  def clean
    connection = ActiveRecord::Base.connection
    %w[articles event_store_events_in_streams event_store_events].each { connection.execute("DELETE FROM #{_1}") }
    LazyProjection.reset!
  end
end
