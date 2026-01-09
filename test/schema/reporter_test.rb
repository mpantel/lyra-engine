# frozen_string_literal: true

require "test_helper"

module Lyra
  module Schema
    class ReporterTest < Minitest::Test
      def setup
        @sample_schema = {
          version: 1,
          created_at: Time.now.iso8601,
          lyra_version: "1.0.0",
          fingerprint: "abc123",
          configuration: {
            mode: :monitor,
            strict_schema: false,
            projection_mode: :sync
          },
          models: {
            "User" => {
              table_name: "users",
              event_prefix: "User",
              aggregate_class: "Lyra::GenericAggregate",
              columns: {
                "id" => { type: "integer", nullable: false, pii: false },
                "email" => { type: "string", nullable: false, pii: true, pii_type: "email" },
                "name" => { type: "string", nullable: true, pii: true, pii_type: "name" }
              },
              events: {
                "UserCreated" => { operation: :created, pii_fields: ["email", "name"] },
                "UserUpdated" => { operation: :updated, pii_fields: ["email", "name"] },
                "UserDestroyed" => { operation: :destroyed, pii_fields: [] }
              }
            },
            "Article" => {
              table_name: "articles",
              event_prefix: "Article",
              aggregate_class: nil,
              columns: {
                "id" => { type: "integer", nullable: false, pii: false },
                "title" => { type: "string", nullable: false, pii: false },
                "author_id" => { type: "integer", nullable: false, pii: false }
              },
              events: {
                "ArticleCreated" => { operation: :created, pii_fields: [] },
                "ArticleUpdated" => { operation: :updated, pii_fields: [] }
              }
            }
          }
        }
      end

      def test_generate_returns_report_hash
        Store.stubs(:load_current).returns(@sample_schema)

        report = Reporter.generate

        assert_kind_of Hash, report
        assert report.key?(:header)
        assert report.key?(:models)
        assert report.key?(:events)
        assert report.key?(:pii)
        assert report.key?(:configuration)
      end

      def test_generate_header_extracts_version_info
        Store.stubs(:load_current).returns(@sample_schema)

        report = Reporter.generate

        assert_equal 1, report[:header][:version]
        assert_equal "1.0.0", report[:header][:lyra_version]
        assert_equal "abc123", report[:header][:fingerprint]
      end

      def test_generate_models_report_extracts_model_info
        Store.stubs(:load_current).returns(@sample_schema)

        report = Reporter.generate

        user_model = report[:models]["User"]
        assert_equal "users", user_model[:table_name]
        assert_equal "User", user_model[:event_prefix]
        assert_equal 3, user_model[:column_count]
        assert_includes user_model[:pii_fields], "email"
        assert_includes user_model[:pii_fields], "name"
      end

      def test_generate_events_report_lists_all_events
        Store.stubs(:load_current).returns(@sample_schema)

        report = Reporter.generate

        event_names = report[:events].map { |e| e[:event_name] }
        assert_includes event_names, "UserCreated"
        assert_includes event_names, "UserUpdated"
        assert_includes event_names, "ArticleCreated"
      end

      def test_generate_events_report_sorted_by_model_and_operation
        Store.stubs(:load_current).returns(@sample_schema)

        report = Reporter.generate
        events = report[:events]

        # Article events should come before User events (alphabetical by model)
        article_idx = events.index { |e| e[:model] == "Article" }
        user_idx = events.index { |e| e[:model] == "User" }
        assert article_idx < user_idx
      end

      def test_generate_pii_report_groups_by_type
        Store.stubs(:load_current).returns(@sample_schema)

        report = Reporter.generate

        assert report[:pii].key?("email")
        assert report[:pii].key?("name")
        assert_includes report[:pii]["email"], "User.email"
        assert_includes report[:pii]["name"], "User.name"
      end

      def test_to_s_returns_formatted_string
        Store.stubs(:load_current).returns(@sample_schema)

        output = Reporter.to_s

        assert_kind_of String, output
        assert_includes output, "Lyra Event Schema Report"
        assert_includes output, "User"
        assert_includes output, "Article"
      end

      def test_to_s_includes_configuration_section
        Store.stubs(:load_current).returns(@sample_schema)

        output = Reporter.to_s

        assert_includes output, "CONFIGURATION"
        assert_includes output, "Mode:"
        assert_includes output, "Strict Schema:"
        assert_includes output, "Projection Mode:"
      end

      def test_to_s_includes_model_mappings_section
        Store.stubs(:load_current).returns(@sample_schema)

        output = Reporter.to_s

        assert_includes output, "MODEL -> EVENT MAPPINGS"
        assert_includes output, "Table: users"
        assert_includes output, "Event Prefix: User"
        assert_includes output, "Events:"
        assert_includes output, "-> UserCreated"
      end

      def test_to_s_includes_pii_summary
        Store.stubs(:load_current).returns(@sample_schema)

        output = Reporter.to_s

        assert_includes output, "PII SUMMARY BY TYPE"
        assert_includes output, "email:"
        assert_includes output, "User.email"
      end

      def test_to_s_includes_all_events_section
        Store.stubs(:load_current).returns(@sample_schema)

        output = Reporter.to_s

        assert_includes output, "ALL EVENTS"
        assert_includes output, "Event Name"
        assert_includes output, "Model"
        assert_includes output, "Operation"
      end

      def test_to_s_marks_pii_events
        Store.stubs(:load_current).returns(@sample_schema)

        output = Reporter.to_s

        # UserCreated has PII fields
        assert_includes output, "[PII]"
      end

      def test_generate_falls_back_to_generator_when_no_stored_schema
        Store.stubs(:load_current).returns(nil)
        Generator.stubs(:generate).returns(@sample_schema)

        report = Reporter.generate

        assert_kind_of Hash, report
        assert report[:models].key?("User")
      end

      def test_to_s_shows_unsaved_message_when_no_version
        schema_without_version = @sample_schema.dup
        schema_without_version.delete(:version)
        Store.stubs(:load_current).returns(schema_without_version)

        output = Reporter.to_s

        assert_includes output, "not yet saved"
      end

      def test_handles_empty_models
        empty_schema = {
          version: 1,
          lyra_version: "1.0.0",
          configuration: { mode: :monitor },
          models: {}
        }
        Store.stubs(:load_current).returns(empty_schema)

        report = Reporter.generate

        assert_empty report[:models]
        assert_empty report[:events]
        assert_empty report[:pii]
      end

      def test_handles_nil_configuration
        schema_nil_config = @sample_schema.dup
        schema_nil_config[:configuration] = nil
        Store.stubs(:load_current).returns(schema_nil_config)

        output = Reporter.to_s

        # Should not crash, should show 'unknown' for mode
        assert_includes output, "CONFIGURATION"
      end

      def test_handles_model_without_pii_fields
        Store.stubs(:load_current).returns(@sample_schema)

        report = Reporter.generate

        article_model = report[:models]["Article"]
        assert_empty article_model[:pii_fields]
      end

      def test_class_methods_delegate_to_instance
        Store.stubs(:load_current).returns(@sample_schema)

        # Both should work without errors
        report = Reporter.generate
        output = Reporter.to_s

        assert_kind_of Hash, report
        assert_kind_of String, output
      end

      def test_instance_to_s_method
        Store.stubs(:load_current).returns(@sample_schema)

        reporter = Reporter.new
        output = reporter.to_s

        assert_kind_of String, output
        assert_includes output, "Lyra Event Schema Report"
      end
    end
  end
end
