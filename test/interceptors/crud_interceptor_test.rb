# frozen_string_literal: true

require "test_helper"
require_relative "../../lib/lyra/interceptors/crud_interceptor"

module Lyra
  module Interceptors
    class CrudInterceptorTest < Minitest::Test
      def setup
        @event_store = RailsEventStore::Client.new
        Lyra.configure do |config|
          config.event_store = @event_store
          config.mode = :monitor
        end
        @email_counter = 0
      end

      def teardown
        Lyra.reset_config!
      end

      def next_email
        @email_counter += 1
        "test#{@email_counter}_#{rand(10000)}@example.com"
      end

      # ===========================================================================
      # Module Structure Tests
      # ===========================================================================

      def test_module_exists
        assert defined?(Lyra::Interceptors::CrudInterceptor)
      end

      def test_module_is_a_concern
        assert Lyra::Interceptors::CrudInterceptor.is_a?(Module)
      end

      def test_module_defines_class_methods
        assert Lyra::Interceptors::CrudInterceptor.const_defined?(:ClassMethods)
      end

      def test_monitor_with_lyra_class_method_exists
        class_methods = Lyra::Interceptors::CrudInterceptor::ClassMethods
        assert class_methods.instance_methods.include?(:monitor_with_lyra)
      end

      # ===========================================================================
      # Mode Detection Tests (using User model from test_helper)
      # ===========================================================================

      def test_lyra_monitored_returns_true_when_enabled
        user = ::User.new(name: "Test", email: next_email)
        assert user.send(:lyra_monitored?)
      end

      def test_lyra_hijack_mode_returns_false_in_monitor_mode
        user = ::User.new(name: "Test", email: next_email)
        refute user.send(:lyra_hijack_mode?)
      end

      def test_lyra_hijack_mode_returns_true_in_hijack_mode
        Lyra.config.mode = :hijack
        user = ::User.new(name: "Test", email: next_email)
        assert user.send(:lyra_hijack_mode?)
      end

      def test_lyra_event_sourcing_mode_returns_false_in_monitor_mode
        user = ::User.new(name: "Test", email: next_email)
        refute user.send(:lyra_event_sourcing_mode?)
      end

      def test_lyra_event_sourcing_mode_returns_true_in_event_sourcing_mode
        Lyra.config.mode = :event_sourcing
        user = ::User.new(name: "Test", email: next_email)
        assert user.send(:lyra_event_sourcing_mode?)
      end

      # ===========================================================================
      # Build Event Data Tests
      # ===========================================================================

      def test_build_event_data_includes_model_class
        user = ::User.create!(name: "Test", email: next_email)
        data = user.send(:build_event_data, :created)

        assert_equal "User", data[:model_class]
      ensure
        user&.destroy
      end

      def test_build_event_data_includes_model_id
        user = ::User.create!(name: "Test", email: next_email)
        data = user.send(:build_event_data, :created)

        assert_equal user.id, data[:model_id]
      ensure
        user&.destroy
      end

      def test_build_event_data_includes_operation
        user = ::User.create!(name: "Test", email: next_email)
        data = user.send(:build_event_data, :updated)

        assert_equal :updated, data[:operation]
      ensure
        user&.destroy
      end

      def test_build_event_data_includes_attributes
        user = ::User.create!(name: "TestUser", email: next_email)
        data = user.send(:build_event_data, :created)

        assert data[:attributes].key?("name")
        assert_equal "TestUser", data[:attributes]["name"]
      ensure
        user&.destroy
      end

      def test_build_event_data_includes_timestamps_in_attributes
        user = ::User.create!(name: "Test", email: next_email)
        data = user.send(:build_event_data, :created)

        assert data[:attributes].key?("created_at"), "replay needs created_at from a create"
        assert data[:attributes].key?("updated_at")
      ensure
        user&.destroy
      end

      def test_build_event_data_includes_timestamp
        user = ::User.create!(name: "Test", email: next_email)
        data = user.send(:build_event_data, :created)

        assert data[:timestamp].is_a?(Time)
      ensure
        user&.destroy
      end

      def test_build_event_data_includes_metadata
        user = ::User.create!(name: "Test", email: next_email)
        data = user.send(:build_event_data, :created)

        assert data[:metadata].is_a?(Hash)
        assert data[:metadata].key?(:user_id)
        assert data[:metadata].key?(:request_id)
        assert data[:metadata].key?(:correlation_id)
        assert data[:metadata].key?(:causation_id)
      ensure
        user&.destroy
      end

      # ===========================================================================
      # Stream Name Tests
      # ===========================================================================

      def test_lyra_stream_name_format
        user = ::User.create!(name: "Test", email: next_email)
        stream_name = user.send(:lyra_stream_name)

        assert_equal "User$#{user.id}", stream_name
      ensure
        user&.destroy
      end

      # ===========================================================================
      # Current Context Tests
      # ===========================================================================

      def test_lyra_current_user_id_returns_nil_when_no_current
        user = ::User.new(name: "Test", email: next_email)
        assert_nil user.send(:lyra_current_user_id)
      end

      def test_lyra_current_request_id_returns_nil_when_no_current
        user = ::User.new(name: "Test", email: next_email)
        assert_nil user.send(:lyra_current_request_id)
      end

      def test_lyra_current_action_id_returns_nil_when_no_context
        user = ::User.new(name: "Test", email: next_email)
        assert_nil user.send(:lyra_current_action_id)
      end

      def test_lyra_current_user_action_returns_nil_when_no_context
        user = ::User.new(name: "Test", email: next_email)
        assert_nil user.send(:lyra_current_user_action)
      end

      # ===========================================================================
      # Event Class Resolution Tests
      # ===========================================================================

      def test_lyra_event_class_for_created_returns_event_class
        user = ::User.new(name: "Test", email: next_email)
        event_class = user.send(:lyra_event_class_for, :created)

        assert event_class < Lyra::Event
      end

      def test_lyra_event_class_for_updated_returns_event_class
        user = ::User.new(name: "Test", email: next_email)
        event_class = user.send(:lyra_event_class_for, :updated)

        assert event_class < Lyra::Event
      end

      def test_lyra_event_class_for_destroyed_returns_event_class
        user = ::User.new(name: "Test", email: next_email)
        event_class = user.send(:lyra_event_class_for, :destroyed)

        assert event_class < Lyra::Event
      end

      # ===========================================================================
      # Monitor Mode Callback Tests
      # ===========================================================================

      def test_monitor_mode_creates_event_after_create
        Lyra.config.mode = :monitor
        events_before = @event_store.read.to_a.count

        user = ::User.create!(name: "MonitorTest", email: next_email)

        events_after = @event_store.read.to_a.count
        assert events_after > events_before
      ensure
        user&.destroy
      end

      def test_monitor_mode_creates_event_after_update
        Lyra.config.mode = :monitor
        user = ::User.create!(name: "Original", email: next_email)

        events_before = @event_store.read.to_a.count
        user.update!(name: "Updated")
        events_after = @event_store.read.to_a.count

        assert events_after > events_before
      ensure
        user&.destroy
      end

      def test_monitor_mode_creates_event_after_destroy
        Lyra.config.mode = :monitor
        user = ::User.create!(name: "ToDelete", email: next_email)

        events_before = @event_store.read.to_a.count
        user.destroy
        events_after = @event_store.read.to_a.count

        assert events_after > events_before
      end

      # ===========================================================================
      # SQL Override Tests
      # ===========================================================================

      def test_update_row_calls_super_when_not_skipping
        # Use TestModel which doesn't have Lyra callbacks to avoid interference
        model = TestModel.create!(name: "Test", email: next_email)
        model.update!(name: "Updated")

        model.reload
        assert_equal "Updated", model.name
      ensure
        model&.destroy
      end

      def test_delete_row_calls_super_when_not_skipping
        user = ::User.create!(name: "Test", email: next_email)
        user_id = user.id

        user.destroy

        refute ::User.exists?(user_id)
      end

      # ===========================================================================
      # Disabled Paper Trail Integration Tests
      # ===========================================================================

      def test_lyra_disable_paper_trail_does_not_crash_without_paper_trail
        user = ::User.new(name: "Test", email: next_email)

        assert_nothing_raised do
          user.send(:lyra_disable_paper_trail!)
        end
      end

      # ===========================================================================
      # Read Override Tests (for event sourcing disabled projection mode)
      # ===========================================================================

      def test_lyra_read_from_events_returns_false_in_monitor_mode
        Lyra.config.mode = :monitor
        refute ::User.send(:lyra_read_from_events?)
      end

      # ===========================================================================
      # Thread Safety Tests
      # ===========================================================================

      def test_thread_current_lyra_skip_insert_cleared_when_no_result
        # When there's no event result, finalize should still clear the flag
        Thread.current[:lyra_skip_insert] = true

        user = ::User.new(name: "Test", email: next_email)
        user.instance_variable_set(:@lyra_event_result, nil)
        user.send(:lyra_finalize_event_source)

        # Finalize clears its state on every exit, the early return included.
        # It used to leave the flag set there, and after a failed store too, so
        # the next insert of any model on the thread skipped its row.
        assert_nil Thread.current[:lyra_skip_insert]
      ensure
        Thread.current[:lyra_skip_insert] = nil
      end

      def test_thread_current_lyra_bypass_read_override
        Thread.current[:lyra_bypass_read_override] = true

        Lyra.config.mode = :event_sourcing
        Lyra.config.projection_mode = :disabled

        refute ::User.send(:lyra_read_from_events?)
      ensure
        Thread.current[:lyra_bypass_read_override] = nil
      end

      # ===========================================================================
      # Error Handling Tests
      # ===========================================================================

      def test_lyra_store_events_raises_when_strict
        Lyra.config.strict_projections = true
        user = ::User.new(name: "Test", email: next_email)

        events = [Lyra::Event.new(data: { test: true })]
        @event_store.stubs(:publish).raises(StandardError.new("Store error"))

        assert_raises(StandardError) do
          user.send(:lyra_store_events, events)
        end
      end

      # ===========================================================================
      # Metadata Proc Tests
      # ===========================================================================

      def test_lyra_custom_metadata_returns_empty_hash_when_no_proc
        Lyra.config.metadata_proc = nil
        user = ::User.new(name: "Test", email: next_email)

        result = user.send(:lyra_custom_metadata, :created)
        assert_equal({}, result)
      end

      def test_lyra_custom_metadata_calls_proc_with_record_and_operation
        called_with = nil
        Lyra.config.metadata_proc = lambda do |record, operation|
          called_with = { record: record, operation: operation }
          { custom: true }
        end

        user = ::User.new(name: "Test", email: next_email)
        user.send(:lyra_custom_metadata, :updated)

        assert_equal user, called_with[:record]
        assert_equal :updated, called_with[:operation]
      end

      def test_lyra_custom_metadata_returns_proc_result
        Lyra.config.metadata_proc = lambda do |record, operation|
          { user_id: 123, source: "test_app" }
        end

        user = ::User.new(name: "Test", email: next_email)
        result = user.send(:lyra_custom_metadata, :created)

        assert_equal 123, result[:user_id]
        assert_equal "test_app", result[:source]
      end

      def test_lyra_custom_metadata_returns_empty_hash_on_proc_error
        Lyra.config.metadata_proc = lambda do |record, operation|
          raise "Something went wrong"
        end

        user = ::User.new(name: "Test", email: next_email)
        result = user.send(:lyra_custom_metadata, :created)

        assert_equal({}, result)
      end

      def test_lyra_custom_metadata_returns_empty_hash_when_proc_returns_non_hash
        Lyra.config.metadata_proc = lambda do |record, operation|
          "not a hash"
        end

        user = ::User.new(name: "Test", email: next_email)
        result = user.send(:lyra_custom_metadata, :created)

        assert_equal({}, result)
      end

      def test_build_event_data_merges_custom_metadata
        Lyra.config.metadata_proc = lambda do |record, operation|
          { custom_user_id: 999, custom_source: "my_app" }
        end

        user = ::User.create!(name: "Test", email: next_email)
        data = user.send(:build_event_data, :created)

        # Custom metadata should be merged
        assert_equal 999, data[:metadata][:custom_user_id]
        assert_equal "my_app", data[:metadata][:custom_source]

        # Built-in metadata should still be present
        assert data[:metadata].key?(:correlation_id)
        assert data[:metadata].key?(:causation_id)
      ensure
        user&.destroy
      end

      def test_custom_metadata_overwrites_built_in_when_same_key
        # Custom metadata should overwrite built-in values
        Lyra.config.metadata_proc = lambda do |record, operation|
          { user_id: 42 }  # Overwrite the built-in user_id
        end

        user = ::User.create!(name: "Test", email: next_email)
        data = user.send(:build_event_data, :created)

        assert_equal 42, data[:metadata][:user_id]
      ensure
        user&.destroy
      end

      def test_metadata_proc_receives_operation_for_each_crud_type
        operations_received = []
        Lyra.config.metadata_proc = lambda do |record, operation|
          operations_received << operation
          {}
        end

        user = ::User.create!(name: "Test", email: next_email)
        user.update!(name: "Updated")
        user.destroy

        assert_includes operations_received, :created
        assert_includes operations_received, :updated
        assert_includes operations_received, :destroyed
      end

      private

      def assert_nothing_raised
        yield
      rescue => e
        flunk "Expected no exception, got: #{e.class}: #{e.message}"
      end
    end

    # ES-NoProj reads (event_sourcing, projection_mode :disabled).
    class CrudInterceptorESDisabledTest < Minitest::Test
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

      # Whether the users table has the row, past Lyra's event-store reads.
      def table_row?(id)
        previous = Thread.current[:lyra_bypass_read_override]
        Thread.current[:lyra_bypass_read_override] = true
        ::User.unscoped.exists?(id)
      ensure
        Thread.current[:lyra_bypass_read_override] = previous
      end

      # Test lyra_read_from_events? returns true in ES disabled mode
      def test_lyra_read_from_events_returns_true_in_es_disabled_mode
        assert ::User.send(:lyra_read_from_events?)
      end


      # Test find method in ES disabled mode
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

      # Test find raises RecordNotFound when not found
      def test_find_raises_when_not_found
        Lyra::Projections::CachedProjection.stubs(:find).with(::User, 999999).returns(nil)

        assert_raises(ActiveRecord::RecordNotFound) do
          ::User.find(999999)
        end
      end

      # Test find_by in ES disabled mode
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

      # Test find_by! raises when not found
      def test_find_by_bang_raises_when_not_found
        Lyra::Projections::CachedProjection.stubs(:find_by).with(::User, { name: "NonExistent" }).returns(nil)

        assert_raises(ActiveRecord::RecordNotFound) do
          ::User.find_by!(name: "NonExistent")
        end
      end

      # Test exists? in ES disabled mode
      def test_exists_checks_event_store
        Lyra::Projections::CachedProjection.stubs(:exists?).with(::User, 123).returns(true)

        assert ::User.exists?(123)
      end

      def test_exists_returns_false_when_not_found
        Lyra::Projections::CachedProjection.stubs(:exists?).with(::User, 999).returns(false)

        refute ::User.exists?(999)
      end

      # Test where in ES disabled mode
      def test_where_returns_cached_relation
        mock_relation = Lyra::Projections::CachedRelation.new(::User, [])
        Lyra::Projections::EventStoreReader.stubs(:relation).with(::User).returns(mock_relation)
        mock_relation.stubs(:where).with(name: "Test").returns(mock_relation)

        result = ::User.where(name: "Test")
        assert result.is_a?(Lyra::Projections::CachedRelation)
      end

      # Test all in ES disabled mode
      def test_all_returns_cached_relation
        mock_relation = Lyra::Projections::CachedRelation.new(::User, [])
        Lyra::Projections::EventStoreReader.stubs(:all).with(::User).returns(mock_relation)

        result = ::User.all
        assert result.is_a?(Lyra::Projections::CachedRelation)
      end

      # Test first in ES disabled mode
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

      # Test last in ES disabled mode
      def test_last_reads_from_event_store
        mock_relation = Lyra::Projections::CachedRelation.new(::User, [])
        ordered_relation = Lyra::Projections::CachedRelation.new(::User, [])

        Lyra::Projections::EventStoreReader.stubs(:relation).with(::User).returns(mock_relation)
        mock_relation.stubs(:order).with(::User.primary_key => :asc).returns(ordered_relation)
        ordered_relation.stubs(:last).with(nil).returns(nil)

        result = ::User.last
        assert_nil result
      end

      # Test find_by! success path
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

      # Test first with limit parameter
      def test_first_with_limit_reads_from_event_store
        mock_relation = Lyra::Projections::CachedRelation.new(::User, [])
        ordered_relation = Lyra::Projections::CachedRelation.new(::User, [])

        Lyra::Projections::EventStoreReader.stubs(:relation).with(::User).returns(mock_relation)
        mock_relation.stubs(:order).with(::User.primary_key => :asc).returns(ordered_relation)
        ordered_relation.stubs(:first).with(3).returns([])

        result = ::User.first(3)
        assert_equal [], result
      end

      # Test last with limit parameter
      def test_last_with_limit_reads_from_event_store
        mock_relation = Lyra::Projections::CachedRelation.new(::User, [])
        ordered_relation = Lyra::Projections::CachedRelation.new(::User, [])

        Lyra::Projections::EventStoreReader.stubs(:relation).with(::User).returns(mock_relation)
        mock_relation.stubs(:order).with(::User.primary_key => :asc).returns(ordered_relation)
        ordered_relation.stubs(:last).with(5).returns([])

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
      # the replication package's examples/aegean_epay_testbed/perf/run_concurrent_benchmark.rb's
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

        # ::User.exists? and ::User.unscoped read the event store in this mode,
        # not the table (an id's creation event outlives delete_all on the
        # row) -- so check the real table directly (table_row?).
        assert_equal 2, deleted
        assert table_row?(keep.id), "delete_all deleted a record outside its #where filter"
        refute table_row?(gone1.id)
        refute table_row?(gone2.id)
      ensure
        Lyra.config.projection_mode = :sync
        [keep, gone1, gone2].each { |u| u&.destroy if u && table_row?(u.id) }
      end

      def test_delete_all_on_empty_relation_deletes_nothing
        Lyra.config.projection_mode = :sync
        survivor = ::User.create!(name: "Survivor", email: next_email)
        Lyra.config.projection_mode = :disabled

        cached = Lyra::Projections::CachedRelation.new(::User, [])
        Lyra::Projections::EventStoreReader.stubs(:relation).with(::User).returns(cached)

        deleted = ::User.where(id: [survivor.id]).delete_all

        assert_equal 0, deleted
        assert table_row?(survivor.id)
      ensure
        Lyra.config.projection_mode = :sync
        survivor&.destroy if survivor && table_row?(survivor.id)
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

        assert_equal [{ id: [1, 2, 3] }], conditions
      ensure
        Thread.current[:lyra_bypass_read_override] = nil
      end
    end

    # A failed command in Hijack mode.
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

      # Test hijack mode create error handling
      def test_hijack_create_handles_command_failure
        # Mock CommandHandler to return failure
        failed_result = OpenStruct.new(success?: false, error: "Create failed")
        Lyra::CommandHandler.stubs(:handle).returns(failed_result)

        user = ::User.new(name: "FailCreate", email: next_email)

        # The create should fail
        refute user.save
        assert user.errors[:base].include?("Create failed")
      end

      # Test hijack mode update error handling
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

      # Test hijack mode destroy error handling
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

    # A failed command, and the sync projection, in event_sourcing mode.
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

      # Test ES create error handling
      def test_es_create_handles_command_failure
        failed_result = OpenStruct.new(success?: false, error: "ES Create failed")
        Lyra::CommandHandler.stubs(:handle).returns(failed_result)

        user = ::User.new(name: "ESFailCreate", email: next_email)

        refute user.save
        assert user.errors[:base].include?("ES Create failed")
      end

      # Test ES update error handling
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

      # Test ES destroy error handling
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

      # ES-Sync projects a write inside a read-your-writes block at once, as
      # outside one: deferring it to the block's end hid the row from the
      # block's reads and from the unique-index check of the writes after it.
      def test_sync_projection_in_a_guaranteed_block_projects_at_once
        Lyra.config.mode = :monitor
        user = ::User.create!(name: "RYWTest", email: next_email)

        Lyra.config.mode = :event_sourcing

        Lyra::Consistency::ReadYourWrites.stubs(:in_guaranteed_block?).returns(true)
        Lyra::Consistency::ReadYourWrites.expects(:record_write).never
        Lyra::Projections::ModelProjection.expects(:project).once

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

      # Test sync projection error handling non-strict mode
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

      # Test sync projection error handling strict mode
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
  end
end
