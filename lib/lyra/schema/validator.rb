# frozen_string_literal: true

module Lyra
  module Schema
    # Validates current schema against stored schema
    class Validator
      attr_reader :current_schema, :stored_schema, :differences

      def initialize
        @current_schema = nil
        @stored_schema = nil
        @differences = []
        @validated = false
      end

      # Check if schema is valid (no differences)
      def valid?
        validate! unless @validated
        @differences.empty?
      end

      # Check if stored schema exists
      def schema_exists?
        Store.exists?
      end

      # Check if there are breaking changes
      def breaking_changes?
        validate! unless @validated
        @differences.any? { |d| d[:severity] == :breaking }
      end

      # Generate human-readable report
      def report
        validate! unless @validated
        Diff.format_report(@differences)
      end

      # Perform validation
      def validate!
        @validated = true
        @stored_schema = Store.load_current
        @current_schema = Generator.generate

        return true if @stored_schema.nil?  # No schema yet = valid

        @differences = Diff.compare(@stored_schema, @current_schema)
        @differences.empty?
      end

      # Validate and enforce strict mode if configured.
      #
      # Severity model (see Diff::SEVERITIES): only BREAKING differences
      # require a new schema version; WARNING means review recommended and
      # INFO a documentation update. With strict_schema, enforce! therefore
      # raises only when at least one breaking difference exists; warning-
      # and info-level drift is logged and the boot continues. Without
      # strict_schema any drift is logged.
      #
      # Returns true when there is no drift, false when drift was logged.
      def enforce!
        return true if valid?

        if Lyra.config.strict_schema && breaking_changes?
          raise SchemaValidationError.new(report, @differences)
        end

        log_warning
        false
      end

      private

      def log_warning
        message = "Lyra: Schema drift detected\n#{report}"
        if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
          Rails.logger.warn(message)
        else
          warn message
        end
      end
    end

    # Custom error for schema validation failures
    class SchemaValidationError < StandardError
      attr_reader :differences

      def initialize(message, differences = [])
        @differences = differences
        super(build_message(message))
      end

      private

      def build_message(report)
        <<~MSG
          Lyra Event Schema Validation Failed!

          #{report}

          To fix this issue, either:
          1. Run 'rake lyra:schema:update' to create a new schema version
          2. Set 'Lyra.config.strict_schema = false' to allow schema drift
          3. Review the changes and ensure they are intentional
        MSG
      end
    end
  end
end
