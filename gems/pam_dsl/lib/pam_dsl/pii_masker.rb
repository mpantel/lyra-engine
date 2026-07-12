# frozen_string_literal: true

module PamDsl
  # Masks PII in attribute hashes for safe display or logging
  #
  # PIIMasker provides batch masking of PII fields in data structures,
  # using PIIDetector for field detection and type-specific masking.
  #
  # @example Mask all PII in a hash
  #   data = { email: "alice@example.com", name: "Alice", status: "active" }
  #   masked = PamDsl::PIIMasker.mask(data)
  #   # => { email: "a***@example.com", name: "Alice ***", status: "active" }
  #
  # @example Full redaction mode
  #   masked = PamDsl::PIIMasker.mask(data, strategy: :full)
  #   # => { email: "[REDACTED]", name: "[REDACTED]", status: "active" }
  #
  # @example Mask a single field
  #   PamDsl::PIIMasker.mask_field("alice@example.com", :email)
  #   # => "a***@example.com"
  #
  class PIIMasker
    # Masking strategies
    STRATEGIES = %i[partial full redact_sensitive].freeze

    class << self
      # Mask all PII fields in an attributes hash
      #
      # @param attributes [Hash] Key-value pairs to mask
      # @param strategy [Symbol] Masking strategy:
      #   - :partial (default) - Type-specific partial masking (e.g., "a***@example.com")
      #   - :full - Complete redaction with "[REDACTED]"
      #   - :redact_sensitive - Full redaction only for sensitive types (ssn, credit_card, etc.)
      # @return [Hash] New hash with PII fields masked
      #
      def mask(attributes, strategy: :partial)
        raise ArgumentError, "Unknown strategy #{strategy.inspect}. Must be one of: #{STRATEGIES.join(', ')}" unless STRATEGIES.include?(strategy)
        return attributes if attributes.nil? || attributes.empty?

        masked = attributes.dup
        pii_fields = PIIDetector.detect(attributes)

        pii_fields.each do |key, info|
          masked[key] = mask_value(info[:value], info[:type], strategy, info[:sensitive])
        end

        masked
      end

      # Mask all PII in a collection of records
      #
      # @param records [Enumerable] Collection of records to mask
      # @param attribute_extractor [Proc] Block that extracts attributes hash from a record
      # @param attribute_setter [Proc] Block that returns a new record with masked attributes
      # @param strategy [Symbol] Masking strategy (see #mask)
      # @return [Array] New array with masked records
      #
      # @example With hashes
      #   records = [{ email: "a@example.com" }, { email: "b@example.com" }]
      #   PIIMasker.mask_records(
      #     records,
      #     attribute_extractor: ->(r) { r },
      #     attribute_setter: ->(r, masked) { masked }
      #   )
      #
      # @example With objects
      #   PIIMasker.mask_records(
      #     events,
      #     attribute_extractor: ->(e) { e.data },
      #     attribute_setter: ->(e, masked) { e.class.new(e.event_id, masked, e.metadata) }
      #   )
      #
      def mask_records(records, attribute_extractor:, attribute_setter:, strategy: :partial)
        records.map do |record|
          attributes = attribute_extractor.call(record)
          masked_attributes = mask(attributes, strategy: strategy)
          attribute_setter.call(record, masked_attributes)
        end
      end

      # Mask a specific field value by field name
      #
      # @param value [Object] The value to mask
      # @param field_name [String, Symbol] Field name to determine PII type
      # @param strategy [Symbol] Masking strategy (see #mask)
      # @return [Object] Masked value, or original if field is not PII
      #
      def mask_field(value, field_name, strategy: :partial)
        pii_type = PIIDetector.pii_type(field_name)
        return value unless pii_type

        sensitive = PIIDetector.sensitive?(pii_type)
        mask_value(value, pii_type, strategy, sensitive)
      end

      # Mask a value given its PII type
      #
      # @param value [Object] The value to mask
      # @param pii_type [Symbol] The PII type (:email, :phone, :ssn, etc.)
      # @param strategy [Symbol] Masking strategy
      # @return [String] Masked value
      #
      def mask_by_type(value, pii_type, strategy: :partial)
        sensitive = PIIDetector.sensitive?(pii_type)
        mask_value(value, pii_type, strategy, sensitive)
      end

      private

      def mask_value(value, pii_type, strategy, sensitive)
        case strategy
        when :full
          "[REDACTED]"
        when :redact_sensitive
          sensitive ? "[REDACTED]" : PIIDetector.mask(value, pii_type)
        else # :partial
          PIIDetector.mask(value, pii_type)
        end
      end
    end
  end
end
