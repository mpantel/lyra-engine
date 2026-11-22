# frozen_string_literal: true

require "test_helper"
require "timeout"

# config.record_touches: a touch whose only change is the update timestamp
# (an instance touch, a touch_all, a belongs_to ... touch: true cascade) is
# recorded by default; with false it is left out of the log, in Monitor only.
# DualView then ignores differences confined to the update timestamps, and
# Hijack and event sourcing, whose log rebuilds the rows, refuse the option.
class RecordTouchesTest < Minitest::Test
  MT = Lyra::ModeTransition
  Registry = Lyra::TouchRegistry

  def setup
    skip "Requires Rails and database" unless defined?(ActiveRecord::Base) && ActiveRecord::Base.connection.table_exists?(:articles)

    Object.send(:remove_const, :TouchOptChild) if defined?(TouchOptChild)
    Object.send(:remove_const, :TouchOptParent) if defined?(TouchOptParent)
    Object.const_set(:TouchOptParent, Class.new(ActiveRecord::Base) { self.table_name = "users" })
    Object.const_set(:TouchOptChild, Class.new(ActiveRecord::Base) do
      self.table_name = "articles"
      belongs_to :author, class_name: "TouchOptParent", optional: true, touch: true
    end)
    [TouchOptParent, TouchOptChild].each do |model|
      model.include(Lyra::Interceptors::CrudInterceptor)
      model.monitor_with_lyra
      Lyra.config.monitor_model(model)
    end
    Lyra.config.mode = :monitor
    clean
  end

  def teardown
    return unless defined?(TouchOptParent)

    Lyra.config.record_touches = true
    Lyra.config.mode = :monitor
    Lyra::ModeSync.reset!
    Registry.reset!
    clean
  end

  # --- the option ---------------------------------------------------------

  def test_on_by_default_and_validated_on_assignment
    assert_equal true, Lyra::Configuration.new.record_touches
    Lyra.config.record_touches = "false"
    assert_equal false, Lyra.config.record_touches
    Lyra.config.record_touches = "true"
    assert_equal true, Lyra.config.record_touches
    error = assert_raises(ArgumentError) { Lyra.config.record_touches = :none }
    assert_match(/true or false/, error.message)
  end

  def test_false_is_refused_in_hijack_and_event_sourcing
    { hijack: -> { Lyra.config.enable_hijack! },
      event_sourcing: -> { Lyra.config.enable_event_sourcing! } }.each do |mode, enter|
      Lyra.config.record_touches = true
      enter.call
      error = assert_raises(ArgumentError) { Lyra.config.record_touches = false }
      assert_match(/refused in #{mode}/, error.message)
      assert_equal true, Lyra.config.record_touches, "a refused assignment leaves the option as it was"
      Lyra.config.enable_monitor!
    end
  end

  def test_with_false_no_mode_whose_log_rebuilds_rows_can_be_entered
    Lyra.config.record_touches = false

    assert_raises(ArgumentError) { Lyra.config.mode = :hijack }
    assert_raises(ArgumentError) { Lyra.config.mode = "event_sourcing" }
    assert_raises(ArgumentError) { Lyra.config.enable_hijack! }
    assert_raises(ArgumentError) { Lyra.config.enable_event_sourcing! }
    assert_equal :monitor, Lyra.config.mode
    refute Lyra.config.hijack_mode?

    Lyra.config.disable!
    Lyra.config.mode = :monitor
    assert Lyra.config.monitor_mode?, "Disabled and Monitor stay open"
  end

  def test_the_gate_refuses_a_switch_and_a_check_even_when_forced
    Lyra.config.record_touches = false

    error = assert_raises(MT::Refused) { MT.to!(:hijack, force: true) }
    assert_match(/monitor -> hijack: config.record_touches = false is refused/, error.message)
    assert_raises(MT::Refused) { MT.to!(:event_sourcing, projection_mode: :lazy) }
    assert_raises(MT::Refused) { MT.check(to: "event_sourcing/sync", models: [TouchOptParent]) }
    assert_equal "monitor", MT.current
  end

  def test_the_raw_hijack_enabled_writer_is_refused_too
    Lyra.config.record_touches = false

    assert_raises(ArgumentError) { Lyra.config.hijack_enabled = true }
    refute Lyra.config.hijack_mode?
    Lyra.config.hijack_enabled = false
  end

  def test_a_rebuild_is_refused_while_touches_are_left_out
    parent, = pair
    Lyra.config.record_touches = false
    later { parent.touch }
    before = row_updated_at(parent)

    error = assert_raises(Lyra::Projections::Rebuild::Refused) { Lyra::Projections::Rebuild.rebuild(TouchOptParent) }
    assert_match(/record_touches is false/, error.message)
    assert_equal before, row_updated_at(parent), "the touched row is left as it is"
  end

  def test_rake_mode_check_prints_the_refusal_and_exits_non_zero
    Lyra.config.record_touches = false
    ENV["TO"] = "hijack"
    ENV["FROM"] = "monitor"

    _, err = capture_io do
      error = assert_raises(SystemExit) { rake("lyra:mode:check") }
      refute error.success?
    end
    assert_match(/Lyra refuses monitor -> hijack: config.record_touches = false is refused/, err)
  ensure
    ENV.delete("TO")
    ENV.delete("FROM")
  end

  # --- the registry of processes that leave touches out --------------------

  def test_a_process_registers_refreshes_expires_and_ends_its_entry
    Lyra.config.record_touches = false
    Registry.boot!

    live = Registry.live_processes
    assert_equal [[Socket.gethostname, Process.pid, Lyra::VERSION]], live.map { [_1[:host], _1[:pid], _1[:version]] }
    first_seen = live.first[:last_seen]

    # A heartbeat at most every HEARTBEAT seconds: none while fresh.
    queries = registry_queries { Registry.heartbeat_if_due }
    assert_empty queries
    sleep 0.01
    Registry.instance_variable_set(:@beat_at, monotonic - Registry::HEARTBEAT - 1)
    Registry.heartbeat_if_due
    assert_operator Registry.live_processes.first[:last_seen], :>, first_seen

    # Not refreshed for EXPIRY seconds: no longer live.
    connection.execute("UPDATE #{MT::TABLE} SET seen_at = seen_at - INTERVAL '#{Registry::EXPIRY + 1} seconds' " \
                       "WHERE kind = 'touch_skipping'")
    assert_empty Registry.live_processes
    # The next refresh brings it back.
    Registry.instance_variable_set(:@beat_at, monotonic - Registry::HEARTBEAT - 1)
    Registry.heartbeat_if_due
    assert_equal 1, Registry.live_processes.size

    Lyra.config.record_touches = true
    assert_empty Registry.live_processes, "set back to true: the entry ends"
    refute_nil connection.select_value("SELECT ended_at FROM #{MT::TABLE} WHERE kind = 'touch_skipping'")
  end

  def test_a_touch_is_left_out_only_once_the_entry_is_written
    parent, = pair
    Lyra.config.record_touches = false
    Registry.reset! # as a process that has not registered yet
    connection.execute("DELETE FROM #{MT::TABLE}")
    mark

    MT.stub(:table_available?, -> { raise "database gone" }) do
      Rails.logger.stub(:error, nil) { later { parent.touch } }
    end
    assert_equal ["touch"], sources(parent), "the entry could not be written: the touch is recorded"

    # No connection of its own to be had inside the touch's transaction: the
    # entry is never written in that transaction, and the touch is recorded.
    no_connection = ->(*) { raise ActiveRecord::ConnectionTimeoutError, "all connections in use" }
    ActiveRecord::Base.connection_pool.stub(:checkout, no_connection) do
      Rails.logger.stub(:warn, nil) { later { parent.touch } }
    end
    assert_empty Registry.live_processes
    assert_equal %w[touch touch], sources(parent)

    later { parent.touch }
    assert_equal 1, Registry.live_processes.size
    assert_equal %w[touch touch], sources(parent), "once the entry is written, the touch is left out"
  end

  # The reviewer's deadlock: an entry due for a heartbeat inside a transaction
  # while every other connection is held, then another heartbeat in the same
  # transaction once they are free. Registry writes never run in the
  # caller's transaction, so nothing waits on its own uncommitted row.
  def test_heartbeats_inside_one_transaction_with_the_pool_exhausted_do_not_hang
    parent, = pair
    Lyra.config.record_touches = false
    later { parent.touch } # registers
    mark
    pool = ActiveRecord::Base.connection_pool
    hold = Queue.new
    started = Queue.new
    holders = Array.new(pool.size - 1) { Thread.new { pool.with_connection { started << 1; hold.pop } } }
    holders.size.times { started.pop }

    Timeout.timeout(20) do
      TouchOptParent.transaction do
        due!
        Rails.logger.stub(:warn, nil) { later { TouchOptParent.find(parent.id).touch } } # no connection: recorded
        holders.size.times { hold << 1 }
        holders.each(&:join)
        due!
        later { TouchOptParent.find(parent.id).touch } # a second connection now: left out
        later { TouchOptChild.where(author_id: parent.id).touch_all } # in the same transaction
      end
    end
    assert_equal ["touch"], sources(parent), "only the touch made with no connection to spare has an event"
    assert_equal 1, Registry.live_processes.size
  ensure
    holders&.size&.times { hold << 1 }
  end

  def test_two_threads_leaving_their_first_touch_out_register_once
    a, = pair
    b, = pair
    Lyra.config.record_touches = false
    Registry.reset!
    connection.execute("DELETE FROM #{MT::TABLE}")
    go = Queue.new
    threads = [a, b].map do |record|
      Thread.new { go.pop; ActiveRecord::Base.connection_pool.with_connection { TouchOptParent.find(record.id).touch } }
    end
    2.times { go << 1 }
    threads.each(&:join)

    assert_equal 1, connection.select_value("SELECT count(*) FROM #{MT::TABLE} WHERE kind = 'touch_skipping'").to_i
    Lyra.config.record_touches = true
    assert_empty Registry.live_processes
  end

  # The entry's times are the database's at the statement, not at the start
  # of the caller's transaction.
  def test_entry_times_are_taken_when_written
    parent, = pair
    Lyra.config.record_touches = false
    Registry.reset!
    connection.execute("DELETE FROM #{MT::TABLE}")
    TouchOptParent.transaction do
      connection.select_value("SELECT 1")
      sleep 1.2
      later { TouchOptParent.find(parent.id).touch }
    end

    lag = connection.select_value("SELECT EXTRACT(EPOCH FROM (clock_timestamp() - seen_at)) FROM #{MT::TABLE} " \
                                  "WHERE kind = 'touch_skipping'").to_f
    assert_operator lag, :<, 1.0
  end

  def test_the_gate_refuses_while_another_process_leaves_touches_out
    Lyra.config.mode_transition_gate = true
    other_process_leaves_touches_out

    error = assert_raises(MT::Refused) { MT.to!(:hijack, force: true) }
    assert_match(/Lyra refuses monitor -> hijack: 1 process leaves touches out of the log/, error.message)
    assert_match(/other-host pid 4242 \(since .+, last seen .+\)/, error.message)
    assert_includes error.message, Registry::STEPS
    assert_raises(MT::Refused) { MT.to!(:event_sourcing, projection_mode: :lazy) }
    assert_raises(MT::Refused) { MT.check(to: "event_sourcing/sync", from: "monitor", models: models) }
    error = assert_raises(Lyra::Projections::Rebuild::Refused) { Lyra::Projections::Rebuild.rebuild(TouchOptParent) }
    assert_match(/other-host pid 4242/, error.message)
    assert_equal "monitor", MT.current

    # A process booting into Hijack is refused too.
    MT.send(:record_applied, "monitor")
    Lyra.config.mode = :hijack
    assert_raises(MT::Refused) { MT.boot_check! }
    Lyra.config.mode = :monitor

    # Once its entry expires, the strict check decides.
    expire_entries
    assert MT.check(to: "hijack", from: "monitor", models: models).clean?
  end

  # A process registers after the switch's first look at the registry (here,
  # while the certificate's re-check runs): the switch's last look, under the
  # registry's lock, sees it.
  def test_a_registration_during_a_switch_refuses_the_switch
    Lyra.config.mode_transition_gate = true
    pair
    assert MT.check(to: "hijack", from: "monitor", models: models).clean?
    hook = Module.new do
      define_method(:certified_check) do |from, to|
        super(from, to).tap { Thread.current[:touch_opt_window]&.call }
      end
    end
    MT.singleton_class.prepend(hook)
    Thread.current[:touch_opt_window] = -> { other_process_leaves_touches_out }

    error = assert_raises(MT::Refused) { MT.to!(:hijack) }
    assert_match(/other-host pid 4242/, error.message)
    assert_equal "monitor", MT.current
    refute_equal "hijack", MT.last_applied
  ensure
    Thread.current[:touch_opt_window] = nil
  end

  # The other order: the switch is recorded first, and a process that then
  # registers sees it under the lock, ends its entry, records the touch, and
  # refuses to go on.
  def test_a_registration_after_a_switch_records_the_touch_and_fences
    Lyra.config.mode_transition_gate = true
    parent, = pair
    MT.to!(:hijack) # process A
    MT.apply_label("monitor") # process B, which has not seen it yet
    process_b_leaves_touches_out
    mark

    Rails.logger.stub(:error, nil) { later { parent.touch } }

    assert_equal ["touch"], sources(parent), "recorded"
    assert Registry.fenced?
    assert_empty Registry.live_processes
    assert_raises(MT::Refused) { later { parent.touch } }
  end

  # ModeSync in a process with the option on does not adopt a switch while
  # another process leaves touches out; the row stays unseen, and it adopts
  # once that entry has ended.
  def test_a_process_refused_adoption_adopts_once_the_entry_ends
    Lyra.config.mode_transition_gate = true
    Lyra.config.mode_sync = true
    MT.to!(:hijack) # process A
    applied = MT.latest_applied
    other_process_leaves_touches_out # in the moment before A's switch, as far as C can tell

    # Process C: the option on, Monitor, has not seen the switch.
    MT.apply_label("monitor")
    Lyra::ModeSync.reset!
    Lyra::ModeSync.seen!(applied[:id] - 1)
    assert_nil Rails.logger.stub(:error, nil) { Lyra::ModeSync.sync! }
    assert_equal "monitor", MT.current
    assert_equal applied[:id] - 1, Lyra::ModeSync.last_seen_id, "the row stays unseen"

    connection.execute("UPDATE #{MT::TABLE} SET ended_at = clock_timestamp() WHERE kind = 'touch_skipping'")
    assert_equal "hijack", Lyra::ModeSync.sync!
  end

  def test_rake_mode_status_lists_the_processes_that_leave_touches_out
    other_process_leaves_touches_out
    out, = capture_io { rake("lyra:mode:status") }

    assert_match(/touches left out \(config.record_touches = false\): 1 live process/, out)
    assert_match(/other-host pid 4242 \(Lyra #{Regexp.escape(Lyra::VERSION)}\), since .+, last seen .+/, out)
    assert_includes out, Registry::STEPS
  end

  def test_rake_mode_check_prints_the_registry_refusal_and_exits_non_zero
    other_process_leaves_touches_out
    ENV["TO"] = "hijack"
    ENV["FROM"] = "monitor"

    _, err = capture_io do
      error = assert_raises(SystemExit) { rake("lyra:mode:check") }
      refute error.success?
    end
    assert_match(/other-host pid 4242/, err)
    assert_includes err, Registry::STEPS
  ensure
    ENV.delete("TO")
    ENV.delete("FROM")
  end

  # Nothing certified before or during a period in which a process left
  # touches out counts afterwards: the next switch checks everything.
  def test_a_certificate_from_before_an_off_period_is_not_taken
    Lyra.config.mode_transition_gate = true
    parent, = pair
    old = MT.check(to: "hijack", from: "monitor", models: models)
    assert old.clean?

    Lyra.config.record_touches = false
    later { parent.touch(time: 1.hour.ago) } # moves no stream, and its time is before the certificate
    Lyra.config.record_touches = true

    error = assert_raises(MT::Refused) { MT.to!(:hijack) }
    assert_match(/TouchOptParent #{parent.id}: row differs from its events \(updated_at\)/, error.message)
    refute_equal old.certificate_id, error.report.certificate_id
    assert_operator error.report.checked, :>, 0, "a full check, not the old certificate"
  end

  def test_a_certificate_issued_after_the_period_is_taken
    Lyra.config.mode_transition_gate = true
    pair
    Lyra.config.record_touches = false
    Registry.boot!
    Lyra.config.record_touches = true
    fresh = MT.check(to: "hijack", from: "monitor", models: models)
    assert fresh.clean?

    report = MT.to!(:hijack)
    assert_equal fresh.certificate_id, report.certificate_id
    assert_equal 0, report.checked, "taken: only what changed since is re-checked"
  end

  # --- an application already in a mode whose log rebuilds rows -----------

  def test_a_process_with_the_option_off_does_not_boot_into_an_authoritative_application
    MT.send(:record_applied, "hijack")
    process_b_leaves_touches_out

    error = assert_raises(MT::Refused) { Registry.boot! }
    assert_equal Registry.process_refusal("hijack"), error.message
    assert_match(/Lyra refuses to run with config.record_touches = false: the application runs in hijack/, error.message)
    assert_includes error.message, Registry::STEPS
    refute Registry.fenced?
  end

  def test_setting_the_option_off_at_runtime_in_an_authoritative_application_is_refused
    parent, = pair
    MT.to!(:hijack)
    MT.apply_label("monitor") # a process that has not seen the switch yet

    error = assert_raises(MT::Refused) { Lyra.config.record_touches = false }
    assert_equal Registry.process_refusal("hijack"), error.message
    assert_equal true, Lyra.config.record_touches, "left as it was"
    mark
    later { parent.touch }
    assert_equal ["touch"], sources(parent)
    assert_empty Registry.live_processes
  end

  def test_mode_sync_refuses_to_go_on_leaving_touches_out_in_an_authoritative_application
    Lyra.config.mode_transition_gate = true
    Lyra.config.mode_sync = true
    parent, child = pair
    # Process B left touches out until its entry expired.
    process_b_leaves_touches_out
    Registry.boot!
    expire_entries
    Registry.reset!
    # Process A (the option on) switches.
    Lyra.config.instance_variable_set(:@record_touches, true)
    MT.to!(:hijack)
    applied = MT.latest_applied

    # Back to B: Monitor, the option off, has not seen the switch.
    MT.apply_label("monitor")
    process_b_leaves_touches_out
    Lyra::ModeSync.reset!
    Lyra::ModeSync.seen!(applied[:id] - 1)

    error = assert_raises(MT::Refused) { Rails.logger.stub(:error, nil) { Lyra::ModeSync.sync! } }
    assert_match(/the application runs in hijack/, error.message)
    assert Registry.fenced?
    assert_equal "monitor", MT.current
    mark
    assert_raises(MT::Refused) { later { parent.touch } }
    assert_raises(MT::Refused) { later { child.update!(title: "u") } }
    assert_equal "t", TouchOptChild.find(child.id).title, "a save that cascades a touch fails with it"
    assert_empty stream(parent), "the touch is refused, not left out"
    assert_raises(MT::Refused) { Rails.logger.stub(:error, nil) { Lyra::ModeSync.sync! } }

    Lyra.config.record_touches = true
    refute Registry.fenced?
    assert_equal "hijack", Lyra::ModeSync.sync!
  end

  # --- warnings ----------------------------------------------------------------

  def test_a_process_that_leaves_touches_out_warns_once
    messages = []
    Rails.logger.stub(:warn, ->(message) { messages << message }) do
      Lyra.config.record_touches = false
      Registry.boot!
      Registry.instance_variable_set(:@beat_at, monotonic - Registry::HEARTBEAT - 1)
      Registry.heartbeat_if_due
    end

    assert_equal [Registry::WARNING], messages
    assert_equal "Lyra: record_touches is off — touches that change only update timestamps are not recorded; " \
                 "escalation to Hijack or event sourcing is refused while any process runs this way. To escalate: " \
                 "restart every process with record_touches on, run `rake lyra:repair` in Monitor, then switch.",
                 Registry::WARNING
  end

  # --- DualView on models without created_at/updated_at ----------------------

  # DualView read record.created_at and record.updated_at whatever the model
  # had: a model with only updated_on, or no timestamps, raised NoMethodError
  # in DualView, the gate's check and lyra:repair.
  def test_dual_view_the_gate_and_repair_handle_models_without_the_usual_timestamps
    connection.create_table(:touch_opt_stamped_on, force: true) do |t|
      t.string :name
      t.datetime :updated_on
    end
    connection.create_table(:touch_opt_unstamped, force: true) { |t| t.string :name }
    stamped = Class.new(ActiveRecord::Base) { self.table_name = "touch_opt_stamped_on" }
    unstamped = Class.new(ActiveRecord::Base) { self.table_name = "touch_opt_unstamped" }
    Object.const_set(:TouchOptStampedOn, stamped)
    Object.const_set(:TouchOptUnstamped, unstamped)
    [stamped, unstamped].each do |model|
      model.include(Lyra::Interceptors::CrudInterceptor)
      model.monitor_with_lyra
      Lyra.config.monitor_model(model)
    end
    a = stamped.create!(name: "a")
    b = unstamped.create!(name: "b")

    assert_equal %i[updated_on], Lyra::DualView.new(stamped, a.id).crud_state[:timestamps].keys
    assert_equal({}, Lyra::DualView.new(unstamped, b.id).crud_state[:timestamps])
    assert_in_line a, b

    Lyra.config.record_touches = false
    later { a.touch }
    assert_in_line a
    Lyra.config.record_touches = true
    report = MT.check(to: "hijack", from: "monitor", models: [stamped, unstamped])
    assert_equal ["updated_on"], report.discrepancies.map(&:details)
    assert_equal 1, Lyra::Repair.run(models: [stamped, unstamped]).repaired.size
    assert MT.check(to: "hijack", from: "monitor", models: [stamped, unstamped]).clean?
  ensure
    %i[TouchOptStampedOn TouchOptUnstamped].each { Object.send(:remove_const, _1) if Object.const_defined?(_1) }
    connection.drop_table(:touch_opt_stamped_on, if_exists: true)
    connection.drop_table(:touch_opt_unstamped, if_exists: true)
  end

  # --- the default costs nothing ---------------------------------------------

  def test_with_the_option_on_no_write_reads_or_writes_the_registry
    parent, child = pair
    queries = registry_queries do
      later { parent.touch }
      later { TouchOptChild.where(id: child.id).touch_all }
      later { child.update!(title: "u") }
      Lyra::ModeSync.maybe_sync!
    end

    assert_empty queries
  end

  def test_with_the_option_off_a_fresh_entry_costs_no_query_per_touch
    parent, = pair
    Lyra.config.record_touches = false
    later { parent.touch } # registers

    queries = registry_queries { 3.times { later { parent.touch } } }
    assert_empty queries
  end

  # --- Monitor, default (recorded) ------------------------------------------

  def test_by_default_every_kind_of_touch_is_recorded
    parent, child = pair
    mark

    later { parent.touch }
    assert_equal ["touch"], sources(parent)

    later { TouchOptChild.where(id: child.id).touch_all }
    assert_equal ["update_all"], sources(child)

    later { child.update!(title: "u") }
    assert_equal %w[touch touch], sources(parent), "the cascade is recorded too"
    assert_in_line parent, child
  end

  # --- Monitor, record_touches = false ---------------------------------------

  def test_off_an_instance_touch_moves_the_row_and_records_nothing
    parent, = pair
    Lyra.config.record_touches = false
    mark
    before = row_updated_at(parent)

    later { parent.touch }

    assert_operator row_updated_at(parent), :>, before
    assert_empty stream(parent)
    assert_in_line parent
  end

  def test_off_a_touch_that_changes_another_column_is_recorded_in_full
    _, child = pair
    Lyra.config.record_touches = false
    mark

    later { child.touch(:published_at) }

    event = stream(child).sole
    assert_equal "touch", event.metadata[:bypass_source]
    assert_equal %w[published_at updated_at], changes(event).keys.sort
    assert_in_line child
  end

  def test_off_a_bare_touch_all_records_nothing_and_a_named_one_records_every_row
    _, a = pair
    b = TouchOptChild.create!(title: "b")
    Lyra.config.record_touches = false
    mark

    later { TouchOptChild.where(id: [a.id, b.id]).touch_all }
    assert_empty stream(a) + stream(b)
    assert_in_line a, b

    later { TouchOptChild.where(id: [a.id, b.id]).touch_all(:published_at) }
    assert_equal %w[update_all update_all], sources(a) + sources(b)
    assert_in_line a, b
  end

  def test_off_an_update_all_of_updated_at_is_not_a_touch_and_is_recorded
    _, child = pair
    Lyra.config.record_touches = false
    mark

    TouchOptChild.where(id: child.id).update_all(updated_at: 1.day.from_now)

    assert_equal ["update_all"], sources(child)
  end

  def test_off_a_cascade_records_the_child_s_write_and_not_the_parent_s_touch
    parent, child = pair
    Lyra.config.record_touches = false
    mark
    before = row_updated_at(parent)

    later { child.update!(title: "u") }

    assert_operator row_updated_at(parent), :>, before, "Rails touched the parent's row"
    assert_empty stream(parent)
    assert_equal ["updated"], stream(child).map { _1.data[:operation].to_s }
    assert_in_line parent, child
  end

  def test_off_dual_view_still_reports_a_difference_in_another_column
    parent, = pair
    Lyra.config.record_touches = false
    later { parent.touch }
    Lyra.unrecorded_write(reason: "test") { TouchOptParent.where(id: parent.id).update_all(name: "Changed") }

    differences = Lyra::DualView.new(TouchOptParent, parent.id).calculate_differences
    assert_equal %w[name updated_at], differences.keys.sort, "the timestamp is reported beside a real difference"
  end

  def test_off_strict_mode_allows_a_touch_and_still_refuses_touch_all
    parent, child = pair
    Lyra.config.record_touches = false
    Lyra.config.strict_data_access = true
    mark

    later { parent.touch }
    assert_empty stream(parent)
    assert_raises(Lyra::StrictDataAccessViolation) { TouchOptChild.where(id: child.id).touch_all }
  end

  # --- back to recording, and escalating ----------------------------------

  # The documented path out: with touches on again the check sees the stale
  # timestamps, lyra:repair records them, and the switch then passes.
  def test_repair_records_the_missed_timestamps_before_an_escalation
    parent, child = pair
    Lyra.config.record_touches = false
    later { parent.touch }
    later { child.update!(title: "u") }
    assert_empty Lyra::Repair.run(models: [TouchOptParent, TouchOptChild], dry_run: true).found,
                 "with touches off, timestamp-only differences are not discrepancies"

    Lyra.config.record_touches = true
    report = MT.check(to: "hijack", from: "monitor", models: [TouchOptParent, TouchOptChild])
    assert_equal [["TouchOptParent", "updated_at"]], report.discrepancies.map { [_1.model, _1.details] }

    result = Lyra::Repair.run(models: [TouchOptParent, TouchOptChild])
    assert_equal 1, result.repaired.size
    assert_equal({}, Lyra::DualView.new(TouchOptParent, parent.id).calculate_differences)
    assert MT.check(to: "hijack", from: "monitor", models: [TouchOptParent, TouchOptChild]).clean?
  end

  # A row without a stream (it predates Lyra) that is touched with the
  # option off gets no event; Genesis imports it later as it then is,
  # timestamps included, so nothing is lost.
  def test_genesis_imports_a_touched_row_that_has_no_stream_as_it_is
    Lyra.config.disable!
    parent = TouchOptParent.create!(name: "Old", email: "old@example.com")
    Lyra.config.mode = :monitor
    Lyra.config.record_touches = false
    later { parent.touch }
    assert_empty stream(parent)

    Lyra.config.record_touches = true
    report = MT.check(to: "hijack", from: "monitor", models: [TouchOptParent])
    assert_equal 1, report.imported
    assert report.clean?, report.discrepancies.map(&:to_s).inspect
  end

  # --- Hijack and ES-Sync: the option cannot be off, touches are recorded ---

  { hijack: -> { Lyra.config.enable_hijack! },
    es_sync: lambda {
      Lyra.config.enable_event_sourcing!
      Lyra.config.projection_mode = :sync
    } }.each do |name, enter|
    define_method(:"test_#{name}_records_every_kind_of_touch") do
      instance_exec(&enter)
      assert_equal({ hijack: "hijack", es_sync: "event_sourcing/sync" }.fetch(name), MT.current)
      parent, child = pair
      mark

      later { parent.touch }
      later { TouchOptChild.where(id: child.id).touch_all }
      later { child.update!(title: "u") }

      assert_equal %w[touch touch], sources(parent)
      assert_includes sources(child), "update_all"
      assert_in_line parent, child
    end
  end

  private

  def pair
    parent = TouchOptParent.create!(name: "Ann", email: "ann-#{SecureRandom.hex(4)}@example.com")
    [parent, TouchOptChild.create!(title: "t", author: parent)]
  end

  # Writes a moment later, so a touch moves updated_at.
  def later
    sleep 0.01
    yield
  end

  def assert_in_line(*records)
    records.each do |record|
      assert_equal({}, Lyra::DualView.new(record.class, record.id).calculate_differences,
                   "#{record.class.name} #{record.id}: row and events agree")
    end
  end

  # Note the events stored so far: stream then returns only those after.
  def mark
    @seen = Lyra.config.event_store.read.to_a.map(&:event_id).to_set
  end

  def stream(record)
    events = Lyra.config.event_store.read.stream(Lyra.stream_name(record.class, record.id)).to_a
    @seen ? events.reject { @seen.include?(_1.event_id) } : events
  end

  def sources(record) = stream(record).map { _1.metadata[:bypass_source] }.compact

  def changes(event) = (event.data[:changes] || event.data["changes"]).transform_keys(&:to_s)

  def row_updated_at(record)
    ActiveRecord::Base.connection.select_value("SELECT updated_at FROM #{record.class.table_name} WHERE id = #{record.id}")
  end

  def clear_events
    conn = ActiveRecord::Base.connection
    conn.execute("DELETE FROM event_store_events_in_streams")
    conn.execute("DELETE FROM event_store_events")
  end

  def models = [TouchOptParent, TouchOptChild]

  # This process has the option off, without registering now (as one that
  # set it in its initializer and has not booted).
  def process_b_leaves_touches_out
    Lyra.config.instance_variable_set(:@record_touches, false)
  end

  def expire_entries
    connection.execute("UPDATE #{MT::TABLE} SET seen_at = seen_at - INTERVAL '#{Registry::EXPIRY + 1} seconds' " \
                       "WHERE kind = 'touch_skipping'")
  end

  # This process's entry is due for a heartbeat.
  def due!
    Registry.instance_variable_set(:@beat_at, monotonic - Registry::HEARTBEAT - 1)
  end
  
  def connection = ActiveRecord::Base.connection
  
  def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  
  # An entry of another process that leaves touches out.
  def other_process_leaves_touches_out
    assert MT.table_available?
    connection.execute(
      "INSERT INTO #{MT::TABLE} (kind, from_config, to_config, position, checked, created_at, seen_at, started_at, host, pid) " \
      "SELECT 'touch_skipping', #{connection.quote(Lyra::VERSION)}, 'touches', COALESCE(MAX(id), 0), 0, " \
      "CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, 'other-host', 4242 FROM #{MT::TABLE}"
    )
  end
  
  # The SQL statements that name the registry's table, from any thread.
  def registry_queries
    seen = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      seen << payload[:sql] if payload[:sql].include?(MT::TABLE)
    end
    yield
    seen
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end
  
  def rake(task)
    require "rake"
    Rake.application = Rake::Application.new
    Rake::Task.define_task(:environment)
    load File.expand_path("../lib/tasks/lyra_mode.rake", __dir__)
    Rake::Task[task].invoke
  end

  def invalidations
    ActiveRecord::Base.connection.select_value("SELECT count(*) FROM #{MT::TABLE} WHERE kind = 'invalidation'").to_i
  end

  def clean
    conn = ActiveRecord::Base.connection
    conn.execute("DELETE FROM articles")
    conn.execute("DELETE FROM users")
    conn.execute("DELETE FROM #{MT::TABLE}") if conn.table_exists?(MT::TABLE)
    clear_events
  end
end
