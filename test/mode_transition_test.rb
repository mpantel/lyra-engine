# frozen_string_literal: true

require "test_helper"

# Mode Transition Safety (Lyra::ModeTransition) and sampled DualView
# verification (Lyra::DualViewSampler).
class ModeTransitionTest < Minitest::Test
  MT = Lyra::ModeTransition

  def setup
    skip "Requires Rails and database" unless defined?(ActiveRecord::Base) && ActiveRecord::Base.connection.table_exists?(:users)

    Object.send(:remove_const, :GateUser) if defined?(GateUser)
    Object.const_set(:GateUser, Class.new(ActiveRecord::Base) { self.table_name = "users" })
    GateUser.include(Lyra::Interceptors::CrudInterceptor)
    GateUser.monitor_with_lyra
    Lyra.config.instance_variable_set(:@monitored_models, [GateUser])
    clean
    Rails.cache.clear
    Lyra.config.mode_transition_gate = true
    Lyra.config.mode = :monitor
    Lyra.config.projection_mode = :sync
  end

  def teardown
    return unless defined?(GateUser)

    clean
    Rails.cache.clear
  end

  def test_which_switches_are_gated
    assert MT.gate_required?("monitor", "hijack")
    assert MT.gate_required?("disabled", "event_sourcing/sync")
    assert MT.gate_required?("event_sourcing/disabled", "monitor")
    assert MT.gate_required?("event_sourcing/async", "hijack")
    refute MT.gate_required?("disabled", "monitor")
    refute MT.gate_required?("monitor", "disabled")
    refute MT.gate_required?("event_sourcing/sync", "event_sourcing/disabled")
    refute MT.gate_required?("event_sourcing/lazy", "event_sourcing/disabled")
  end

  def test_escalation_passes_when_rows_and_events_agree_importing_old_rows
    GateUser.create!(name: "Ann", email: "ann@example.com")
    raw("INSERT INTO users (name, email, created_at, updated_at) VALUES ('Old', 'old@example.com', now(), now())")

    report = MT.to!(:hijack)

    assert report.clean?, report.discrepancies.map(&:to_s).inspect
    assert_equal 1, report.imported, "the row that predates Lyra was imported"
    assert_equal :hijack, Lyra.config.mode
    assert_equal "hijack", MT.last_applied
  end

  def test_escalation_is_refused_when_a_row_was_changed_behind_lyra
    user = GateUser.create!(name: "Ann", email: "ann@example.com")
    raw("UPDATE users SET name = 'Changed' WHERE id = #{user.id}")

    error = assert_raises(MT::Refused) { MT.to!(:hijack) }
    assert_match(/GateUser #{user.id}: row differs from its events/, error.message)
    assert_equal :monitor, Lyra.config.mode, "the mode is unchanged"

    MT.to!(:hijack, force: true)
    assert_equal :hijack, Lyra.config.mode, "force: switches anyway"
  end

  def test_leaving_es_noproj_needs_the_tables_rebuilt
    Lyra.config.mode = :event_sourcing
    Lyra.config.projection_mode = :disabled
    GateUser.create!(name: "Ann", email: "ann@example.com") # events only, no row

    error = assert_raises(MT::Refused) { MT.to!(:monitor) }
    assert_match(/events but no row/, error.message)

    report = MT.to!(:monitor, rebuild: true)
    assert report.clean?
    assert_equal 1, report.rebuilt
    assert_equal "Ann", raw("SELECT name FROM users")
  end

  def test_a_destroyed_record_is_not_a_discrepancy
    user = GateUser.create!(name: "Ann", email: "ann@example.com")
    user.destroy!

    assert MT.check(to: "hijack").clean?
  end

  def test_a_certificate_is_reused_and_a_later_change_invalidates_it
    user = GateUser.create!(name: "Ann", email: "ann@example.com")
    assert MT.check(to: "hijack", from: "monitor").clean?

    MT.stub(:check, ->(**) { flunk "a fresh certificate must spare the full check" }) do
      raw("UPDATE users SET name = 'Changed', updated_at = now() + interval '1 second' WHERE id = #{user.id}")
      error = assert_raises(MT::Refused) { MT.to!(:hijack) }
      assert_match(/row differs/, error.message, "the change after the certificate is re-checked")
    end
  end

  def test_enable_hijack_goes_through_the_gate
    user = GateUser.create!(name: "Ann", email: "ann@example.com")
    raw("UPDATE users SET name = 'Changed' WHERE id = #{user.id}")

    assert_raises(MT::Refused) { Lyra.config.enable_hijack! }
    assert_equal :monitor, Lyra.config.mode
  end

  def test_the_boot_gate_refuses_an_uncertified_switch
    MT.send(:record_applied, "monitor")
    Lyra.config.mode = :hijack

    assert_raises(MT::Refused) { MT.boot_check! }

    ENV["LYRA_FORCE_MODE_TRANSITION"] = "1"
    MT.boot_check!
    assert_equal "hijack", MT.last_applied
  ensure
    ENV.delete("LYRA_FORCE_MODE_TRANSITION")
  end

  def test_the_boot_gate_accepts_a_certified_switch
    GateUser.create!(name: "Ann", email: "ann@example.com")
    MT.send(:record_applied, "monitor")
    assert MT.check(to: "hijack", from: "monitor").clean?
    Lyra.config.mode = :hijack

    MT.boot_check!
    assert_equal "hijack", MT.last_applied
  end

  def test_sampling_reports_a_write_whose_event_was_lost
    found = []
    Lyra.config.dual_view_sample_rate = 1.0
    Lyra.config.dual_view_discrepancy_handler = ->(discrepancy) { found << discrepancy }

    Lyra.config.event_store.stub(:publish, ->(*_a, **_k) { raise "store down" }) do
      GateUser.create!(name: "Ann", email: "ann@example.com") # Monitor keeps the row, logs the lost event
    end

    assert_equal ["row but no events"], found.map(&:problem)
  ensure
    Lyra.config.dual_view_sample_rate = 0.0
  end

  def test_sampling_is_off_by_default
    assert_equal 0.0, Lyra::Configuration.new.dual_view_sample_rate
  end

  private

  def raw(sql) = ActiveRecord::Base.connection.select_value(sql)

  def clean
    conn = ActiveRecord::Base.connection
    conn.execute("DELETE FROM users")
    conn.execute("DELETE FROM event_store_events_in_streams")
    conn.execute("DELETE FROM event_store_events")
    conn.execute("DELETE FROM #{MT::TABLE}") if conn.table_exists?(MT::TABLE)
  end
end
