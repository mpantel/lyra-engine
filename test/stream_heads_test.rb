# frozen_string_literal: true

require "test_helper"
require "timeout"

# The history clauses of Hypothesis H, enforced where events are appended
# (Lyra::StreamHeads, 1.0.1), in the six configurations that record events.
# Lyra 1.0.0 failed each of these: a create with a live record's key, given or
# generated, appended a second Created in every event-sourcing mode; a change
# of a record's key recorded its update on another record's stream, or on a
# stream with no create, in every mode; an upsert that met a live row recorded
# a second Created in every mode but ES-NoProj.
class StreamHeadsTest < Minitest::Test
  TABLE = "lyra_stream_head_items"
  MODES = %i[monitor hijack es_sync es_async es_lazy es_noproj].freeze
  WITH_TABLE = MODES - %i[es_noproj]

  def setup
    skip "Requires Rails and PostgreSQL" unless defined?(ActiveRecord::Base) && connection.adapter_name.match?(/postgres/i)

    connection.create_table(TABLE, force: true) do |t|
      t.integer :n, null: false, default: 0
      t.timestamps
    end
    define_model(:HeadItem, TABLE)
    clean
  end

  def teardown
    return unless defined?(HeadItem)

    Lyra.config.projection_mode = :sync
    Lyra.reset_config!
    clean
    connection.drop_table(TABLE, if_exists: true)
  end

  MODES.each do |mode|
    define_method(:"test_#{mode}_refuses_a_create_with_a_live_key") do
      use(mode)
      item = HeadItem.create!(n: 1)

      assert_raises(ActiveRecord::RecordNotUnique) { HeadItem.create!(id: item.id, n: 8) }
      assert_equal %i[created], operations(item.id)
      assert_equal 1, HeadItem.find(item.id).n
    end

    define_method(:"test_#{mode}_refuses_a_generated_key_that_meets_a_live_one") do
      use(mode)
      item = HeadItem.create!(n: 1)
      sequence_to(item.id)

      assert_raises(ActiveRecord::RecordNotUnique) { HeadItem.create!(n: 8) }
      assert_equal %i[created], operations(item.id)
    end

    define_method(:"test_#{mode}_creates_a_destroyed_key_again") do
      use(mode)
      item = HeadItem.create!(n: 1)
      HeadItem.find(item.id).destroy!

      HeadItem.create!(id: item.id, n: 2)
      assert_equal %i[created destroyed created], operations(item.id)
      assert_equal 2, HeadItem.find(item.id).n
    end

    define_method(:"test_#{mode}_lets_one_of_two_concurrent_creators_of_a_key_win") do
      use(mode)
      key = HeadItem.create!(n: 0).id + 100
      gate = Queue.new
      outcomes = Array.new(2) do
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            gate.pop
            HeadItem.create!(id: key, n: 1)
            :created
          rescue ActiveRecord::RecordNotUnique
            :refused
          end
        end
      end
      2.times { gate << true }
      results = outcomes.map { |thread| Timeout.timeout(20) { thread.value } }

      assert_equal %i[created refused], results.sort
      assert_equal %i[created], operations(key)
    end

    define_method(:"test_#{mode}_does_not_obey_a_head_whose_events_were_deleted") do
      use(mode)
      item = HeadItem.create!(n: 1)
      connection.execute("DELETE FROM event_store_events_in_streams")
      connection.execute("DELETE FROM event_store_events")
      connection.execute("DELETE FROM #{TABLE}")

      HeadItem.create!(id: item.id, n: 5)
      assert_equal %i[created], operations(item.id)
    end
  end

  (MODES - %i[monitor]).each do |mode|
    define_method(:"test_#{mode}_refuses_a_key_change_to_a_live_key") do
      use(mode)
      a = HeadItem.create!(n: 1)
      b = HeadItem.create!(n: 2)

      assert_raises(Lyra::StreamHeads::KeyChangeError) { HeadItem.find(a.id).update!(id: b.id, n: 99) }
      assert_equal 2, HeadItem.find(b.id).n
      assert_equal %i[created], operations(b.id)
    end

    define_method(:"test_#{mode}_refuses_a_key_change_to_a_free_key") do
      use(mode)
      a = HeadItem.create!(n: 1)

      assert_raises(Lyra::StreamHeads::KeyChangeError) { HeadItem.find(a.id).update!(id: a.id + 1000) }
      assert_empty operations(a.id + 1000)
      assert_equal %i[created], operations(a.id)
    end
  end

  def test_monitor_records_a_key_change_as_the_destroy_and_the_create
    use(:monitor)
    a = HeadItem.create!(n: 1)

    HeadItem.find(a.id).update!(id: a.id + 1000, n: 3)
    assert_equal %i[created destroyed], operations(a.id)
    assert_equal %i[created], operations(a.id + 1000)
    assert_empty Lyra::DualView.new(HeadItem, a.id + 1000).compare[:differences]
  end

  def test_monitor_refuses_nothing_the_table_took
    use(:monitor)
    a = HeadItem.create!(n: 1)
    connection.execute("DELETE FROM #{TABLE}")
    mismatches = []
    subscriber = ActiveSupport::Notifications.subscribe("lyra.stream_head_mismatch") { |*, payload| mismatches << payload }

    HeadItem.create!(id: a.id, n: 2)
    assert_equal %i[created created], operations(a.id), "the table took it, so Monitor records it"
    assert_equal 1, mismatches.size
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  WITH_TABLE.each do |mode|
    define_method(:"test_#{mode}_records_an_upsert_that_met_a_live_record_as_its_update") do
      use(mode)
      item = HeadItem.create!(n: 1)
      sequence_to(item.id)

      HeadItem.upsert_all([{ n: 9 }])
      assert_equal %i[created updated], operations(item.id)
    end
  end

  def test_switched_off_it_behaves_as_1_0_0
    use(:es_sync)
    Lyra.config.stream_heads = false
    item = HeadItem.create!(n: 1)

    HeadItem.create!(id: item.id, n: 8)
    assert_equal %i[created created], operations(item.id)
  end

  private

  def define_model(name, table)
    Object.send(:remove_const, name) if Object.const_defined?(name)
    klass = Class.new(ActiveRecord::Base)
    Object.const_set(name, klass)
    klass.table_name = table
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
      Lyra.config.projection_mode = { es_sync: :sync, es_async: :async, es_lazy: :lazy, es_noproj: :disabled }.fetch(mode)
    end
  end

  def sequence_to(id)
    connection.execute("SELECT setval(pg_get_serial_sequence('#{TABLE}', 'id'), #{id}, false)")
  end

  def operations(id)
    Lyra.config.event_store.read.stream(Lyra.stream_name(HeadItem, id)).to_a.map { |e| Lyra::Event.operation_of(e) }
  end

  def clean
    connection.execute("DELETE FROM event_store_events_in_streams")
    connection.execute("DELETE FROM event_store_events")
    connection.execute("DELETE FROM #{Lyra::StreamHeads::TABLE}") if connection.table_exists?(Lyra::StreamHeads::TABLE)
    Lyra::Projections::LazyProjection.reset! if defined?(Lyra::Projections::LazyProjection)
  end

  def connection = ActiveRecord::Base.connection
end
