# frozen_string_literal: true

require "test_helper"
require "active_job/test_helper"

# Trace conformance: the steps Lyra actually takes on a write, in each mode,
# must form a firing sequence of the paper's Petri net (Section 3) as each mode
# places it (Section 4). verify_model_correspondence.rb checks the structure of
# the code by pattern matching; this test checks its behaviour.
#
# A trace is recorded from the running code, not from the source:
#   reserve      a sequence nextval (Hijack and event-sourcing creates)
#   map_<op>     the event is built (T_create / T_update / T_delete), with the
#                operation its event class names
#   apply        the event is applied to the aggregate (T_apply)
#   publish      Lyra.append_events stores it (T_publish)
#   write        the row is written to the model's table (T_write)
#   commit       the outermost transaction commits
#
# Each mode's net is built with PetriFlow and the trace is replayed on it token
# by token: every step must fire an enabled transition, and the last must leave
# the token in the net's final place.
module TraceConformance
  module Recorder
    module_function

    def record(step)
      trace = Thread.current[:lyra_trace]
      trace << step if trace
    end

    # Count only the outermost call: CommandHandler#create_events builds through
    # Lyra::DomainEvents.build, and GenericAggregate#apply may reach Aggregate#apply.
    def once(key)
      depth = (Thread.current[key] ||= 0)
      Thread.current[key] = depth + 1
      result = yield
      [result, depth.zero?]
    ensure
      Thread.current[key] -= 1
    end

    def operation_of(events)
      name = Array(events).first.class.name.to_s
      case name
      when /Created\z/, /Imported\z/ then :created
      when /Updated\z/ then :updated
      when /Destroyed\z/, /Deleted\z/ then :destroyed
      else :unknown
      end
    end

    def install!(table)
      @table = table
      return if @installed

      @installed = true
      Lyra::DomainEvents.singleton_class.prepend(Module.new do
        def build(*args, **kwargs)
          events, outer = Recorder.once(:lyra_trace_map) { super }
          Recorder.record(:"map_#{Recorder.operation_of(events)}") if outer
          events
        end
      end)
      Lyra::CommandHandler.prepend(Module.new do
        private

        # The handler builds a write's events here: its own event, then
        # Lyra::DomainEvents.build, which may replace or add to it.
        def create_events(*args)
          events, outer = Recorder.once(:lyra_trace_map) { super }
          Recorder.record(:"map_#{Recorder.operation_of(events)}") if outer
          events
        end
      end)
      [Lyra::Aggregate, Lyra::GenericAggregate].each do |klass|
        klass.prepend(Module.new do
          def apply(*args, **kwargs)
            result, outer = Recorder.once(:lyra_trace_apply) { super }
            Recorder.record(:apply) if outer
            result
          end
        end)
      end
      Lyra.singleton_class.prepend(Module.new do
        def append_events(*args, **kwargs)
          super.tap { Recorder.record(:publish) }
        end
      end)
      ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        sql = payload[:sql].to_s
        if sql.match?(/nextval/i)
          Recorder.record(:reserve)
        elsif sql.match?(/\A\s*(INSERT INTO|UPDATE|DELETE FROM)\s+"?#{Recorder.table}"?\s/i)
          Recorder.record(:write)
        elsif sql.strip.casecmp?("COMMIT")
          Recorder.record(:commit)
        end
      end
    end

    def table = @table

    # Consecutive row writes are one T_write: ES-Async's job brings the row up
    # to date by replaying the record's whole stream into it (insert, then each
    # update, then a delete), so that whichever job runs first converges.
    def capture
      Thread.current[:lyra_trace] = []
      yield
      Thread.current[:lyra_trace].chunk_while { |a, b| a == :write && b == :write }.map(&:first)
    ensure
      Thread.current[:lyra_trace] = nil
    end
  end

  # The net for one mode: the paper's core net (map, apply, publish) with the
  # host's row write placed as the mode places it. :map stands for the three
  # guarded transitions T_create, T_update and T_delete between the same places.
  NETS = {
    monitor: { create: %i[write map publish commit],
               default: %i[write map publish commit] },
    hijack: { create: %i[reserve map apply publish write commit],
              default: %i[map apply publish write commit] },
    es_sync: { create: %i[reserve map apply publish write commit],
               default: %i[map apply publish write commit] },
    # The row follows in a job enqueued after commit; the job writes it in a
    # transaction of its own.
    es_async: { create: %i[reserve map apply publish commit write commit],
                default: %i[map apply publish commit write commit] },
    # No row is written at write time: reads rebuild the state from the log.
    es_disabled: { create: %i[reserve map apply publish commit],
                   default: %i[map apply publish commit] },
    es_lazy: { create: %i[reserve map apply publish commit],
               default: %i[map apply publish commit] }
  }.freeze

  MAP_TRANSITIONS = { create: :map_created, update: :map_updated, destroy: :map_destroyed }.freeze

  def self.net_for(mode, operation)
    steps = NETS.fetch(mode).fetch(operation == :create ? :create : :default)
    net = PetriFlow.create_net(name: "#{mode}_#{operation}")
    places = (0..steps.size).map { |i| :"p#{i}" }
    places.each_with_index { |p, i| net.add_place(id: p, initial_tokens: i.zero? ? 1 : 0) }
    steps.each_with_index do |step, i|
      labels = step == :map ? MAP_TRANSITIONS.values : [step]
      labels.each do |label|
        id = :"t#{i}_#{label}"
        net.add_transition(id: id, name: label.to_s)
        net.add_arc(source_id: places[i], target_id: id)
        net.add_arc(source_id: id, target_id: places[i + 1])
      end
    end
    [net, places.last]
  end

  # Replay the trace on the net; nil when it conforms, else what went wrong.
  def self.replay(net, final_place, trace)
    trace.each_with_index do |step, i|
      transition = net.enabled_transitions.find { |t| t.name == step.to_s }
      return "step #{i + 1} (#{step}) is not enabled after #{trace.first(i).inspect}" unless transition

      net.fire_transition(transition.id)
    end
    return nil if net.current_marking.tokens_at(final_place) == 1

    "the trace #{trace.inspect} stops before the net's final place"
  end
