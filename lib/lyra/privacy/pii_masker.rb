module Lyra
  module Privacy
    # Masks PII in attribute hashes
    #
    # This class delegates to PamDsl::PIIMasker for the core masking logic,
    # providing a unified implementation across both Lyra and PAM DSL.
    #
    # @example Mask all PII in attributes
    #   PIIMasker.mask({ email: "test@example.com", name: "John" })
    #   # => { email: "t***@example.com", name: "John ***" }
    #
    # @example Full redaction
    #   PIIMasker.mask({ email: "test@example.com" }, strategy: :full)
    #   # => { email: "[REDACTED]" }
    #
    class PIIMasker
      class << self
        # Mask all PII fields in an attributes hash
        #
        # @param attributes [Hash] Key-value pairs to mask
        # @param strategy [Symbol] Masking strategy (:partial, :full, :redact_sensitive)
        # @return [Hash] New hash with PII fields masked
        #
        def mask(attributes, strategy: :partial)
          PamDsl::PIIMasker.mask(attributes, strategy: strategy)
        end

        # Mask specific field
        #
        # @param value [Object] The value to mask
        # @param field_name [String, Symbol] Field name to determine PII type
        # @return [Object] Masked value, or original if not PII
        #
        def mask_field(value, field_name)
          PamDsl::PIIMasker.mask_field(value, field_name)
        end

        # Mask all PII in a collection of Lyra events
        #
        # @param events [Array<Lyra::Event>] Events to mask
        # @param strategy [Symbol] Masking strategy
        # @return [Array] Events with masked attributes
        #
        def mask_events(events, strategy: :partial)
          PamDsl::PIIMasker.mask_records(
            events,
            attribute_extractor: ->(e) { e.attributes },
            attribute_setter: ->(e, masked) {
              Lyra::Event.new(
                event_id: e.event_id,
                operation: e.operation,
                model_class: e.model_class,
                model_id: e.model_id,
                attributes: masked,
                changes: e.changes,
                timestamp: e.timestamp,
                metadata: e.metadata
              )
            },
            strategy: strategy
          )
        end
      end
    end
  end
end
