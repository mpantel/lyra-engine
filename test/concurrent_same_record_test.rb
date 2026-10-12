# frozen_string_literal: true

require "test_helper"

# Two writers of the same attribute of one record, interleaved so that the
# first has appended its event and not yet written its row when the second
# runs from start to commit.
#
# Theorem 5 (Chapter 3 of the thesis) is conditional on a lock on the aggregate
# held from before the append to the end of the transaction (assumption L).
# Monitor has it through the row write's own lock. Hijack and ES-Sync take one
# before the append (config.lock_aggregate_before_append, default on): the
# second writer waits for the first, and row and log agree. With the lock off
# they append before the row write and take nothing first, so the row can end
# at the first writer's value while the log replays to the second's.
class ConcurrentSameRecordTest < Minitest::Test
  TABLE = "lyra_race_items"

  # Pauses the writer of the current thread once, at the point it names, and
  # lets the test release it. Inert unless a thread has set Thread.current[:race_gate].
  module Pause
    def self.at(point)
      gate = Thread.current[:race_gate]
      return unless gate && gate[:point] == point

      Thread.current[:race_gate] = nil
      gate[:reached] << true
      gate[:resume].pop
    end

    module Handler
      def handle(command)
        result = super
        Pause.at(:after_command)
        result
      end
    end

    module Projection
      def project(*args)
        Pause.at(:before_projection)
        super
      end
    end

    module Append
      def append_events(*args, **kwargs)
        result = super
        Pause.at(:after_append)
        result
      end
    end
  end

  Lyra::CommandHandler.singleton_class.prepend(Pause::Handler)
  Lyra::Projections::ModelProjection.singleton_class.prepend(Pause::Projection)
  Lyra.singleton_class.prepend(Pause::Append)

  def setup
    skip "Requires Rails and PostgreSQL" unless defined?(ActiveRecord::Base) && connection.adapter_name.match?(/postgres/i)

    connection.create_table(TABLE, force: true) do |t|
      t.string :label
      t.timestamps
    end
    Object.send(:remove_const, :RaceItem) if defined?(RaceItem)
    Object.const_set(:RaceItem, Class.new(ActiveRecord::Base) do
      self.table_name = TABLE
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
    end)
    RaceItem.reset_column_information
    clean_events
    Lyra.config.monitor_model(RaceItem)
  end

  def teardown
    return unless defined?(RaceItem)

    Lyra.reset_config!
    clean_events
    connection.drop_table(TABLE, if_exists: true)
  end

  # Hijack, lock on (default): the first writer holds the aggregate's lock
  # from before its append, so the second waits and the orders agree.
  def test_hijack_orders_the_row_and_the_log_the_same_way
    Lyra.config.enable_hijack!
    id = RaceItem.create!(label: "initial").id

    interleave_blocked(id, pause_at: :after_command)

    assert_equal "from-t2", row_label(id)
    assert_equal row_label(id), replayed_label(id), "row and log agree on the last writer"
  end

  # Hijack, lock off: the first writer's append is stored; its row write waits.
  def test_hijack_without_the_lock_can_leave_the_row_and_the_log_in_different_orders
    Lyra.config.enable_hijack!
    Lyra.config.lock_aggregate_before_append = false
    id = RaceItem.create!(label: "initial").id

    interleave(id, pause_at: :after_command)

    assert_equal "from-t2", replayed_label(id), "the log replays the writers in the order they appended"
    assert_equal "from-t1", row_label(id), "the row was written last by the first writer"
  end

  # ES-Sync, lock on (default).
  def test_es_sync_orders_the_row_and_the_log_the_same_way
    Lyra.config.enable_event_sourcing!
    Lyra.config.projection_mode = :sync
    id = RaceItem.create!(label: "initial").id

    interleave_blocked(id, pause_at: :before_projection)

    assert_equal "from-t2", row_label(id)
    assert_equal row_label(id), replayed_label(id)
  end

  # ES-Sync, lock off: the first writer's event is stored; its projection waits.
  def test_es_sync_without_the_lock_can_leave_the_row_and_the_log_in_different_orders
    Lyra.config.enable_event_sourcing!
    Lyra.config.projection_mode = :sync
    Lyra.config.lock_aggregate_before_append = false
    id = RaceItem.create!(label: "initial").id

    interleave(id, pause_at: :before_projection)

    assert_equal "from-t2", replayed_label(id)
    assert_equal "from-t1", row_label(id)
  end

  # A destroy takes the lock too: the second writer waits behind an update.
  def test_hijack_destroy_waits_for_an_update_in_flight
    Lyra.config.enable_hijack!
    id = RaceItem.create!(label: "initial").id

    gate = { point: :after_command, reached: Queue.new, resume: Queue.new }
    first = Thread.new do
      Thread.current[:race_gate] = gate
      with_connection { RaceItem.find(id).update!(label: "from-t1") }
    end
    gate[:reached].pop

    second = Thread.new { with_connection { RaceItem.find(id).destroy! } }
    refute second.join(0.5), "the destroy ran past the update's lock"

    gate[:resume] << true
    first.value
    second.value

    assert_nil row_label(id)
    assert_equal %w[Created Updated Destroyed],
                 Lyra.config.event_store.read.stream("RaceItem$#{id}").map { |e| e.event_type[/[A-Z][a-z]+\z/] }
  end

  # ES-Async: the writers only append, under the lock on the aggregate, so a
  # second writer waits for the first and the record's events commit in the
  # order they were appended; the projection job applies them in order under a
  # lock held per stream, so the row follows the log whichever order the jobs
  # run in (here: newest first).
  def test_es_async_leaves_the_row_following_the_log
    previous = ActiveJob::Base.queue_adapter
    adapter = ActiveJob::QueueAdapters::TestAdapter.new
    ActiveJob::Base.queue_adapter = adapter
    Lyra.config.enable_event_sourcing!
    Lyra.config.projection_mode = :async
    Lyra.config.async_projections_inline = false
    id = RaceItem.create!(label: "initial").id
    run_enqueued(adapter)

    interleave_blocked(id, pause_at: :after_append)
    run_enqueued(adapter, newest_first: true)

    assert_equal "from-t2", replayed_label(id)
    assert_equal "from-t2", row_label(id), "the row follows the log"
  ensure
    ActiveJob::Base.queue_adapter = previous if previous
  end

  # ES-Async without the lock: the second writer does not wait, and the job,
  # with no ordering to rely on, replays the whole stream; the row still
  # follows the log.
  def test_es_async_without_the_lock_still_converges_by_replaying_the_stream
    previous = ActiveJob::Base.queue_adapter
    adapter = ActiveJob::QueueAdapters::TestAdapter.new
    ActiveJob::Base.queue_adapter = adapter
    Lyra.config.enable_event_sourcing!
    Lyra.config.projection_mode = :async
    Lyra.config.async_projections_inline = false
    Lyra.config.lock_aggregate_before_append = false
    id = RaceItem.create!(label: "initial").id
    run_enqueued(adapter)

    interleave(id, pause_at: :after_append)
    run_enqueued(adapter, newest_first: true)

    assert_equal "from-t2", replayed_label(id)
    assert_equal "from-t2", row_label(id), "the row follows the log"
  ensure
    ActiveJob::Base.queue_adapter = previous if previous
  end

  # ES-Async projected inline (async_projections_inline: the test
  # environment's default, and the benchmarks' choice so that a round's row is
  # complete when its last write returns) must converge as the job does. It
  # applied only its own event, inside the writer's transaction and under no
  # lock, so a writer paused before its projection rolled the row back to its
  # value after a later writer had committed.
  def test_es_async_inline_leaves_the_row_following_the_log
    Lyra.config.enable_event_sourcing!
    Lyra.config.projection_mode = :async
    Lyra.config.async_projections_inline = true
    id = RaceItem.create!(label: "initial").id

    interleave_blocked(id, pause_at: :after_append)

    assert_equal "from-t2", replayed_label(id)
    assert_equal "from-t2", row_label(id), "the row follows the log"
  end

  # Monitor: the first writer's row write holds the row lock until its
  # transaction ends, so the second writer waits and the orders agree.
  def test_monitor_orders_the_row_and_the_log_the_same_way
    Lyra.config.enable_monitor!
    id = RaceItem.create!(label: "initial").id

    interleave_blocked(id, pause_at: :after_append)

    assert_equal "from-t2", row_label(id)
    assert_equal row_label(id), replayed_label(id), "row and log agree on the last writer"
  end

  private

  # The first writer runs to +pause_at+ and waits, holding whatever it holds;
  # the second must not get past it; the first is released and both finish.
  def interleave_blocked(id, pause_at:)
    gate = { point: pause_at, reached: Queue.new, resume: Queue.new }
    first = Thread.new do
      Thread.current[:race_gate] = gate
      with_connection { RaceItem.find(id).update!(label: "from-t1") }
    end
    gate[:reached].pop

    second = Thread.new { with_connection { RaceItem.find(id).update!(label: "from-t2") } }
    refute second.join(0.5), "the second writer ran past the first writer's lock"

    gate[:resume] << true
    first.value
    second.value
  end

  # The first writer runs to +pause_at+ and waits; the second runs to commit;
  # the first then finishes.
  def interleave(id, pause_at:)
    gate = { point: pause_at, reached: Queue.new, resume: Queue.new }
    first = Thread.new do
      Thread.current[:race_gate] = gate
      with_connection { RaceItem.find(id).update!(label: "from-t1") }
    end
    gate[:reached].pop

    second = Thread.new { with_connection { RaceItem.find(id).update!(label: "from-t2") } }
    assert second.join(5), "the second writer did not finish while the first waited"

    gate[:resume] << true
    first.value
    second.value
  end

  # Run the projection jobs the test adapter holds, oldest or newest first.
  def run_enqueued(adapter, newest_first: false)
    jobs = adapter.enqueued_jobs.dup
    adapter.enqueued_jobs.clear
    jobs.reverse! if newest_first
    jobs.each { |job| job[:job].perform_now(*job[:args]) }
  end

  def with_connection(&block) = ActiveRecord::Base.connection_pool.with_connection(&block)

  def connection = ActiveRecord::Base.connection

  # Straight to the table: in ES modes the model's own reads would answer from
  # the event store.
  def row_label(id)
    connection.select_value("SELECT label FROM #{TABLE} WHERE id = #{Integer(id)}")
  end

  # The label after replaying the record's stream in order.
  def replayed_label(id)
    label = nil
    Lyra.config.event_store.read.stream("RaceItem$#{id}").each do |event|
      data = event.data
      attrs = data[:changes] || data["changes"] || data[:attributes] || data["attributes"] || {}
      attrs = attrs.with_indifferent_access
      next unless attrs.key?(:label)

      value = attrs[:label]
      label = value.is_a?(Array) ? value.last : value
    end
    label
  end

  def clean_events
    connection.execute("DELETE FROM event_store_events_in_streams")
    connection.execute("DELETE FROM event_store_events")
  end
end
