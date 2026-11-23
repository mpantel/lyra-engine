# frozen_string_literal: true

require "test_helper"
require_relative "es_async_locked_reads_test"

# ES-Async: a write that skips callbacks, on a record whose job has not run
# yet, starts from the row as its stream has it (1.0.1). Before, it started
# from the row the job had not written: update_all's SQL expressions,
# update_counters and increment! computed from the stale value, so the update
# pending in the job was lost (n went 0 -> 7 in the log, then 0 -> 1, where
# Monitor gives 8),
class EsAsyncBulkWritePendingTest < EsAsyncLockedReadsTest
  EsAsyncLockedReadsTest.instance_methods(false).grep(/^test_/).each { undef_method(_1) }

  {
    "update_all with an expression" => -> { AsyncLockItem.where(id: @id).update_all("n = n + 1") },
    "update_counters" => -> { AsyncLockItem.update_counters(@id, n: 1) },
    "increment!" => -> { AsyncLockItem.find(@id).increment!(:n) }
  }.each do |name, write|
    define_method(:"test_#{name.tr(' !', '_')}_counts_the_update_pending_in_a_job") do
      AsyncLockItem.find(@id).update!(n: 7)
      assert_equal 0, row_n, "the job has not run"
      instance_exec(&write)
      assert_equal 8, row_n
      assert_equal 8, value
      assert_equal [[0, 7], [7, 8]], n_changes
    end
  end

  # update_columns writes the values it is given: the pending update is not
  # lost, and the job does not write over it. Its change is recorded from the
  # record it was called on (here read before the job ran), as in Monitor.
  def test_update_columns_on_a_record_whose_update_is_pending_keeps_its_value
    AsyncLockItem.find(@id).update!(n: 7)
    AsyncLockItem.find(@id).update_columns(n: 9)
    assert_equal 9, value
    assert_equal 9, n_changes.last.last
  end

  def test_delete_all_of_a_record_whose_update_is_pending
    AsyncLockItem.find(@id).update!(n: 7)
    assert_equal 1, AsyncLockItem.where(id: @id).delete_all
    value
    assert_nil row_n
    assert_equal "Destroyed", Lyra.config.event_store.read.stream("AsyncLockItem$#{@id}").to_a.last.event_type[/Destroyed\z/]
  end

  private

  def row_n = ActiveRecord::Base.connection.select_value("SELECT n FROM #{TABLE} WHERE id = #{Integer(@id)}")

  def n_changes
    Lyra.config.event_store.read.stream("AsyncLockItem$#{@id}").to_a.filter_map do |event|
      changes = event.data[:changes] || event.data["changes"] || {}
      changes["n"] || changes[:n]
    end
  end
end
