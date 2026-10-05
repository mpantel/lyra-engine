# frozen_string_literal: true

require "test_helper"
require "stringio"

# What a write does when its event cannot be stored.
#
# In Hijack and the event-sourcing modes the event log is the record of every
# change (in ES-NoProj the only one), so the write must fail and roll back:
# nothing in the table, nothing in the log. In Monitor the table stays
# authoritative, so the write stands and the failure is logged. Event
# sourcing used to log the failure and carry on, which in ES-NoProj reported
# a write that existed nowhere, and in ES-Sync projected a row from an event
# that was never stored.
class EventStoreFailureTest < Minitest::Test
  class Unavailable < StandardError; end

  def setup
    skip "Requires Rails and database" unless defined?(ActiveRecord::Base) && ActiveRecord::Base.connection.table_exists?(:users)

    Object.send(:remove_const, :FailingUser) if defined?(FailingUser)
    Object.const_set(:FailingUser, Class.new(ActiveRecord::Base) do
      self.table_name = "users"
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
    end)
    clean
    Lyra.config.monitor_model(FailingUser)
  end

  def teardown
    return unless defined?(FailingUser)

    Lyra.config.projection_mode = :sync
    Lyra.config.monitor_append_failure = :log
    clean
  end

  def test_es_sync_a_create_whose_event_cannot_be_stored_fails_and_leaves_nothing
    event_sourcing(:sync)
    store_fails do
      assert_raises(Lyra::EventStoreUnavailableError) { FailingUser.create!(name: "Ann", email: "ann@example.com") }
    end
    assert_nothing_written
  end

  def test_es_noproj_a_create_whose_event_cannot_be_stored_fails
    event_sourcing(:disabled)
    store_fails do
      assert_raises(Lyra::EventStoreUnavailableError) { FailingUser.create!(name: "Ann", email: "ann@example.com") }
    end
    assert_nothing_written
    assert_equal 0, FailingUser.count
  end

  def test_es_sync_an_update_whose_event_cannot_be_stored_leaves_the_row_unchanged
    event_sourcing(:sync)
    user = FailingUser.create!(name: "Ann", email: "ann@example.com")
    store_fails do
      assert_raises(Lyra::EventStoreUnavailableError) { user.update!(name: "Bea") }
    end
    assert_equal "Ann", raw("SELECT name FROM users WHERE id = #{user.id}")
  end

  # Hijack used to turn the failure into a refused save (false), unlike
  # event sourcing; both now fail closed with the same error.
  def test_hijack_fails_the_write_with_the_typed_error
    Lyra.config.enable_hijack!
    store_fails do
      assert_raises(Lyra::EventStoreUnavailableError) { FailingUser.new(name: "Ann", email: "ann@example.com").save }
    end
    assert_nothing_written
  end

  def test_the_error_names_the_stream_and_keeps_the_store_s_error_as_its_cause
    event_sourcing(:sync)
    error = store_fails do
      assert_raises(Lyra::EventStoreUnavailableError) { FailingUser.create!(name: "Ann", email: "ann@example.com") }
    end
    assert_match(/could not store events in FailingUser\$\d+: EventStoreFailureTest::Unavailable/, error.message)
    assert_kind_of Unavailable, error.cause
  end

  def test_a_bulk_write_in_event_sourcing_is_rolled_back_with_its_events
    event_sourcing(:sync)
    user = FailingUser.create!(name: "Ann", email: "ann@example.com")
    store_fails do
      assert_raises(Lyra::EventStoreUnavailableError) { FailingUser.where(id: user.id).update_all(name: "Bea") }
      assert_raises(Lyra::EventStoreUnavailableError) { user.update_columns(name: "Cy") }
    end
    assert_equal "Ann", raw("SELECT name FROM users WHERE id = #{user.id}")
  end

  # A failed event-sourced create used to leave the thread's skip-insert
  # signal set, so the next insert of any model on that thread skipped its row
  # while reporting success.
  def test_a_failed_write_leaves_nothing_behind_for_the_next_one
    event_sourcing(:sync)
    store_fails do
      assert_raises(Lyra::EventStoreUnavailableError) { FailingUser.create!(name: "Ann", email: "ann@example.com") }
    end

    Lyra.config.enable_monitor!
    user = FailingUser.create!(name: "Bea", email: "bea@example.com")
    assert_equal "Bea", raw("SELECT name FROM users WHERE id = #{user.id}"), "the next insert writes its row"
  end

  def test_monitor_keeps_the_write_and_logs_the_failure
    Lyra.config.enable_monitor!
    store_fails do
      FailingUser.create!(name: "Ann", email: "ann@example.com")
      FailingUser.where(name: "Ann").update_all(name: "Bea")
    end
    assert_equal "Bea", raw("SELECT name FROM users")
    assert_equal 0, raw("SELECT count(*) FROM event_store_events").to_i
  end

  def test_monitor_s_log_line_points_to_the_repair
    Lyra.config.enable_monitor!
    log = StringIO.new
    Rails.logger.stub(:error, ->(message) { log.puts(message) }) do
      store_fails { FailingUser.create!(name: "Ann", email: "ann@example.com") }
    end
    assert_match(/the write stands, run bin\/rails lyra:repair to bring FailingUser\$\d+ back in line/, log.string)
  end