end

class TraceConformanceTest < Minitest::Test
  include ActiveJob::TestHelper

  MODES = {
    monitor: -> { Lyra.config.enable_monitor! },
    hijack: -> { Lyra.config.enable_hijack! },
    es_sync: -> { es(:sync) },
    es_async: -> { es(:async) },
    es_disabled: -> { es(:disabled) },
    es_lazy: -> { es(:lazy) }
  }.freeze

  def self.es(projection)
    Lyra.config.enable_event_sourcing!
    Lyra.config.projection_mode = projection
    Lyra.config.async_projections_inline = false if projection == :async
  end

  def setup
    skip "Requires Rails and database" unless defined?(ActiveRecord::Base) && ActiveRecord::Base.connection.table_exists?(:articles)
    skip "Requires PetriFlow" unless Lyra.petri_flow_available?

    @event_store = Lyra.config.event_store
    @previous_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    Object.send(:remove_const, :TraceArticle) if defined?(TraceArticle)
    Object.const_set(:TraceArticle, Class.new(ActiveRecord::Base) do
      self.table_name = "articles"
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
    end)
    TraceConformance::Recorder.install!("articles")
    clean
  end

  def teardown
    return unless defined?(TraceArticle)

    clear_enqueued_jobs
    ActiveJob::Base.queue_adapter = @previous_adapter
    clean
    Lyra.reset_config!
    Lyra.config.event_store = @event_store
  end

  MODES.each_key do |mode|
    define_method(:"test_#{mode}_traces_are_firing_sequences_of_the_net") do
      traces = record_traces(mode)

      traces.each do |operation, trace|
        net, final_place = TraceConformance.net_for(mode, operation)
        problem = TraceConformance.replay(net, final_place, trace)
        assert_nil problem, "#{mode} #{operation}: #{problem}"
      end
    end
  end

  # The guard of the net (Definitions 4-6) on real writes: each operation builds
  # exactly one event, of its own type.
  def test_each_operation_fires_exactly_its_own_mapping_transition
    MODES.each_key do |mode|
      record_traces(mode).each do |operation, trace|
        maps = trace.grep(/\Amap_/)
        assert_equal [TraceConformance::MAP_TRANSITIONS.fetch(operation)], maps, "#{mode} #{operation}"
      end
    end
  end

  # A deliberately wrong order must be rejected, or the replay proves nothing.
  def test_a_trace_out_of_order_does_not_conform
    net, final_place = TraceConformance.net_for(:hijack, :update)

    refute_nil TraceConformance.replay(net, final_place, %i[map_updated publish apply write commit])
  end

  private

  def record_traces(mode)
    Lyra.reset_config!
    Lyra.config.event_store = @event_store
    self.class::MODES.fetch(mode).call
    Lyra.config.monitor_model(TraceArticle)

    article = nil
    traces = {}
    traces[:create] = capture { article = TraceArticle.create!(title: "T", body: "B") }
    traces[:update] = capture { article.update!(title: "T2") }
    traces[:destroy] = capture { article.destroy! }
    traces
  ensure
    clean
  end

  # One write's trace; under ES-Async the jobs it enqueued run inside the
  # capture, after the write's commit, as they would in production.
  def capture(&write)
    TraceConformance::Recorder.capture do
      write.call
      perform_enqueued_jobs
    end
  end

  def clean
    Thread.current[:lyra_bypass_read_override] = true
    ActiveRecord::Base.connection.execute("DELETE FROM articles")
    ActiveRecord::Base.connection.execute("DELETE FROM event_store_events_in_streams")
    ActiveRecord::Base.connection.execute("DELETE FROM event_store_events")
    clear_enqueued_jobs
  ensure
    Thread.current[:lyra_bypass_read_override] = nil
  end
end
