# frozen_string_literal: true

require "test_helper"
require "tmpdir"

module Lyra
  module Schema
    class StoreTest < Minitest::Test
      def setup
        @temp_path = Dir.mktmpdir("lyra_schemas_test")
        Store.schema_path = @temp_path
      end

      def teardown
        FileUtils.rm_rf(@temp_path)
        Store.reset_path!
      end

      def test_schema_path_returns_pathname
        assert_instance_of Pathname, Store.schema_path
      end

      def test_schema_path_can_be_set
        custom_path = "/custom/path"
        Store.schema_path = custom_path

        assert_equal Pathname.new(custom_path), Store.schema_path
      end

      def test_exists_returns_false_when_no_schema
        refute Store.exists?
      end

      def test_exists_returns_true_when_current_yml_exists
        Store.ensure_directory!
        FileUtils.touch(File.join(@temp_path, "current.yml"))

        assert Store.exists?
      end

      def test_save_creates_versioned_file
        schema = { version: 1, models: {} }
        file_path = Store.save(schema)

        assert file_path.exist?
        assert_match(/v1_\d+\.yml$/, file_path.to_s)
      end

      def test_save_creates_current_yml
        schema = { version: 1, models: {} }
        Store.save(schema)

        current_path = Pathname.new(@temp_path).join("current.yml")
        assert current_path.exist?
      end

      def test_load_current_returns_nil_when_no_schema
        assert_nil Store.load_current
      end

      def test_load_current_returns_schema
        schema = { version: 1, models: { "User" => { table_name: "users" } } }
        Store.save(schema)

        loaded = Store.load_current
        assert_equal 1, loaded[:version]
        # Keys are symbolized when loading
        assert_equal "users", loaded[:models][:User][:table_name]
      end

      def test_load_version_returns_specific_version
        Store.save({ version: 1, models: { "V1" => {} } })
        Store.save({ version: 2, models: { "V2" => {} } })

        v1 = Store.load_version(1)
        v2 = Store.load_version(2)

        assert_equal 1, v1[:version]
        assert_equal 2, v2[:version]
      end

      def test_load_version_returns_nil_for_nonexistent
        assert_nil Store.load_version(999)
      end

      def test_versions_returns_sorted_list
        Store.save({ version: 1 })
        Store.save({ version: 2 })
        Store.save({ version: 3 })

        assert_equal [1, 2, 3], Store.versions
      end

      def test_versions_returns_empty_when_no_schemas
        assert_equal [], Store.versions
      end

      def test_latest_version_returns_highest
        Store.save({ version: 1 })
        Store.save({ version: 2 })

        assert_equal 2, Store.latest_version
      end

      def test_latest_version_returns_zero_when_empty
        assert_equal 0, Store.latest_version
      end

      def test_history_returns_metadata
        Store.save({ version: 1, created_at: "2025-01-01", lyra_version: "0.5.0", summary: { models_count: 2 } })

        history = Store.history
        assert_equal 1, history.size

        entry = history.first
        assert_equal 1, entry[:version]
        assert_equal "2025-01-01", entry[:created_at]
        assert_equal "0.5.0", entry[:lyra_version]
        assert_equal 2, entry[:models_count]
      end
    end
  end
end
