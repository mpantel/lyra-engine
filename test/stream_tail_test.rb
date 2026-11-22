# frozen_string_literal: true

require "test_helper"

# Lyra::StreamTail: the destroyed check made before every update and destroy
# that the record's row lock does not cover (ES-NoProj, ES-Async, ES-Lazy).
# It used to read and deserialize the stream's whole last event through Rails
# Event Store, and decided from that event alone. It now decides from the
# stream's last replayed event, in one query when the last event is
# positively a replayed create, import or update. Its answer must be the
# one a read of the whole stream gives (+full_answer+), for every kind of
# stream and every store configuration.
class StreamTailTest < Minitest::Test
  TABLE = "lyra_tail_items"
  STI_TABLE = "lyra_tail_vehicles"
  ITEMS = "lyra_tail_habtm_items"
  TAGS = "lyra_tail_habtm_tags"
  JOIN = "lyra_tail_habtm_items_tags"
  SERIALIZERS = {
    yaml: -> { RubyEventStore::Serializers::YAML },
    json: -> { JSON },
    lyra: -> { Lyra::EventSerializer }
  }.freeze
  CHECKED_MODES = { es_noproj: :disabled, es_async: :async, es_lazy: :lazy }.freeze
  ARCHIVE_ON_DESTROY = [{ name: "TailItemArchived", on: :destroy, also: true }].freeze

  def setup
    skip "Requires Rails and PostgreSQL" unless defined?(ActiveRecord::Base) && connection.adapter_name.match?(/postgres/i)

    connection.create_table(TABLE, force: true) do |t|
      t.string :label
      t.string :operation
      t.timestamps
    end
    connection.create_table(STI_TABLE, force: true) do |t|
      t.string :type
      t.string :label
      t.timestamps
    end
    define_model(:TailItem, TABLE)
    define_model(:TailVehicle, STI_TABLE)
    Object.send(:remove_const, :TailCar) if Object.const_defined?(:TailCar)
    Object.const_set(:TailCar, Class.new(TailVehicle))
    clean
    Lyra::StreamTail.reset!
    Lyra.config.enable_monitor!
  end

  def teardown
    return unless defined?(TailItem)

    Lyra::StreamTail.reset!
    Lyra.reset_config!
    clean
    [TABLE, STI_TABLE, JOIN, ITEMS, TAGS].each { connection.drop_table(_1, if_exists: true) }
  end

  # --- the shortcut decides as a read of the whole stream does --------------

  SERIALIZERS.each do |name, serializer|
    define_method("test_created_updated_and_destroyed_streams_with_#{name}") do
      use_serializer(serializer.call)
      created = TailItem.create!(label: "a")
      updated = TailItem.create!(label: "a").tap { _1.update!(label: "b") }
      destroyed = TailItem.create!(label: "a").tap(&:destroy!)

      assert_shortcut_taken
      assert_same_answer(stream(TailItem, created.id), false)
      assert_same_answer(stream(TailItem, updated.id), false)
      assert_same_answer(stream(TailItem, destroyed.id), true)
    end

    define_method("test_imported_streams_with_#{name}") do
      use_serializer(serializer.call)
      only_imported = stream(TailItem, 900)
      append(only_imported, "TailItemImported", operation: :imported)
      imported_then_destroyed = stream(TailItem, 901)
      append(imported_then_destroyed, "TailItemImported", operation: :imported)
      append(imported_then_destroyed, "TailItemDestroyed", operation: :destroyed)

      assert_same_answer(only_imported, false)
      assert_same_answer(imported_then_destroyed, true)
    end

    define_method("test_an_empty_stream_with_#{name}") do
      use_serializer(serializer.call)

      assert_same_answer(stream(TailItem, 999_999), false)
    end

    define_method("test_sti_streams_with_#{name}") do
      use_serializer(serializer.call)
      car = TailCar.create!(label: "a")
      car.update!(label: "b")
      gone = TailCar.create!(label: "a").tap(&:destroy!)

      assert_equal "TailVehicle$#{car.id}", stream(TailCar, car.id), "a subclass writes to its base class's stream"
      assert_same_answer(stream(TailCar, car.id), false)
      assert_same_answer(stream(TailCar, gone.id), true)
    end

    # A destroy stored under a name that does not say so (a domain event, a
    # custom event name) is found from its data; an event that records no
    # operation falls back on its name, as Lyra::Event.operation_of does.
    define_method("test_a_destroy_under_any_name_with_#{name}") do
      use_serializer(serializer.call)
      renamed = stream(TailItem, 910)
      append(renamed, "TailItemCreated", operation: :created)
      append(renamed, "TailItemRetired", operation: :destroyed)
      legacy = stream(TailItem, 911)
      append(legacy, "TailItemDestroyed", operation: nil)
      deleted = stream(TailItem, 912)
      append(deleted, "TailItemBypassed", operation: "deleted")
      # A destroy under a name ending like an update's.
      misnamed = stream(TailItem, 913)
      append(misnamed, "TailItemUpdated", operation: :destroy)

      assert_same_answer(renamed, true)
      assert_same_answer(legacy, true)
      assert_same_answer(deleted, true)
      assert_same_answer(misnamed, true)
    end

    # Data that mentions a destroy without being one (a column named
    # operation, a value) only sends the check to the full read.
    define_method("test_an_update_that_mentions_a_destroy_is_not_one_with_#{name}") do
      use_serializer(serializer.call)
      item = TailItem.create!(label: "destroyed", operation: "destroy")
      item.update!(label: "deleted", operation: "deleted")

      assert_same_answer(stream(TailItem, item.id), false)
    end

    # Events that are not replayed (an additional domain event, an erasure's
    # record, a link) after a destroy: the record is still destroyed.
    define_method("test_events_that_are_not_replayed_after_a_destroy_with_#{name}") do
      use_serializer(serializer.call)
      tail = stream(TailItem, 920)
      append(tail, "TailItemCreated", operation: :created)
      append(tail, "TailItemDestroyed", operation: :destroyed)
      append(tail, "TailItemArchived", operation: :destroyed, replay: false)
      after_update = stream(TailItem, 921)
      append(after_update, "TailItemCreated", operation: :created)
      append(after_update, "TailItemUpdated", operation: :updated, replay: false)
      # An additional event named like an update, after a destroy.
      named_like_an_update = stream(TailItem, 922)
      append(named_like_an_update, "TailItemCreated", operation: :created)
      append(named_like_an_update, "TailItemDestroyed", operation: :destroyed)
      append(named_like_an_update, "TailItemUpdated", operation: :updated, replay: false)

      assert_same_answer(tail, true)
      assert_same_answer(after_update, false)
      assert_same_answer(named_like_an_update, true)
    end

    # More events that are not replayed than one page holds.
    define_method("test_a_destroy_behind_more_than_a_page_of_links_with_#{name}") do
      use_serializer(serializer.call)
      tail = stream(TailItem, 925)
      append(tail, "TailItemCreated", operation: :created)
      append(tail, "TailItemDestroyed", operation: :destroyed)
      (Lyra::StreamTail::PAGE * 2 + 1).times { append(tail, "AssociationLinked", operation: "linked") }
      only_links = stream(TailItem, 926)
      Lyra::StreamTail::PAGE.times { append(only_links, "AssociationLinked", operation: "linked") }

      assert_same_answer(tail, true)
      assert_same_answer(only_links, false)
    end
  end

  # A String subclass as the operation (ActiveSupport::StringInquirer) is
  # written with a YAML tag; it may be a destroy.
  def test_a_tagged_operation_under_yaml
    use_serializer(RubyEventStore::Serializers::YAML)
    tail = stream(TailItem, 940)
    append(tail, "TailItemUpdated", operation: "destroyed".inquiry)

    assert_includes raw_data(tail), "!ruby/string:ActiveSupport::StringInquirer"
    assert_same_answer(tail, true)
  end

  # A String subclass with an instance variable, twice in one event: YAML
  # writes it once with an anchor (&1) and then an alias (*1).
  def test_an_anchored_or_aliased_operation_under_yaml
    use_serializer(RubyEventStore::Serializers::YAML)
    operation = "destroyed".inquiry
    operation.instance_variable_set(:@note, 1)
    aliased = stream(TailItem, 941)
    Lyra.append_events(event_class("TailItemUpdated").new(data: { model_class: "TailItem", model_id: 941, payload: operation, operation: operation }),
                       stream_name: aliased)
    anchored = stream(TailItem, 942)
    Lyra.append_events(event_class("TailItemUpdated").new(data: { model_class: "TailItem", model_id: 942, operation: operation, payload: operation }),
                       stream_name: anchored)

    assert_match(/:operation: \*/, raw_data(aliased))
    assert_match(/:operation: &/, raw_data(anchored))
    assert_same_answer(aliased, true)
    assert_same_answer(anchored, true)
  end

  # Erasure rewrites the stream's events in place and appends an
  # ErasureApplied, which is not replayed.
  def test_erasure_rewritten_streams
    with_erasable_items do
      item = TailItem.create!(label: "Ann")
      item.update!(label: "Ann B")
      gone = TailItem.create!(label: "Bob")
      gone.destroy!

      Lyra::Erasure.erase!(TailItem, item.id, reason: "Art. 17 request")
      Lyra::Erasure.erase!(TailItem, gone.id, reason: "Art. 17 request")

      assert_equal "Lyra::Events::ErasureApplied", event_types(stream(TailItem, gone.id)).last
      assert_same_answer(stream(TailItem, item.id), false)
      assert_same_answer(stream(TailItem, gone.id), true)
    end
  end

  # The types Lyra never replays, as Lyra writes them, have no operation.
  def test_the_types_skipped_in_the_query_are_never_replayed
    with_erasable_items do
      define_habtm_models
      use_mode(:disabled)
      item = TailHabtmItem.create!(label: "item")
      tag = TailHabtmTag.create!(name: "red")
      item.tags << tag
      item.tags.delete(tag)
      gone = TailItem.create!(label: "Ann").tap(&:destroy!)
      Lyra::Erasure.erase!(TailItem, gone.id, reason: "Art. 17 request")

      events = Lyra.config.event_store.read.of_type(Lyra::StreamTail::NEVER_REPLAYED.map { Object.const_get(_1) }).to_a
      assert_equal Lyra::StreamTail::NEVER_REPLAYED.sort, events.map(&:event_type).uniq.sort
      assert events.all? { Lyra::Event.operation_of(_1).nil? }
    end
  end

  # No write may be stored under one of those names.
  def test_writes_cannot_be_named_like_the_skipped_types
    assert_raises(ArgumentError) { Lyra::DomainEvents.rule(name: "AssociationLinked", on: :destroy) }
    assert_raises(ArgumentError) { Lyra::DomainEvents.rule(class: Lyra::Events::ErasureApplied, on: :destroy) }
    assert_raises(ArgumentError) { Lyra::ModelConfiguration.new(TailItem, event_mapping: { destroyed: "AssociationUnlinked" }) }
    assert Lyra::DomainEvents.rule(name: "AssociationArchived", on: :destroy)
  end

  # A popular record: hundreds of links in its stream. They are skipped in
  # the query, so the check stays one query, or a few behind a destroy.
  def test_hundreds_of_links_are_skipped_in_the_query
    use_mode(:disabled)
    tag = TailItem.create!(label: "popular")
    gone = TailItem.create!(label: "gone").tap(&:destroy!)
    [tag, gone].each { |record| 400.times { append(stream(TailItem, record.id), "AssociationLinked", operation: "linked") } }

    assert_equal 1, sql_during { refute Lyra::StreamTail.destroyed?(stream(TailItem, tag.id)) }.size
    assert_operator sql_during { assert Lyra::StreamTail.destroyed?(stream(TailItem, gone.id)) }.size, :<=, 3
    queries = sql_during { TailItem.find(tag.id).update!(label: "still popular") }
    assert_equal 1, queries.grep(/FROM "event_store_events_in_streams" s JOIN/).size, queries.join("\n")
    # 19 statements; walking the 400 links a page at a time would add 8.
    assert_operator queries.size, :<, 23, queries.join("\n")
  end

  # Additional events (not replayed, of any name) are walked past, a page
  # at a time.
  SERIALIZERS.each do |name, serializer|
    define_method("test_a_destroy_behind_more_than_a_page_of_additional_events_with_#{name}") do
      use_serializer(serializer.call)
      tail = stream(TailItem, 970)
      append(tail, "TailItemCreated", operation: :created)
      append(tail, "TailItemDestroyed", operation: :destroyed)
      (Lyra::StreamTail::PAGE + 1).times { append(tail, "TailItemArchived", operation: :destroyed, replay: false) }

      assert_same_answer(tail, true)
    end
  end

  # --- the first check: trying the query ------------------------------------

  # Every connection of the pool in use: the first write does not wait for
  # one to try the query.
  def test_the_first_write_does_not_wait_for_a_free_connection
    use_mode(:disabled)
    item = TailItem.create!(label: "a")
    Lyra::StreamTail.reset!
    pool = ActiveRecord::Base.connection_pool
    held = Queue.new
    release = Queue.new
    holders = Array.new(pool.size - 1) { Thread.new { pool.with_connection { held << true; release.pop } } }
    holders.size.times { held.pop }

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    TailItem.transaction { item.update!(label: "b") }

    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 1.0
    refute_nil Lyra::StreamTail.source_for(Lyra.config.event_store)
  ensure
    holders&.size&.times { release << true }
    holders&.each(&:join)
  end

  # Writers that make their first check together try the query once.
  def test_the_query_is_tried_once_by_concurrent_first_writers
    Lyra::StreamTail.reset!
    probes = 0
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      probes += 1 if payload[:name] == "Lyra stream tail probe"
    end
    store = Lyra.config.event_store
    Array.new(4) { Thread.new { with_connection { Lyra::StreamTail.source_for(store) } } }.each(&:join)

    assert_equal 1, probes
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  # --- store configurations ---------------------------------------------------

  # A json or jsonb data column gives the data back as a Hash: operation_of
  # decides from it, in the one query.
  def test_a_jsonb_data_column
    with_jsonb_data do
      updated = TailItem.create!(label: "a").tap { _1.update!(label: "b") }
      destroyed = TailItem.create!(label: "a").tap(&:destroy!)
      tail = stream(TailItem, 950)
      append(tail, "TailItemCreated", operation: :created)
      append(tail, "TailItemDestroyed", operation: :destroyed)
      append(tail, "TailItemArchived", operation: :destroyed, replay: false)

      assert_kind_of Hash, raw_data(stream(TailItem, updated.id))
      assert_same_answer(stream(TailItem, updated.id), false)
      assert_same_answer(stream(TailItem, destroyed.id), true)
      assert_same_answer(tail, true)
      assert_equal 1, sql_during { Lyra::StreamTail.destroyed?(stream(TailItem, updated.id)) }.size
      assert_equal 1, sql_during { Lyra::StreamTail.destroyed?(stream(TailItem, destroyed.id)) }.size
    end
  end

  def test_another_serializer_reads_through_rails_event_store
    use_serializer(Marshal)
    destroyed = TailItem.create!(label: "a").tap(&:destroy!)

    assert_nil Lyra::StreamTail.source_for(Lyra.config.event_store)
    assert_same_answer(stream(TailItem, destroyed.id), true)
  end

  def test_another_repository_reads_through_rails_event_store
    store = RailsEventStore::Client.new(repository: RubyEventStore::InMemoryRepository.new)
    store.publish(event_class("TailItemDestroyed").new(data: { model_class: "TailItem", model_id: 1, operation: :destroyed }),
                  stream_name: "TailItem$1")

    assert_nil Lyra::StreamTail.source_for(store)
    assert Lyra::StreamTail.destroyed?("TailItem$1", store)
    refute Lyra::StreamTail.destroyed?("TailItem$2", store)
  end

  # A mapper that transforms records on load can change the type and the
  # data operation_of sees: here an upcaster turns a stored TailItemRemoved
  # into a destroy.
  def test_another_mapper_reads_through_rails_event_store
    event_class("TailItemDestroyed")
    upcast = RubyEventStore::Mappers::Transformation::Upcast.new(
      "Lyra::Events::TailItemRemoved" => lambda { |record|
        RubyEventStore::Record.new(event_id: record.event_id, event_type: "Lyra::Events::TailItemDestroyed",
                                   data: record.data.merge(operation: :destroyed), metadata: record.metadata,
                                   timestamp: record.timestamp, valid_at: record.valid_at)
      }
    )
    pipeline = RubyEventStore::Mappers::Pipeline.new(upcast, RubyEventStore::Mappers::Transformation::SymbolizeMetadataKeys.new)
    use_serializer(RubyEventStore::Serializers::YAML,
                   mapper: RubyEventStore::Mappers::BatchMapper.new(RubyEventStore::Mappers::PipelineMapper.new(pipeline)))
    tail = stream(TailItem, 960)
    append(tail, "TailItemRemoved", operation: :updated)

    assert_nil Lyra::StreamTail.source_for(Lyra.config.event_store)
    assert_same_answer(tail, true)
  end

  def test_the_default_mapper_takes_the_shortcut_however_it_is_wrapped
    use_serializer(RubyEventStore::Serializers::YAML, mapper: RubyEventStore::Mappers::Default.new)

    refute_nil Lyra::StreamTail.source_for(Lyra.config.event_store)
  end

  # A Rails Event Store whose internals changed: resolved once, logged once,
  # and every check reads through Rails Event Store.
  def test_a_store_that_cannot_be_resolved_is_logged_once
    calls = 0
    Lyra::StreamTail.stubs(:resolve).with { calls += 1 }.raises(NoMethodError, "undefined method 'event_klass'")
    messages = capture_warnings do
      3.times { refute Lyra::StreamTail.destroyed?(stream(TailItem, 1)) }
    end

    assert_equal 1, calls, "resolved once"
    assert_equal 1, messages.size, messages.inspect
    assert_nil Lyra::StreamTail.source_for(Lyra.config.event_store)
  end

  # Without a connection the store is resolved again on the next check.
  def test_a_store_resolved_without_a_connection_is_tried_again
    calls = 0
    Lyra::StreamTail.stubs(:resolve).with { calls += 1 }.raises(ActiveRecord::ConnectionNotEstablished, "no connection")
    capture_warnings { 2.times { Lyra::StreamTail.source_for(Lyra.config.event_store) } }

    assert_equal 2, calls
  end

  # Tables whose columns changed (a Rails Event Store upgrade): the query is
  # tried in the first check, in a savepoint, so that its failure cannot
  # abort the write, which goes ahead with the read through Rails Event Store.
  def test_a_query_that_fails_does_not_break_a_write
    use_mode(:disabled)
    item = TailItem.create!(label: "a")
    Lyra::StreamTail.reset!
    Lyra::StreamTail.stubs(:select_from).returns(
      'SELECT s.id, e.event_id, e.event_type, e.payload FROM "event_store_events_in_streams" s ' \
      'JOIN "event_store_events" e ON e.event_id = s.event_id'
    )

    messages = capture_warnings do
      TailItem.transaction { item.update!(label: "b") }
    end

    assert_equal "b", TailItem.find(item.id).label
    assert_nil Lyra::StreamTail.source_for(Lyra.config.event_store)
    assert_match(/payload/, messages.join)
  end

  # --- the query ----------------------------------------------------------------

  def test_an_update_after_an_update_costs_one_query
    item = TailItem.create!(label: "a")
    item.update!(label: "b")
    Lyra::StreamTail.source_for(Lyra.config.event_store)

    queries = sql_during { refute Lyra::StreamTail.destroyed?(stream(TailItem, item.id)) }

    assert_equal 1, queries.size, queries.join("\n")
    assert_match(/\ASELECT s\.id, e\.event_id, e\.event_type, e\.data FROM "event_store_events_in_streams" s JOIN "event_store_events" e ON e\.event_id = s\.event_id AND e\.event_type NOT IN \('Lyra::Events::AssociationLinked', 'Lyra::Events::AssociationUnlinked', 'Lyra::Events::ErasureApplied'\) WHERE s\.stream = 'TailItem\$#{item.id}' ORDER BY s\.id DESC LIMIT 1\z/,
                 queries.first)
  end

  def test_a_destroyed_stream_is_confirmed_through_rails_event_store
    item = TailItem.create!(label: "a").tap(&:destroy!)
    Lyra::StreamTail.source_for(Lyra.config.event_store)

    queries = sql_during { assert Lyra::StreamTail.destroyed?(stream(TailItem, item.id)) }

    assert_match(/\ASELECT s\.id, e\.event_id, e\.event_type, e\.data FROM/, queries.first)
    assert_operator queries.size, :>, 1, "the last event is read through Rails Event Store"
  end

  # The tail is read past the query cache: a destroy committed by another
  # connection after an identical read is seen.
  def test_the_tail_is_never_read_from_the_query_cache
    item = TailItem.create!(label: "a")
    item.update!(label: "b")
    tail = stream(TailItem, item.id)

    ActiveRecord::Base.cache do
      refute Lyra::StreamTail.destroyed?(tail)
      Thread.new { with_connection { append(tail, "TailItemDestroyed", operation: :destroyed) } }.join

      assert Lyra::StreamTail.destroyed?(tail), "the second read reached the database"
    end
  end

  def test_an_update_in_each_checked_mode_reads_the_stream_tail_once
    CHECKED_MODES.each do |mode, projection|
      use_mode(projection)
      item = TailItem.create!(label: "a")
      item = TailItem.find(item.id)
      item.update!(label: "b")
      item = TailItem.find(item.id)

      queries = sql_during { item.update!(label: "c") }

      tail_reads = queries.grep(/FROM "event_store_events_in_streams" s JOIN "event_store_events" e/)
      assert_equal 1, tail_reads.size, "#{mode}: one tail read\n#{queries.join("\n")}"
      refute queries.any? { _1.match?(/FROM "event_store_events_in_streams" WHERE .*ORDER BY "event_store_events_in_streams"\."id" DESC LIMIT/) },
             "#{mode}: no backward read through Rails Event Store\n#{queries.join("\n")}"
    end
  end

  # --- the destroyed-record refusals, in the modes that take the check ------

  CHECKED_MODES.each do |mode, projection|
    define_method("test_a_write_to_a_destroyed_record_is_refused_in_#{mode}") do
      use_mode(projection)
      id = TailItem.create!(label: "a").id
      stale = TailItem.find(id)
      other = TailItem.find(id)
      TailItem.find(id).destroy!

      assert_raises(Lyra::RecordDestroyedError) { stale.update!(label: "late") }
      assert_raises(Lyra::RecordDestroyedError) { other.destroy! }
      assert_equal %i[created destroyed], operations(TailItem, id)
    end

    define_method("test_a_write_to_a_destroyed_sti_record_is_refused_in_#{mode}") do
      use_mode(projection)
      id = TailCar.create!(label: "a").id
      stale = TailCar.find(id)
      TailCar.find(id).destroy!

      assert_raises(Lyra::RecordDestroyedError) { stale.update!(label: "late") }
      assert_equal %i[created destroyed], operations(TailCar, id)
    end

    # A destroy that also emits an additional domain event (also:, replay:
    # false), which ends the stream.
    define_method("test_a_destroy_followed_by_an_additional_event_is_refused_in_#{mode}") do
      TailItem.monitor_with_lyra(domain_events: ARCHIVE_ON_DESTROY)
      Lyra.config.monitor_model(TailItem, domain_events: ARCHIVE_ON_DESTROY)
      use_mode(projection)
      id = TailItem.create!(label: "a").id
      stale = TailItem.find(id)
      TailItem.find(id).destroy!

      assert_equal "Lyra::Events::TailItemArchived", event_types(stream(TailItem, id)).last
      assert_raises(Lyra::RecordDestroyedError) { stale.update!(label: "late") }
      assert_equal %i[created destroyed] + [nil], operations(TailItem, id)
    end

    # An erasure after the destroy ends the stream with an ErasureApplied.
    define_method("test_a_destroy_followed_by_an_erasure_is_refused_in_#{mode}") do
      with_erasable_items do
        use_mode(projection)
        id = TailItem.create!(label: "Ann").id
        stale = TailItem.find(id)
        TailItem.find(id).destroy!
        Lyra::Erasure.erase!(TailItem, id, reason: "Art. 17 request")

        assert_equal "Lyra::Events::ErasureApplied", event_types(stream(TailItem, id)).last
        assert_raises(Lyra::RecordDestroyedError) { stale.update!(label: "late") }
        assert_equal %i[created destroyed] + [nil], operations(TailItem, id)
      end
    end

    # A has_and_belongs_to_many link made with a stale copy of a destroyed
    # tag is linked into the tag's stream after its destroy.
    define_method("test_a_destroy_followed_by_a_link_is_refused_in_#{mode}") do
      define_habtm_models
      use_mode(projection)
      item = TailHabtmItem.create!(label: "item")
      tag_id = TailHabtmTag.create!(name: "red").id
      stale = TailHabtmTag.find(tag_id)
      TailHabtmTag.find(tag_id).destroy!
      item.tags << stale

      assert_equal "Lyra::Events::AssociationLinked", event_types(stream(TailHabtmTag, tag_id)).last
      assert_raises(Lyra::RecordDestroyedError) { stale.update!(name: "late") }
    end

    # Two writers: a destroy holds the lock on the aggregate; an update of the
    # same record waits for it, then finds the stream ending in the destroy.
    define_method("test_an_update_waiting_on_a_destroy_is_refused_in_#{mode}") do
      use_mode(projection)
      id = TailItem.create!(label: "a").id
      # Loaded first: in ES-Lazy a read waits for the destroy to commit.
      stale = TailItem.find(id)
      destroyed = Queue.new
      commit = Queue.new

      destroyer = Thread.new do
        with_connection do
          TailItem.transaction do
            TailItem.find(id).destroy!
            destroyed << true
            commit.pop
          end
        end
      end
      destroyed.pop
      updater = Thread.new do
        with_connection do
          stale.update!(label: "late")
          :updated
        rescue Lyra::RecordDestroyedError
          :refused
        end
      end
      refute updater.join(0.5), "the update ran past the destroy's lock"

      commit << true
      destroyer.value
      assert_equal :refused, updater.value
      assert_equal %i[created destroyed], operations(TailItem, id)
    end

    # And the other way round: the destroy waits for the update and then goes ahead.
    define_method("test_a_destroy_waiting_on_an_update_goes_ahead_in_#{mode}") do
      use_mode(projection)
      id = TailItem.create!(label: "a").id
      stale = TailItem.find(id)
      updated = Queue.new
      commit = Queue.new

      updater = Thread.new do
        with_connection do
          TailItem.transaction do
            TailItem.find(id).update!(label: "b")
            updated << true
            commit.pop
          end
        end
      end
      updated.pop
      destroyer = Thread.new { with_connection { stale.destroy! } }
      refute destroyer.join(0.5), "the destroy ran past the update's lock"

      commit << true
      updater.value
      destroyer.value
      assert_equal %i[created updated destroyed], operations(TailItem, id)
    end
  end

  private

  # The answer from the whole stream: is its last replayed event a destroy?
  def full_answer(stream_name, store = Lyra.config.event_store)
    last = store.read.stream(stream_name).to_a.reverse.find { Lyra::Event.operation_of(_1) }
    !last.nil? && Lyra::Event.operation_of(last) == :destroyed
  end

  def assert_same_answer(stream_name, expected)
    assert_equal expected, full_answer(stream_name), "the whole stream #{stream_name}"
    assert_equal expected, Lyra::StreamTail.destroyed?(stream_name), "the check on #{stream_name}"
    assert_equal expected, Lyra::StreamTail.destroyed_by_reading?(stream_name), "the read through RES on #{stream_name}"
  end

  def assert_shortcut_taken
    refute_nil Lyra::StreamTail.source_for(Lyra.config.event_store), "the shortcut applies to this store"
  end

  def use_serializer(serializer, mapper: nil)
    options = { repository: RubyEventStore::ActiveRecord::EventRepository.new(serializer: serializer) }
    options[:mapper] = mapper if mapper
    Lyra.config.event_store = RailsEventStore::Client.new(**options)
  end

  def use_mode(projection)
    Lyra.config.enable_event_sourcing!
    Lyra.config.projection_mode = projection
  end

  def event_class(type)
    Lyra::Events.const_defined?(type, false) ? Lyra::Events.const_get(type, false) : Lyra::Events.const_set(type, Class.new(Lyra::Event))
  end

  # An event as Lyra writes one (Lyra::EventData's envelope), under +type+.
  def append(stream_name, type, operation:, replay: nil)
    data = { model_class: "TailItem", model_id: stream_name.split("$").last.to_i, attributes: { label: "a" }, changes: {} }
    data[:operation] = operation if operation
    data[:replay] = replay unless replay.nil?
    Lyra.append_events(event_class(type).new(data: data), stream_name: stream_name)
  end

  def raw_data(stream_name)
    Lyra::StreamTail.event_rows(Lyra::StreamTail.source_for(Lyra.config.event_store), stream_name).first.last
  end

  def with_erasable_items
    skip "Requires pam_dsl" unless Lyra.pam_dsl_available?

    PamDsl.reset!
    PamDsl.define_policy(:tail_policy) do
      field :label, type: :name
      purpose(:contact) { basis :contract }
    end
    TailItem.monitor_with_lyra(privacy_policy: :tail_policy)
    Lyra.config.monitor_model(TailItem, privacy_policy: :tail_policy)
    yield
  ensure
    PamDsl.reset! if defined?(PamDsl)
  end

  # The event store's data column as jsonb, with the JSON serializer.
  def with_jsonb_data
    clean
    connection.execute("ALTER TABLE event_store_events ALTER COLUMN data TYPE jsonb USING convert_from(data, 'UTF8')::jsonb")
    reset_event_columns
    use_serializer(JSON)
    yield
  ensure
    clean
    connection.execute("ALTER TABLE event_store_events ALTER COLUMN data TYPE bytea USING convert_to(data::text, 'UTF8')")
    reset_event_columns
  end

  def reset_event_columns
    ActiveRecord::Base.descendants.select { _1.table_name == "event_store_events" }.each(&:reset_column_information)
  end

  def define_habtm_models
    connection.create_table(ITEMS, force: true) { |t| t.string :label; t.timestamps }
    connection.create_table(TAGS, force: true) { |t| t.string :name; t.timestamps }
    connection.create_table(JOIN, id: false, force: true) do |t|
      t.bigint :item_id, null: false
      t.bigint :tag_id, null: false
    end
    %i[TailHabtmItem TailHabtmTag].each { Object.send(:remove_const, _1) if Object.const_defined?(_1) }
    Object.const_set(:TailHabtmItem, Class.new(ActiveRecord::Base))
    Object.const_set(:TailHabtmTag, Class.new(ActiveRecord::Base))
    TailHabtmItem.class_eval do
      self.table_name = ITEMS
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
      has_and_belongs_to_many :tags, class_name: "TailHabtmTag", join_table: JOIN,
                                     foreign_key: :item_id, association_foreign_key: :tag_id
    end
    TailHabtmTag.class_eval do
      self.table_name = TAGS
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
      has_and_belongs_to_many :items, class_name: "TailHabtmItem", join_table: JOIN,
                                      foreign_key: :tag_id, association_foreign_key: :item_id
    end
    [TailHabtmItem, TailHabtmTag].each(&:reset_column_information)
    Lyra.config.monitor_model(TailHabtmItem)
    Lyra.config.monitor_model(TailHabtmTag)
  end

  def capture_warnings
    messages = []
    Rails.logger.stubs(:warn).with { |message| messages << message.to_s if message.to_s.include?("destroyed check"); true }
    yield
    messages
  ensure
    Rails.logger.unstub(:warn)
  end

  # The statements this thread sends in the block, without schema queries,
  # transaction control and statements on Solid Cache's table. Only this
  # thread's: after a cache write, Solid Cache may estimate its size and
  # expire entries on a background thread of its own (SELECT max(id) -
  # min(id) + 1 FROM solid_cache_entries), at any later moment.
  def sql_during(&block)
    queries = []
    thread = Thread.current
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      next unless Thread.current == thread
      next if payload[:name] == "SCHEMA" || payload[:sql].match?(/\A\s*(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/)
      next if payload[:sql].include?("solid_cache_entries")

      queries << payload[:sql]
    end
    block.call
    queries
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  def stream(model, id) = Lyra.stream_name(model, id)

  def event_types(stream_name) = Lyra.config.event_store.read.stream(stream_name).map(&:event_type)

  def operations(model, id)
    Lyra.config.event_store.read.stream(stream(model, id)).to_a.map { Lyra::Event.operation_of(_1) }
  end

  def define_model(name, table)
    Object.send(:remove_const, name) if Object.const_defined?(name)
    klass = Class.new(ActiveRecord::Base)
    Object.const_set(name, klass)
    klass.table_name = table
    klass.include Lyra::Interceptors::CrudInterceptor
    klass.monitor_with_lyra
    klass.reset_column_information
    Lyra.config.monitor_model(klass)
  end

  def with_connection(&block) = ActiveRecord::Base.connection_pool.with_connection(&block)

  def clean
    connection.execute("DELETE FROM event_store_events_in_streams")
    connection.execute("DELETE FROM event_store_events")
  end

  def connection = ActiveRecord::Base.connection
end
