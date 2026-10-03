# frozen_string_literal: true

require "test_helper"
require "stringio"

# Lyra::ModeSync: every process follows the application-wide mode, the
# latest switch recorded by any process.
class ModeSyncTest < Minitest::Test
  MT = Lyra::ModeTransition
  Sync = Lyra::ModeSync

  def setup
    skip "Requires Rails and database" unless defined?(ActiveRecord::Base) && ActiveRecord::Base.connection.table_exists?(:users)

    Object.send(:remove_const, :SyncUser) if defined?(SyncUser)
    Object.const_set(:SyncUser, Class.new(ActiveRecord::Base) { self.table_name = "users" })
    SyncUser.include(Lyra::Interceptors::CrudInterceptor)
    SyncUser.monitor_with_lyra
    clean
    Lyra.config.mode_transition_gate = true
    Lyra.config.mode_sync = true
    Lyra.config.mode_sync_interval = 0
    Lyra.config.mode = :monitor
    Lyra.config.projection_mode = :sync
    Sync.reset!
    Sync.seen!(MT.send(:record_applied, "monitor"))
  end

  def teardown
    return unless defined?(SyncUser)

    Sync.reset!
    clean
  end

  def test_a_switch_recorded_by_another_process_is_adopted
    other_process_switches_to("event_sourcing/lazy")

    assert_equal "event_sourcing/lazy", Sync.maybe_sync!
    assert_equal :event_sourcing, Lyra.config.mode
    assert_equal :lazy, Lyra.config.projection_mode
  end

  def test_a_write_adopts_it_first
    other_process_switches_to("hijack")

    SyncUser.create!(name: "Ann", email: "ann@example.com")
    assert_equal :hijack, Lyra.config.mode, "adopted before the write, outside its transaction"
  end

  def test_never_inside_a_transaction
    other_process_switches_to("hijack")

    ActiveRecord::Base.transaction do
      assert_nil Sync.maybe_sync!
      assert_equal :monitor, Lyra.config.mode
    end
    Sync.maybe_sync!
    assert_equal :hijack, Lyra.config.mode
  end

  def test_the_raw_setter_is_left_alone_without_a_new_switch
    Lyra.config.mode = :event_sourcing # a benchmark harness, say
    Sync.maybe_sync!

    assert_equal :event_sourcing, Lyra.config.mode
  end

  def test_checks_are_throttled_by_the_interval
    Lyra.config.mode_sync_interval = 60
    Sync.maybe_sync!
    other_process_switches_to("hijack")

    assert_nil Sync.maybe_sync!, "not due yet"
    assert_equal :monitor, Lyra.config.mode
  end

  def test_this_process_s_own_switch_is_not_adopted_again_and_says_what_it_reaches
    log = StringIO.new
    Rails.logger.stub(:warn, ->(message) { log.puts(message) }) do
      MT.to!(:hijack, force: true)
    end

    assert_match(/switched the application monitor -> hijack; other processes adopt it within 0/, log.string)
    Lyra.config.mode = :monitor # changed in-process after the switch
    assert_nil Sync.maybe_sync!, "its own record is already seen"
  end

  def test_with_sync_off_the_switch_says_it_reaches_this_process_only
    Lyra.config.mode_sync = false
    log = StringIO.new
    Rails.logger.stub(:warn, ->(message) { log.puts(message) }) do
      MT.to!(:hijack, force: true)
    end

    assert_match(/switched this process monitor -> hijack\. ModeSync is off/, log.string)
    other_process_switches_to("event_sourcing/sync")
    assert_nil Sync.maybe_sync!
  end

  def test_the_middleware_syncs_before_the_request
    other_process_switches_to("hijack")
    seen = nil
    app = ->(_env) { seen = Lyra.config.mode; [200, {}, ["ok"]] }

    Lyra::ModeSync::Middleware.new(app).call({})
    assert_equal :hijack, seen
  end

  private

  # Another process's ModeTransition.to!: the record, without applying it here.
  def other_process_switches_to(label)
    MT.send(:record_applied, label)
  end

  def clean
    conn = ActiveRecord::Base.connection
    conn.execute("DELETE FROM users")
    conn.execute("DELETE FROM event_store_events_in_streams")
    conn.execute("DELETE FROM event_store_events")
    conn.execute("DELETE FROM #{MT::TABLE}") if conn.table_exists?(MT::TABLE)
  end
end