# config.monitor_append_failure: opt-in fail-closed Monitor. The default
# (:log) is the policy above, unchanged.
def test_monitor_append_failure_defaults_to_log_and_is_validated
  assert_equal :log, Lyra::Configuration.new.monitor_append_failure
  Lyra.config.monitor_append_failure = "fail_write"
  assert_equal :fail_write, Lyra.config.monitor_append_failure
  assert_raises(ArgumentError) { Lyra.config.monitor_append_failure = :retry }
end

def test_monitor_with_fail_write_fails_a_create_and_leaves_nothing
  Lyra.config.enable_monitor!
  Lyra.config.monitor_append_failure = :fail_write
  store_fails do
    assert_raises(Lyra::EventStoreUnavailableError) { FailingUser.create!(name: "Ann", email: "ann@example.com") }
  end
  assert_nothing_written
end

def test_monitor_with_fail_write_leaves_the_row_unchanged_when_an_update_fails
  Lyra.config.enable_monitor!
  user = FailingUser.create!(name: "Ann", email: "ann@example.com")
  Lyra.config.monitor_append_failure = :fail_write
  store_fails do
    assert_raises(Lyra::EventStoreUnavailableError) { user.update!(name: "Bea") }
  end
  assert_equal "Ann", raw("SELECT name FROM users WHERE id = #{user.id}")
end

def test_monitor_with_fail_write_rolls_back_a_bulk_write_with_its_events
  Lyra.config.enable_monitor!
  user = FailingUser.create!(name: "Ann", email: "ann@example.com")
  Lyra.config.monitor_append_failure = :fail_write
  store_fails do
    assert_raises(Lyra::EventStoreUnavailableError) { FailingUser.where(id: user.id).update_all(name: "Bea") }
    assert_raises(Lyra::EventStoreUnavailableError) { user.update_columns(name: "Cy") }
  end
  assert_equal "Ann", raw("SELECT name FROM users WHERE id = #{user.id}")
end

def test_monitor_with_fail_write_still_writes_normally_when_the_store_works
  Lyra.config.enable_monitor!
  Lyra.config.monitor_append_failure = :fail_write
  user = FailingUser.create!(name: "Ann", email: "ann@example.com")
  assert_equal "Ann", raw("SELECT name FROM users WHERE id = #{user.id}")
  assert_equal 1, raw("SELECT count(*) FROM event_store_events").to_i
end

  private

  def event_sourcing(projection_mode)
    Lyra.config.enable_event_sourcing!
    Lyra.config.projection_mode = projection_mode
  end

  def store_fails
    Lyra.config.event_store.stub(:publish, ->(*_args, **_kw) { raise Unavailable, "event store unavailable" }) { yield }
  end

  def assert_nothing_written
    assert_equal 0, raw("SELECT count(*) FROM users").to_i, "no row"
    assert_equal 0, raw("SELECT count(*) FROM event_store_events").to_i, "no event"
  end

  def raw(sql) = ActiveRecord::Base.connection.select_value(sql)

  def clean
    conn = ActiveRecord::Base.connection
    conn.execute("DELETE FROM users")
    conn.execute("DELETE FROM event_store_events_in_streams")
    conn.execute("DELETE FROM event_store_events")
  end
end
