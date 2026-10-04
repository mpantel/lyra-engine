# frozen_string_literal: true

require "test_helper"

# Lyra::AdvisoryLock: a PostgreSQL advisory lock, nothing (and no warning) on
# SQLite, and nothing with one warning per purpose on other adapters.
class AdvisoryLockTest < Minitest::Test
  FakeConnection = Struct.new(:adapter_name, :executed) do
    def execute(sql) = (executed << sql)
    def quote(value) = "'#{value}'"
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
    Lyra::Projections::LazyProjection.stubs(:up_to_date?).returns(true)
    assert_equal 0, Lyra::Projections::LazyProjection.catch_up!(force: true)
  end
end
