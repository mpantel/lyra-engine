# frozen_string_literal: true

require "test_helper"
require "timeout"
require_relative "es_async_locked_reads_test"

# ES-Async: a record-level write that skips callbacks (touch, update_columns)
# against a projection job's last pass (1.0.1). The job takes the stream's
# lock, reads the events after its checkpoint, then waits for the row. Before,
# such a write took no stream lock: the job read the stream before it, waited
# for its row, then wrote its older value over the write and set its
# checkpoint below the write's event, which no job then applied (the row
# stayed behind its log; the Olist replay at 4 threads, Spree::Shipment).
# Now the write brings the row up to date under the stream's lock first, so
# the job finishes before it or reads after it.
class EsAsyncRecordBypassJobTest < EsAsyncLockedReadsTest
  EsAsyncLockedReadsTest.instance_methods(false).grep(/^test_/).each { undef_method(_1) }

  JOB = Lyra::Projections::AsyncProjectionJob

  def setup
    super
    @row_waits = JOB::ROW_WAITS
    JOB.send(:remove_const, :ROW_WAITS)
    JOB.const_set(:ROW_WAITS, 0) # straight to the last pass: the stream's lock, the events, then the row
  end

  def teardown
    JOB.send(:remove_const, :ROW_WAITS)
    JOB.const_set(:ROW_WAITS, @row_waits)
    super
  end

  {
    "touch" => ->(record) { record.touch },
    "update_columns" => ->(record) { record.update_columns(n: 9) }
  }.each do |name, write|
    define_method(:"test_a_#{name}_holding_the_row_is_not_overwritten_by_a_job_s_last_pass") do
      AsyncLockItem.find(@id).update!(n: 7) # its job pending
      held = Queue.new
      go = Queue.new
      writer = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          AsyncLockItem.transaction do
            write.call(AsyncLockItem.find(@id))
            held << true
            go.pop
          end
        end
      end
      held.pop
      jobs = Thread.new { ActiveRecord::Base.connection_pool.with_connection { value } }
      sleep 0.5 # the job reads the stream, or waits for its lock
      go << true
      Timeout.timeout(20) { writer.value }
      Timeout.timeout(20) { jobs.value }
      value
      last = Lyra.config.event_store.read.stream("AsyncLockItem$#{@id}").to_a.last
      changes = last.data[:changes] || last.data["changes"]
      if (stamp = changes["updated_at"])
        assert_equal stamp.last.utc.round(6), row_updated_at.utc.round(6), "the row is the log's last event (to the microsecond)"
      end
      assert_equal (name == "touch" ? 7 : 9), row("n"), "the update pending in the job and the write both count"
    end
  end

  private

  def row(column) = ActiveRecord::Base.connection.select_value("SELECT #{column} FROM #{TABLE} WHERE id = #{Integer(@id)}")

  def row_updated_at = AsyncLockItem.unscoped.where(id: @id).pick(:updated_at)
end
