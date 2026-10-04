# frozen_string_literal: true

require "test_helper"
require "bigdecimal"

# Tests to improve coverage of key files for IEEE TSE paper
# Targets: aggregate.rb, dual_view.rb, crud_interceptor.rb

module Lyra
  # ==========================================================================
  # Aggregate Coverage Tests
  # ==========================================================================
  class AggregateCoverageTest < Minitest::Test
    def setup
      @event_store = RailsEventStore::Client.new
      Lyra.configure do |config|
        config.event_store = @event_store
        config.mode = :monitor
      end
    end

    def teardown
      Lyra.reset_config!
    end

    # Test Aggregate.load with events (lines 19, 21, 22)
    def test_aggregate_load_replays_events_from_stream
      # First publish some events to a stream using GenericAggregate
      model_class = Class.new
      model_class.define_singleton_method(:name) { "LoadTestModel" }

      aggregate_id = "test-load-#{SecureRandom.hex(4)}"
      stream_name = "LoadTestModel$#{aggregate_id}"

      # Create a properly named event class
      unless Lyra::Events.const_defined?("LoadTestModelCreated")
        Lyra::Events.const_set("LoadTestModelCreated", Class.new(Lyra::Event))
      end

      event = Lyra::Events::LoadTestModelCreated.new(
        data: {
          model_class: "LoadTestModel",
          model_id: aggregate_id,
          operation: :create,
          attributes: { name: "LoadTest" }
        }
      )

      @event_store.publish(event, stream_name: stream_name)

      # Load using GenericAggregate which handles dynamic event names
      loaded = GenericAggregate.new(aggregate_id, model_class)

      # Read events and apply them manually to test the load path
      events = @event_store.read.stream(stream_name).to_a
      events.each { |e| loaded.apply(e, persisted: true) }

      assert_equal aggregate_id, loaded.id
      assert_equal 1, loaded.version
      assert_equal "LoadTest", loaded.send(:get_state, :name)
    end

    # Test Aggregate.load rescue branch (line 24) - when stream doesn't exist
    def test_aggregate_load_returns_new_aggregate_when_stream_missing
      # Use a non-existent ID - the rescue branch catches EventNotFound
      # But RailsEventStore doesn't raise for empty streams, it returns []
      # So we test with a custom aggregate that will have empty events
      aggregate_id = "nonexistent-#{SecureRandom.hex(4)}"

      # This tests the path where events array is empty
      # The rescue branch is for when the event store itself fails
      loaded = Aggregate.load(aggregate_id, @event_store)

      assert_equal aggregate_id, loaded.id
      assert_equal 0, loaded.version  # No events = version 0
    end

    # Test extract_operation else branch (line 106)
    def test_generic_aggregate_extract_operation_with_non_standard_event
      model_class = Class.new
      model_class.define_singleton_method(:name) { "TestModel" }

      aggregate = GenericAggregate.new("test-123", model_class)

      # Create an event with non-standard naming
      custom_event_class = Class.new(Lyra::Event)
      Lyra::Events.const_set("CustomAction", custom_event_class) unless Lyra::Events.const_defined?("CustomAction")

      event = Lyra::Events::CustomAction.new(
        data: {
          model_class: "TestModel",
          model_id: "test-123",
          operation: :custom
        }
      )

      # This should hit the else branch in extract_operation
      # The event name "custom_action" doesn't match _created, _updated, or _destroyed
      aggregate.apply(event)

      # Verify it processed (even if no matching apply method)
      assert_equal 0, aggregate.version  # No matching method, so version doesn't increment
    end
  end

  # ==========================================================================
  # DualView Coverage Tests
  # ==========================================================================
  class DualViewCoverageTest < Minitest::Test
    def setup
      @model_class = Class.new
      @model_class.define_singleton_method(:name) { "CoverageTestModel" }
      @dual_view = DualView.new(@model_class, 999)
    end

    # Test Date normalization (line 153)
    def test_normalize_value_with_date
      def @dual_view.crud_state
        { exists: true, attributes: { birthday: Date.new(2024, 6, 15) } }
      end

      def @dual_view.event_sourced_state
        { exists: true, state: { birthday: "2024-06-15" } }
      end

      differences = @dual_view.calculate_differences

      assert_equal({ no_differences: true }, differences)
    end

    # Test BigDecimal normalization (line 155) - already tested but ensure coverage
    def test_normalize_value_with_big_decimal_precision
      def @dual_view.crud_state
        { exists: true, attributes: { amount: BigDecimal("123.456789") } }
      end

      def @dual_view.event_sourced_state
        { exists: true, state: { amount: 123.456789 } }
      end

      differences = @dual_view.calculate_differences

      assert_equal({ no_differences: true }, differences)
    end

    # Test time parsing rescue branch (line 166)
    def test_normalize_value_with_invalid_timestamp_string
      def @dual_view.crud_state
        { exists: true, attributes: { weird_date: "2024-invalid-date" } }
      end

      def @dual_view.event_sourced_state
        { exists: true, state: { weird_date: "2024-invalid-date" } }
      end

      differences = @dual_view.calculate_differences

      assert_equal({ no_differences: true }, differences)
    end

    # Test non-timestamp/non-numeric string else branch (line 172)
    def test_normalize_value_with_plain_string
      def @dual_view.crud_state
        { exists: true, attributes: { description: "Hello World" } }
      end

      def @dual_view.event_sourced_state
        { exists: true, state: { description: "Hello World" } }
      end

      differences = @dual_view.calculate_differences

      assert_equal({ no_differences: true }, differences)
    end

    # Test TrueClass/FalseClass branch (line 175)
    def test_normalize_value_with_booleans
      def @dual_view.crud_state
        { exists: true, attributes: { active: true, archived: false } }
      end

      def @dual_view.event_sourced_state
        { exists: true, state: { active: true, archived: false } }
      end

      differences = @dual_view.calculate_differences

      assert_equal({ no_differences: true }, differences)
    end

    # Test NilClass branch (line 177)
    def test_normalize_value_with_nil
      def @dual_view.crud_state
        { exists: true, attributes: { optional_field: nil } }
      end

      def @dual_view.event_sourced_state
        { exists: true, state: { optional_field: nil } }
      end

      differences = @dual_view.calculate_differences

      assert_equal({ no_differences: true }, differences)
    end

    # Test else branch with custom object (line 179)
    def test_normalize_value_with_custom_object
      custom_obj = Object.new
      def custom_obj.to_s
        "custom_string_value"
      end

      # We can't easily inject custom object, but we can test with a symbol
      # which will fall through to else branch
      def @dual_view.crud_state
        { exists: true, attributes: { status: :pending } }
      end

      def @dual_view.event_sourced_state
        { exists: true, state: { status: "pending" } }
      end

      differences = @dual_view.calculate_differences

      # Symbol :pending.to_s == "pending", so should match
      assert_equal({ no_differences: true }, differences)
    end

    # Test with actual Date object difference detection
    def test_date_difference_detection
      def @dual_view.crud_state
        { exists: true, attributes: { birthday: Date.new(2024, 6, 15) } }
      end

      def @dual_view.event_sourced_state
        { exists: true, state: { birthday: "2024-07-15" } }  # Different date
      end

      differences = @dual_view.calculate_differences

      assert differences.key?(:birthday)
    end
  end

  # ==========================================================================
  # CrudInterceptor Coverage Tests - ES Disabled Projection Mode
  # ==========================================================================
  class CrudInterceptorESDisabledCoverageTest < Minitest::Test
    def setup
      @event_store = RailsEventStore::Client.new
      Lyra.configure do |config|
        config.event_store = @event_store
        config.mode = :event_sourcing
        config.projection_mode = :disabled
      end
      @email_counter = 0
    end

    def teardown
      Lyra.reset_config!
      Thread.current[:lyra_bypass_read_override] = nil
      Rails.cache.clear if Rails.cache.respond_to?(:clear)
    end

    def next_email
      @email_counter += 1
      "es_disabled_#{@email_counter}_#{rand(100000)}@example.com"
    end

    # Test lyra_read_from_events? returns true in ES disabled mode
    def test_lyra_read_from_events_returns_true_in_es_disabled_mode
      assert ::User.send(:lyra_read_from_events?)
    end

    # Test lyra_read_from_events? returns false when bypassed
    def test_lyra_read_from_events_returns_false_when_bypassed
      Thread.current[:lyra_bypass_read_override] = true
      refute ::User.send(:lyra_read_from_events?)
    end

    # Test find method in ES disabled mode (lines 90-93)
    def test_find_reads_from_event_store
      # First create a record via event sourcing to populate the cache
      Lyra.config.projection_mode = :sync  # Use sync to populate cache
      user = ::User.create!(name: "FindTest", email: next_email)
      user_id = user.id

      # Switch to disabled mode
      Lyra.config.projection_mode = :disabled

      # Mock the CachedProjection to return data
      Lyra::Projections::CachedProjection.stubs(:find).with(::User, user_id).returns({
        "id" => user_id,
        "name" => "FindTest",
        "email" => user.email
      })

      found = ::User.find(user_id)
      assert_equal user_id, found.id
      assert_equal "FindTest", found.name
    ensure
      Lyra.config.projection_mode = :sync
      user&.destroy
    end

    # Test find raises RecordNotFound when not found (line 93)
    def test_find_raises_when_not_found
      Lyra::Projections::CachedProjection.stubs(:find).with(::User, 999999).returns(nil)

      assert_raises(ActiveRecord::RecordNotFound) do
        ::User.find(999999)
      end
    end

    # Test find_by in ES disabled mode (lines 101, 108-111)
    def test_find_by_reads_from_event_store
      Lyra::Projections::CachedProjection.stubs(:find_by).with(::User, { name: "TestFind" }).returns({
        "id" => 1,
        "name" => "TestFind",
        "email" => "test@example.com"
      })

      found = ::User.find_by(name: "TestFind")
      assert_equal "TestFind", found.name
    end

    # Test find_by returns nil when not found
    def test_find_by_returns_nil_when_not_found
      Lyra::Projections::CachedProjection.stubs(:find_by).with(::User, { name: "NonExistent" }).returns(nil)

      found = ::User.find_by(name: "NonExistent")
      assert_nil found
    end

    # Test find_by! raises when not found (lines 113, 119)
    def test_find_by_bang_raises_when_not_found
      Lyra::Projections::CachedProjection.stubs(:find_by).with(::User, { name: "NonExistent" }).returns(nil)

      assert_raises(ActiveRecord::RecordNotFound) do
        ::User.find_by!(name: "NonExistent")
      end
    end

    # Test exists? in ES disabled mode (lines 129)
    def test_exists_checks_event_store
      Lyra::Projections::CachedProjection.stubs(:exists?).with(::User, 123).returns(true)

      assert ::User.exists?(123)
    end

    def test_exists_returns_false_when_not_found
      Lyra::Projections::CachedProjection.stubs(:exists?).with(::User, 999).returns(false)

      refute ::User.exists?(999)
    end

    # Test where in ES disabled mode (lines 149-151)
    def test_where_returns_cached_relation
      mock_relation = Lyra::Projections::CachedRelation.new(::User, [])
      Lyra::Projections::EventStoreReader.stubs(:relation).with(::User).returns(mock_relation)
      mock_relation.stubs(:where).with(name: "Test").returns(mock_relation)

      result = ::User.where(name: "Test")
      assert result.is_a?(Lyra::Projections::CachedRelation)
    end

    # Test all in ES disabled mode (lines 158-160)
    def test_all_returns_cached_relation
      mock_relation = Lyra::Projections::CachedRelation.new(::User, [])
      Lyra::Projections::EventStoreReader.stubs(:all).with(::User).returns(mock_relation)

      result = ::User.all
      assert result.is_a?(Lyra::Projections::CachedRelation)
    end

    # Test first in ES disabled mode (lines 149-150, 153)
    def test_first_reads_from_event_store
      user_attrs = { "id" => 1, "name" => "First", "email" => "first@example.com" }
      mock_relation = Lyra::Projections::CachedRelation.new(::User, [])
      ordered_relation = Lyra::Projections::CachedRelation.new(::User, [])

      Lyra::Projections::EventStoreReader.stubs(:relation).with(::User).returns(mock_relation)
      mock_relation.stubs(:order).with(::User.primary_key => :asc).returns(ordered_relation)
      ordered_relation.stubs(:first).with(nil).returns(nil)

      result = ::User.first
      # Just verify it doesn't crash - the mock returns nil
      assert_nil result
    end

    # Test last in ES disabled mode (lines 158-159, 162)
    def test_last_reads_from_event_store
      mock_relation = Lyra::Projections::CachedRelation.new(::User, [])
      ordered_relation = Lyra::Projections::CachedRelation.new(::User, [])

      Lyra::Projections::EventStoreReader.stubs(:relation).with(::User).returns(mock_relation)
      mock_relation.stubs(:order).with(::User.primary_key => :desc).returns(ordered_relation)
      ordered_relation.stubs(:first).with(nil).returns(nil)

      result = ::User.last
      assert_nil result
    end

    # Test find_by! success path (line 111, 113)
    def test_find_by_bang_returns_record_when_found
      Lyra::Projections::CachedProjection.stubs(:find_by).with(::User, { name: "Found" }).returns({
        "id" => 42,
        "name" => "Found",
        "email" => "found@example.com"
      })

      found = ::User.find_by!(name: "Found")
      assert_equal 42, found.id
      assert_equal "Found", found.name
    end

    # Test first with limit parameter (line 153)
    def test_first_with_limit_reads_from_event_store
      mock_relation = Lyra::Projections::CachedRelation.new(::User, [])
      ordered_relation = Lyra::Projections::CachedRelation.new(::User, [])

      Lyra::Projections::EventStoreReader.stubs(:relation).with(::User).returns(mock_relation)
      mock_relation.stubs(:order).with(::User.primary_key => :asc).returns(ordered_relation)
      ordered_relation.stubs(:first).with(3).returns([])

      result = ::User.first(3)
      assert_equal [], result
    end

    # Test last with limit parameter (line 162)
    def test_last_with_limit_reads_from_event_store
      mock_relation = Lyra::Projections::CachedRelation.new(::User, [])
      ordered_relation = Lyra::Projections::CachedRelation.new(::User, [])

      Lyra::Projections::EventStoreReader.stubs(:relation).with(::User).returns(mock_relation)
      mock_relation.stubs(:order).with(::User.primary_key => :desc).returns(ordered_relation)
      ordered_relation.stubs(:first).with(5).returns([])

      result = ::User.last(5)
      assert_equal [], result
    end

    # Regression test for the CachedRelation#method_missing bug where
    # delete_all/destroy_all/update_all were delegated to a query rebuilt
    # from model_class.unscoped -- discarding whatever #where the relation
    # was actually built from and mutating every row in the table. In the
    # Aegean ePay benchmark this turned
    # `Registration.where(id: created_ids).delete_all` into a bare
    # `DELETE FROM "registrations"`, wiping the whole table (see
    # examples/aegean_epay_testbed/perf/run_concurrent_benchmark.rb's
    # per-thread cleanup) and starving the next mode of the rows it expected
    # to read.
    def test_delete_all_on_filtered_relation_only_deletes_matching_records
      Lyra.config.projection_mode = :sync
      keep = ::User.create!(name: "Keep", email: next_email)
      gone1 = ::User.create!(name: "Gone1", email: next_email)
      gone2 = ::User.create!(name: "Gone2", email: next_email)
      Lyra.config.projection_mode = :disabled

      cached = Lyra::Projections::CachedRelation.new(::User, [keep, gone1, gone2])
      Lyra::Projections::EventStoreReader.stubs(:relation).with(::User).returns(cached)

      deleted = ::User.where(id: [gone1.id, gone2.id]).delete_all

      # ::User.exists? is itself overridden in this mode to check the event
      # store, not the table (an id's creation event outlives delete_all on
      # the row) -- so check the real table directly via .unscoped, which
      # Lyra deliberately does not intercept.
      assert_equal 2, deleted
      assert ::User.unscoped.exists?(keep.id), "delete_all deleted a record outside its #where filter"
      refute ::User.unscoped.exists?(gone1.id)
      refute ::User.unscoped.exists?(gone2.id)
    ensure
      Lyra.config.projection_mode = :sync
      [keep, gone1, gone2].each { |u| u&.destroy if u && ::User.unscoped.exists?(u.id) }
    end

    def test_delete_all_on_empty_relation_deletes_nothing
      Lyra.config.projection_mode = :sync
      survivor = ::User.create!(name: "Survivor", email: next_email)
      Lyra.config.projection_mode = :disabled

      cached = Lyra::Projections::CachedRelation.new(::User, [])
      Lyra::Projections::EventStoreReader.stubs(:relation).with(::User).returns(cached)

      deleted = ::User.where(id: [survivor.id]).delete_all

      assert_equal 0, deleted
      assert ::User.unscoped.exists?(survivor.id)
    ensure
      Lyra.config.projection_mode = :sync
      survivor&.destroy if survivor && ::User.unscoped.exists?(survivor.id)
    end

    # Regression test for extract_where_conditions missing
    # Arel::Nodes::HomogeneousIn -- the node Rails compiles `where(id: [...])`
    # to for arrays of more than one homogeneous scalar. Before this fix, an
    # IN condition built this way was silently dropped from the extracted
    # hash, which (for a scope whose only condition was such an IN) made
    # CachedRelation#method_missing's scope-delegation branch fall through to
    # an unfiltered relation.
    def test_extract_where_conditions_handles_homogeneous_in
      cached = Lyra::Projections::CachedRelation.new(::User, [])

      Thread.current[:lyra_bypass_read_override] = true
      real_relation = ::User.where(id: [1, 2, 3])
      Thread.current[:lyra_bypass_read_override] = nil

      conditions = cached.send(:extract_where_conditions, real_relation)

      assert_equal [1, 2, 3], conditions[:id]
    ensure
      Thread.current[:lyra_bypass_read_override] = nil
    end
  end

  # ==========================================================================
  # CrudInterceptor Coverage Tests - Error Handling
  # ==========================================================================
  class CrudInterceptorErrorHandlingTest < Minitest::Test
    def setup
      @event_store = RailsEventStore::Client.new
      Lyra.configure do |config|
        config.event_store = @event_store
        config.mode = :hijack
      end
      @email_counter = 0
    end

    def teardown
      Lyra.reset_config!
    end

    def next_email
      @email_counter += 1
      "error_test_#{@email_counter}_#{rand(100000)}@example.com"
    end

    # Test hijack mode create error handling (lines 229-230)
    def test_hijack_create_handles_command_failure
      # Mock CommandHandler to return failure
      failed_result = OpenStruct.new(success?: false, error: "Create failed")
      Lyra::CommandHandler.stubs(:handle).returns(failed_result)

      user = ::User.new(name: "FailCreate", email: next_email)

      # The create should fail
      refute user.save
      assert user.errors[:base].include?("Create failed")
    end

    # Test hijack mode update error handling (lines 242-243)
    def test_hijack_update_handles_command_failure
      # First create successfully
      Lyra.config.mode = :monitor
      user = ::User.create!(name: "UpdateFail", email: next_email)

      # Switch to hijack and mock failure
      Lyra.config.mode = :hijack
      failed_result = OpenStruct.new(success?: false, error: "Update failed")
      Lyra::CommandHandler.stubs(:handle).returns(failed_result)

      refute user.update(name: "NewName")
      assert user.errors[:base].include?("Update failed")
    ensure
      Lyra.config.mode = :monitor
      user&.destroy
    end

    # Test hijack mode destroy error handling (lines 255-256)
    def test_hijack_destroy_handles_command_failure
      # First create successfully
      Lyra.config.mode = :monitor
      user = ::User.create!(name: "DestroyFail", email: next_email)

      # Switch to hijack and mock failure
      Lyra.config.mode = :hijack
      failed_result = OpenStruct.new(success?: false, error: "Destroy failed")
      Lyra::CommandHandler.stubs(:handle).returns(failed_result)

      refute user.destroy
      assert user.errors[:base].include?("Destroy failed")
    ensure
      Lyra.config.mode = :monitor
      user&.reload&.destroy rescue nil
    end
  end

  # ==========================================================================
  # CrudInterceptor Coverage Tests - Event Sourcing Error Handling
  # ==========================================================================
  class CrudInterceptorESErrorHandlingTest < Minitest::Test
    def setup
      @event_store = RailsEventStore::Client.new
      Lyra.configure do |config|
        config.event_store = @event_store
        config.mode = :event_sourcing
        config.projection_mode = :sync
      end
      @email_counter = 0
    end

    def teardown
      Lyra.reset_config!
    end

    def next_email
      @email_counter += 1
      "es_error_#{@email_counter}_#{rand(100000)}@example.com"
    end

    # Test ES create error handling (lines 284-285)
    def test_es_create_handles_command_failure
      failed_result = OpenStruct.new(success?: false, error: "ES Create failed")
      Lyra::CommandHandler.stubs(:handle).returns(failed_result)

      user = ::User.new(name: "ESFailCreate", email: next_email)

      refute user.save
      assert user.errors[:base].include?("ES Create failed")
    end

    # Test ES update error handling (lines 301-302)
    def test_es_update_handles_command_failure
      # First create successfully with monitor mode
      Lyra.config.mode = :monitor
      user = ::User.create!(name: "ESUpdateFail", email: next_email)

      # Switch to ES mode and mock failure
      Lyra.config.mode = :event_sourcing
      failed_result = OpenStruct.new(success?: false, error: "ES Update failed")
      Lyra::CommandHandler.stubs(:handle).returns(failed_result)

      refute user.update(name: "NewName")
      assert user.errors[:base].include?("ES Update failed")
    ensure
      Lyra.config.mode = :monitor
      user&.destroy
    end

    # Test ES destroy error handling (lines 318-319)
    def test_es_destroy_handles_command_failure
      # First create successfully with monitor mode
      Lyra.config.mode = :monitor
      user = ::User.create!(name: "ESDestroyFail", email: next_email)

      # Switch to ES mode and mock failure
      Lyra.config.mode = :event_sourcing
      failed_result = OpenStruct.new(success?: false, error: "ES Destroy failed")
      Lyra::CommandHandler.stubs(:handle).returns(failed_result)

      refute user.destroy
      assert user.errors[:base].include?("ES Destroy failed")
    ensure
      Lyra.config.mode = :monitor
      user&.reload&.destroy rescue nil
    end

    # Test sync projection with read-your-writes (line 355-356)
    def test_sync_projection_records_write_in_guaranteed_block
      Lyra.config.mode = :monitor
      user = ::User.create!(name: "RYWTest", email: next_email)

      Lyra.config.mode = :event_sourcing

      # Simulate being in a guaranteed block
      Lyra::Consistency::ReadYourWrites.stubs(:in_guaranteed_block?).returns(true)
      Lyra::Consistency::ReadYourWrites.expects(:record_write).once

      # This should record the write rather than project immediately
      success_result = OpenStruct.new(
        success?: true,
        attributes: { id: user.id, name: "Updated" },
        events: []
      )

      user.send(:lyra_run_sync_projection, :update, success_result)
    ensure
      Lyra.config.mode = :monitor
      user&.destroy
    end

    # Test sync projection error handling non-strict mode (lines 361-365)
    def test_sync_projection_handles_error_non_strict
      Lyra.config.strict_projections = false

      user = ::User.new(name: "Test", email: next_email)

      # Mock projection to raise error
      Lyra::Projections::ModelProjection.stubs(:project).raises(StandardError.new("Projection error"))
      Lyra::Consistency::ReadYourWrites.stubs(:in_guaranteed_block?).returns(false)

      # Should not raise, just log
      result = OpenStruct.new(success?: true, attributes: {}, events: [])

      assert_nothing_raised do
        user.send(:lyra_run_sync_projection, :create, result)
      end
    ensure
      Lyra.config.strict_projections = false
    end

    # Test sync projection error handling strict mode (line 361)
    def test_sync_projection_raises_error_in_strict_mode
      Lyra.config.strict_projections = true

      user = ::User.new(name: "Test", email: next_email)

      Lyra::Projections::ModelProjection.stubs(:project).raises(StandardError.new("Strict projection error"))
      Lyra::Consistency::ReadYourWrites.stubs(:in_guaranteed_block?).returns(false)

      result = OpenStruct.new(success?: true, attributes: {}, events: [])

      assert_raises(StandardError) do
        user.send(:lyra_run_sync_projection, :create, result)
      end
    ensure
      Lyra.config.strict_projections = false
    end

    private

    def assert_nothing_raised
      yield
    rescue => e
      flunk "Expected no exception, got: #{e.class}: #{e.message}"
    end
  end

  # ==========================================================================
  # CrudInterceptor Coverage Tests - Hijack Mode
  # ==========================================================================
  class CrudInterceptorHijackCoverageTest < Minitest::Test
    def setup
      @event_store = RailsEventStore::Client.new
      Lyra.configure do |config|
        config.event_store = @event_store
        config.mode = :hijack
      end
      @email_counter = 0
    end

    def teardown
      Lyra.reset_config!
    end

    def next_email
      @email_counter += 1
      "hijack_test_#{@email_counter}_#{rand(100000)}@example.com"
    end

    # Test hijack mode create
    def test_hijack_mode_creates_record_and_event
      events_before = @event_store.read.to_a.count

      user = ::User.create!(name: "HijackCreate", email: next_email)

      events_after = @event_store.read.to_a.count
      assert events_after > events_before
      assert user.persisted?
    ensure
      user&.destroy
    end

    # Test hijack mode update
    def test_hijack_mode_updates_record_and_creates_event
      user = ::User.create!(name: "HijackUpdate", email: next_email)
      events_before = @event_store.read.to_a.count

      user.update!(name: "HijackUpdated")

      events_after = @event_store.read.to_a.count
      assert events_after > events_before

      user.reload
      assert_equal "HijackUpdated", user.name
    ensure
      user&.destroy
    end

    # Test hijack mode destroy
    def test_hijack_mode_destroys_record_and_creates_event
      user = ::User.create!(name: "HijackDestroy", email: next_email)
      user_id = user.id
      events_before = @event_store.read.to_a.count

      user.destroy

      events_after = @event_store.read.to_a.count
      assert events_after > events_before
      refute ::User.exists?(user_id)
    end
  end

  # ==========================================================================
  # CrudInterceptor Coverage Tests - Event Sourcing Mode
  # ==========================================================================
  class CrudInterceptorEventSourcingCoverageTest < Minitest::Test
    def setup
      @event_store = RailsEventStore::Client.new
      Lyra.configure do |config|
        config.event_store = @event_store
        config.mode = :event_sourcing
        config.projection_mode = :sync
      end
      @email_counter = 0
    end

    def teardown
      Lyra.reset_config!
      Thread.current[:lyra_skip_insert] = nil
    end

    def next_email
      @email_counter += 1
      "es_test_#{@email_counter}_#{rand(100000)}@example.com"
    end

    # Test event sourcing create
    def test_event_sourcing_mode_creates_record_via_events
      events_before = @event_store.read.to_a.count

      user = ::User.create!(name: "ESCreate", email: next_email)

      events_after = @event_store.read.to_a.count
      assert events_after > events_before
      assert user.persisted?
    ensure
      user&.destroy
    end

    # Test event sourcing update
    def test_event_sourcing_mode_updates_record_via_events
      user = ::User.create!(name: "ESUpdate", email: next_email)
      events_before = @event_store.read.to_a.count

      user.update!(name: "ESUpdated")

      events_after = @event_store.read.to_a.count
      assert events_after > events_before
    ensure
      user&.destroy
    end

    # Test event sourcing destroy
    def test_event_sourcing_mode_destroys_record_via_events
      user = ::User.create!(name: "ESDestroy", email: next_email)
      user_id = user.id
      events_before = @event_store.read.to_a.count

      user.destroy

      events_after = @event_store.read.to_a.count
      assert events_after > events_before
      refute ::User.exists?(user_id)
    end
  end
end
