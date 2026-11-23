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

  def test_an_adopted_hijack_does_not_outlive_a_later_mode_change
    other_process_switches_to("hijack")
    Sync.maybe_sync!
    Lyra.config.mode = :disabled

    SyncUser.create!(name: "Ann", email: "ann@example.com")
    assert_equal 0, ActiveRecord::Base.connection.select_value("SELECT count(*) FROM event_store_events").to_i,
                 "Disabled stores no event"
  end

  def test_an_applied_hijack_does_not_outlive_a_later_mode_change
    MT.to!(:hijack, force: true)
    Lyra.config.mode = :disabled

    refute Lyra.hijack_mode?
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

  # A row nobody gated (one INSERT) must not move this process into a mode whose
  # stores were never compared (0.9.3 adopted any row).
  def test_an_inserted_row_nobody_gated_is_not_adopted
    MT.send(:record_applied, "event_sourcing/disabled")

    assert_nil Sync.maybe_sync!
    assert_equal :monitor, Lyra.config.mode
  end

  def test_the_refusal_is_logged_with_its_reason
    io = StringIO.new
    previous = Rails.logger
    Rails.logger = Logger.new(io)
    MT.send(:record_applied, "event_sourcing/disabled")

    Sync.maybe_sync!

    assert_match(/did not adopt the application's mode event_sourcing\/disabled.*stays in monitor.*no clean check certifies/m, io.string)
  ensure
    Rails.logger = previous
  end

  def test_a_certificate_for_another_target_does_not_authorise_the_switch
    id = certify("monitor", "hijack")
    MT.send(:record_applied, "event_sourcing/disabled", from: "monitor", certificate_id: id)

    assert_nil Sync.maybe_sync!
    assert_equal :monitor, Lyra.config.mode
  end

  # The switch names the certificate that cleared it; a fresh certificate the
  # row does not name proves nothing about the row.
  def test_a_certificate_the_row_does_not_name_does_not_authorise_it
    certify("monitor", "hijack")
    MT.send(:record_applied, "hijack", from: "monitor")

    assert_nil Sync.maybe_sync!
    assert_equal :monitor, Lyra.config.mode
  end

  def test_a_certificate_already_used_by_an_earlier_switch_does_not_authorise_another
    id = certify("monitor", "hijack")
    MT.send(:record_applied, "hijack", from: "monitor", certificate_id: id)
    MT.send(:record_applied, "monitor", from: "hijack")
    Sync.seen!(MT.latest_applied[:id])
    MT.send(:record_applied, "hijack", from: "monitor", certificate_id: id)

    assert_nil Sync.maybe_sync!
    assert_equal :monitor, Lyra.config.mode
  end

  # The switcher checked the certificate's age when it switched. Its clock, the
  # certifying process's and this one's need not agree, and the switch may be
  # recorded near the end of the certificate's life: neither refuses it here.
  def test_a_named_certificate_authorises_the_switch_whatever_the_clocks_say
    id = certify("monitor", "hijack", at: Time.current + 60)
    MT.send(:record_applied, "hijack", from: "monitor", certificate_id: id)

    assert_equal "hijack", Sync.maybe_sync!
  end

  def test_a_named_certificate_near_the_end_of_its_life_authorises_the_switch
    id = certify("monitor", "hijack", at: Time.current - Lyra.config.mode_transition_certificate_ttl - 60)
    MT.send(:record_applied, "hijack", from: "monitor", certificate_id: id)

    assert_equal "hijack", Sync.maybe_sync!
  end

  # A forged row cannot pick a from that makes its switch ungated: the
  # application was last switched to monitor, so reaching ES-NoProj is gated
  # whatever the row says it came from.
  def test_a_row_whose_from_skips_the_gate_is_judged_from_the_previous_switch_too
    MT.send(:record_applied, "event_sourcing/disabled", from: "event_sourcing/sync")

    assert_nil Sync.maybe_sync!
    assert_equal :monitor, Lyra.config.mode
  end

  # With the gate off there are no certificates; a switch still reaches every
  # process.
  def test_with_the_gate_off_a_switch_is_adopted_without_a_certificate
    Lyra.config.mode_transition_gate = false
    MT.send(:record_applied, "event_sourcing/disabled", from: "monitor")

    assert_equal "event_sourcing/disabled", Sync.maybe_sync!
  ensure
    Lyra.config.mode_transition_gate = true
  end

  # An error while deciding leaves the row unseen, so the next check tries it again.
  def test_an_error_while_deciding_leaves_the_switch_to_be_adopted_later
    other_process_switches_to("hijack")
    MT.stubs(:adoption_refusal).raises(ActiveRecord::StatementInvalid, "connection lost")

    assert_raises(ActiveRecord::StatementInvalid) { Sync.maybe_sync! }
    assert_equal :monitor, Lyra.config.mode

    MT.unstub(:adoption_refusal)
    assert_equal "hijack", Sync.maybe_sync!
  end

  # Columns added to a table an earlier version created stay when the caller's
  # transaction rolls back: they are added outside it.
  def test_columns_added_inside_a_rolled_back_transaction_stay
    conn = ActiveRecord::Base.connection
    conn.remove_column(MT::TABLE, :forced)
    MT.instance_variable_set(:@table_ready, false)

    ActiveRecord::Base.transaction do
      MT.send(:table_ready?)
      raise ActiveRecord::Rollback
    end

    conn.schema_cache.clear!
    assert conn.column_exists?(MT::TABLE, :forced), "forced was added outside the rolled-back transaction"
  ensure
    MT.instance_variable_set(:@table_ready, false)
    MT.send(:table_ready?)
  end

  def test_a_switch_the_operator_forced_is_adopted_and_says_so
    MT.send(:record_applied, "hijack", from: "monitor", forced: true)

    assert MT.latest_applied[:forced]
    assert_equal "hijack", Sync.maybe_sync!
  end

  # A switch the gate does not check needs no certificate: leaving a mode that
  # reads the tables (Hijack) for Monitor.
  def test_leaving_a_mode_that_reads_the_tables_for_monitor_needs_no_certificate
    Lyra.config.mode = :hijack
    Lyra.config.hijack_enabled = true
    MT.send(:record_applied, "monitor", from: "hijack")

    assert_equal "monitor", Sync.maybe_sync!
  end

  # The rule covers every switch the gate checks, not only escalations: leaving
  # a lagging mode (ES-Async) for one that reads the tables needs the certificate.
  def test_leaving_a_lagging_mode_for_one_that_reads_the_tables_needs_a_certificate
    Lyra.config.mode = :event_sourcing
    Lyra.config.projection_mode = :async
    Sync.seen!(MT.send(:record_applied, "event_sourcing/async", from: "monitor", forced: true))
    MT.send(:record_applied, "monitor", from: "event_sourcing/async")

    assert_nil Sync.maybe_sync!, "a bare row is not adopted"
    assert_equal :event_sourcing, Lyra.config.mode

    id = certify("event_sourcing/async", "monitor")
    MT.send(:record_applied, "monitor", from: "event_sourcing/async", certificate_id: id)
    assert_equal "monitor", Sync.maybe_sync!
  end

  # A row an earlier version wrote has no from and names no certificate: it is
  # judged from this process's mode, and an escalation is not adopted.
  def test_a_row_an_earlier_version_wrote_is_judged_from_this_process_s_mode
    certify("monitor", "hijack")
    MT.send(:record_applied, "hijack") # no from, as 0.9.3 wrote it

    assert_nil Sync.maybe_sync!
    assert_equal :monitor, Lyra.config.mode
  end

  def test_the_applied_row_names_the_certificate_that_cleared_it
    MT.check(to: "hijack", models: [])
    MT.to!(:hijack)

    row = MT.latest_applied
    refute_nil row[:certificate_id]
    refute row[:forced]
  end

  def test_the_applied_row_records_where_the_switch_came_from_and_whether_it_was_forced
    MT.to!(:hijack, force: true)

    row = MT.latest_applied
    assert_equal "monitor", row[:from]
    assert row[:forced], "the gate was required and overridden"
    assert_equal "hijack", row[:config]
  end

  def test_a_switch_that_needed_no_gate_is_not_marked_forced
    Lyra.config.mode = :hijack
    Lyra.config.hijack_enabled = true
    MT.to!(:monitor, force: true)

    refute MT.latest_applied[:forced], "leaving Hijack for Monitor is not gated, so nothing was overridden"
  end

  private

  # Another process's gated ModeTransition.to!: a clean check's certificate, then
  # the record, without applying it here.
  def other_process_switches_to(label)
    id = certify("monitor", label)
    MT.send(:record_applied, label, from: "monitor", certificate_id: id)
  end

  # The certificate's id.
  def certify(from, to, at: Time.current)
    MT.send(:certify, MT::Report.new(from: from, to: to, checked: 0, position: 0, finished_at: at))
  end

  def clean
    conn = ActiveRecord::Base.connection
    conn.execute("DELETE FROM users")
    conn.execute("DELETE FROM event_store_events_in_streams")
    conn.execute("DELETE FROM event_store_events")
    conn.execute("DELETE FROM #{MT::TABLE}") if conn.table_exists?(MT::TABLE)
  end
end
