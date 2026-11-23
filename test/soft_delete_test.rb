# frozen_string_literal: true

require "test_helper"

# A soft delete (paranoia's paranoia_destroy: the destroy callbacks, run by
# hand around an update_columns of deleted_at, and the row kept) from 1.0.1:
# recorded as the update it is, so the record's stream stays live while its
# row stays. 1.0.0 recorded a Destroyed, the stream ended while the row
# remained, and every comparison (DualView, the mode gate, the effect check)
# had to treat the record as a mismatch or an exception; ES-NoProj lost the
# record from its view, where Monitor keeps it behind its default scope.
class SoftDeleteTest < Minitest::Test
  TABLE = "lyra_soft_items"
  MODES = {
    monitor: -> { Lyra.config.enable_monitor! },
    hijack: -> { Lyra.config.enable_hijack! },
    es_sync: -> { Lyra.config.enable_event_sourcing!; Lyra.config.projection_mode = :sync },
    es_async: -> { Lyra.config.enable_event_sourcing!; Lyra.config.projection_mode = :async; Lyra.config.async_projections_inline = true },
    es_lazy: -> { Lyra.config.enable_event_sourcing!; Lyra.config.projection_mode = :lazy },
    es_noproj: -> { Lyra.config.enable_event_sourcing!; Lyra.config.projection_mode = :disabled }
  }.freeze

  def setup
    skip "Requires Rails and PostgreSQL" unless defined?(ActiveRecord::Base) && connection.adapter_name.match?(/postgres/i)

    connection.create_table(TABLE, force: true) do |t|
      t.string :name
      t.datetime :deleted_at
      t.timestamps
    end
    Object.send(:remove_const, :SoftItem) if Object.const_defined?(:SoftItem)
    Object.const_set(:SoftItem, Class.new(ActiveRecord::Base) do
      self.table_name = TABLE
      default_scope { where(deleted_at: nil) }
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra

      # As paranoia's paranoia_destroy and restore do it.
      def soft_destroy = with_transaction_returning_status { run_callbacks(:destroy) { update_columns(deleted_at: Time.current); true } }
      def restore = update_columns(deleted_at: nil)
    end)
    Lyra.config.monitor_model(SoftItem)
    clean
  end

  def teardown
    return unless Object.const_defined?(:SoftItem)

    Lyra.reset_config!
    clean
    connection.drop_table(TABLE, if_exists: true)
  end

  def test_a_soft_delete_is_recorded_as_an_update_in_every_mode
    MODES.each do |mode, enable|
      use(enable)
      item = SoftItem.create!(name: "ann")
      item.soft_destroy

      assert_equal %i[created updated], operations(item.id), mode
      assert_empty SoftItem.all.to_a, "#{mode}: the default scope hides it"
      refute_nil SoftItem.unscoped.find(item.id).deleted_at, "#{mode}: it is there, deleted_at set"
      assert_nil Lyra::ModeTransition.discrepancy(SoftItem, item.id), "#{mode}: row and log agree" unless mode == :es_noproj # no rows to compare
    end
  end

  # Its stream is live, so an update and a restore are recorded as updates,
  # where 1.0.1 before this change refused them (RecordDestroyedError).
  def test_a_soft_deleted_record_can_be_updated_and_restored
    MODES.each do |mode, enable|
      use(enable)
      item = SoftItem.create!(name: "ann")
      item.soft_destroy
      stale = SoftItem.unscoped.find(item.id)
      stale.update!(name: "bea")
      stale.restore
      stale.touch

      assert_equal %i[created updated updated updated updated], operations(item.id), mode
      assert_equal ["bea"], SoftItem.pluck(:name), "#{mode}: restored"
      assert_nil Lyra::ModeTransition.discrepancy(SoftItem, item.id), mode unless mode == :es_noproj # no rows to compare
    end
  end

  # A real destroy of a soft-deleted record (paranoia's really_destroy!) is
  # still a destroy.
  def test_a_real_destroy_after_a_soft_delete_is_a_destroy
    MODES.each do |mode, enable|
      use(enable)
      item = SoftItem.create!(name: "ann")
      item.soft_destroy
      SoftItem.unscoped.find(item.id).destroy!

      assert_equal %i[created updated destroyed], operations(item.id), mode
      assert_nil SoftItem.unscoped.find_by(id: item.id), mode
    end
  end

  private

  def use(enable)
    clean
    enable.call
  end

  def operations(id)
    Lyra.config.event_store.read.stream(Lyra.stream_name(SoftItem, id)).to_a.filter_map { Lyra::Event.operation_of(_1) }
  end

  def clean
    connection.execute("DELETE FROM #{TABLE}") if connection.table_exists?(TABLE)
    connection.execute("DELETE FROM event_store_events_in_streams")
    connection.execute("DELETE FROM event_store_events")
    connection.execute("DELETE FROM #{Lyra::StreamHeads::TABLE}") if connection.table_exists?(Lyra::StreamHeads::TABLE)
    Lyra::Projections::LazyProjection.reset!
  end

  def connection = ActiveRecord::Base.connection
end
