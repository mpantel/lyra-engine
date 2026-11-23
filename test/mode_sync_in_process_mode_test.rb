# frozen_string_literal: true

require "test_helper"
require "rbconfig"
require "tmpdir"

# A mode changed in the process after boot is left alone by a switch recorded
# before that boot (1.0.0 adopted it at the first check of a rake process,
# whose boot check is skipped), and a process that merely booted with another
# mode than the application's still adopts the application's, or it would
# write in the wrong mode.
class ModeSyncInProcessModeTest < Minitest::Test
  MT = Lyra::ModeTransition
  Sync = Lyra::ModeSync

  def setup
    skip "Requires Rails and database" unless defined?(ActiveRecord::Base) && ActiveRecord::Base.connection.table_exists?(:users)

    MT.table_available?
    clean
    Lyra.config.mode_transition_gate = true
    Lyra.config.mode_sync = true
    Lyra.config.mode_sync_interval = 0
    Lyra.config.mode = :monitor
    Lyra.config.projection_mode = :sync
    Sync.reset!
  end

  def teardown
    return unless defined?(ActiveRecord::Base)

    Sync.reset!
    Lyra::TouchRegistry.reset!
    MT.instance_variable_set(:@table_ready, false)
    MT.table_available?
    clean
  end

  # --- changed: the process's own change wins over a row from before its boot

  def test_a_mode_set_after_boot_is_not_overridden_by_an_older_row
    boot(:monitor, applied: "monitor")
    Lyra.config.mode = :disabled

    assert_nil Sync.sync!
    assert_equal "disabled", MT.current
  end

  def test_nor_by_an_older_row_of_a_third_mode
    boot(:monitor, applied: "hijack")
    Lyra.config.mode = :disabled

    assert_nil Sync.sync!
    assert_equal "disabled", MT.current
  end

  def test_nor_is_a_projection_mode_set_after_boot
    boot(:event_sourcing, applied: "event_sourcing/lazy")
    Lyra.config.projection_mode = :async

    assert_nil Sync.sync!
    assert_equal "event_sourcing/async", MT.current
  end

  def test_nor_is_disable!
    boot(:monitor, applied: "hijack")
    Lyra.config.disable!

    assert_nil Sync.sync!
    assert_equal "disabled", MT.current
  end

  def test_nor_with_the_gate_off_and_mode_sync_on
    Lyra.config.mode_transition_gate = false
    boot(:monitor, applied: "hijack")
    Lyra.config.mode = :disabled

    assert_nil Sync.sync!
    assert_equal "disabled", MT.current
  end

  # The row counts as seen from then on, as in a process whose boot check ran.
  def test_the_next_mode_the_process_sets_is_left_alone_too
    boot(:monitor, applied: "hijack")
    Lyra.config.mode = :disabled
    Sync.sync!
    Lyra.config.mode = :monitor # the one it booted in, as a sweep's next mode

    assert_nil Sync.sync!
    assert_equal "monitor", MT.current
  end

  # Any set counts, the mode the process booted in too: the process said
  # which mode it runs in.
  def test_setting_the_mode_it_booted_in_keeps_it
    boot(:monitor, applied: "hijack")
    Lyra.config.mode = :monitor

    assert_nil Sync.sync!
    assert_equal "monitor", MT.current
  end

  def test_a_mode_set_back_before_the_first_check_is_kept
    boot(:monitor, applied: "hijack")
    Lyra.config.mode = :disabled
    Lyra.config.mode = :monitor

    assert_nil Sync.sync!
    assert_equal "monitor", MT.current
  end

  def test_a_projection_mode_set_outside_event_sourcing_counts_too
    boot(:monitor, applied: "hijack")
    Lyra.config.projection_mode = :async

    assert_nil Sync.sync!
    assert_equal "monitor", MT.current
  end

  {
    "hijack_enabled = false" => -> { Lyra.config.hijack_enabled = false },
    "enable_monitor!" => -> { Lyra.config.enable_monitor! },
    "enable_event_sourcing!" => -> { Lyra.config.enable_event_sourcing! }
  }.each do |name, set|
    define_method("test_#{name.tr(' =!', '_')}_after_boot_is_a_set") do
      Lyra.config.mode_transition_gate = false # the helpers' raw branch
      boot(:monitor, applied: "hijack")
      instance_exec(&set)

      assert_nil Sync.sync!
    end
  end

  # --- unchanged: the application's mode is still adopted

  def test_a_process_that_merely_booted_adopts_the_older_row
    boot(:monitor, applied: "hijack")

    assert_equal "hijack", Sync.sync!
  end

  def test_the_configuration_applied_again_by_a_code_reload_is_no_set
    boot(:monitor, applied: "hijack")
    Sync.reapplying_configuration { Lyra.config.mode = :monitor }

    assert_equal "hijack", Sync.sync!
  end

  def test_a_set_on_another_configuration_object_is_no_set
    boot(:monitor, applied: "hijack")
    Lyra::Configuration.new.mode = :disabled

    assert_equal "hijack", Sync.sync!
  end

  def test_a_set_refused_by_validation_is_no_set
    boot(:monitor, applied: "hijack")
    assert_raises(ArgumentError) { Lyra.config.mode = :monitr }

    assert_equal "hijack", Sync.sync!
  end

  def test_a_switch_recorded_after_boot_and_before_the_set_is_adopted
    boot(:disabled, applied: "disabled")
    switched_elsewhere_to("hijack")
    Lyra.config.mode = :monitor

    assert_equal "hijack", Sync.sync!
  end

  def test_a_switch_recorded_after_the_set_is_adopted
    boot(:monitor, applied: "monitor")
    Lyra.config.mode = :disabled
    switched_elsewhere_to("hijack")

    assert_equal "hijack", Sync.sync!
  end

  def test_a_switch_recorded_after_the_first_check_is_adopted
    boot(:monitor, applied: "monitor")
    Lyra.config.mode = :disabled
    Sync.sync!
    switched_elsewhere_to("hijack")

    assert_equal "hijack", Sync.sync!
  end

  def test_a_mode_set_after_the_first_check_is_left_alone
    boot(:monitor, applied: "hijack")
    Sync.sync!
    Lyra.config.mode = :disabled

    assert_nil Sync.sync!
    assert_equal "disabled", MT.current
  end

  def test_with_no_row_at_boot_a_later_switch_is_adopted
    boot(:monitor)
    Lyra.config.mode = :disabled
    assert_nil Sync.sync!
    switched_elsewhere_to("hijack")

    assert_equal "hijack", Sync.sync!
  end

  def test_with_no_table_at_boot_a_later_switch_is_adopted
    connection = ActiveRecord::Base.connection
    connection.drop_table(MT::TABLE)
    MT.instance_variable_set(:@table_ready, false)
    Sync.remember_boot!
    refute connection.table_exists?(MT::TABLE), "looking at boot creates nothing"
    Lyra.config.mode = :disabled
    switched_elsewhere_to("hijack")

    assert_equal "hijack", Sync.sync!
  end

  def test_unreadable_at_boot_the_older_row_is_adopted
    applied_row("hijack")
    pool = ActiveRecord::Base.connection_pool
    pool.stubs(:with_connection).raises(ActiveRecord::ConnectionNotEstablished)
    Sync.remember_boot!
    pool.unstub(:with_connection)
    Lyra.config.mode = :disabled

    assert_equal "hijack", Sync.sync!
  end

  def test_with_mode_sync_off_boot_reads_nothing
    Lyra.config.mode_sync = false
    pool = ActiveRecord::Base.connection_pool
    pool.expects(:with_connection).never

    Sync.remember_boot!
  ensure
    pool&.unstub(:with_connection)
  end

  def test_after_a_switch_that_failed_to_record_the_applications_mode_is_adopted
    boot(:monitor, applied: "disabled")
    MT.stubs(:record_applied).raises(ActiveRecord::StatementInvalid, "connection lost")
    assert_raises(ActiveRecord::StatementInvalid) { MT.to!(:hijack, force: true) }
    MT.unstub(:record_applied)
    assert_equal "hijack", MT.current, "applied, not recorded"

    assert_equal "disabled", Sync.sync!
  end

  def test_a_process_leaving_touches_out_is_still_fenced
    Lyra.config.record_touches = false
    boot(:monitor, applied: "hijack")
    Lyra.config.mode = :disabled

    assert_raises(MT::Refused) { Rails.logger.stub(:error, nil) { Sync.sync! } }
    assert Lyra::TouchRegistry.fenced?
  end

  def test_an_older_row_waiting_for_a_touch_skipping_process_stays_unseen
    boot(:monitor, applied: "hijack")
    Lyra::TouchRegistry.stubs(:gate_refusal).returns("a live process leaves touches out")
    assert_nil Rails.logger.stub(:error, nil) { Sync.sync! }
    assert_nil Sync.last_seen_id
    Lyra::TouchRegistry.unstub(:gate_refusal)

    assert_equal "hijack", Sync.sync!
  end

  # --- real processes, where boot decides

  def test_a_rake_task_s_disabled_stores_no_event_over_an_older_monitor_row
    applied_row("monitor")

    assert_equal "disabled events=0", in_rake("Lyra.config.mode = :disabled; write")
  end

  # The campaign's workaround (every process booted in Disabled), with the
  # older Monitor row left in place.
  def test_a_rake_task_that_sets_the_mode_it_booted_in_keeps_it
    applied_row("monitor")

    assert_equal "disabled events=0", in_rake("Lyra.config.mode = :disabled; write", configured: "disabled")
  end

  def test_a_runner_with_the_gate_off_keeps_the_mode_it_set
    applied_row("monitor")

    assert_equal "disabled events=0", in_runner("Lyra.config.mode = :disabled; write", gate: false)
  end

  def test_a_runner_with_the_gate_on_keeps_the_mode_it_set
    applied_row("monitor")

    assert_equal "disabled events=0", in_runner("Lyra.config.mode = :disabled; write")
  end

  def test_a_runner_with_the_gate_off_that_merely_booted_adopts
    applied_row("monitor")

    assert_equal "monitor events=1", in_runner("write", configured: "disabled", gate: false)
  end

  def test_a_rake_task_that_merely_booted_adopts
    applied_row("monitor")

    assert_equal "monitor events=1", in_rake("write", configured: "disabled")
  end

  def test_a_mode_configured_in_the_applications_after_initialize_is_still_configuration
    applied_row("monitor")

    assert_equal "monitor events=1", in_rake("write", configured: "disabled", configured_in: "after_initialize")
  end

  def test_a_mode_configured_when_active_record_loads_is_still_configuration
    applied_row("monitor")

    assert_equal "monitor events=1", in_rake("write", configured: "disabled", configured_in: "on_load")
  end

  def test_a_mode_set_before_initialisation_is_configuration
    applied_row("monitor")

    assert_equal "monitor events=1", in_rake("write", configured: nil, before_boot: "Lyra.config.mode = :disabled")
  end

  def test_a_code_reload_in_a_rake_task_is_no_change
    applied_row("monitor")

    assert_equal "monitor events=1", in_rake("Rails.application.reloader.prepare!; write", configured: "disabled")
  end

  def test_a_rake_task_adopts_a_switch_recorded_after_it_booted
    applied_row("monitor")

    assert_equal "hijack events=1",
                 in_rake("Lyra.config.mode = :disabled; switched_elsewhere_to('hijack'); write")
  end

  def test_in_the_test_environments_default_nothing_is_adopted
    applied_row("monitor")

    assert_equal "disabled events=0", in_rake("write", configured: "disabled", gate: nil)
  end

  # db:drop, and a task that runs dropdb, need the database free of sessions.
  def test_a_rake_boot_keeps_no_connection
    applied_row("monitor")

    assert_equal "connected=false", in_rake('puts "probe: connected=#{ActiveRecord::Base.connection_pool.connected?}"')
  end

  def test_a_rake_boot_needs_no_database
    assert_equal "booted", in_rake("puts 'probe: booted'", env: { "DATABASE_URL" => "postgres://nobody@127.0.0.1:1/none" })
  end

  def test_a_rake_boot_creates_no_sqlite_database
    Dir.mktmpdir do |dir|
      file = File.join(dir, "none.sqlite3")

      assert_equal "booted", in_rake("puts 'probe: booted'", env: { "DATABASE_URL" => "sqlite3:#{file}" })
      refute File.exist?(file), "db:create would report the database as existing"
    end
  end

  private

  DUMMY =File.expand_path("dummy", __dir__)

  # What both hosts load: the dummy application, configured as an application's
  # initializer would, and what a script may call.
  HOST = <<~RUBY
    ENV["RAILS_ENV"] = "test"
    require "#{DUMMY}/config/application"

    app = Rails.application
    gate = { "true" => true, "false" => false }[ENV["PROBE_GATE"]]
    app.config.before_initialize do
      Lyra.configure do |c|
        c.mode_transition_gate = gate
        c.mode_sync = true if gate == false
        c.mode_sync_interval = 0
      end
    end

    if (mode = ENV["PROBE_MODE"])
      configure = proc { Lyra.configure { |c| c.mode = mode } }
      case ENV["PROBE_MODE_IN"]
      when "after_initialize" # the application's, so it runs after Lyra's
        app.class.initializer("probe.mode") { |a| a.config.after_initialize { configure.call } }
      when "on_load"
        ActiveSupport.on_load(:active_record) { configure.call }
      else
        app.config.to_prepare { configure.call }
      end
    end

    module Probe
      def self.events
        ActiveRecord::Base.connection.select_value("SELECT count(*) FROM event_store_events").to_i
      end

      def self.switched_elsewhere_to(label)
        Lyra::ModeTransition.send(:record_applied, label, from: "monitor", forced: true)
      end

      def self.write
        user = Object.const_set(:ModeSyncProbeUser, Class.new(ActiveRecord::Base) { self.table_name = "users" })
        user.include(Lyra::Interceptors::CrudInterceptor)
        user.monitor_with_lyra
        before = events
        user.create!(name: "Probe", email: "probe@example.com")
        puts "probe: \#{Lyra::ModeTransition.current} events=\#{events - before}"
      end

      def self.run = instance_eval(ENV.fetch("PROBE_SCRIPT"))
    end
  RUBY

  # bin/rake
  def in_rake(script, before_boot: nil, **options)
    in_process(script, **options) do |host, dir|
      rakefile = File.join(dir, "Rakefile")
      File.write(rakefile, <<~RUBY)
        require #{host.inspect}
        Rails.application.load_tasks
        task(:before_boot) { #{before_boot} }
        task(probe: %i[before_boot environment]) { Probe.run }
      RUBY
      ["-e", "load Gem.bin_path('rake', 'rake')", "--", "-f", rakefile, "probe"]
    end
  end

  # bin/rails runner
  def in_runner(script, **options)
    in_process(script, **options) do |host, _dir|
      ["-e", <<~RUBY]
        require #{host.inspect}
        APP_PATH = "#{DUMMY}/config/application"
        ARGV.replace(%w[runner Probe.run])
        require "rails/commands"
      RUBY
    end
  end

  # What the script printed after "probe: ".
  def in_process(script, configured: "monitor", configured_in: "to_prepare", gate: true, env: {})
    Dir.mktmpdir do |dir|
      host = File.join(dir, "host.rb")
      File.write(host, HOST)
      env = { "PROBE_SCRIPT" => script, "PROBE_MODE" => configured, "PROBE_MODE_IN" => configured_in,
              "PROBE_GATE" => gate&.to_s }.merge(env)
      # IO.popen, not Open3: see test/integration/lyra_without_petri_flow_test.rb.
      out = IO.popen(env, [RbConfig.ruby, "-rbundler/setup", *yield(host, dir)],
                     chdir: DUMMY, err: %i[child out], &:read)

      assert $?.success?, "the process failed:\n#{out.lines.grep_v(/warning:/).first(8).join}"
      out[/^probe: (.*)$/, 1]
    end
  end

  # As a process that skips the boot check (a rake task): it boots configured
  # for +mode+ in an application whose latest switch is +applied+.
  def boot(mode, applied: nil)
    applied_row(applied) if applied
    Lyra.config.mode = mode
    Sync.remember_boot!
  end

  def applied_row(label) = MT.send(:record_applied, label, forced: true)

  # Another process's switch, the gate overridden, so that it may be adopted.
  def switched_elsewhere_to(label) = MT.send(:record_applied, label, from: "monitor", forced: true)

  def clean
    conn = ActiveRecord::Base.connection
    conn.execute("DELETE FROM users")
    conn.execute("DELETE FROM event_store_events_in_streams")
    conn.execute("DELETE FROM event_store_events")
    conn.execute("DELETE FROM #{MT::TABLE}")
  end
end
