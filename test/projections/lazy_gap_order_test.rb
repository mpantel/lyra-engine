# frozen_string_literal: true

require "test_helper"

# ES-Lazy under foreign keys: a gap's event is applied in its place in the
# log's order, before the events that came after it.
#
# A catch-up applied the events above the checkpoint and filled the gaps
# after them. A child above the checkpoint whose parent was a gap failed on
# its foreign key, the catch-up rolled back, and every later read failed the
# same way: the store never recovered. Filling a gap replayed its record's
# whole stream, which failed in the same way through a parent destroyed
# since, or created by an event not applied yet.
class LazyGapOrderTest < Minitest::Test
  LazyProjection = Lyra::Projections::LazyProjection
  TIMEOUT = 20

  def setup
    skip "Requires PostgreSQL" unless defined?(ActiveRecord::Base) && ActiveRecord::Base.connection.adapter_name.match?(/postgres/i)

    @connection = ActiveRecord::Base.connection
    create_tables
    { OrderParent: "gap_order_parents", OrderChild: "gap_order_children" }.each do |name, table|
      Object.send(:remove_const, name) if Object.const_defined?(name)
      Object.const_set(name, Class.new(ActiveRecord::Base) do
        self.table_name = table
        include Lyra::Interceptors::CrudInterceptor
        monitor_with_lyra
      end)
      Object.const_get(name).reset_column_information
    end
    clear_log
    Lyra.config.enable_event_sourcing!
    Lyra.config.projection_mode = :lazy
    [OrderParent, OrderChild].each { Lyra.config.monitor_model(_1) }
    @base = OrderParent.create!(n: 0)
    OrderParent.count
    # Less the ids of earlier tests' events, which a fresh checkpoint watches.
    @connection.execute("UPDATE #{LazyProjection::TABLE} SET gaps = '{}'")
  end

  def teardown
    return unless @connection

    Lyra.config.projection_mode = :sync
    @connection.execute("DROP TABLE IF EXISTS gap_order_children, gap_order_parents")
    clear_log
  end

  def test_a_child_above_the_checkpoint_of_a_parent_in_a_gap
    parent = child = nil
    ActiveRecord::Base.transaction do
      parent = OrderParent.create!(n: 1)
      pass_the_open_ids!
      child = OrderChild.create!(parent_id: parent.id)
    end

    3.times { assert_equal parent.id, OrderChild.find(child.id).parent_id }
    assert_empty gaps
  end

  def test_a_child_written_after_its_parents_transaction_committed
    parent = nil
    ActiveRecord::Base.transaction do
      parent = OrderParent.create!(n: 1)
      pass_the_open_ids!
    end
    child = OrderChild.create!(parent_id: parent.id)

    assert_equal parent.id, OrderChild.find(child.id).parent_id
  end

  def test_a_store_already_stuck_recovers
    parent = child = nil
    ActiveRecord::Base.transaction do
      parent = OrderParent.create!(n: 1)
      pass_the_open_ids!
      child = OrderChild.create!(parent_id: parent.id)
    end
    # As a stuck store was left: no catch-up could commit, so the gap is
    # still listed, older than GAP_TTL by now, and the writes went on.
    aged = gaps.transform_values { Time.now.to_i - LazyProjection::GAP_TTL - 60 }
    @connection.execute("UPDATE #{LazyProjection::TABLE} SET gaps = '#{JSON.generate(aged)}'")
    LazyProjection.instance_variable_set(:@gaps_checked_at, nil)
    later = LazyProjection.without_catch_up { OrderChild.create!(parent_id: parent.id) }

    assert_equal [child.id, later.id].sort, OrderChild.order(:id).pluck(:id).sort
    assert_empty gaps
    assert_operator LazyProjection.checkpoint.first, :>=, @connection.select_value("SELECT MAX(id) FROM event_store_events").to_i
  end

  def test_three_levels_behind_a_gap
    top = middle = child = nil
    ActiveRecord::Base.transaction do
      top = OrderParent.create!(n: 1)
      pass_the_open_ids!
      middle = OrderParent.create!(parent_id: top.id)
      child = OrderChild.create!(parent_id: middle.id)
    end

    assert_equal middle.id, OrderChild.find(child.id).parent_id
    assert_equal top.id, OrderParent.find(middle.id).parent_id
  end

  def test_a_parent_in_a_gap_updated_later_to_a_record_created_after_it
    parent = child = target = nil
    ActiveRecord::Base.transaction do
      parent = OrderParent.create!(n: 1)
      pass_the_open_ids!
      child = OrderChild.create!(parent_id: parent.id)
      target = OrderParent.create!(n: 2)
      parent.update!(parent_id: target.id)
    end

    assert_equal target.id, OrderParent.find(parent.id).parent_id
    assert_equal parent.id, OrderChild.find(child.id).parent_id
  end

  def test_gaps_that_refer_to_each_other_are_filled_in_the_logs_order
    parent = target = nil
    ActiveRecord::Base.transaction do
      parent = OrderParent.create!(n: 1)
      target = OrderParent.create!(n: 2)
      parent.update!(parent_id: target.id)
      pass_the_open_ids!
    end

    assert_equal target.id, OrderParent.find(parent.id).parent_id
  end

  def test_a_parent_destroyed_after_its_childs_destroy_in_a_gap
    parent = OrderParent.create!(n: 1)
    child = OrderChild.create!(parent_id: parent.id)
    OrderParent.count
    ActiveRecord::Base.transaction do
      child.destroy!
      pass_the_open_ids!
      parent.destroy!
    end

    assert_nil OrderParent.find_by(id: parent.id)
    assert_nil OrderChild.find_by(id: child.id)
  end

  def test_a_child_destroyed_with_its_parent_both_in_gaps
    parent = OrderParent.create!(n: 1)
    child = OrderChild.create!(parent_id: parent.id)
    OrderParent.count
    ActiveRecord::Base.transaction do
      child.destroy!
      parent.destroy!
      pass_the_open_ids!
    end

    assert_nil OrderParent.find_by(id: parent.id)
    assert_nil OrderChild.find_by(id: child.id)
  end

  def test_a_gap_whose_record_once_had_a_parent_destroyed_since
    old = OrderParent.create!(n: 1)
    child = OrderChild.create!(n: 0)
    child.update!(parent_id: old.id)
    child.update!(parent_id: @base.id)
    old.destroy!
    OrderParent.count
    ActiveRecord::Base.transaction do
      child.update!(n: 7)
      pass_the_open_ids!
    end

    assert_equal [@base.id, 7], OrderChild.where(id: child.id).pick(:parent_id, :n)
  end

  def test_every_event_of_a_record_in_gaps
    child = nil
    ActiveRecord::Base.transaction do
      child = OrderChild.create!(parent_id: @base.id)
      child.update!(n: 1)
      child.update!(n: 2)
      pass_the_open_ids!
    end
    assert_equal 2, OrderChild.find(child.id).n

    ActiveRecord::Base.transaction do
      child.update!(n: 3)
      child.destroy!
      pass_the_open_ids!
    end
    assert_nil OrderChild.find_by(id: child.id)
  end

  def test_a_gap_found_and_committed_between_a_catch_ups_batches
    inserted = Queue.new
    go = Queue.new
    writer = in_thread do
      ActiveRecord::Base.transaction do
        id = OrderParent.create!(n: 1).id
        inserted << id
        take(go)
      end
    end
    parent_id = take(inserted)
    OrderParent.create!(n: 9) # the first batch: it passes the parent's id
    child = nil
    between = lambda do
      go << true
      value_of(writer)
      child = value_of(in_thread { LazyProjection.without_catch_up { OrderChild.create!(parent_id: parent_id) } })
    end

    with_batch(1) { after_first(/WHERE id > /, between) { OrderParent.count } }

    assert_equal parent_id, OrderChild.find(child.id).parent_id
  end

  def test_a_late_event_does_not_undo_a_later_one_already_applied
    # Without the aggregate lock an update can be applied while an earlier
    # one of the same record is still uncommitted. The stream heads (1.0.1)
    # order two writers of one record at the append by themselves, so they are
    # off too.
    Lyra.config.lock_aggregate_before_append = false
    Lyra.config.stream_heads = false
    id = @base.id
    copy = OrderParent.find(id)
    ActiveRecord::Base.transaction do
      copy.update!(n: 1)
      value_of(in_thread { LazyProjection.without_catch_up { OrderParent.find(id).update!(n: 2) } })
      value_of(in_thread { OrderParent.count })
      LazyProjection.instance_variable_set(:@gaps_checked_at, nil)
    end

    stream = Lyra.config.event_store.read.stream(Lyra.stream_name(OrderParent, id)).to_a
    assert_equal 3, stream.size
    OrderParent.count
    assert_equal 2, @connection.select_value("SELECT n FROM gap_order_parents WHERE id = #{Integer(id)}")
  end

  def test_a_catch_up_with_no_gaps_asks_nothing_about_gaps
    OrderParent.create!(n: 1)
    seen = []
    thread = Thread.current
    subscription = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      seen << payload[:sql].to_s if Thread.current == thread
    end
    OrderParent.count

    assert_empty seen.grep(/FROM event_store_events WHERE (id IN|event_id IN)/)
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription) if subscription
  end

  private

  def create_tables
    @connection.execute("DROP TABLE IF EXISTS gap_order_children, gap_order_parents")
    @connection.execute(<<~SQL)
      CREATE TABLE gap_order_parents (id bigserial PRIMARY KEY, n int,
        parent_id bigint REFERENCES gap_order_parents(id), created_at timestamp, updated_at timestamp)
    SQL
    @connection.execute(<<~SQL)
      CREATE TABLE gap_order_children (id bigserial PRIMARY KEY, n int,
        parent_id bigint REFERENCES gap_order_parents(id), created_at timestamp, updated_at timestamp)
    SQL
  end

  def clear_log
    %w[event_store_events_in_streams event_store_events].each { @connection.execute("DELETE FROM #{_1}") }
    LazyProjection.reset!
  end

  def gaps = LazyProjection.checkpoint.last

  # Another event commits and is applied in another connection: the ids this
  # thread's transaction took are gaps below the checkpoint.
  def pass_the_open_ids!
    value_of(in_thread do
      LazyProjection.without_catch_up { OrderParent.create!(n: 9) }
      OrderParent.count
    end)
  end

  def in_thread(&block)
    Thread.new { ActiveRecord::Base.connection_pool.with_connection { block.call } }.tap { |t| t.report_on_exception = false }
  end

  def take(queue) = queue.pop(timeout: TIMEOUT) || flunk("nothing within #{TIMEOUT} s")

  def value_of(thread)
    flunk "a thread did not end within #{TIMEOUT} s" unless thread.join(TIMEOUT)
    thread.value
  end

  def with_batch(size)
    batch = LazyProjection::BATCH
    LazyProjection.send(:remove_const, :BATCH)
    LazyProjection.const_set(:BATCH, size)
    yield
  ensure
    LazyProjection.send(:remove_const, :BATCH)
    LazyProjection.const_set(:BATCH, batch)
  end

  # +run+ once, after this thread's first statement that matches +pattern+.
  def after_first(pattern, run)
    thread = Thread.current
    ran = false
    subscription = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      next if ran || Thread.current != thread || !payload[:sql].to_s.match?(pattern)

      ran = true
      run.call
    end
    yield
    flunk "no statement matched #{pattern.inspect}" unless ran
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription)
  end
end
