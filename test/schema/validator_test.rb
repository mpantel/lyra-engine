# frozen_string_literal: true

require "test_helper"
require "tmpdir"

module Lyra
  module Schema
    class ValidatorTest < Minitest::Test
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
            %w[id email]
          end

          def self.columns
            [
              OpenStruct.new(name: "id", type: :integer, null: false, limit: nil, default: nil),
              OpenStruct.new(name: "email", type: :string, null: false, limit: 255, default: nil)
            ]
          end
        end

        Lyra.config.monitor_model(@mock_model)
      end

      def teardown
        FileUtils.rm_rf(@temp_path)
        Store.reset_path!
        Lyra.reset_config!
      end

      def test_valid_when_no_schema_exists
        validator = Validator.new

        assert validator.valid?
        refute validator.schema_exists?
      end

      def test_valid_when_schema_matches
        # Create and save schema
        schema = Generator.generate
        Store.save(schema)

        validator = Validator.new

        assert validator.valid?
        assert validator.schema_exists?
      end

      def test_invalid_when_column_removed
        # Save schema
        schema = Generator.generate
        Store.save(schema)

        # Modify the model to have fewer columns
        @mock_model.define_singleton_method(:column_names) { %w[id] }
        @mock_model.define_singleton_method(:columns) do
          [OpenStruct.new(name: "id", type: :integer, null: false, limit: nil, default: nil)]
        end

        validator = Validator.new

        refute validator.valid?
        assert validator.breaking_changes?
      end

      def test_invalid_when_column_added
        # Save schema
        schema = Generator.generate
        Store.save(schema)

        # Modify the model to have more columns
        @mock_model.define_singleton_method(:column_names) { %w[id email name] }
        @mock_model.define_singleton_method(:columns) do
          [
            OpenStruct.new(name: "id", type: :integer, null: false, limit: nil, default: nil),
            OpenStruct.new(name: "email", type: :string, null: false, limit: 255, default: nil),
            OpenStruct.new(name: "name", type: :string, null: true, limit: 100, default: nil)
          ]
        end

        validator = Validator.new

        refute validator.valid?
        refute validator.breaking_changes?  # column_added is info, not breaking
      end

      def test_report_shows_differences
        # Save schema
        schema = Generator.generate
        Store.save(schema)

        # Modify the model
        @mock_model.define_singleton_method(:column_names) { %w[id] }
        @mock_model.define_singleton_method(:columns) do
          [OpenStruct.new(name: "id", type: :integer, null: false, limit: nil, default: nil)]
        end

        validator = Validator.new
        validator.valid?

        report = validator.report

        assert_includes report, "email"
        assert_includes report, "removed"
      end

      def test_enforce_raises_in_strict_mode
        # Save schema
        schema = Generator.generate
        Store.save(schema)

        # Modify the model
        @mock_model.define_singleton_method(:column_names) { %w[id] }
        @mock_model.define_singleton_method(:columns) do
          [OpenStruct.new(name: "id", type: :integer, null: false, limit: nil, default: nil)]
        end

        Lyra.config.strict_schema = true

        validator = Validator.new

        assert_raises(SchemaValidationError) do
          validator.enforce!
        end
      end

      def test_enforce_returns_false_without_strict_mode
        # Save schema
        schema = Generator.generate
        Store.save(schema)

        # Modify the model
        @mock_model.define_singleton_method(:column_names) { %w[id] }
        @mock_model.define_singleton_method(:columns) do
          [OpenStruct.new(name: "id", type: :integer, null: false, limit: nil, default: nil)]
        end

        Lyra.config.strict_schema = false

        validator = Validator.new

        refute validator.enforce!  # Returns false, doesn't raise
      end

      def test_strict_enforce_boots_on_info_only_drift
        Store.save(Generator.generate)

        # column_added is :info
        @mock_model.define_singleton_method(:column_names) { %w[id email name] }
        @mock_model.define_singleton_method(:columns) do
          [
            OpenStruct.new(name: "id", type: :integer, null: false, limit: nil, default: nil),
            OpenStruct.new(name: "email", type: :string, null: false, limit: 255, default: nil),
            OpenStruct.new(name: "name", type: :string, null: true, limit: 100, default: nil)
          ]
        end
        Lyra.config.strict_schema = true

        validator = Validator.new
        log = capture_schema_log { refute validator.enforce! }

        assert_equal [:info], validator.differences.map { |d| d[:severity] }.uniq
        assert_includes log, "Schema drift detected"
      end

      def test_strict_enforce_boots_on_warning_drift_and_logs
        Store.save(Generator.generate)

        # column_nullable_changed is :warning
        @mock_model.define_singleton_method(:columns) do
          [
            OpenStruct.new(name: "id", type: :integer, null: false, limit: nil, default: nil),
            OpenStruct.new(name: "email", type: :string, null: true, limit: 255, default: nil)
          ]
        end
        Lyra.config.strict_schema = true

        validator = Validator.new
        log = capture_schema_log { refute validator.enforce! }

        assert_includes validator.differences.map { |d| d[:severity] }, :warning
        refute validator.breaking_changes?
        assert_includes log, "Schema drift detected"
        assert_includes log, "email"
      end

      def test_strict_enforce_raises_when_breaking_mixed_with_info
        Store.save(Generator.generate)

        # email removed (:breaking), name added (:info)
        @mock_model.define_singleton_method(:column_names) { %w[id name] }
        @mock_model.define_singleton_method(:columns) do
          [
            OpenStruct.new(name: "id", type: :integer, null: false, limit: nil, default: nil),
            OpenStruct.new(name: "name", type: :string, null: true, limit: 100, default: nil)
          ]
        end
        Lyra.config.strict_schema = true

        error = assert_raises(SchemaValidationError) { Validator.new.enforce! }
        assert(error.differences.any? { |d| d[:severity] == :breaking })
      end

      def test_enforce_returns_true_when_valid
        schema = Generator.generate
        Store.save(schema)

        validator = Validator.new

        assert validator.enforce!
      end

      private

      # Capture what Validator#log_warning writes, whichever sink it uses.
      def capture_schema_log
        if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
          io = StringIO.new
          original = Rails.logger
          Rails.logger = Logger.new(io)
          begin
            yield
          ensure
            Rails.logger = original
          end
          io.string
        else
          _out, err = capture_io { yield }
          err
        end
      end
    end

    class SchemaValidationErrorTest < Minitest::Test
      def test_error_includes_differences
        differences = [{ type: :column_removed, message: "Test" }]
        error = SchemaValidationError.new("Report text", differences)

        assert_equal differences, error.differences
      end

      def test_error_message_includes_instructions
        error = SchemaValidationError.new("Test report", [])

        assert_includes error.message, "lyra:schema:update"
        assert_includes error.message, "strict_schema"
      end
    end
  end
end
