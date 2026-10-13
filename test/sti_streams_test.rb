# frozen_string_literal: true

require "test_helper"

# Single-table inheritance: one stream per row, named after the table's class
# (Lyra.stream_name), whatever the record's concrete class, so readers given
# the base class or a subclass find it (issue #16). Before, events went to the
# concrete class's stream and readers given the base class found none.
class StiStreamsTest < Minitest::Test
  TABLE = "lyra_sti_items"

  def setup
    skip "Requires Rails and PostgreSQL" unless defined?(ActiveRecord::Base) && connection.adapter_name.match?(/postgres/i)

    connection.create_table(TABLE, force: true) do |t|
      t.string :type
      t.string :label
      t.timestamps
    end
    %i[StiDeluxe StiSpecial StiItem].each { |c| Object.send(:remove_const, c) if Object.const_defined?(c) }
    Object.const_set(:StiItem, Class.new(ActiveRecord::Base) do
      self.table_name = TABLE
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
    end)
    Object.const_set(:StiSpecial, Class.new(StiItem))
    Object.const_set(:StiDeluxe, Class.new(StiSpecial))
    StiItem.reset_column_information
    clean
    Rails.cache.clear
    Lyra.config.monitor_model(StiItem)
  end

  def teardown
    return unless defined?(StiItem)

    Lyra.reset_config!
    clean
    connection.drop_table(TABLE, if_exists: true)
  end

  def test_an_events_class_name_resolves_to_its_model_through_the_base_class
    assert_equal StiItem, Lyra.config.monitored_model_named("StiItem")
    assert_equal StiDeluxe, Lyra.config.monitored_model_named("StiDeluxe"), "a subclass of a monitored base"
    assert_nil Lyra.config.monitored_model_named("String")
    assert_nil Lyra.config.monitored_model_named("NoSuchClass")
  end

  def test_the_stream_is_named_after_the_tables_class
    assert_equal "StiItem$7", Lyra.stream_name(StiDeluxe, 7)
    assert_equal "StiItem$", Lyra.stream_prefix(StiSpecial)
    assert_equal "StiItem$7", Lyra.stream_name(StiItem, 7)
  end

  def test_every_mode_files_a_subclass_records_events_under_the_base_stream
    %i[monitor hijack es_sync es_async es_lazy es_noproj].each do |mode|
      use(mode)
      record = StiSpecial.create!(label: "a")
      StiSpecial.find(record.id).update!(label: "b")

      assert_equal 2, events("StiItem$#{record.id}").size, "#{mode}: created and updated, in the base stream"
      assert_empty events("StiSpecial$#{record.id}"), "#{mode}: nothing in the subclass's stream"
      next if mode == :es_noproj

      [StiItem, StiSpecial].each do |reader|
        assert_equal({ no_differences: true }, Lyra::DualView.new(reader, record.id).calculate_differences,
                     "#{mode}: DualView given #{reader.name}")
      end
    end
  end

  # ES-NoProj answers from the events: a subclass sees its own records and
  # its subclasses', the base class sees all, as ActiveRecord's type
  # condition decides with tables.
  def test_es_noproj_reads_respect_the_hierarchy
    use(:es_noproj)
    plain = StiItem.create!(label: "plain")
    special = StiSpecial.create!(label: "special")
    deluxe = StiDeluxe.create!(label: "deluxe")

    assert_instance_of StiSpecial, StiItem.find(special.id)
    assert_equal %w[deluxe plain special], StiItem.all.map(&:label).sort
    assert_equal %w[deluxe special], StiSpecial.all.map(&:label).sort
    assert_equal %w[deluxe], StiDeluxe.all.map(&:label)
    assert_raises(ActiveRecord::RecordNotFound) { StiDeluxe.find(special.id) }
    assert_nil StiSpecial.find_by(id: plain.id)
    assert_equal "deluxe", StiSpecial.find(deluxe.id).label
  end

  def test_a_rebuild_from_the_base_class_restores_every_subclass_row
    use(:es_sync)
    special = StiSpecial.create!(label: "s")
    deluxe = StiDeluxe.create!(label: "d")
    connection.execute("DELETE FROM #{TABLE}")

    Lyra::Projections::Rebuild.rebuild(StiItem)

    rows = connection.select_rows("SELECT id, type, label FROM #{TABLE} ORDER BY id").map { |id, type, label| [id.to_i, type, label] }
    assert_equal [[special.id, "StiSpecial", "s"], [deluxe.id, "StiDeluxe", "d"]], rows
  end

  # Event stores written before: a subclass record's events in the subclass's
  # stream are linked into the base stream, in order, once.
  def test_the_migration_links_legacy_subclass_streams_into_the_base_stream
    use(:monitor)
    record = StiSpecial.create!(label: "a")
    legacy = "StiSpecial$#{record.id}"
    base = "StiItem$#{record.id}"
    ids = events(base).map(&:event_id)
    move_events(base, legacy) # as an older Lyra wrote them

    dry = Lyra::StiStreamMigration.run!(dry_run: true)
    assert_equal 1, dry[:linked]
    assert_empty events(base)

    result = Lyra::StiStreamMigration.run!
    assert_equal({ streams: 1, linked: 1, already: 0, conflicts: [] }, result)
    assert_equal ids, events(base).map(&:event_id)

    again = Lyra::StiStreamMigration.run!
    assert_equal 0, again[:linked]
    assert_equal 1, again[:already]
  end

  def test_the_migration_reports_a_base_stream_that_already_has_newer_events
    use(:monitor)
    record = StiSpecial.create!(label: "a")
    base = "StiItem$#{record.id}"
    move_events(base, "StiSpecial$#{record.id}")
    StiSpecial.find(record.id).update!(label: "b") # written after the upgrade, to the base stream

    result = Lyra::StiStreamMigration.run!

    assert_equal ["StiSpecial$#{record.id}"], result[:conflicts]
    assert_equal 0, result[:linked]
  end

  private

  def use(mode)
    LyraConfigIsolation.install_fresh_config
    Lyra.config.monitor_model(StiItem)
    Lyra::Projections::ReferenceLinks.reset!
    case mode
    when :monitor then Lyra.config.enable_monitor!
    when :hijack then Lyra.config.enable_hijack!
    else
      Lyra.config.enable_event_sourcing!
      Lyra.config.projection_mode = { es_sync: :sync, es_async: :async, es_lazy: :lazy, es_noproj: :disabled }.fetch(mode)
      Lyra.config.async_projections_inline = true
    end
  end

  def events(stream)
    Lyra.config.event_store.read.stream(stream).to_a
  rescue RubyEventStore::EventNotFoundInStream
    []
  end

  # Re-file +from+'s events under +to+ only, as an event store written before
  # this change holds them.
  def move_events(from, to)
    connection.execute("UPDATE event_store_events_in_streams SET stream = #{connection.quote(to)} " \
                       "WHERE stream = #{connection.quote(from)}")
  end

  def connection = ActiveRecord::Base.connection

  def clean
    connection.execute("DELETE FROM event_store_events_in_streams")
    connection.execute("DELETE FROM event_store_events")
  end
end
