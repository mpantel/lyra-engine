# frozen_string_literal: true

require "test_helper"

module Lyra
  module Schema
    class DiffTest < Minitest::Test
      def test_no_differences_when_schemas_identical
        schema = { models: { "User" => { columns: { "id" => { type: "integer" } } } } }

        differences = Diff.compare(schema, schema.deep_dup)

        assert_empty differences
      end

      def test_detects_added_model
        old_schema = { models: {} }
        new_schema = { models: { "User" => { columns: {} } } }

        differences = Diff.compare(old_schema, new_schema)

        assert_equal 1, differences.size
        assert_equal :model_added, differences.first[:type]
        assert_equal :info, differences.first[:severity]
        assert_equal "User", differences.first[:model]
      end

      def test_detects_removed_model
        old_schema = { models: { "User" => { columns: {} } } }
        new_schema = { models: {} }

        differences = Diff.compare(old_schema, new_schema)

        assert_equal 1, differences.size
        assert_equal :model_removed, differences.first[:type]
        assert_equal :breaking, differences.first[:severity]
      end

      def test_detects_added_column
        old_schema = { models: { "User" => { columns: { "id" => { type: "integer" } } } } }
        new_schema = { models: { "User" => { columns: {
          "id" => { type: "integer" },
          "email" => { type: "string", pii: true, pii_type: "email" }
        } } } }

        differences = Diff.compare(old_schema, new_schema)

        assert_equal 1, differences.size
        assert_equal :column_added, differences.first[:type]
        assert_equal :info, differences.first[:severity]
        assert_equal "email", differences.first[:column]
      end

      def test_detects_removed_column
        old_schema = { models: { "User" => { columns: {
          "id" => { type: "integer" },
          "email" => { type: "string" }
        } } } }
        new_schema = { models: { "User" => { columns: { "id" => { type: "integer" } } } } }

        differences = Diff.compare(old_schema, new_schema)

        assert_equal 1, differences.size
        assert_equal :column_removed, differences.first[:type]
        assert_equal :breaking, differences.first[:severity]
      end

      def test_detects_column_type_change
        old_schema = { models: { "User" => { columns: { "age" => { type: "string" } } } } }
        new_schema = { models: { "User" => { columns: { "age" => { type: "integer" } } } } }

        differences = Diff.compare(old_schema, new_schema)

        assert_equal 1, differences.size
        assert_equal :column_type_changed, differences.first[:type]
        assert_equal :breaking, differences.first[:severity]
        assert_equal "string", differences.first[:old_value]
        assert_equal "integer", differences.first[:new_value]
      end

      def test_detects_column_nullable_change
        old_schema = { models: { "User" => { columns: { "name" => { type: "string", nullable: true } } } } }
        new_schema = { models: { "User" => { columns: { "name" => { type: "string", nullable: false } } } } }

        differences = Diff.compare(old_schema, new_schema)

        assert_equal 1, differences.size
        assert_equal :column_nullable_changed, differences.first[:type]
        assert_equal :warning, differences.first[:severity]
      end

      def test_detects_pii_field_added
        old_schema = { models: { "User" => { columns: { "email" => { type: "string", pii: false } } } } }
        new_schema = { models: { "User" => { columns: { "email" => { type: "string", pii: true } } } } }

        differences = Diff.compare(old_schema, new_schema)

        assert_equal 1, differences.size
        assert_equal :pii_field_added, differences.first[:type]
        assert_equal :warning, differences.first[:severity]
      end

      def test_detects_pii_field_removed
        old_schema = { models: { "User" => { columns: { "email" => { type: "string", pii: true } } } } }
        new_schema = { models: { "User" => { columns: { "email" => { type: "string", pii: false } } } } }

        differences = Diff.compare(old_schema, new_schema)

        assert_equal 1, differences.size
        assert_equal :pii_field_removed, differences.first[:type]
        assert_equal :info, differences.first[:severity]
      end

      def test_detects_event_prefix_change
        old_schema = { models: { "User" => { event_prefix: "User", columns: {} } } }
        new_schema = { models: { "User" => { event_prefix: "UserEvent", columns: {} } } }

        differences = Diff.compare(old_schema, new_schema)

        assert_equal 1, differences.size
        assert_equal :event_prefix_changed, differences.first[:type]
        assert_equal :warning, differences.first[:severity]
      end

      def test_detects_config_change
        old_schema = { models: {}, configuration: { mode: "monitor" } }
        new_schema = { models: {}, configuration: { mode: "hijack" } }

        differences = Diff.compare(old_schema, new_schema)

        assert_equal 1, differences.size
        assert_equal :config_changed, differences.first[:type]
        assert_equal :info, differences.first[:severity]
      end

      def test_format_report_with_no_changes
        differences = []

        report = Diff.format_report(differences)

        assert_includes report, "No schema changes detected"
      end

      def test_format_report_with_breaking_changes
        differences = [
          { type: :column_removed, severity: :breaking, message: "Column removed" }
        ]

        report = Diff.format_report(differences)

        assert_includes report, "BREAKING"
        assert_includes report, "Column removed"
        assert_includes report, "ACTION REQUIRED"
      end

      def test_format_report_with_multiple_severities
        differences = [
          { type: :model_added, severity: :info, message: "Model added" },
          { type: :column_nullable_changed, severity: :warning, message: "Nullable changed" },
          { type: :column_removed, severity: :breaking, message: "Column removed" }
        ]

        report = Diff.format_report(differences)

        assert_includes report, "BREAKING"
        assert_includes report, "WARNING"
        assert_includes report, "INFO"
      end

      # Additional tests for better coverage

      def test_detects_column_limit_change
        old_schema = { models: { "User" => { columns: { "name" => { type: "string", limit: 50 } } } } }
        new_schema = { models: { "User" => { columns: { "name" => { type: "string", limit: 255 } } } } }

        differences = Diff.compare(old_schema, new_schema)

        assert_equal 1, differences.size
        assert_equal :column_limit_changed, differences.first[:type]
        assert_equal :warning, differences.first[:severity]
        assert_equal 50, differences.first[:old_value]
        assert_equal 255, differences.first[:new_value]
      end

      def test_detects_event_rename
        old_schema = { models: { "User" => {
          columns: {},
          events: { "UserCreated" => { operation: :created } }
        } } }
        new_schema = { models: { "User" => {
          columns: {},
          events: { "UserRegistered" => { operation: :created } }
        } } }

        differences = Diff.compare(old_schema, new_schema)

        assert_equal 1, differences.size
        assert_equal :event_name_changed, differences.first[:type]
        assert_equal :breaking, differences.first[:severity]
        assert_equal "UserCreated", differences.first[:old_value]
        assert_equal "UserRegistered", differences.first[:new_value]
      end

      def test_handles_symbol_keys_in_schema
        # Test that symbol and string keys are normalized - use same string value for type
        old_schema = { models: { User: { columns: { id: { type: "integer" } } } } }
        new_schema = { models: { "User" => { columns: { "id" => { "type" => "integer" } } } } }

        differences = Diff.compare(old_schema, new_schema)

        assert_empty differences
      end

      def test_handles_empty_schemas
        differences = Diff.compare({}, {})
        assert_empty differences
      end

      def test_handles_nil_models
        old_schema = { models: nil }
        new_schema = { models: nil }

        differences = Diff.compare(old_schema, new_schema)

        assert_empty differences
      end

      def test_handles_nil_columns
        old_schema = { models: { "User" => { columns: nil } } }
        new_schema = { models: { "User" => { columns: nil } } }

        differences = Diff.compare(old_schema, new_schema)

        assert_empty differences
      end

      def test_detects_multiple_column_changes
        old_schema = { models: { "User" => { columns: {
          "email" => { type: "string", nullable: true, pii: false }
        } } } }
        new_schema = { models: { "User" => { columns: {
          "email" => { type: "text", nullable: false, pii: true }
        } } } }

        differences = Diff.compare(old_schema, new_schema)

        types = differences.map { |d| d[:type] }
        assert_includes types, :column_type_changed
        assert_includes types, :column_nullable_changed
        assert_includes types, :pii_field_added
      end

      def test_format_report_uses_severity_icons
        differences = [
          { type: :model_added, severity: :info, message: "Added model" },
          { type: :column_nullable_changed, severity: :warning, message: "Nullable changed" },
          { type: :column_removed, severity: :breaking, message: "Column removed" }
        ]

        report = Diff.format_report(differences)

        assert_includes report, "[!]"  # breaking icon
        assert_includes report, "[?]"  # warning icon
        assert_includes report, "[i]"  # info icon
      end

      def test_detects_strict_schema_config_change
        old_schema = { models: {}, configuration: { strict_schema: false } }
        new_schema = { models: {}, configuration: { strict_schema: true } }

        differences = Diff.compare(old_schema, new_schema)

        assert_equal 1, differences.size
        assert_equal :config_changed, differences.first[:type]
        assert_equal "strict_schema", differences.first[:key]
      end

      def test_detects_projection_mode_config_change
        old_schema = { models: {}, configuration: { projection_mode: :sync } }
        new_schema = { models: {}, configuration: { projection_mode: :async } }

        differences = Diff.compare(old_schema, new_schema)

        assert_equal 1, differences.size
        assert_equal :config_changed, differences.first[:type]
        assert_equal "projection_mode", differences.first[:key]
      end

      def test_compare_model_instance_method
        diff = Diff.new
        old_model = { "event_prefix" => "User", "columns" => {}, "events" => {} }
        new_model = { "event_prefix" => "Account", "columns" => {}, "events" => {} }

        differences = diff.compare_model("User", old_model, new_model)

        assert_equal 1, differences.size
        assert_equal :event_prefix_changed, differences.first[:type]
      end

      def test_pii_message_includes_type
        old_schema = { models: { "User" => { columns: { "id" => { type: "integer" } } } } }
        new_schema = { models: { "User" => { columns: {
          "id" => { type: "integer" },
          "ssn" => { type: "string", pii: true, pii_type: "ssn" }
        } } } }

        differences = Diff.compare(old_schema, new_schema)
        message = differences.first[:message]

        assert_includes message, "PII: ssn"
      end

      def test_class_methods_delegate_to_instance
        schema = { models: { "User" => { columns: { "id" => { type: "integer" } } } } }

        # Test that class methods work correctly
        differences = Diff.compare(schema, schema)
        assert_empty differences

        report = Diff.format_report([])
        assert_includes report, "No schema changes detected"
      end

      # ===========================================================================
      # Tests for diff output keys (used by the schema view for display)
      # ===========================================================================

      def test_column_change_includes_column_key_not_field
        old_schema = { models: { "User" => { columns: { "email" => { type: "string" } } } } }
        new_schema = { models: { "User" => { columns: { "email" => { type: "text" } } } } }

        differences = Diff.compare(old_schema, new_schema)
        change = differences.first

        # View uses :column key, not :field
        assert change.key?(:column), "Change should have :column key"
        assert_equal "email", change[:column]
        refute change.key?(:field), "Change should NOT have :field key"
      end

      def test_column_change_includes_message_key_not_description
        old_schema = { models: { "User" => { columns: { "email" => { type: "string" } } } } }
        new_schema = { models: { "User" => { columns: { "email" => { type: "text" } } } } }

        differences = Diff.compare(old_schema, new_schema)
        change = differences.first

        # View uses :message key, not :description
        assert change.key?(:message), "Change should have :message key"
        refute change.key?(:description), "Change should NOT have :description key"
      end

      def test_column_change_includes_old_value_new_value_not_from_to
        old_schema = { models: { "User" => { columns: { "age" => { type: "string" } } } } }
        new_schema = { models: { "User" => { columns: { "age" => { type: "integer" } } } } }

        differences = Diff.compare(old_schema, new_schema)
        change = differences.first

        # View uses :old_value/:new_value, not :from/:to
        assert change.key?(:old_value), "Change should have :old_value key"
        assert change.key?(:new_value), "Change should have :new_value key"
        assert_equal "string", change[:old_value]
        assert_equal "integer", change[:new_value]
        refute change.key?(:from), "Change should NOT have :from key"
        refute change.key?(:to), "Change should NOT have :to key"
      end

      def test_diff_output_complete_structure_for_view
        old_schema = { models: { "User" => { columns: {
          "email" => { type: "string", nullable: true }
        } } } }
        new_schema = { models: { "User" => { columns: {
          "email" => { type: "text", nullable: false }
        } } } }

        differences = Diff.compare(old_schema, new_schema)

        # Each change should have the keys the view expects
        differences.each do |change|
          assert change.key?(:type), "Change must have :type"
          assert change.key?(:model), "Change must have :model"
          assert change.key?(:message), "Change must have :message"

          # Column-level changes must have :column
          if [:column_type_changed, :column_nullable_changed, :column_added, :column_removed].include?(change[:type])
            assert change.key?(:column), "Column change must have :column key"
          end

          # Value changes must have old_value/new_value
          if [:column_type_changed, :column_nullable_changed, :column_limit_changed].include?(change[:type])
            assert change.key?(:old_value), "Value change must have :old_value"
            assert change.key?(:new_value), "Value change must have :new_value"
          end
        end
      end
    end
  end
end
