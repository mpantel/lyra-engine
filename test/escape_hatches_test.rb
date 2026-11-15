# frozen_string_literal: true

require "test_helper"

# Lyra's escape hatches (1.0.0). Lyra.projection_write and
# PurposeBoundReads.internal switch off the checks that keep every write in the log
# and every read under its purpose: they are for Lyra's own code. Application code
# that needs to write without events uses Lyra.unrecorded_write, which asks for a
# reason and records that it happened.
class EscapeHatchesTest < Minitest::Test
  TABLE = "lyra_hatch_items"

  def setup
    skip "Requires Rails and PostgreSQL" unless defined?(ActiveRecord::Base) && connection.adapter_name.match?(/postgres/i)

    connection.create_table(TABLE, force: true) do |t|
      t.string :label
      t.timestamps
    end
    Object.send(:remove_const, :HatchItem) if defined?(HatchItem)
    klass = Class.new(ActiveRecord::Base)
    Object.const_set(:HatchItem, klass)
    klass.table_name = TABLE
    klass.include Lyra::Interceptors::CrudInterceptor
    klass.monitor_with_lyra
    klass.reset_column_information
    clean
    Lyra.config.monitor_model(klass)
    Lyra.config.enable_hijack!
    Lyra.config.strict_data_access = true
    @item = HatchItem.create!(label: "a")
  end

  def teardown
    return unless defined?(HatchItem)

    Lyra.reset_config!
    clean
    connection.drop_table(TABLE, if_exists: true)
  end

  def test_application_code_cannot_call_projection_write
    error = assert_raises(Lyra::InternalApiError) { Lyra.projection_write { HatchItem.update_all(label: "x") } }

    assert_match(/unrecorded_write/, error.message, "the error says what to use instead")
    assert_equal "a", @item.reload.label, "the block did not run"
  end

  def test_application_code_cannot_call_purpose_bound_reads_internal
    assert_raises(Lyra::InternalApiError) { Lyra::PurposeBoundReads.internal { HatchItem.first } }
  end

  def test_the_token_is_not_a_public_constant
    assert_raises(NameError) { Lyra::INTERNAL }
  end

  def test_strict_mode_still_refuses_a_bulk_write
    assert_raises(Lyra::StrictDataAccessViolation) { HatchItem.update_all(label: "x") }
  end

  def test_an_unrecorded_write_changes_the_row_and_leaves_no_event_for_it
    before = events_of(@item).size

    Lyra.unrecorded_write(reason: "reseeding the fixtures") { HatchItem.update_all(label: "seeded") }

    assert_equal "seeded", @item.reload.label
    assert_equal before, events_of(@item).size, "the change itself is not in the record's stream"
  end

  def test_an_unrecorded_write_is_itself_recorded_with_its_reason_and_where_it_was_called
    Lyra.unrecorded_write(reason: "reseeding the fixtures") { HatchItem.update_all(label: "seeded") }

    event = Lyra.config.event_store.read.stream(Lyra::UNRECORDED_WRITES_STREAM).to_a.sole
    assert_kind_of Lyra::Events::UnrecordedWrite, event
    assert_equal "reseeding the fixtures", event.data[:reason]
    assert_match(/escape_hatches_test\.rb:\d+/, event.data[:called_from], "the caller, not a Lyra frame")
    assert_equal "lyra_unrecorded_write", event.metadata[:source]
  end

  def test_a_reason_and_a_block_are_required
    assert_raises(ArgumentError) { Lyra.unrecorded_write(reason: "") { 1 } }
    assert_raises(ArgumentError) { Lyra.unrecorded_write(reason: "  ") { 1 } }
    assert_raises(ArgumentError) { Lyra.unrecorded_write(reason: "wipe") }
    assert_empty Lyra.config.event_store.read.stream(Lyra::UNRECORDED_WRITES_STREAM).to_a
  end

  def test_deny_refuses_the_write_and_records_nothing
    Lyra.config.unrecorded_writes = :deny
    ran = false

    assert_raises(Lyra::UnrecordedWriteDenied) { Lyra.unrecorded_write(reason: "seed") { ran = true } }

    refute ran
    assert_empty Lyra.config.event_store.read.stream(Lyra::UNRECORDED_WRITES_STREAM).to_a
  end

  def test_the_mode_is_validated
    assert_raises(ArgumentError) { Lyra.config.unrecorded_writes = :sometimes }
    assert_equal :allow, Lyra::Configuration.new.unrecorded_writes
  end

  def test_nothing_is_recorded_in_disabled_mode
    Lyra.config.disable!

    Lyra.unrecorded_write(reason: "seed") { HatchItem.update_all(label: "x") }

    assert_empty Lyra.config.event_store.read.stream(Lyra::UNRECORDED_WRITES_STREAM).to_a
  end

  # A refused call leaves the flags of the block it was called in as they were.
  def test_a_refused_projection_write_keeps_the_outer_blocks_flags
    Lyra.projection_write(lyra_internal) do
      assert_raises(Lyra::InternalApiError) { Lyra.projection_write { 1 } }

      assert Thread.current[:lyra_projection_write], "the outer projection write is still on"
      assert Thread.current[:lyra_bypass_strict_access]
    end
  end

  def test_a_refused_internal_read_keeps_the_outer_blocks_flag
    Lyra::PurposeBoundReads.internal(lyra_internal) do
      assert_raises(Lyra::InternalApiError) { Lyra::PurposeBoundReads.internal { 1 } }

      assert Thread.current[:lyra_internal_read], "the outer internal read is still on"
    end
  end

  # ModelProjection writes the table without events, as projection_write does:
  # only Lyra calls it.
  def test_application_code_cannot_project_into_the_table
    result = Struct.new(:events, :attributes, :success?, keyword_init: true)
                   .new(events: [], attributes: { id: @item.id, "label" => "x" }, success?: true)

    assert_raises(Lyra::InternalApiError) { Lyra::Projections::ModelProjection.project(HatchItem, :update, result) }
    assert_raises(NoMethodError) { Lyra::Projections::ModelProjection.project_update(HatchItem, result) }
    assert_raises(NoMethodError) { Lyra::Projections::ModelProjection.project_destroy(HatchItem, result) }
    assert_raises(NoMethodError) { Lyra::Projections::ModelProjection.project_create(HatchItem, result) }
    assert_equal "a", @item.reload.label
  end

  private

  def events_of(item) = Lyra.config.event_store.read.stream(Lyra.stream_name(HatchItem, item.id)).to_a

  def clean
    connection.execute("DELETE FROM event_store_events_in_streams")
    connection.execute("DELETE FROM event_store_events")
  end

  def connection = ActiveRecord::Base.connection
end
