# frozen_string_literal: true

require "test_helper"

# A destroy that deletes no row records no destroy. Active Record runs
# after_destroy whether or not its DELETE reached a row (without optimistic
# locking nothing checks the count), and also for a record that is not
# persisted, a new one or a copy already destroyed, for which it runs no DELETE.
# Before 1.0.0 Monitor appended Destroyed in every such case: two stale copies
# both destroyed, or one copy destroyed twice, left [Created, Destroyed,
# Destroyed], a stream no replay can apply (apply(⊥, Destroyed) is undefined).
# Hijack and the event-sourcing modes refuse a stale destroy
# (Lyra::RecordDestroyedError, 0.9.3), as before.
class StaleDestroyTest < Minitest::Test
  TABLE = "lyra_stale_destroy_items"
  CHILDREN = "lyra_stale_destroy_children"
  LOCKED = "lyra_stale_destroy_locked"
  MODES = %i[monitor hijack es_sync es_noproj].freeze

  def setup
    skip "Requires Rails and PostgreSQL" unless defined?(ActiveRecord::Base) && connection.adapter_name.match?(/postgres/i)

    connection.create_table(TABLE, force: true) do |t|
      t.string :label
      t.timestamps
    end
    connection.create_table(CHILDREN, force: true) do |t|
      t.integer :parent_id
      t.string :label
      t.timestamps
    end
    connection.create_table(LOCKED, force: true) do |t|
      t.string :label
      t.integer :lock_version, default: 0, null: false
      t.timestamps
    end
    define_model(:DestroyChild, CHILDREN)
    define_model(:DestroyItem, TABLE) { has_many :children, class_name: "DestroyChild", foreign_key: :parent_id, dependent: :destroy }
    define_model(:DestroyLocked, LOCKED)
    clean
    Lyra.config.enable_monitor!
  end

  def teardown
    return unless defined?(DestroyItem)

    Lyra.reset_config!
    clean
    [TABLE, CHILDREN, LOCKED].each { connection.drop_table(_1, if_exists: true) }
  end

  def test_two_stale_copies_destroyed_record_one_destroy
    item = DestroyItem.create!(label: "a")
    first = DestroyItem.find(item.id)
    stale = DestroyItem.find(item.id)

    first.destroy
    assert stale.destroy, "Active Record's destroy still succeeds"

    assert_equal %i[created destroyed], operations(DestroyItem, item.id), "the stream stays well formed"
  end

  def test_the_same_copy_destroyed_twice_records_one_destroy
    item = DestroyItem.create!(label: "a")

    item.destroy
    item.destroy

    assert_equal %i[created destroyed], operations(DestroyItem, item.id)
  end

  # delete_all records its own Destroyed (Lyra::BypassEvents); the stale copy's
  # destroy then deletes nothing.
  def test_a_destroy_after_delete_all_records_no_second_destroy
    item = DestroyItem.create!(label: "a")
    stale = DestroyItem.find(item.id)
    DestroyItem.where(id: item.id).delete_all

    stale.destroy

    assert_equal %i[created destroyed], operations(DestroyItem, item.id)
  end

  # A row deleted by hand-written SQL leaves no event (nothing can record it).
  # The destroy that follows deletes nothing and records nothing: the stream
  # has fallen behind the table, as after any write that bypasses Active
  # Record, and DualView reports it for lyra:repair, which appends the Destroyed.
  def test_a_destroy_after_a_raw_sql_delete_records_nothing_and_repair_closes_the_gap
    item = DestroyItem.create!(label: "a")
    stale = DestroyItem.find(item.id)
    connection.execute("DELETE FROM #{TABLE} WHERE id = #{item.id}")

    stale.destroy

    assert_equal %i[created], operations(DestroyItem, item.id)
    assert_equal "events but no row", Lyra::ModeTransition.discrepancy(DestroyItem, item.id.to_s)&.problem
    Lyra::Repair.repair(DestroyItem, item.id.to_s, operator: "test")
    assert_equal %i[created destroyed], operations(DestroyItem, item.id)
  end

  MODES.each do |mode|
    define_method("test_a_destroy_is_recorded_once_in_#{mode}") do
      use(mode)
      item = DestroyItem.create!(label: "a")

      DestroyItem.find(item.id).destroy

      assert_equal %i[created destroyed], operations(DestroyItem, item.id)
    end

    define_method("test_a_new_record_s_destroy_records_nothing_in_#{mode}") do
      use(mode)
      before = event_count

      DestroyItem.new(label: "never saved").destroy

      assert_equal before, event_count
    end

    define_method("test_dependent_destroy_records_each_child_once_in_#{mode}") do
      use(mode)
      parent = DestroyItem.create!(label: "p")
      children = 2.times.map { |i| DestroyChild.create!(parent_id: parent.id, label: "c#{i}") }

      DestroyItem.find(parent.id).destroy

      assert_equal %i[created destroyed], operations(DestroyItem, parent.id)
      children.each { assert_equal %i[created destroyed], operations(DestroyChild, _1.id), "#{mode} child #{_1.id}" }
    end

    define_method("test_destroy_all_records_each_record_once_in_#{mode}") do
      use(mode)
      items = 3.times.map { |i| DestroyItem.create!(label: "i#{i}") }

      DestroyItem.where(id: items.map(&:id)).destroy_all

      items.each { assert_equal %i[created destroyed], operations(DestroyItem, _1.id), "#{mode} item #{_1.id}" }
    end

    # Optimistic locking stays as Active Record defines it: a stale destroy
    # raises StaleObjectError, its transaction rolls back, nothing is recorded.
    define_method("test_a_stale_destroy_with_optimistic_locking_raises_in_#{mode}") do
      use(mode)
      item = DestroyLocked.create!(label: "a")
      stale = DestroyLocked.find(item.id)
      DestroyLocked.find(item.id).update!(label: "b")

      assert_raises(ActiveRecord::StaleObjectError) { stale.destroy }
      assert_equal %i[created updated], operations(DestroyLocked, item.id)

      DestroyLocked.find(item.id).destroy
      assert_equal %i[created updated destroyed], operations(DestroyLocked, item.id)
    end
  end

  # Where Lyra writes the record, a stale destroy is still refused.
  (MODES - %i[monitor]).each do |mode|
    define_method("test_a_stale_destroy_is_refused_in_#{mode}") do
      use(mode)
      item = DestroyItem.create!(label: "a")
      stale = DestroyItem.find(item.id)
      DestroyItem.find(item.id).destroy

      assert_raises(Lyra::RecordDestroyedError) { stale.destroy }
      assert_equal %i[created destroyed], operations(DestroyItem, item.id)
    end
  end

  private

  def define_model(name, table, &block)
    Object.send(:remove_const, name) if Object.const_defined?(name)
    klass = Class.new(ActiveRecord::Base)
    Object.const_set(name, klass)
    klass.table_name = table
    klass.class_eval(&block) if block
    klass.include Lyra::Interceptors::CrudInterceptor
    klass.monitor_with_lyra
    klass.reset_column_information
    Lyra.config.monitor_model(klass)
  end

  def use(mode)
    case mode
    when :monitor then Lyra.config.enable_monitor!
    when :hijack then Lyra.config.enable_hijack!
    else
      Lyra.config.enable_event_sourcing!
      Lyra.config.projection_mode = mode == :es_sync ? :sync : :disabled
    end
  end

  def operations(model, id)
    Lyra.config.event_store.read.stream(Lyra.stream_name(model, id)).to_a.map { |e| Lyra::Event.operation_of(e) }
  end

  def event_count
    connection.select_value("SELECT count(*) FROM event_store_events").to_i
  end

  def clean
    connection.execute("DELETE FROM event_store_events_in_streams")
    connection.execute("DELETE FROM event_store_events")
  end

  def connection = ActiveRecord::Base.connection
end
