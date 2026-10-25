# frozen_string_literal: true

require "test_helper"

# Optimistic locking (a lock_version column) in every mode.
#
# Active Record checks the column in the UPDATE or DELETE that writes the row
# and raises ActiveRecord::StaleObjectError when another writer has moved it
# since the record was loaded. In the event-sourcing modes Lyra writes the row
# from the event, or not at all, so that statement never ran: a stale update
# silently overwrote the newer one (a lost update), and the events never
# carried the version's increment, so the log replayed to a lock_version the
# row did not have.
class OptimisticLockingTest < Minitest::Test
  TABLE = "lyra_locked_items"

  # Holds the writer of the current thread once, just after its event is
  # appended, until the test releases it. Inert unless the thread set
  # Thread.current[:hold_after_append].
  module HoldAfterAppend
    def append_events(*args, **kwargs)
      result = super
      gate = Thread.current[:hold_after_append]
      if gate
        Thread.current[:hold_after_append] = nil
        gate[:reached] << true
        gate[:resume].pop
      end
      result
    end
  end
  Lyra.singleton_class.prepend(HoldAfterAppend)

  MODES = %i[monitor hijack es_sync es_async es_noproj es_lazy].freeze

  def setup
    skip "Requires Rails and PostgreSQL" unless defined?(ActiveRecord::Base) && connection.adapter_name.match?(/postgres/i)

    connection.create_table(TABLE, force: true) do |t|
      t.string :label
      t.integer :hits, default: 0, null: false
      t.integer :lock_version, default: 0, null: false
      t.timestamps
    end
    Object.send(:remove_const, :LockedItem) if defined?(LockedItem)
    Object.const_set(:LockedItem, Class.new(ActiveRecord::Base) do
      self.table_name = TABLE
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
    end)
    LockedItem.reset_column_information
    clean
    Lyra.config.monitor_model(LockedItem)
  end

  def teardown
    return unless defined?(LockedItem)

    Lyra.reset_config!
    clean
    connection.drop_table(TABLE, if_exists: true)
  end

  MODES.each do |mode|
    define_method("test_a_stale_update_raises_in_#{mode}") do
      use(mode)
      id = LockedItem.create!(label: "initial").id
      first = LockedItem.find(id)
      stale = LockedItem.find(id)
      first.update!(label: "first")

      assert_raises(ActiveRecord::StaleObjectError) { stale.update!(label: "stale") }
      assert_equal 0, stale.lock_version, "the stale copy keeps its version, as Active Record leaves it"
      assert_equal ["first", 1], current(id)
      refute_includes labels_in_log(id), "stale", "the stale write appended nothing"
      assert_row_and_log_agree(id)
    end

    define_method("test_a_fresh_copy_updates_after_a_stale_one_failed_in_#{mode}") do
      use(mode)
      id = LockedItem.create!(label: "initial").id
      stale = LockedItem.find(id)
      LockedItem.find(id).update!(label: "first")
      assert_raises(ActiveRecord::StaleObjectError) { stale.update!(label: "stale") }

      LockedItem.find(id).update!(label: "second")

      assert_equal ["second", 2], current(id)
      assert_row_and_log_agree(id)
    end

    define_method("test_one_copy_saved_twice_is_not_stale_in_#{mode}") do
      use(mode)
      record = LockedItem.create!(label: "initial")
      record.update!(label: "one")
      record.update!(label: "two")

      assert_equal 2, record.lock_version
      refute record.lock_version_changed?, "the increment is saved, not pending"
      assert_equal ["two", 2], current(record.id)
      assert_row_and_log_agree(record.id)
    end

    # The Rails idiom for forms: the version the form was rendered with is
    # submitted with the change, and checked instead of the loaded one.
    define_method("test_a_submitted_lock_version_is_checked_in_#{mode}") do
      use(mode)
      id = LockedItem.create!(label: "initial").id
      LockedItem.find(id).update!(label: "first")

      assert_raises(ActiveRecord::StaleObjectError) { LockedItem.find(id).update!(label: "form", lock_version: 0) }
      LockedItem.find(id).update!(label: "form", lock_version: 1)

      assert_equal ["form", 2], current(id)
      assert_row_and_log_agree(id)
    end

    define_method("test_a_stale_destroy_raises_in_#{mode}") do
      use(mode)
      id = LockedItem.create!(label: "initial").id
      stale = LockedItem.find(id)
      LockedItem.find(id).update!(label: "first")

      assert_raises(ActiveRecord::StaleObjectError) { stale.destroy! }
      assert_equal ["first", 1], current(id)
      refute_includes operations_in_log(id), :destroyed

      LockedItem.find(id).destroy!
      assert_includes operations_in_log(id), :destroyed
    end

    define_method("test_touch_records_the_new_lock_version_in_#{mode}") do
      use(mode)
      record = LockedItem.create!(label: "initial")
      record.touch

      assert_equal 1, record.lock_version
      assert_equal ["initial", 1], current(record.id)
      assert_row_and_log_agree(record.id)
    end

    define_method("test_increment_bang_keeps_the_version_in_line_in_#{mode}") do
      use(mode)
      record = LockedItem.create!(label: "initial")
      record.increment!(:hits)
      record.update!(label: "after")

      assert_equal ["after", 2], current(record.id)
      assert_row_and_log_agree(record.id)
    end
  end

  # Two writers of one record, both holding version 0: the first is held
  # after its append, inside its transaction, while the second runs. The
  # check and the append happen under the aggregate's lock, so the second
  # waits, then finds the log at version 1 and raises.
  %i[es_sync es_async es_noproj es_lazy].each do |mode|
    define_method("test_concurrent_writers_of_one_version_cannot_both_win_in_#{mode}") do
      use(mode)
      id = LockedItem.create!(label: "initial").id
      first = LockedItem.find(id)
      second = LockedItem.find(id)

      gate = { reached: Queue.new, resume: Queue.new }
      writer = Thread.new do
        Thread.current[:hold_after_append] = gate
        with_connection { first.update!(label: "first") }
      end
      gate[:reached].pop

      racer = Thread.new do
        with_connection { second.update!(label: "second") }
        :won
      rescue ActiveRecord::StaleObjectError
        :stale
      end
      refute racer.join(0.5), "the second writer ran past the first's lock"

      gate[:resume] << true
      writer.value
      assert_equal :stale, racer.value
      assert_equal ["first", 1], current(id)
      refute_includes labels_in_log(id), "second"
    end
  end

  # Events written before the version was recorded (here: a row whose
  # lock_version moved without an event, as Hijack left it) give the log an
  # older version than the record's. Such a record is not stale.
  def test_a_log_that_never_recorded_the_increments_does_not_lock_the_record_out
    use(:es_sync)
    id = LockedItem.create!(label: "initial").id
    connection.execute("UPDATE #{TABLE} SET lock_version = 3 WHERE id = #{Integer(id)}")

    LockedItem.find(id).update!(label: "later")

    assert_equal ["later", 4], current(id)
    assert_row_and_log_agree(id)
  end

  # ES-Async with a real queue: the row trails the log until the job runs. A
  # touch is checked against the log, so it is not taken for stale.
  def test_touch_while_the_row_trails_the_log_in_es_async
    previous = ActiveJob::Base.queue_adapter
    adapter = ActiveJob::QueueAdapters::TestAdapter.new
    ActiveJob::Base.queue_adapter = adapter
    use(:es_async)
    Lyra.config.async_projections_inline = false
    record = LockedItem.create!(label: "initial")
    run_enqueued(adapter)
    record.update!(label: "queued")
    assert_equal 0, connection.select_value("SELECT lock_version FROM #{TABLE} WHERE id = #{record.id}").to_i

    record.touch
    run_enqueued(adapter)

    assert_equal 2, record.lock_version
    assert_equal ["queued", 2], current(record.id)
    assert_row_and_log_agree(record.id)
  ensure
    ActiveJob::Base.queue_adapter = previous if previous
  end

  private

  def with_connection(&block) = ActiveRecord::Base.connection_pool.with_connection(&block)

  def run_enqueued(adapter)
    jobs = adapter.enqueued_jobs.dup
    adapter.enqueued_jobs.clear
    jobs.each { |job| job[:job].perform_now(*job[:args]) }
  end

  def use(mode)
    case mode
    when :monitor then Lyra.config.enable_monitor!
    when :hijack then Lyra.config.enable_hijack!
    else
      Lyra.config.enable_event_sourcing!
      Lyra.config.projection_mode = { es_sync: :sync, es_async: :async, es_noproj: :disabled, es_lazy: :lazy }.fetch(mode)
    end
    @mode = mode
  end

  def connection = ActiveRecord::Base.connection

  # The record as the mode's reads give it.
  def current(id)
    record = LockedItem.find(id)
    [record.label, record.lock_version]
  end

  def stream(id) = Lyra.config.event_store.read.stream(Lyra.stream_name(LockedItem, id)).to_a

  def labels_in_log(id)
    stream(id).filter_map do |event|
      attrs = event.data[:changes] || event.data["changes"] || event.data[:attributes] || event.data["attributes"] || {}
      value = attrs.with_indifferent_access[:label]
      value.is_a?(Array) ? value.last : value
    end
  end

  def operations_in_log(id) = stream(id).map { |e| Lyra::Event.operation_of(e) }

  # The table (where the mode keeps one) and the log replayed agree on every
  # column, lock_version included.
  def assert_row_and_log_agree(id)
    LockedItem.count if @mode == :es_lazy # bring the table up to date first
    differences = Lyra::DualView.new(LockedItem, id).calculate_differences

    assert_equal({ no_differences: true }, differences)
    return if @mode == :es_noproj

    row = connection.select_value("SELECT lock_version FROM #{TABLE} WHERE id = #{Integer(id)}")
    assert_equal current(id).last, row.to_i, "the row has the version the mode's reads give"
  end

  def clean
    connection.execute("DELETE FROM #{TABLE}") if connection.table_exists?(TABLE)
    connection.execute("DELETE FROM event_store_events_in_streams")
    connection.execute("DELETE FROM event_store_events")
    Lyra::Projections::LazyProjection.reset!
  end
end
