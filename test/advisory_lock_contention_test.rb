# frozen_string_literal: true

require "test_helper"

# AdvisoryLock.xact_lock_all when another session holds some of the locks.
# A caller that holds no advisory lock of its own yet (a bulk write) waits
# for those, keeping the ones it took, but never as long as
# deadlock_timeout: it gives every lock back when the time is up and tries
# again. So it is not kept out for good by sessions that come and go with a
# few of its records, it is never part of a deadlock PostgreSQL reports, and
# a session that holds one of its locks and asks for another it took goes on.
# A caller that already holds locks of its own waits holding none of the
# new ones, as before.
class AdvisoryLockContentionTest < Minitest::Test
  KEYS = %w[lyra_test/contention/a lyra_test/contention/b lyra_test/contention/c].freeze
  LOCK = Lyra::AdvisoryLock

  def setup
    skip "Requires Rails and PostgreSQL" unless defined?(ActiveRecord::Base) &&
                                                ActiveRecord::Base.connection.adapter_name.match?(/postgres/i)
  end

  # Uncontended, inside a transaction: one try, nothing else.
  def test_free_locks_take_one_statement_in_a_savepoint
    with_sessions(1) do |bulk|
      statements = recording(bulk) do
        bulk.transaction { assert LOCK.xact_lock_all(bulk, KEYS, purpose: "aggregate write") }
      end
      assert_equal 1, statements.count { _1.include?("pg_try_advisory_xact_lock") }
      assert_empty(statements.grep(/lock_timeout|pg_locks|pg_advisory_xact_lock\(/))
    end
  end

  # The lock another session holds is waited for, the others are kept
  # meanwhile (a third session cannot take them), and the call returns once
  # the holder ends, holding all, with lock_timeout as it was. (The bounds
  # are raised here so that the wait outlasts the test's checks.)
  def test_a_bulk_write_waits_for_a_held_lock_keeping_the_others
    with_long_waits do
      with_sessions(3) do |holder, bulk, third|
        hold(holder, KEYS[1])
        bulk_pid = pid(bulk)
        result = @thread = Thread.new do
          bulk.transaction do
            bulk.select_value("SELECT set_config('deadlock_timeout', '20s', true)")
            taken = LOCK.xact_lock_all(bulk, KEYS, purpose: "aggregate write")
            [taken, bulk.select_value("SHOW lock_timeout"), held_by_other?(third, KEYS)]
          end
        end
        wait_until_waiting(holder, bulk_pid)
        assert_equal [true, true], held_by_other?(third, [KEYS[0], KEYS[2]]), "the locks it took are kept while it waits"

        holder.commit_db_transaction
        taken, lock_timeout, held = result.value
        assert taken
        assert_equal "0", lock_timeout
        assert_equal [true, true, true], held
      end
    end
  end

  # A session that holds one of the locks and then asks for another the
  # call took: the call gives its locks back well within deadlock_timeout,
  # so that session goes on and nobody is reported deadlocked; the call then
  # takes them all once the session ends.
  def test_a_bulk_write_gives_its_locks_back_to_a_holder_that_waits_for_one_of_them
    with_sessions(2) do |holder, bulk|
      hold(holder, KEYS[1])
      bulk_pid = pid(bulk)
      result = @thread = Thread.new do
        bulk.transaction { LOCK.xact_lock_all(bulk, KEYS, purpose: "aggregate write") }
      rescue StandardError => e
        e
      end
      wait_until_waiting(holder, bulk_pid)

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      holder.execute("SELECT pg_advisory_xact_lock(hashtext(#{holder.quote(KEYS[0])}))")
      waited = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      deadlock_timeout = holder.select_value(
        "SELECT EXTRACT(epoch FROM current_setting('deadlock_timeout')::interval)"
      ).to_f
      assert_operator waited, :<, deadlock_timeout

      holder.commit_db_transaction
      assert_equal true, result.value
    end
  end

  # A transaction that holds a lock of its own (it wrote a record) and now
  # takes others: while one is held, it keeps none of the new ones.
  def test_a_caller_that_holds_locks_waits_holding_none_of_the_new_ones
    with_sessions(3) do |holder, bulk, third|
      hold(holder, KEYS[1])
      bulk_pid = pid(bulk)
      result = @thread = Thread.new do
        bulk.transaction do
          bulk.execute("SELECT pg_advisory_xact_lock(hashtext('lyra_test/contention/own'))")
          LOCK.xact_lock_all(bulk, KEYS, purpose: "aggregate write")
        end
      end
      wait_until_waiting(holder, bulk_pid)
      sleep 0.2 # past a bounded wait, had there been one
      assert_equal [false, false], held_by_other?(third, [KEYS[0], KEYS[2]])

      holder.commit_db_transaction
      assert_equal true, result.value
    end
  end

  # A lock_timeout of the caller's own, shorter than the call's bounded
  # wait, is the caller's: its timeout raises, as for a wait without a
  # bound, rather than being taken for the call's own limit and tried again.
  def test_a_callers_own_shorter_lock_timeout_raises
    with_sessions(2) do |holder, bulk|
      hold(holder, KEYS[1])
      result = @thread = Thread.new do
        bulk.transaction do
          bulk.select_value("SELECT set_config('lock_timeout', '20ms', true)")
          LOCK.xact_lock_all(bulk, KEYS, purpose: "aggregate write")
        end
      rescue StandardError => e
        e
      end
      assert_kind_of ActiveRecord::LockWaitTimeout, result.value
      holder.commit_db_transaction
    end
  end

  # A cancel is the caller's error; only the call's own time limit is not.
  def test_a_cancel_by_request_is_raised
    with_sessions(2) do |holder, bulk|
      hold(holder, KEYS[1])
      bulk_pid = pid(bulk)
      result = @thread = Thread.new do
        bulk.transaction { LOCK.xact_lock_all(bulk, KEYS, purpose: "aggregate write") }
      rescue StandardError => e
        e
      end
      wait_until_waiting(holder, bulk_pid)
      holder.select_value("SELECT pg_cancel_backend(#{Integer(bulk_pid)})")
      assert_kind_of ActiveRecord::QueryCanceled, result.value
      holder.commit_db_transaction
    end
  end

  private

  # +count+ sessions; the first is the holder. Afterwards (a failed
  # assertion too) the holder's transaction ends first, so that the test's
  # thread (@thread) can finish before its session is used again.
  def with_sessions(count)
    sessions = count.times.map { ActiveRecord::Base.connection_pool.checkout }
    yield(*sessions)
  ensure
    sessions&.first&.execute("ROLLBACK")
    @thread&.join(10)
    sessions&.each do |session|
      session.execute("ROLLBACK")
      ActiveRecord::Base.connection_pool.checkin(session)
    end
  end

  def with_long_waits
    previous = LOCK.singleton_class::MAX_WAIT_MS
    LOCK.singleton_class.send(:remove_const, :MAX_WAIT_MS)
    LOCK.singleton_class.const_set(:MAX_WAIT_MS, 20_000)
    yield
  ensure
    LOCK.singleton_class.send(:remove_const, :MAX_WAIT_MS)
    LOCK.singleton_class.const_set(:MAX_WAIT_MS, previous)
  end

  def pid(session) = session.select_value("SELECT pg_backend_pid()")

  # Open a transaction on +session+ that holds +key+'s lock.
  def hold(session, key)
    session.begin_db_transaction
    session.execute("SELECT pg_advisory_xact_lock(hashtext(#{session.quote(key)}))")
  end

  # Whether another session holds each of +keys+ (tried in a transaction
  # rolled back, so the try keeps nothing).
  def held_by_other?(session, keys)
    held = nil
    session.transaction do
      held = keys.map { |key| !session.select_value("SELECT pg_try_advisory_xact_lock(hashtext(#{session.quote(key)}))") }
      raise ActiveRecord::Rollback
    end
    held
  end

  def recording(session)
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      statements << payload[:sql] if payload[:connection].equal?(session)
    end
    yield
    statements
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  def wait_until_waiting(session, pid)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    until session.select_value(
      "SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND NOT granted AND pid = #{Integer(pid)}"
    ).to_i.positive?
      raise "nobody waits for an advisory lock" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.01
    end
  end
end
