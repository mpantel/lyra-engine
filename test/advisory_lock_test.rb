# frozen_string_literal: true

require "test_helper"

# Lyra::AdvisoryLock: a PostgreSQL advisory lock, nothing (and no warning) on
# SQLite, and nothing with one warning per purpose on other adapters.
class AdvisoryLockTest < Minitest::Test
  FakeConnection = Struct.new(:adapter_name, :executed) do
    def execute(sql) = (executed << sql)
    def select_value(sql) = (executed << sql) && true
    def quote(value) = "'#{value}'"
    def transaction_open? = false
  end

  def setup
    Lyra::AdvisoryLock.reset_warnings!
  end

  def teardown
    Lyra::AdvisoryLock.reset_warnings!
  end

  def test_postgresql_takes_the_lock
    connection = FakeConnection.new("PostgreSQL", [])
    assert Lyra::AdvisoryLock.xact_lock(connection, "lyra_genesis/User", purpose: "Genesis")
    assert_equal ["SELECT pg_advisory_xact_lock(hashtext('lyra_genesis/User'))"], connection.executed
  end

  # Several locks in one statement, each key once, held by the transaction
  # until it ends, as xact_lock holds one.
  def test_postgresql_takes_several_locks_in_one_statement
    keys = %w[lyra_test/all/a lyra_test/all/b lyra_test/all/c]
    connection = FakeConnection.new("PostgreSQL", [])
    assert Lyra::AdvisoryLock.xact_lock_all(connection, keys + keys.first(1), purpose: "aggregate write")
    assert_equal 1, connection.executed.size
    assert_equal 3, connection.executed.first.scan("'lyra_test/all/").size
    refute Lyra::AdvisoryLock.xact_lock_all(connection, [], purpose: "aggregate write")

    holder = ActiveRecord::Base.connection_pool.checkout
    other = ActiveRecord::Base.connection_pool.checkout
    holder.transaction do
      Lyra::AdvisoryLock.xact_lock_all(holder, keys, purpose: "aggregate write")
      keys.each { |key| refute other.select_value("SELECT pg_try_advisory_xact_lock(hashtext('#{key}'))"), key }
    end
    keys.each { |key| assert other.select_value("SELECT pg_try_advisory_lock(hashtext('#{key}'))"), key }
    keys.each { |key| other.select_value("SELECT pg_advisory_unlock(hashtext('#{key}'))") }
  ensure
    [holder, other].compact.each { ActiveRecord::Base.connection_pool.checkin(_1) }
  end

  def test_postgresql_tries_the_lock
    connection = FakeConnection.new("PostgreSQL", [])
    assert Lyra::AdvisoryLock.try_xact_lock(connection, "lyra_lazy_projection", purpose: "ES-Lazy catch-up")
    assert_equal ["SELECT pg_try_advisory_xact_lock(hashtext('lyra_lazy_projection'))"], connection.executed
  end

  # Waiting for a holder takes the lock shared in a savepoint and rolls the
  # savepoint back: the caller's transaction goes on without the lock, and
  # other sessions can take it exclusively at once.
  def test_postgresql_waits_for_the_holder_without_keeping_the_lock
    key = "lyra_test/wait_for"
    holder = ActiveRecord::Base.connection_pool.checkout
    waiter = ActiveRecord::Base.connection_pool.checkout
    holder.begin_db_transaction
    holder.execute("SELECT pg_advisory_xact_lock(hashtext('#{key}'))")
    went_on = Queue.new
    done = Queue.new
    waited = Thread.new do
      waiter.transaction do
        Lyra::AdvisoryLock.wait_for(waiter, key)
        went_on << true
        done.pop
        waiter.select_value("SELECT 1") # the transaction is still usable
      end
    end
    sleep 0.01 until holder.select_value("SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND NOT granted").to_i.positive?
    assert went_on.empty?, "the waiter went on while the lock was held"

    holder.commit_db_transaction
    went_on.pop
    # The waiter's transaction is still open, and does not hold the lock.
    assert holder.select_value("SELECT pg_try_advisory_lock(hashtext('#{key}'))"), "the waiter kept the lock"
    holder.select_value("SELECT pg_advisory_unlock(hashtext('#{key}'))")
    done << true
    assert_equal 1, waited.value
  ensure
    [holder, waiter].compact.each { ActiveRecord::Base.connection_pool.checkin(_1) }
  end

  # Without the lock there is no one to wait for: the caller goes on as the
  # holder, as xact_lock lets it.
  def test_sqlite_try_lets_the_caller_go_on_and_takes_nothing
    connection = FakeConnection.new("SQLite", [])
    assert Lyra::AdvisoryLock.try_xact_lock(connection, "k", purpose: "ES-Lazy catch-up")
    refute Lyra::AdvisoryLock.wait_for(connection, "k")
    assert_empty connection.executed
  end

  def test_sqlite_takes_no_lock_and_does_not_warn
    connection = FakeConnection.new("SQLite", [])
    _out, err = capture_io do
      Rails.logger.stub(:warn, ->(message) { warn(message) }) do
        refute Lyra::AdvisoryLock.xact_lock(connection, "k", purpose: "Genesis")
      end
    end
    assert_empty connection.executed
    assert_empty err
  end

  def test_other_adapters_warn_once_per_purpose
    connection = FakeConnection.new("Mysql2", [])
    warnings = []
    Rails.logger.stub(:warn, ->(message) { warnings << message }) do
      2.times { refute Lyra::AdvisoryLock.xact_lock(connection, "k", purpose: "Genesis") }
      Lyra::AdvisoryLock.xact_lock(connection, "k", purpose: "ES-Lazy catch-up")
    end
    assert_empty connection.executed
    assert_equal 2, warnings.size
    assert_match(/Genesis runs without a lock on Mysql2/, warnings.first)
    assert_match(/single process only/, warnings.first)
  end
end

# LazyProjection.catch_up! runs only in ES-Lazy, unless forced (the mode check
# leaving ES-Lazy may run in a process already configured for its target).
class LazyCatchUpForceTest < Minitest::Test
  def setup
    @mode = Lyra.config.mode
    @projection_mode = Lyra.config.projection_mode
    Lyra.config.mode = :monitor
  end

  def teardown
    Lyra.config.mode = @mode
    Lyra.config.projection_mode = @projection_mode
  end

  def test_outside_es_lazy_it_does_nothing
    Lyra::Projections::LazyProjection.expects(:ensure_table!).never
    assert_equal 0, Lyra::Projections::LazyProjection.catch_up!
  end

  def test_forced_it_runs_outside_es_lazy
    Lyra::Projections::LazyProjection.expects(:ensure_table!).once
    Lyra::Projections::LazyProjection.stubs(:catch_up_target).returns(nil)
    assert_equal 0, Lyra::Projections::LazyProjection.catch_up!(force: true)
  end
end
