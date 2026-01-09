# frozen_string_literal: true

require "test_helper"
require "tmpdir"

module Lyra
  module Schema
    class GeneratorTest < Minitest::Test
      def setup
        Lyra.reset_config!
        @temp_path = Dir.mktmpdir("lyra_schemas_test")
        Store.schema_path = @temp_path

        # Create a mock model class
        @mock_model = Class.new do
          def self.name
            "MockUser"
          end

          def self.table_name
            "mock_users"
          end

          def self.primary_key
            "id"
          end

          def self.column_names
            %w[id email name age created_at updated_at]
          end

          def self.columns
            [
              OpenStruct.new(name: "id", type: :integer, null: false, limit: nil, default: nil),
              OpenStruct.new(name: "email", type: :string, null: false, limit: 255, default: nil),
              OpenStruct.new(name: "name", type: :string, null: true, limit: 100, default: nil),
              OpenStruct.new(name: "age", type: :integer, null: true, limit: nil, default: nil),
              OpenStruct.new(name: "created_at", type: :datetime, null: false, limit: nil, default: nil),
              OpenStruct.new(name: "updated_at", type: :datetime, null: false, limit: nil, default: nil)
            ]
          end
        end

        Lyra.config.monitor_model(@mock_model, event_prefix: "MockUser")
      end

      def teardown
        FileUtils.rm_rf(@temp_path)
        Store.reset_path!
        Lyra.reset_config!
      end

      def test_generates_schema_with_version
        schema = Generator.generate

        assert_equal 1, schema[:version]
      end

      def test_generates_schema_with_metadata
        schema = Generator.generate

        assert schema[:created_at]
        assert_equal Lyra::VERSION, schema[:lyra_version]
        assert schema[:fingerprint].start_with?("sha256:")
      end

      def test_generates_model_schema
        schema = Generator.generate

        assert schema[:models].key?("MockUser")
        model_schema = schema[:models]["MockUser"]
        assert_equal "mock_users", model_schema[:table_name]
        assert_equal "MockUser", model_schema[:event_prefix]
      end

      def test_generates_columns_schema
        schema = Generator.generate
        columns = schema[:models]["MockUser"][:columns]

        assert columns.key?("id")
        assert columns.key?("email")
        assert columns.key?("name")

        assert_equal "integer", columns["id"][:type]
        assert_equal true, columns["id"][:primary_key]

        assert_equal "string", columns["email"][:type]
        assert_equal 255, columns["email"][:limit]
      end

      def test_detects_pii_fields
        schema = Generator.generate
        columns = schema[:models]["MockUser"][:columns]

        if PAM_DSL_AVAILABLE
          assert columns["email"][:pii], "email should be detected as PII"
          assert columns["name"][:pii], "name should be detected as PII"
          refute columns["age"][:pii], "age should not be detected as PII"
          refute columns["id"][:pii], "id should not be detected as PII"
        else
          # Without PAM DSL, no PII detection occurs
          refute columns["email"][:pii], "email should not be marked as PII without PAM DSL"
          refute columns["name"][:pii], "name should not be marked as PII without PAM DSL"
        end
      end

      def test_generates_events_for_crud_operations
        schema = Generator.generate
        events = schema[:models]["MockUser"][:events]

        assert events.key?("MockUserCreated")
        assert events.key?("MockUserUpdated")
        assert events.key?("MockUserDestroyed")

        assert_equal "created", events["MockUserCreated"][:operation]
        assert_equal "updated", events["MockUserUpdated"][:operation]
        assert_equal "destroyed", events["MockUserDestroyed"][:operation]
      end

      def test_events_include_pii_fields
        schema = Generator.generate
        pii_fields = schema[:models]["MockUser"][:events]["MockUserCreated"][:pii_fields]

        if PAM_DSL_AVAILABLE
          assert_includes pii_fields, "email"
          assert_includes pii_fields, "name"
          refute_includes pii_fields, "age"
        else
          # Without PAM DSL, no PII fields are detected
          assert_empty pii_fields
        end
      end

      def test_generates_summary
        schema = Generator.generate

        assert_equal 1, schema[:summary][:models_count]
        assert_equal 6, schema[:summary][:total_columns]
        assert_equal 3, schema[:summary][:events_count]
        if PAM_DSL_AVAILABLE
          assert schema[:summary][:pii_fields_count] >= 2  # email and name
        else
          assert_equal 0, schema[:summary][:pii_fields_count]
        end
      end

      def test_generates_configuration
        Lyra.config.strict_schema = true

        schema = Generator.generate

        assert_equal "monitor", schema[:configuration][:mode]
        assert_equal true, schema[:configuration][:strict_schema]
      end

      def test_fingerprint_changes_when_schema_changes
        schema1 = Generator.generate
        fingerprint1 = schema1[:fingerprint]

        # Add another model
        another_model = Class.new do
          def self.name
            "AnotherModel"
          end

          def self.table_name
            "another_models"
          end

          def self.primary_key
            "id"
          end

          def self.column_names
            ["id"]
          end

          def self.columns
            [OpenStruct.new(name: "id", type: :integer, null: false)]
          end
        end

        Lyra.config.monitor_model(another_model)
        schema2 = Generator.generate
        fingerprint2 = schema2[:fingerprint]

        refute_equal fingerprint1, fingerprint2
      end
    end
  end
end
