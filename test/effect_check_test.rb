# frozen_string_literal: true

require "test_helper"

# The effect clause of Hypothesis H (H2), checked at the write when
# config.check_effects is on (Lyra::EffectCheck, from 1.0.1). A trigger that
# changes a column the event also records makes the row differ from its
# events: in Hijack and ES-Sync the write is refused in its transaction, and
# neither the row nor the event stays. Off (the default), the write goes
# through and the two stores part, as in 1.0.0, until DualView finds it.
class EffectCheckTest < Minitest::Test
  TABLE = "lyra_effect_items"
  MODES = { hijack: -> { Lyra.config.enable_hijack! },
            es_sync: -> { Lyra.config.enable_event_sourcing!; Lyra.config.projection_mode = :sync } }.freeze

  def setup
    skip "Requires Rails and PostgreSQL" unless defined?(ActiveRecord::Base) && connection.adapter_name.match?(/postgres/i)

    connection.create_table(TABLE, force: true) do |t|
      t.string :name
      t.string :code, default: "c0"
      t.timestamps
    end
    Object.send(:remove_const, :EffectItem) if Object.const_defined?(:EffectItem)
    Object.const_set(:EffectItem, Class.new(ActiveRecord::Base) { self.table_name = TABLE })
    EffectItem.include Lyra::Interceptors::CrudInterceptor
    EffectItem.monitor_with_lyra
    Lyra.config.monitor_model(EffectItem)
    clean
  end

  def teardown
    return unless Object.const_defined?(:EffectItem)

    Lyra.reset_config!
    clean
    connection.execute("DROP TRIGGER IF EXISTS lyra_effect_upcase ON #{TABLE}")
    connection.drop_table(TABLE, if_exists: true)
    connection.execute("DROP FUNCTION IF EXISTS lyra_effect_upcase()")
  end

  def test_a_write_whose_row_matches_its_events_passes
    MODES.each do |mode, enable|
      use(enable, check: true)
      item = EffectItem.create!(name: "ann")
      item.update!(name: "bea")
      other = EffectItem.create!(name: "gone")
      other.destroy!

      assert_equal [["bea", "c0"]], EffectItem.pluck(:name, :code), mode
    end
  end

  def test_a_trigger_that_changes_the_row_refuses_the_write
    upcase_trigger!
    MODES.each do |mode, enable|
      use(enable, check: true)
      error = assert_raises(Lyra::EffectMismatchError, mode) { EffectItem.create!(name: "ann") }
      assert_match(/row differs from its events/, error.message)
      assert_equal 0, EffectItem.count, "#{mode}: the row rolled back"
      assert_equal 0, event_count, "#{mode}: the event rolled back"
    end
  end

  def test_an_update_the_trigger_changes_is_refused_and_the_record_stays
    MODES.each do |mode, enable|
      use(enable, check: true)
      item = EffectItem.create!(name: "ANN")
      upcase_trigger!
      events = event_count
      assert_raises(Lyra::EffectMismatchError, mode) { item.update!(name: "bea") }
      assert_equal ["ANN"], EffectItem.pluck(:name), mode
      assert_equal events, event_count, mode
      drop_trigger!
    end
  end

  # Off by default: the write goes through, and the row and the log part.
  def test_off_the_write_goes_through_as_in_1_0_0
    upcase_trigger!
    MODES.each do |mode, enable|
      use(enable, check: false)
      item = EffectItem.create!(name: "ann")

      assert_equal ["ANN"], EffectItem.pluck(:name), mode
      refute_nil Lyra::ModeTransition.discrepancy(EffectItem, item.id), "#{mode}: DualView finds it later"
    end
  end

  # A soft delete runs the destroy callbacks and keeps the row, so its stream
  # ends in a destroy while its row stays, by design: not a mismatch.
  def test_a_soft_delete_is_not_a_mismatch
    EffectItem.class_eval { def soft_destroy = with_transaction_returning_status { run_callbacks(:destroy) { true } } }
    MODES.each do |mode, enable|
      use(enable, check: true)
      item = EffectItem.create!(name: "ann")
      item.soft_destroy

      assert_equal ["ann"], EffectItem.pluck(:name), mode
    end
  end

  # Monitor records what its table did: nothing to check.
  def test_monitor_is_not_checked
    upcase_trigger!
    clean
    Lyra.config.enable_monitor!
    Lyra.config.check_effects = true
    EffectItem.create!(name: "ann")

    assert_equal ["ANN"], EffectItem.pluck(:name)
  end

  private

  def use(enable, check:)
    clean
    enable.call
    Lyra.config.check_effects = check
  end

  def upcase_trigger!
    connection.execute(<<~SQL)
      CREATE OR REPLACE FUNCTION lyra_effect_upcase() RETURNS trigger AS $$
      BEGIN NEW.name := upper(NEW.name); RETURN NEW; END $$ LANGUAGE plpgsql
    SQL
    connection.execute("DROP TRIGGER IF EXISTS lyra_effect_upcase ON #{TABLE}")
    connection.execute("CREATE TRIGGER lyra_effect_upcase BEFORE INSERT OR UPDATE ON #{TABLE} FOR EACH ROW EXECUTE FUNCTION lyra_effect_upcase()")
  end

  def drop_trigger! = connection.execute("DROP TRIGGER IF EXISTS lyra_effect_upcase ON #{TABLE}")

  def event_count = connection.select_value("SELECT count(*) FROM event_store_events").to_i

  def clean
    connection.execute("DELETE FROM #{TABLE}") if connection.table_exists?(TABLE)
    connection.execute("DELETE FROM event_store_events_in_streams")
    connection.execute("DELETE FROM event_store_events")
    connection.execute("DELETE FROM #{Lyra::StreamHeads::TABLE}") if connection.table_exists?(Lyra::StreamHeads::TABLE)
  end

  def connection = ActiveRecord::Base.connection
end
