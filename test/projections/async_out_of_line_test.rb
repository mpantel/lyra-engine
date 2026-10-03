# frozen_string_literal: true

require "test_helper"

# ES-Async as it runs in production: projections enqueued as
# AsyncProjectionJob and run by the :async job adapter on its own threads,
# not inline. Setting async_projections_inline = false opts a test out of the
# test-environment default (inline), which used to be forced.
class AsyncOutOfLineTest < Minitest::Test
  # Records the thread of every ModelProjection.project call while switched
  # on. Prepended once and never removed, so it cannot take the real method
  # with it.
  module ProjectionThreads
    class << self
      attr_reader :queue

      def record_into(queue)
        Lyra::Projections::ModelProjection.singleton_class.prepend(self) unless Lyra::Projections::ModelProjection.singleton_class.include?(self)
        @queue = queue
      end
    end

    def project(*args)
      ProjectionThreads.queue&.push(Thread.current)
      super
    end
  end

  def setup
    skip "Requires Rails and database" unless defined?(ActiveRecord::Base) && ActiveRecord::Base.connection.table_exists?(:users)

    Object.send(:remove_const, :AsyncUser) if defined?(AsyncUser)
    Object.const_set(:AsyncUser, Class.new(ActiveRecord::Base) do
      self.table_name = "users"
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
    end)
    clean
    @previous_adapter = ActiveJob::Base.queue_adapter
    @adapter = ActiveJob::QueueAdapters::AsyncAdapter.new(min_threads: 1, max_threads: 2)
    ActiveJob::Base.queue_adapter = @adapter
    Lyra.config.enable_event_sourcing!
    Lyra.config.projection_mode = :async
    Lyra.config.async_projections_inline = false
    Lyra.config.monitor_model(AsyncUser)
  end

  def teardown
    return unless defined?(AsyncUser)

    @adapter&.shutdown(wait: true)
    ActiveJob::Base.queue_adapter = @previous_adapter
    Lyra.config.projection_mode = :sync
    clean
  end

  def test_the_test_environment_still_defaults_to_inline
    Lyra.config.async_projections_inline = nil
    assert Lyra.config.async_projections_inline?
    Lyra.config.async_projections_inline = false
    refute Lyra.config.async_projections_inline?
  end

  def test_projections_run_on_job_threads_and_converge
    projecting = Queue.new
    ProjectionThreads.record_into(projecting)

    users = 5.times.map { |i| AsyncUser.create!(name: "U#{i}", email: "u#{i}@example.com") }
    users.each { |u| u.update!(name: "#{u.name}*") }
    users.last.destroy!
    @adapter.shutdown(wait: true)

    threads = []
    threads << projecting.pop until projecting.empty?
    refute_empty threads, "projections ran"
    refute_includes threads, Thread.current, "no projection may run on the writing thread"

    rows = ActiveRecord::Base.connection.select_rows("SELECT id, name FROM users ORDER BY id")
    expected = users[0..3].map { |u| [u.id, "#{u.name}"] }
    assert_equal expected, rows.map { |id, name| [id.to_i, name] }
    users[0..3].each do |u|
      differences = Lyra::DualView.new(AsyncUser, u.id).compare[:differences]
      assert differences[:no_differences], "row #{u.id} matches its events: #{differences.inspect}"
    end
  ensure
    ProjectionThreads.record_into(nil)
  end

  private

  def clean
    conn = ActiveRecord::Base.connection
    conn.execute("DELETE FROM users")
    conn.execute("DELETE FROM event_store_events_in_streams")
    conn.execute("DELETE FROM event_store_events")
  end
end
