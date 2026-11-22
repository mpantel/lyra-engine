# frozen_string_literal: true

require "test_helper"

# A model whose table declares a primary key of several columns, enrolled
# before Active Record read it (Lyra::ModelSelection refuses one it knows):
# insert_all, insert_all! and upsert_all with returning: asked for the key
# as one quoted name and raised PG::UndefinedColumn; without returning: the
# key was not found in the result and the rows were written with no event.
# Each key column is now returned (and taken out of the caller's result
# again), the caller gets Active Record's own result, and each row its event,
# in Monitor and Hijack, which replay nothing. The event-sourcing modes
# refuse the writes before any SQL.
class CompositeKeyInsertTest < Minitest::Test
  TABLE = "lyra_cpk_items"

  def setup
    skip "Requires Rails and PostgreSQL" unless defined?(ActiveRecord::Base) && connection.adapter_name.match?(/postgres/i)

    connection.create_table(TABLE, primary_key: %i[shop_id number], force: true) do |t|
      t.bigint :shop_id
      t.bigint :number
      t.string :name
      t.timestamps
    end
    %i[CpkItem CpkPlainItem].each { Object.send(:remove_const, _1) if Object.const_defined?(_1) }
    Object.const_set(:CpkPlainItem, Class.new(ActiveRecord::Base) { self.table_name = TABLE })
    Object.const_set(:CpkItem, Class.new(ActiveRecord::Base) do
      self.table_name = TABLE
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra # before the key is read: not refused
    end)
    clean
  end

  def teardown
    return unless Object.const_defined?(:CpkItem)

    Lyra.reset_config!
    clean
    connection.drop_table(TABLE, if_exists: true)
  end

  def test_inserts_return_active_record_s_result_and_record_each_row
    assert_equal %w[shop_id number], CpkItem.primary_key
    now = Time.utc(2026, 1, 2, 3, 4, 5)
    forms = { default: nil, none: false, symbol: :name, array: %i[number name], sql: Arel.sql("upper(name) AS shout"),
              star: Arel.sql("*") }
    number = 0
    %i[monitor hijack].each do |mode|
      clean
      mode == :monitor ? Lyra.config.enable_monitor! : Lyra.config.enable_hijack!
      forms.each do |form, returning|
        %i[insert_all insert_all! upsert_all].each do |write|
          number += 1
          row = { shop_id: 7, number: number, name: "n#{number}", created_at: now, updated_at: now }
          plain = CpkPlainItem.public_send(write, [row], returning: returning)
          CpkPlainItem.where(shop_id: 7, number: number).delete_all
          lyra = CpkItem.public_send(write, [row], returning: returning)

          assert_equal shape(plain), shape(lyra), "#{mode} #{write} #{form}"
          events = Lyra.config.event_store.read.stream(Lyra.stream_name(CpkItem, [7, number])).to_a
          assert_equal [:created], events.map { Lyra::Event.operation_of(_1) }, "#{mode} #{write} #{form}"
          assert_equal write.to_s, events.first.metadata[:bypass_source]
        end
      end

      CpkItem.upsert_all([{ shop_id: 7, number: number, name: "again", created_at: now, updated_at: now }])
      events = Lyra.config.event_store.read.stream(Lyra.stream_name(CpkItem, [7, number])).to_a
      assert_equal %i[created updated], events.map { Lyra::Event.operation_of(_1) }, mode
      changes = events.last.data[:changes] || events.last.data["changes"]
      assert_equal [["n#{number}", "again"]], changes.values_at("name")
    end
  end

  # In the event-sourcing modes the writes are refused before any SQL:
  # their events would name the record by an array no projection,
  # catch-up or rebuild can apply (ES-Lazy's catch-up then failed on
  # every read of every monitored model).
  def test_the_event_sourcing_modes_refuse_them_before_writing
    now = Time.utc(2026, 1, 2, 3, 4, 5)
    %i[sync async lazy disabled].each do |projection|
      clean
      Lyra.config.enable_event_sourcing!
      Lyra.config.projection_mode = projection
      %i[insert_all insert_all! upsert_all].each do |write|
        next if write == :upsert_all && projection == :disabled # refused there for any model

        statements = []
        subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, p| statements << p[:sql] if p[:sql].include?(TABLE) && p[:name] != "SCHEMA" }
        error = assert_raises(ArgumentError, "#{projection} #{write}") do
          CpkItem.public_send(write, [{ shop_id: 1, number: 1, name: "a", created_at: now, updated_at: now }])
        end
        ActiveSupport::Notifications.unsubscribe(subscriber)
        assert_includes error.message, "composite primary key (shop_id, number)"
        assert_empty statements, "#{projection} #{write}: nothing sent"
      end
      assert_equal 0, connection.select_value("SELECT count(*) FROM event_store_events").to_i, projection
    end
  end

  private

  def shape(result)
    { columns: result.columns, rows: result.rows, column_types: result.column_types,
      cast_values: result.cast_values, affected_rows: result.affected_rows }
  end

  def clean
    connection.execute("DELETE FROM #{TABLE}") if connection.table_exists?(TABLE)
    connection.execute("DELETE FROM event_store_events_in_streams")
    connection.execute("DELETE FROM event_store_events")
  end

  def connection = ActiveRecord::Base.connection
end
