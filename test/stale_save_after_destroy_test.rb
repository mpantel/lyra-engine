# frozen_string_literal: true

require "test_helper"

# A save that changes no row records no update. A copy loaded before another
# process destroyed the record is saved afterwards: its UPDATE reaches no row,
# or, when nothing changed, no UPDATE runs at all. Active Record still runs
# after_update either way, and before 1.0.0 Monitor appended Updated after
# Destroyed, an ill-formed stream [Created, Destroyed, Updated]. A save that
# changes nothing records nothing in any mode: an update carries its changes,
# and there are none.
class StaleSaveAfterDestroyTest < Minitest::Test
  TABLE = "lyra_stale_items"
  MODES = %i[monitor hijack es_sync es_noproj].freeze

  def setup
    skip "Requires Rails and PostgreSQL" unless defined?(ActiveRecord::Base) && connection.adapter_name.match?(/postgres/i)

    connection.create_table(TABLE, force: true) do |t|
      t.string :label
      t.timestamps
    end
    Object.send(:remove_const, :StaleItem) if defined?(StaleItem)
    klass = Class.new(ActiveRecord::Base)
    Object.const_set(:StaleItem, klass)
    klass.table_name = TABLE
    klass.include Lyra::Interceptors::CrudInterceptor
    klass.monitor_with_lyra
    klass.reset_column_information
    clean
    Lyra.config.monitor_model(klass)
    Lyra.config.enable_monitor!
  end

  def teardown
    return unless defined?(StaleItem)

    Lyra.reset_config!
    clean
    connection.drop_table(TABLE, if_exists: true)
  end

  def test_a_stale_save_after_a_concurrent_destroy_appends_no_event
    item = StaleItem.create!(label: "a")
    stale = StaleItem.find(item.id)
    StaleItem.find(item.id).destroy!

    stale.update!(label: "b")

    assert_equal %i[created destroyed], operations(item.id), "the stream stays well formed"
  end

  def test_a_stale_save_that_changes_nothing_after_a_concurrent_destroy_appends_no_event
    item = StaleItem.create!(label: "a")
    stale = StaleItem.find(item.id)
    StaleItem.find(item.id).destroy!

    stale.save!

    assert_equal %i[created destroyed], operations(item.id), "the stream stays well formed"
  end

  def test_a_normal_update_is_still_recorded
    item = StaleItem.create!(label: "a")

    item.update!(label: "b")

    assert_equal %i[created updated], operations(item.id)
  end

  def test_a_second_update_of_the_same_copy_is_still_recorded
    item = StaleItem.create!(label: "a")
    item.update!(label: "b")
    item.update!(label: "c")

    assert_equal %i[created updated updated], operations(item.id)
  end

  def test_a_save_that_changes_nothing_does_not_hide_the_next_update
    item = StaleItem.create!(label: "a")
    item.save!
    item.update!(label: "b")

    assert_equal %i[created updated], operations(item.id)
  end

  MODES.each do |mode|
    define_method("test_a_save_that_changes_nothing_records_nothing_in_#{mode}") do
      use(mode)
      item = StaleItem.create!(label: "a")

      assert StaleItem.find(item.id).save, "the save still succeeds"
      item.update!(label: "a")

      assert_equal %i[created], operations(item.id)
    end

    define_method("test_an_update_after_a_save_that_changed_nothing_is_recorded_in_#{mode}") do
      use(mode)
      item = StaleItem.create!(label: "a")
      item.save!
      item.update!(label: "b")

      assert_equal %i[created updated], operations(item.id)
      assert_equal "b", StaleItem.find(item.id).label
    end
  end

  # Where Lyra writes the record, a save of a destroyed record is refused
  # whether or not it changes anything (Lyra::RecordDestroyedError, 0.9.3).
  (MODES - %i[monitor]).each do |mode|
    define_method("test_a_stale_save_that_changes_nothing_is_refused_in_#{mode}") do
      use(mode)
      item = StaleItem.create!(label: "a")
      stale = StaleItem.find(item.id)
      StaleItem.find(item.id).destroy!

      assert_raises(Lyra::RecordDestroyedError) { stale.save }
      assert_equal %i[created destroyed], operations(item.id)
    end
  end

  private

  def use(mode)
    case mode
    when :monitor then Lyra.config.enable_monitor!
    when :hijack then Lyra.config.enable_hijack!
    else
      Lyra.config.enable_event_sourcing!
      Lyra.config.projection_mode = mode == :es_sync ? :sync : :disabled
    end
  end

  def operations(id)
    Lyra.config.event_store.read.stream(Lyra.stream_name(StaleItem, id)).to_a.map { |e| Lyra::Event.operation_of(e) }
  end

  def clean
    connection.execute("DELETE FROM event_store_events_in_streams")
    connection.execute("DELETE FROM event_store_events")
  end

  def connection = ActiveRecord::Base.connection
end
