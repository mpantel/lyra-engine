# frozen_string_literal: true

require "test_helper"

module Lyra
  module Projections
    # Tests for CachedProjection - the caching layer for disabled projection mode
    #
    # Key behavior tested: warm() must invalidate collection caches to ensure
    # accurate counts after record creation/updates.
    class CachedProjectionTest < Minitest::Test
      def setup
        Lyra.reset_config!
        @cache_store = ActiveSupport::Cache::MemoryStore.new
      end

      def teardown
        Lyra.reset_config!
        @cache_store.clear
      end

      # =========================================================================
      # warm() Tests - ensures collection caches are invalidated
      # This is the critical fix for ES disabled mode tests
      # =========================================================================

      def test_warm_invalidates_collection_caches
        model_class = create_mock_model_class("User")

        Rails.stub(:cache, @cache_store) do
          # Pre-populate collection cache with stale count
          count_key = "lyra_projections/User/collections/count/v1"
          all_key = "lyra_projections/User/collections/all/v1"
          @cache_store.write(count_key, 5)
          @cache_store.write(all_key, [{ "id" => 1 }])

          assert_equal 5, @cache_store.read(count_key), "Count cache should be pre-populated"
          assert_equal [{ "id" => 1 }], @cache_store.read(all_key), "All cache should be pre-populated"

          # Stub event loading to return empty (simulating new record with no events yet cached)
          CachedProjection.stub(:load_events, []) do
            CachedProjection.warm(model_class, 999)
          end

          # Collection caches should be invalidated
          assert_nil @cache_store.read(count_key), "Count cache should be invalidated after warm()"
          assert_nil @cache_store.read(all_key), "All cache should be invalidated after warm()"
        end
      end

      def test_warm_is_called_with_new_record_invalidates_count
        model_class = create_mock_model_class("Registration")

        Rails.stub(:cache, @cache_store) do
          count_key = "lyra_projections/Registration/collections/count/v1"

          # Simulate stale count in cache
          @cache_store.write(count_key, 10)

          # Warm the cache for a "new" record (stubbing load_events)
          CachedProjection.stub(:load_events, []) do
            CachedProjection.warm(model_class, 42)
          end

          # Count should be invalidated so next count() call rebuilds from events
          assert_nil @cache_store.read(count_key),
            "Count cache must be invalidated when warm() is called for a new record"
        end
      end

      # =========================================================================
      # invalidate() Tests
      # =========================================================================

      def test_invalidate_clears_record_and_collection_caches
        model_class = create_mock_model_class("User")

        Rails.stub(:cache, @cache_store) do
          record_key = "lyra_projections/User/records/42/v1"
          count_key = "lyra_projections/User/collections/count/v1"
          all_key = "lyra_projections/User/collections/all/v1"

          @cache_store.write(record_key, { "id" => 42 })
          @cache_store.write(count_key, 10)
          @cache_store.write(all_key, [])

          CachedProjection.invalidate(model_class, 42)

          assert_nil @cache_store.read(record_key), "Record cache should be invalidated"
          assert_nil @cache_store.read(count_key), "Count cache should be invalidated"
          assert_nil @cache_store.read(all_key), "All cache should be invalidated"
        end
      end

      # =========================================================================
      # count() Tests
      # =========================================================================

      def test_count_is_cached
        model_class = create_mock_model_class("User")

        Rails.stub(:cache, @cache_store) do
          call_count = 0

          CachedProjection.stub(:build_count_from_events, ->(_mc, _cond) { call_count += 1; 5 }) do
            # First call should build from events
            result1 = CachedProjection.count(model_class)
            assert_equal 5, result1
            assert_equal 1, call_count

            # Second call should use cache
            result2 = CachedProjection.count(model_class)
            assert_equal 5, result2
            assert_equal 1, call_count, "Should use cached count, not rebuild"
          end
        end
      end

      def test_count_after_warm_rebuilds_from_events
        model_class = create_mock_model_class("User")

        Rails.stub(:cache, @cache_store) do
          # Pre-populate with stale count
          count_key = "lyra_projections/User/collections/count/v1"
          @cache_store.write(count_key, 5)

          # Warm should invalidate the count cache
          CachedProjection.stub(:load_events, []) do
            CachedProjection.warm(model_class, 999)
          end

          # Now count should rebuild from events
          CachedProjection.stub(:build_count_from_events, ->(_mc, _cond) { 6 }) do
            result = CachedProjection.count(model_class)
            assert_equal 6, result, "Count should be rebuilt after warm() invalidates cache"
          end
        end
      end

      private

      def create_mock_model_class(name)
        Class.new do
          define_singleton_method(:name) { name }
          define_singleton_method(:column_names) { %w[id name email created_at updated_at] }
        end
      end
    end
  end
end
