# frozen_string_literal: true

require "test_helper"

# One event shape in every mode (Lyra::EventData, 1.0.0): the same create,
# update and destroy leave the same envelope in Monitor, Hijack and event
# sourcing, and what reads an event's fields finds the same ones.
class EventShapeTest < Minitest::Test
  TABLE = "lyra_shape_items"
  MODES = %i[monitor hijack es_sync es_noproj].freeze
  ENVELOPE = %w[attributes changes model_class model_id operation timestamp].freeze

  def setup
    skip "Requires Rails and PostgreSQL" unless defined?(ActiveRecord::Base) && connection.adapter_name.match?(/postgres/i)

    connection.create_table(TABLE, force: true) do |t|
      t.string :label
      t.string :email
      t.timestamps
    end
    Object.send(:remove_const, :ShapeItem) if defined?(ShapeItem)
    klass = Class.new(ActiveRecord::Base)
    Object.const_set(:ShapeItem, klass) # named before it is monitored: event names come from the name
    klass.table_name = TABLE
    klass.include Lyra::Interceptors::CrudInterceptor
    klass.monitor_with_lyra
    klass.reset_column_information
    clean
    Lyra.config.monitor_model(klass)
  end

  def teardown
    return unless defined?(ShapeItem)

    Lyra.reset_config!
    clean
    connection.drop_table(TABLE, if_exists: true)
  end

  MODES.each do |mode|
    define_method("test_a_create_carries_the_record_and_no_changes_in_#{mode}") do
      event = write_in(mode, :created)

      assert_equal ENVELOPE, data_of(event).keys.map(&:to_s).sort
      assert_equal %w[created_at email id label updated_at], attributes_of(event).keys.map(&:to_s).sort
      assert_empty changes_of(event)
    end

    define_method("test_an_update_carries_its_changes_only_in_#{mode}") do
      event = write_in(mode, :updated)

      assert_equal ENVELOPE, data_of(event).keys.map(&:to_s).sort
      assert_empty attributes_of(event), "the record is not repeated on an update"
      assert_equal %w[email updated_at], changes_of(event).keys.map(&:to_s).sort
      assert_equal %w[a@example.com b@example.com], changes_of(event)["email"] || changes_of(event)[:email]
    end

    define_method("test_a_destroy_carries_neither_in_#{mode}") do
      event = write_in(mode, :destroyed)

      assert_equal ENVELOPE, data_of(event).keys.map(&:to_s).sort
      assert_empty attributes_of(event)
      assert_empty changes_of(event)
    end

    define_method("test_every_event_names_its_source_in_#{mode}") do
      event = write_in(mode, :updated)

      refute_nil event.metadata[:source], "the builder that wrote the event is recorded in every mode"
    end

    define_method("test_an_application_source_wins_over_lyra_s_in_#{mode}") do
      Lyra.config.metadata_proc = ->(_record, _operation) { { source: "my_app", tenant: "t1" } }
      event = write_in(mode, :updated)

      assert_equal %w[my_app t1], event.metadata.to_h.values_at(:source, :tenant), "metadata_proc's keys win, source included"
    ensure
      Lyra.config.metadata_proc = nil
    end

    define_method("test_personal_data_is_found_in_an_update_in_#{mode}") do
      skip "Requires PAM DSL" unless Lyra.privacy_features_available?

      event = write_in(mode, :updated)

      assert_equal %w[b@example.com], [Lyra::Event.fields_of(event)["email"] || Lyra::Event.fields_of(event)[:email]]
      refute_empty Lyra::Privacy::PIIDetector.detect(Lyra::Event.fields_of(event)), "an update that changes an email touches personal data"
    end
  end

  def test_an_update_never_nests_its_changes_in_its_attributes
    MODES.each do |mode|
      clean
      event = write_in(mode, :updated)

      refute attributes_of(event).key?("changes") || attributes_of(event).key?(:changes), "#{mode}: no changes key among the attributes"
    end
  end

  # fields_of on the shapes older versions wrote
  def test_fields_of_reads_a_legacy_monitor_update_from_its_changes
    legacy = event(operation: :updated, attributes: { "id" => 1, "email" => "b@example.com", "name" => "Ann" },
                   changes: { "email" => ["a@example.com", "b@example.com"] })

    assert_equal({ "email" => "b@example.com" }, Lyra::Event.fields_of(legacy))
  end

  def test_fields_of_reads_a_legacy_destroy_from_its_attributes
    legacy = event(operation: :destroyed, attributes: { "id" => 1, "email" => "a@example.com" }, changes: {})

    assert_equal({ "id" => 1, "email" => "a@example.com" }, Lyra::Event.fields_of(legacy))
  end

  # Timestamps are ordinary columns from 1.0.0: a create gives what its
  # attributes hold, and nothing is recovered from its changes.
  def test_fields_of_a_create_is_its_attributes
    created = event(operation: :created, attributes: { "id" => 1, "created_at" => Time.utc(2026, 1, 1) }, changes: {})

    assert_equal({ "id" => 1, "created_at" => Time.utc(2026, 1, 1) }, Lyra::Event.fields_of(created))
  end

  def test_fields_of_an_object_without_data_is_its_attributes
    plain = Struct.new(:attributes).new({ "email" => "a@example.com" })

    assert_equal({ "email" => "a@example.com" }, Lyra::Event.fields_of(plain))
  end

  def test_event_data_applies_the_shape_to_every_operation
    attrs = { "id" => 1, "label" => "x" }
    delta = { "label" => %w[x y] }

    assert_equal attrs,  Lyra::EventData.build(ShapeItem, 1, :created, attributes: attrs, changes: delta)[:attributes]
    assert_equal({},     Lyra::EventData.build(ShapeItem, 1, :created, attributes: attrs, changes: delta)[:changes])
    assert_equal attrs,  Lyra::EventData.build(ShapeItem, 1, :imported, attributes: attrs)[:attributes]
    assert_equal({},     Lyra::EventData.build(ShapeItem, 1, :updated, attributes: attrs, changes: delta)[:attributes])
    assert_equal delta,  Lyra::EventData.build(ShapeItem, 1, :updated, attributes: attrs, changes: delta)[:changes]
    assert_equal({},     Lyra::EventData.build(ShapeItem, 1, :destroyed, attributes: attrs, changes: delta)[:attributes])
    assert_equal({},     Lyra::EventData.build(ShapeItem, 1, :destroyed, attributes: attrs, changes: delta)[:changes])
  end

  private

  # The write that makes the event, in +mode+; returns the event of +operation+.
  def write_in(mode, operation)
    use(mode)
    item = ShapeItem.create!(label: "x", email: "a@example.com")
    item.update!(email: "b@example.com") if %i[updated destroyed].include?(operation)
    item.destroy! if operation == :destroyed
    events = Lyra.config.event_store.read.stream(Lyra.stream_name(ShapeItem, item.id)).to_a
    events.reverse.find { |e| Lyra::Event.operation_of(e) == operation } or flunk("no #{operation} event in #{mode}")
  end

  def use(mode)
    case mode
    when :monitor then Lyra.config.enable_monitor!
    when :hijack then Lyra.config.enable_hijack!
    else
      Lyra.config.enable_event_sourcing!
      Lyra.config.projection_mode = mode == :es_sync ? :sync : :disabled
    end
  end

  def event(operation:, attributes:, changes:)
    RubyEventStore::Event.new(data: { model_class: "ShapeItem", model_id: 1, operation: operation,
                                      attributes: attributes, changes: changes })
  end

  def data_of(event) = event.data
  def attributes_of(event) = event.data[:attributes] || event.data["attributes"] || {}
  def changes_of(event) = event.data[:changes] || event.data["changes"] || {}

  def clean
    connection.execute("DELETE FROM event_store_events_in_streams")
    connection.execute("DELETE FROM event_store_events")
  end

  def connection = ActiveRecord::Base.connection
end
