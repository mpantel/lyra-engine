# frozen_string_literal: true

require "test_helper"

# Model correspondence: every element of the core CRUD-to-event net has its
# counterpart in Lyra's source, found by pattern matching on the code. It checks
# structure, not behaviour; trace_conformance_test.rb replays real writes on the
# nets. A change to the code that breaks one of these patterns fails the suite.
class ModelCorrespondenceTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def interceptor = @interceptor ||= read("lib/lyra/interceptors/crud_interceptor.rb")
  def handler = @handler ||= read("lib/lyra/command_handler.rb")
  def domain_events = @domain_events ||= read("lib/lyra/domain_events.rb")

  def handler_ops
    %w[handle_create handle_update handle_destroy].map { |name| method_source(handler, name) }
  end

  # P_crud: the interceptor's after_* callbacks place the operation's token.
  def test_p_crud_is_the_interceptor_callbacks
    %w[create update destroy].each do |op|
      assert_match(/after_#{op}.*lyra_intercept_#{op}/, interceptor, "after_#{op} callback")
    end
  end

  # T_create, T_update, T_delete: one command handler each.
  def test_mapping_transitions_are_the_command_handlers
    handler_ops.zip(%w[create update destroy]).each do |body, op|
      refute_nil body, "CommandHandler#handle_#{op}"
    end
  end

  # G(T_x): the guards are the command cases of CommandHandler#call.
  def test_guards_are_the_command_cases
    %w[Create Update Destroy].each do |kind|
      assert_match(/when Commands::#{kind}Command/, handler, "#{kind}Command case")
    end
  end

  # E(T_x): the event is built from the operation's data on both paths.
  # CommandHandler#create_event (Hijack, event sourcing) instantiates the
  # operation's event class; CrudInterceptor#publish_event (Monitor) goes
  # through Lyra::DomainEvents.build, whose default is the operation's class.
  # The event id may be passed through first (**id).
  def test_arc_expression_builds_the_event_from_the_operation_data
    create_event = method_source(handler, "create_event")
    publish_event = method_source(interceptor, "publish_event")
    build = method_source(domain_events, "build")

    assert_match(/event_class\.new\(\s*(?:\*\*\w+,\s*)?data:[^\n]*metadata:/, create_event.to_s)
    assert_match(/Lyra::DomainEvents\.build\(.*data:.*metadata:.*default_class:\s*lyra_event_class_for\(operation\)/m,
                 publish_event.to_s)
    assert_match(/default_class\.new\(\s*(?:\*\*\w+,\s*)?data:\s*data,\s*metadata:\s*metadata\s*\)/, build.to_s)
  end

  # P_event: every handler builds its events through create_events.
  def test_p_event_is_built_through_create_events
    handler_ops.each { |body| assert_match(/events = create_events\(/, body.to_s) }
    assert_match(/create_event\(operation/, method_source(handler, "create_events").to_s)
  end

  # T_publish / P_published: both paths append to the record's stream.
  def test_t_publish_appends_to_the_record_stream
    # The record's own stream by default; a key change in Monitor (1.0.1)
    # records the old key's destroy on the old key's stream.
    publish = method_source(interceptor, "publish_event").to_s
    assert_match(/def publish_event\(operation, data, stream_name: lyra_stream_name\)/, publish)
    assert_match(/Lyra\.append_events\(events, stream_name: stream_name\)/, publish)
    assert_match(/Lyra\.append_events\(events, stream_name: stream_name\)/, handler)
  end

  # T_apply precedes T_publish: each handler applies the event to the aggregate
  # before storing it.
  def test_t_apply_precedes_t_publish_in_each_handler
    handler_ops.each do |body|
      apply_at = body.to_s.index("aggregate.apply(event)")
      store_at = body.to_s.index("aggregate.store(")
      assert apply_at && store_at && apply_at < store_at, "apply before store"
    end
  end

  # The core net itself: four reachable markings, one terminal, safe.
  def test_core_net_is_safe_with_one_terminal_marking
    results = PetriFlow.verify(core_net)

    assert_equal 4, results[:reachability][:total_reachable_states]
    assert_equal 1, results[:reachability][:terminal_states]
    assert results[:boundedness][:is_safe]
  end

  private

  def read(path) = File.read(File.join(ROOT, path))

  # The source of one method, from its def to the next def (or private /
  # protected) at the same depth, or the end of the file; nil when undefined.
  def method_source(source, name)
    start = source =~ /^([ \t]*)def #{Regexp.escape(name)}\b/ or return nil
    indent = Regexp.last_match(1)
    rest = source[start..]
    stop = rest.index(/^#{indent}(def |private\b|protected\b)/, 1)
    stop ? rest[0...stop] : rest
  end

  # P_crud -> T_map -> P_event -> T_apply -> P_aggregate -> T_publish -> P_published,
  # with T_map standing for T_create, T_update and T_delete.
  def core_net
    net = PetriFlow.create_net(name: "core_crud_to_event")
    %i[p_crud p_event p_aggregate p_published].each_with_index do |id, i|
      net.add_place(id: id, initial_tokens: i.zero? ? 1 : 0)
    end
    %i[t_map t_apply t_publish].each { |id| net.add_transition(id: id, name: id.to_s) }
    [%i[p_crud t_map], %i[t_map p_event], %i[p_event t_apply], %i[t_apply p_aggregate],
     %i[p_aggregate t_publish], %i[t_publish p_published]].each do |source, target|
      net.add_arc(source_id: source, target_id: target)
    end
    net
  end
end
