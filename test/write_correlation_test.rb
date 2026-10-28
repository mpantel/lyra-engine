# frozen_string_literal: true

require "test_helper"

# Write scopes (config.correlate_writes): a write made inside another write's
# callbacks records that write's event as its cause; the outermost write opens
# the correlation when none is in scope; a request's writes share one.
class WriteCorrelationTest < Minitest::Test
  PARENTS = "lyra_wc_parents"
  CHILDREN = "lyra_wc_children"

  def setup
    skip "Requires Rails and database" unless defined?(ActiveRecord::Base) && ActiveRecord::Base.connection.adapter_name.match?(/postgres/i)

    connection.create_table(PARENTS, force: true) do |t|
      t.string :label
      t.timestamps
    end
    connection.create_table(CHILDREN, force: true) do |t|
      t.bigint :wc_parent_id
      t.string :label
      t.timestamps
    end
    define_models
    clean_events
  end

  def teardown
    return unless defined?(WcParent)

    Lyra.config.projection_mode = :sync
    [WcParent, WcChild].each { |model| Lyra::Projections::CachedProjection.invalidate_all(model) }
    clean_events
    [PARENTS, CHILDREN].each { |table| connection.drop_table(table, if_exists: true) }
  end

  def test_a_write_inside_another_write_names_it_as_its_cause
    parent = WcParent.create!(label: "p")
    parent_event = own_event(WcParent, parent.id)
    child_event = own_event(WcChild, parent.children_created.first)

    assert_nil parent_event.metadata[:causation_id], "the outermost write has no cause"
    assert_equal parent_event.event_id, child_event.metadata[:causation_id]
    assert_equal parent_event.event_id, parent_event.metadata[:correlation_id],
                 "the outermost write opens the correlation: its own id, the store's convention for a root event"
    assert_equal parent_event.event_id, child_event.metadata[:correlation_id]
  end

  def test_a_correlation_in_scope_is_kept
    parent = Lyra::Correlation.with_id("req-1") { WcParent.create!(label: "p") }

    assert_equal "req-1", own_event(WcParent, parent.id).metadata[:correlation_id]
    assert_equal "req-1", own_event(WcChild, parent.children_created.first).metadata[:correlation_id]
  end

  def test_separate_writes_outside_any_scope_are_separate_chains
    first = WcParent.create!(label: "a")
    second = WcParent.create!(label: "b")

    refute_equal own_event(WcParent, first.id).metadata[:correlation_id],
                 own_event(WcParent, second.id).metadata[:correlation_id]
  end

  def test_a_save_inside_its_own_callbacks_is_caused_by_the_outer_save
    parent = WcParent.create!(label: "renamed-on-create")
    events = Lyra.config.event_store.read.stream(Lyra.stream_name(WcParent, parent.id)).to_a
    created, updated = events

    assert_equal 2, events.size
    assert_equal created.event_id, updated.metadata[:causation_id]
    assert_nil created.metadata[:causation_id], "the outer write keeps its own cause after the inner one ends"
  end

  def test_hijack_and_event_sourcing_name_the_cause_too
    [-> { Lyra.config.enable_hijack! }, -> { Lyra.config.enable_event_sourcing! }].each do |mode|
      clean_events
      mode.call
      parent = WcParent.create!(label: "p")
      parent_event = own_event(WcParent, parent.id)
      child_event = own_event(WcChild, parent.children_created.first)

      assert_equal parent_event.event_id, child_event.metadata[:causation_id], "mode #{Lyra.config.mode}"
      assert_equal parent_event.event_id, child_event.metadata[:correlation_id], "mode #{Lyra.config.mode}"
    end
  end

  def test_off_leaves_causation_to_the_application
    Lyra.config.correlate_writes = false
    parent = WcParent.create!(label: "p")

    assert_nil own_event(WcChild, parent.children_created.first).metadata[:causation_id]
  end

  def test_middleware_gives_a_request_one_correlation
    written = []
    app = lambda do |_env|
      written << WcParent.create!(label: "a") << WcParent.create!(label: "b")
      [200, {}, ["ok"]]
    end
    Lyra::Correlation::Middleware.new(app).call("action_dispatch.request_id" => "req-42")

    assert_equal(%w[req-42 req-42], written.map { |p| own_event(WcParent, p.id).metadata[:correlation_id] })
    assert_nil Lyra::Correlation.current_id, "the request's correlation ends with it"
  end

  def test_middleware_keeps_a_correlation_in_scope_and_can_be_switched_off
    seen = []
    app = ->(_env) { seen << Lyra::Correlation.current_id and [200, {}, []] }
    middleware = Lyra::Correlation::Middleware.new(app)

    Lyra::Correlation.with_id("outer") { middleware.call("action_dispatch.request_id" => "req-1") }
    Lyra.config.correlate_writes = false
    middleware.call("action_dispatch.request_id" => "req-2")

    assert_equal ["outer", nil], seen
  end

  # A job created inside a write's callbacks and deferred to after the commit
  # is serialized outside that write, yet its writes name it as their cause
  # and share its correlation.
  def test_a_job_created_inside_a_write_carries_its_cause_and_correlation
    parent = with_test_queue { WcParent.create!(label: "enqueue") }
    parent_event = own_event(WcParent, parent.id)

    assert_equal parent_event.event_id, enqueued_jobs.sole["lyra_causation_id"]
    refute enqueued_jobs.sole.key?("lyra_cause_unconfirmed"), "a deferred job is sent only once its cause commits"
    run_jobs
    job_events = job_children.map { |id| own_event(WcChild, id) }

    assert_equal 2, job_events.size
    assert_equal([parent_event.event_id] * 2, job_events.map { |e| e.metadata[:causation_id] })
    assert_equal([parent_event.event_id] * 2, job_events.map { |e| e.metadata[:correlation_id] })
  end

  # Sent at once, inside the write's transaction: the cause is unconfirmed,
  # kept when the job runs because the write committed.
  def test_a_job_sent_at_once_keeps_a_cause_that_committed
    WcJob.enqueue_after_transaction_commit = false
    parent = with_test_queue { WcParent.create!(label: "enqueue") }
    parent_event = own_event(WcParent, parent.id)

    assert_equal true, enqueued_jobs.sole["lyra_cause_unconfirmed"]
    run_jobs

    assert_equal([parent_event.event_id] * 2, job_children.map { |id| own_event(WcChild, id).metadata[:causation_id] })
  end

  # ... and dropped when the write rolled back, so that no job names a cause
  # the log lacks. The job's writes still share one correlation.
  def test_a_job_sent_at_once_drops_a_cause_that_rolled_back
    WcJob.enqueue_after_transaction_commit = false
    with_test_queue do
      WcParent.transaction do
        WcParent.create!(label: "enqueue")
        raise ActiveRecord::Rollback
      end
    end
    cause = enqueued_jobs.sole["lyra_causation_id"]

    assert_nil Lyra.config.event_store.read.event(cause), "the cause rolled back"
    run_jobs
    job_events = job_children.map { |id| own_event(WcChild, id) }

    assert_equal([nil, nil], job_events.map { |e| e.metadata[:causation_id] })
    assert_equal 1, job_events.map { |e| e.metadata[:correlation_id] }.uniq.size
  end

  def test_a_job_created_in_a_request_shares_its_correlation
    app = ->(_env) { WcJob.perform_later(0) and [200, {}, []] }
    with_test_queue { Lyra::Correlation::Middleware.new(app).call("action_dispatch.request_id" => "req-7") }
    run_jobs
    job_events = job_children.map { |id| own_event(WcChild, id) }

    assert_equal(%w[req-7 req-7], job_events.map { |e| e.metadata[:correlation_id] })
    assert_equal([nil, nil], job_events.map { |e| e.metadata[:causation_id] })
  end

  def test_a_job_with_nothing_in_scope_is_one_correlation_its_id
    with_test_queue { WcJob.perform_later(0) }
    job_id = enqueued_jobs.sole["job_id"]
    run_jobs

    assert_equal([job_id] * 2, job_children.map { |id| own_event(WcChild, id).metadata[:correlation_id] })
  end

  def test_off_leaves_jobs_alone
    Lyra.config.correlate_writes = false
    with_test_queue { Lyra::Correlation.with_id("req-8") { WcJob.perform_later(0) } }

    refute enqueued_jobs.sole.key?("lyra_correlation_id"), "nothing added to the payload"
    run_jobs
    correlations = job_children.map { |id| own_event(WcChild, id).metadata[:correlation_id] }

    assert_equal 2, correlations.uniq.size, "each write its own chain (the store assigns each one)"
    refute_includes correlations, "req-8"
  end

  private

  # Jobs enqueued in the block go to a test queue (enqueued_jobs); run_jobs
  # performs them from their payload, outside any scope, as a worker would.
  def with_test_queue
    @queue = ActiveJob::QueueAdapters::TestAdapter.new
    previous = WcJob.queue_adapter
    WcJob.queue_adapter = @queue
    yield
  ensure
    WcJob.queue_adapter = previous
  end

  def enqueued_jobs = @queue.enqueued_jobs

  def run_jobs
    assert_nil Lyra::Correlation.current_id
    enqueued_jobs.each { |job| ActiveJob::Base.execute(job) }
  end

  def job_children = WcChild.where(label: "job").order(:id).pluck(:id)

  # The write's own event for the record (its first in the stream).
  def own_event(model, id)
    Lyra.config.event_store.read.stream(Lyra.stream_name(model, id)).first
  end

  def define_models
    %i[WcParent WcChild WcJob].each { |name| Object.send(:remove_const, name) if Object.const_defined?(name) }
    Object.const_set(:WcChild, Class.new(ActiveRecord::Base) do
      self.table_name = CHILDREN
      include Lyra::Interceptors::CrudInterceptor
    end)
    Object.const_set(:WcParent, Class.new(ActiveRecord::Base) do
      self.table_name = PARENTS
      include Lyra::Interceptors::CrudInterceptor
      attr_reader :children_created

      # A write made inside this write's callbacks, a save of itself, and a job.
      after_create do
        @children_created = [WcChild.create!(wc_parent_id: id, label: "c").id]
        update!(label: "renamed") if label == "renamed-on-create"
        WcJob.perform_later(id) if label == "enqueue"
      end
    end)
    # Two writes, deferred to after the commit as AsyncProjectionJob is.
    Object.const_set(:WcJob, Class.new(ActiveJob::Base) do
      self.enqueue_after_transaction_commit = true
      def perform(parent_id) = 2.times { WcChild.create!(wc_parent_id: parent_id, label: "job") }
    end)
    # Monitored once named: the event names come from the model's name.
    [WcChild, WcParent].each do |model|
      model.monitor_with_lyra
      model.reset_column_information
    end
  end

  def connection = ActiveRecord::Base.connection

  def clean_events
    connection.execute("DELETE FROM event_store_events_in_streams")
    connection.execute("DELETE FROM event_store_events")
  end
end
