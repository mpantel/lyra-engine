# frozen_string_literal: true

require "test_helper"

# Which writes take the lock on the aggregate (assumption L of Theorem 5,
# config.lock_aggregate_before_append), read from the SQL a write issues:
# updates and destroys in Hijack and ES-Sync, and nothing else. A refactor of
# the write hooks that drops the call, or widens it to creates or to Monitor,
# which would add a statement to every write, fails here.
class AggregateLockStatementsTest < Minitest::Test
  TABLE = "lyra_lock_items"
  ROW_LOCK = /\ASELECT 1 FROM "lyra_lock_items" WHERE "id" = \d+ FOR (NO KEY )?UPDATE\z/
  ADVISORY = /pg_advisory_xact_lock\(hashtext\('lyra_aggregate\/LockItem\$\d+'\)\)/
  LOCK = Regexp.union(ROW_LOCK, ADVISORY)

  def setup
    skip "Requires Rails and PostgreSQL" unless defined?(ActiveRecord::Base) && connection.adapter_name.match?(/postgres/i)

    connection.create_table(TABLE, force: true) do |t|
      t.string :label
      t.timestamps
    end
    Object.send(:remove_const, :LockItem) if defined?(LockItem)
    Object.const_set(:LockItem, Class.new(ActiveRecord::Base) do
      self.table_name = TABLE
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
    end)
    LockItem.reset_column_information
    clean_events
    Lyra.config.monitor_model(LockItem)
    Lyra.config.async_projections_inline = true
  end

  def teardown
    return unless defined?(LockItem)

    Lyra.reset_config!
    clean_events
    connection.drop_table(TABLE, if_exists: true)
  end

  def test_hijack_update_and_destroy_take_the_lock_and_create_does_not
    Lyra.config.enable_hijack!

    created = nil
    refute_locked(statements { created = LockItem.create!(label: "a") }, "a create")
    assert_locked(statements { created.update!(label: "b") }, "an update")
    assert_locked(statements { created.destroy! }, "a destroy")
  end

  def test_es_sync_update_and_destroy_take_the_lock_and_create_does_not
    Lyra.config.enable_event_sourcing!
    Lyra.config.projection_mode = :sync

    created = nil
    refute_locked(statements { created = LockItem.create!(label: "a") }, "a create")
    assert_locked(statements { created.update!(label: "b") }, "an update")
    assert_locked(statements { created.destroy! }, "a destroy")
  end

  def test_the_lock_is_taken_before_the_event_is_appended
    Lyra.config.enable_hijack!
    item = LockItem.create!(label: "a")

    sql = statements { item.update!(label: "b") }
    lock = sql.index { |s| s.match?(LOCK) }
    append = sql.index { |s| s.match?(/INSERT INTO "event_store_events"/) }

    refute_nil lock
    refute_nil append
    assert_operator lock, :<, append, "the lock must precede the append"
  end

  # The lock is the row's own, in the strength the write would take: an
  # update's FOR NO KEY UPDATE (so foreign-key checks of child inserts, which
  # take FOR KEY SHARE, are not blocked), a destroy's FOR UPDATE.
  def test_the_lock_is_the_rows_own_in_the_writes_strength
    Lyra.config.enable_hijack!
    item = LockItem.create!(label: "a")

    update = statements { item.update!(label: "b") }.grep(ROW_LOCK)
    destroy = statements { item.destroy! }.grep(ROW_LOCK)

    assert_equal 1, update.size
    assert update.first.end_with?("FOR NO KEY UPDATE"), update.first
    assert_equal 1, destroy.size
    assert destroy.first.end_with?(" FOR UPDATE") && !destroy.first.include?("NO KEY"), destroy.first
  end

  # A record whose row is missing (written by another path, or deleted under
  # it) still gets a lock: the advisory lock on its stream.
  def test_without_a_row_the_advisory_lock_is_taken
    Lyra.config.enable_hijack!
    item = LockItem.create!(label: "a")
    connection.execute("DELETE FROM #{TABLE} WHERE id = #{item.id}")

    sql = statements { item.update!(label: "b") rescue nil }

    assert sql.any? { |s| s.match?(ROW_LOCK) }, "the row lock is tried first"
    assert sql.any? { |s| s.match?(ADVISORY) }, "then the advisory lock:\n#{sql.join("\n")}"
  end

  def test_monitor_takes_no_lock_its_row_write_is_the_lock
    Lyra.config.enable_monitor!
    item = LockItem.create!(label: "a")

    refute_locked(statements { item.update!(label: "b") }, "a Monitor update")
    refute_locked(statements { item.destroy! }, "a Monitor destroy")
  end

  def test_es_async_and_es_noproj_take_no_lock
    Lyra.config.enable_event_sourcing!
    %i[async disabled].each do |projection|
      Lyra.config.projection_mode = projection
      item = LockItem.create!(label: "a")
      refute_locked(statements { item.update!(label: "b") }, "an ES-#{projection} update")
    end
  end

  def test_the_lock_can_be_turned_off
    Lyra.config.enable_hijack!
    Lyra.config.lock_aggregate_before_append = false
    item = LockItem.create!(label: "a")

    refute_locked(statements { item.update!(label: "b") }, "an update with the lock off")
  end

  private

  # The SQL the current thread issues in the block, schema and cached
  # queries excluded.
  def statements
    seen = []
    writer = Thread.current
    subscription = ActiveSupport::Notifications.subscribe("sql.active_record") do |*args|
      next unless Thread.current == writer

      payload = args.last
      next if payload[:name].to_s == "SCHEMA" || payload[:cached]

      seen << payload[:sql].to_s
    end
    yield
    seen
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription)
  end

  def assert_locked(sql, what)
    assert sql.any? { |s| s.match?(LOCK) }, "#{what} took no lock; it issued:\n#{sql.join("\n")}"
  end

  def refute_locked(sql, what)
    refute sql.any? { |s| s.match?(LOCK) }, "#{what} took the lock; it issued:\n#{sql.join("\n")}"
  end

  def connection = ActiveRecord::Base.connection

  def clean_events
    connection.execute("DELETE FROM event_store_events_in_streams")
    connection.execute("DELETE FROM event_store_events")
  end
end
