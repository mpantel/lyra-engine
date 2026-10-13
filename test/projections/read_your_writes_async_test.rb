# frozen_string_literal: true

require "test_helper"

# ReadYourWrites.with_guaranteed_read under ES-Async with the projection job
# queued, not run inline: the block's writes are projected when it ends. Only
# ES-Sync used to record them, so under ES-Async the block had no effect.
class ReadYourWritesAsyncTest < Minitest::Test
  def setup
    skip "Requires Rails and database" unless defined?(ActiveRecord::Base) && ActiveRecord::Base.connection.table_exists?(:users)

    Object.send(:remove_const, :RywUser) if defined?(RywUser)
    Object.const_set(:RywUser, Class.new(ActiveRecord::Base) do
      self.table_name = "users"
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
    end)
    clean
    @previous_adapter = ActiveJob::Base.queue_adapter
    @adapter = ActiveJob::QueueAdapters::TestAdapter.new
    ActiveJob::Base.queue_adapter = @adapter
    Lyra.config.enable_event_sourcing!
    Lyra.config.projection_mode = :async
    Lyra.config.async_projections_inline = false
    Lyra.config.monitor_model(RywUser)
  end

  def teardown
    return unless defined?(RywUser)

    ActiveJob::Base.queue_adapter = @previous_adapter
    Lyra.config.projection_mode = :sync
    clean
  end

  def test_a_create_inside_the_block_is_in_the_table_when_the_block_returns
    user = Lyra::Consistency::ReadYourWrites.with_guaranteed_read do
      RywUser.create!(name: "Gus", email: "gus@example.com")
    end

    assert_equal [[user.id, "Gus"]], rows, "projected when the block ended"
    assert_equal 1, @adapter.enqueued_jobs.size, "the job is still enqueued"

    # The job converges on the same row when it runs.
    job = @adapter.enqueued_jobs.first
    Lyra::Projections::AsyncProjectionJob.perform_now(*ActiveJob::Arguments.deserialize(job[:args]))
    assert_equal [[user.id, "Gus"]], rows
  end

  def test_updates_and_destroys_inside_the_block_are_projected
    user = Lyra::Consistency::ReadYourWrites.with_guaranteed_read do
      RywUser.create!(name: "Hal", email: "hal@example.com")
    end
    other = Lyra::Consistency::ReadYourWrites.with_guaranteed_read do
      user.update!(name: "Hal2")
      RywUser.create!(name: "Ivy", email: "ivy@example.com").tap(&:destroy!)
    end

    assert_equal [[user.id, "Hal2"]], rows
    refute_includes rows.map(&:first), other.id
  end

  # A nested block projects its own writes when it ends and leaves the outer
  # block's list intact: the writes before and after it are projected when
  # the outer block ends. The inner block used to reset the list, losing them.
  def test_nested_blocks_project_every_write
    ryw = Lyra::Consistency::ReadYourWrites
    before = inner = after = nil
    rows_after_inner = nil

    ryw.with_guaranteed_read do
      before = RywUser.create!(name: "Before", email: "before@example.com")
      ryw.with_guaranteed_read do
        inner = RywUser.create!(name: "Inner", email: "inner@example.com")
      end
      rows_after_inner = rows
      assert ryw.in_guaranteed_block?, "still inside the outer block"
      after = RywUser.create!(name: "After", email: "after@example.com")
    end

    assert_includes rows_after_inner, [inner.id, "Inner"], "the inner block projected its write when it ended"
    assert_equal [[before.id, "Before"], [inner.id, "Inner"], [after.id, "After"]].sort, rows.sort
    refute ryw.in_guaranteed_block?, "the outermost block clears the list"
  end

  def test_writes_of_a_failed_inner_block_are_projected_by_the_outer_block
    ryw = Lyra::Consistency::ReadYourWrites
    inner = nil

    ryw.with_guaranteed_read do
      begin
        ryw.with_guaranteed_read do
          inner = RywUser.create!(name: "Kim", email: "kim@example.com")
          raise ArgumentError, "inner failure"
        end
      rescue ArgumentError
        nil
      end
    end

    assert_equal [[inner.id, "Kim"]], rows
  end

  # By default a read inside the block does not see the block's own writes;
  # with each_write: true it does, as code that reads back what it has just
  # written in the same unit of work needs (Solidus's order.complete! reads
  # the payment created a line before).
  def test_each_write_makes_a_write_visible_to_reads_later_in_the_block
    seen_default = Lyra::Consistency::ReadYourWrites.with_guaranteed_read do
      RywUser.create!(name: "Ned", email: "ned@example.com")
      rows.map(&:last)
    end
    seen_each_write = Lyra::Consistency::ReadYourWrites.with_guaranteed_read(each_write: true) do
      user = RywUser.create!(name: "Ola", email: "ola@example.com")
      user.update!(name: "Ola2")
      rows.map(&:last)
    end

    assert_equal [], seen_default, "the default projects when the block ends"
    assert_includes seen_each_write, "Ola2", "each_write projects every write as it is made"
    assert_equal %w[Ned Ola2], rows.map(&:last).sort
  end

  def test_with_each_write_the_job_still_converges_on_the_same_row
    user = Lyra::Consistency::ReadYourWrites.with_guaranteed_read(each_write: true) do
      RywUser.create!(name: "Pia", email: "pia@example.com").tap { _1.update!(name: "Pia2") }
    end

    @adapter.enqueued_jobs.dup.each do |job|
      Lyra::Projections::AsyncProjectionJob.perform_now(*ActiveJob::Arguments.deserialize(job[:args]))
    end

    assert_equal [[user.id, "Pia2"]], rows
  end

  # A default block nested in an each_write block keeps its own behaviour, and
  # the outer block's is back after it.
  def test_each_write_is_per_block
    inner_seen = outer_seen = nil
    Lyra::Consistency::ReadYourWrites.with_guaranteed_read(each_write: true) do
      Lyra::Consistency::ReadYourWrites.with_guaranteed_read do
        RywUser.create!(name: "Quin", email: "quin@example.com")
        inner_seen = rows.map(&:last)
      end
      RywUser.create!(name: "Rae", email: "rae@example.com")
      outer_seen = rows.map(&:last)
    end

    assert_equal [], inner_seen
    assert_equal %w[Quin Rae], outer_seen.sort
  end

  def test_outside_the_block_the_write_waits_for_the_job
    RywUser.create!(name: "Jo", email: "jo@example.com")

    assert_empty rows
    assert_equal 1, @adapter.enqueued_jobs.size
  end

  private

  def rows
    ActiveRecord::Base.connection.select_rows("SELECT id, name FROM users ORDER BY id").map { |id, name| [id.to_i, name] }
  end

  def clean
    conn = ActiveRecord::Base.connection
    conn.execute("DELETE FROM users")
    conn.execute("DELETE FROM event_store_events_in_streams")
    conn.execute("DELETE FROM event_store_events")
  end
end
