# frozen_string_literal: true

require "test_helper"

# The lock on the aggregate (assumption L of Theorem 5) must not add a
# deadlock that plain ActiveRecord would not have. Each case runs the same
# interleaving with Lyra disabled (plain ActiveRecord, the reference) and in
# Hijack and ES-Sync with the lock on, and compares the outcomes: both finish,
# or both deadlock (PostgreSQL detects it and aborts one transaction).
class AggregateLockDeadlockTest < Minitest::Test
  TABLE = "lyra_deadlock_items"
  MODES = %i[disabled hijack es_sync].freeze

  def setup
    skip "Requires Rails and PostgreSQL" unless defined?(ActiveRecord::Base) && connection.adapter_name.match?(/postgres/i)

    connection.create_table(TABLE, force: true) do |t|
      t.string :label
      t.timestamps
    end
    Object.send(:remove_const, :DeadlockItem) if defined?(DeadlockItem)
    Object.const_set(:DeadlockItem, Class.new(ActiveRecord::Base) do
      self.table_name = TABLE
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
    end)
    DeadlockItem.reset_column_information
    clean_events
    Lyra.config.monitor_model(DeadlockItem)
  end

  def teardown
    return unless defined?(DeadlockItem)

    Lyra.reset_config!
    clean_events
    connection.drop_table(TABLE, if_exists: true)
  end

  # Two transactions write the same two records in the same order: the second
  # waits for the first, nobody deadlocks, row and log agree on each record.
  def test_writes_to_several_records_in_one_order_never_deadlock
    MODES.each do |mode|
      use(mode)
      a, b = 2.times.map { |i| DeadlockItem.create!(label: "initial-#{i}").id }

      outcome = run_pair(
        ->(step) { write(a, "t1", step) { write(b, "t1") } },
        ->(_step) { write(a, "t2") { write(b, "t2") } }
      )

      assert_equal [:ok, :ok], outcome, "#{mode}: same-order writers"
      [a, b].each { |id| assert_row_follows_log(id, mode) unless mode == :disabled }
    end
  end

  # Opposite orders deadlock under plain ActiveRecord already. With the lock
  # they must deadlock the same way (detected, one transaction aborted, the
  # other finishes), not hang, and the aborted one must leave no event.
  def test_writes_in_opposite_orders_deadlock_as_plain_active_record_does
    reference = nil
    MODES.each do |mode|
      use(mode)
      a, b = 2.times.map { |i| DeadlockItem.create!(label: "initial-#{i}").id }

      outcome = run_pair(
        ->(step) { write(a, "t1", step) { write(b, "t1") } },
        ->(step) { write(b, "t2", step) { write(a, "t2") } },
        both_pause: true
      )

      reference ||= outcome
      assert_equal reference.sort, outcome.sort, "#{mode} must end as plain ActiveRecord does"
      assert_includes outcome, :deadlock, "#{mode}: opposite orders"
      [a, b].each { |id| assert_row_follows_log(id, mode) unless mode == :disabled }
    end
  end

  # One writer holds the row lock first (record.lock!, with_lock), the other
  # updates the record plainly. Plain ActiveRecord: the plain update waits for
  # the row and both finish. The lock on the aggregate must not turn that into
  # a deadlock (taking it before the row lock, as an advisory lock does, does).
  def test_a_writer_holding_the_row_lock_does_not_deadlock_a_plain_writer
    MODES.each do |mode|
      use(mode)
      id = DeadlockItem.create!(label: "initial").id

      outcome = run_pair(
        lambda do |step|
          ActiveRecord::Base.transaction do
            record = DeadlockItem.find(id)
            record.lock!
            step.call
            record.update!(label: "with-lock")
          end
        end,
        ->(_step) { DeadlockItem.find(id).update!(label: "plain") }
      )

      assert_equal [:ok, :ok], outcome, "#{mode}: a row lock held first, then a plain update"
      assert_row_follows_log(id, mode) unless mode == :disabled
    end
  end

  private

  # Runs +first+ until it calls its step (and holds what it took), then
  # +second+ (until its own step, if both_pause), then releases them. Returns
  # [:ok or :deadlock] per writer. Neither may hang: a writer still running
  # after 20 s fails the test.
  def run_pair(first, second, both_pause: false)
    first_reached = Queue.new
    first_go = Queue.new
    second_reached = Queue.new
    second_go = Queue.new
    step_one = -> { first_reached << true; first_go.pop }
    step_two = -> { second_reached << true; second_go.pop }

    t1 = Thread.new { outcome_of { first.call(step_one) } }
    first_reached.pop
    t2 = Thread.new { outcome_of { second.call(step_two) } }
    if both_pause
      second_reached.pop
      first_go << true
      second_go << true
    else
      # Let the second writer reach whatever it waits on, then release the first.
      sleep 0.3
      first_go << true
    end

    [t1, t2].map do |thread|
      assert thread.join(20), "a writer hung: neither finished nor was aborted as a deadlock"
      thread.value
    end
  end

  def outcome_of
    ActiveRecord::Base.connection_pool.with_connection { yield }
    :ok
  rescue ActiveRecord::Deadlocked
    :deadlock
  end

  # An update of +id+ in a transaction; +step+ (if any) is called after it,
  # then the block (further writes in the same transaction).
  def write(id, label, step = nil)
    ActiveRecord::Base.transaction do
      DeadlockItem.find(id).update!(label: "#{label}-#{id}")
      step&.call
      yield if block_given?
    end
  end

  def use(mode)
    LyraConfigIsolation.install_fresh_config
    Lyra.config.monitor_model(DeadlockItem)
    case mode
    when :disabled then Lyra.config.disable!
    when :hijack then Lyra.config.enable_hijack!
    when :es_sync
      Lyra.config.enable_event_sourcing!
      Lyra.config.projection_mode = :sync
    end
  end

  def assert_row_follows_log(id, mode)
    assert_equal row_label(id), replayed_label(id), "#{mode}: row and log disagree on record #{id}"
  end

  def connection = ActiveRecord::Base.connection

  def row_label(id)
    connection.select_value("SELECT label FROM #{TABLE} WHERE id = #{Integer(id)}")
  end

  def replayed_label(id)
    label = nil
    Lyra.config.event_store.read.stream("DeadlockItem$#{id}").each do |event|
      data = event.data
      attrs = (data[:changes] || data["changes"] || data[:attributes] || data["attributes"] || {}).with_indifferent_access
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
