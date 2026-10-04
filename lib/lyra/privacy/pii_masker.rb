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
        # Returns new events, one per input event, of the same class, with
        # the same event_id, event type and metadata; only data changes:
        # its attributes are masked, and so is each [old, new] pair in its
        # changes. The stored events are not touched (they are immutable).
        #
        # @param events [Array<Lyra::Event>] Events to mask
        # @param strategy [Symbol] Masking strategy
        # @return [Array<Lyra::Event>] Masked copies of the events
        #
        def mask_events(events, strategy: :partial)
          PamDsl::PIIMasker.mask_records(
            events,
            attribute_extractor: ->(e) { e.attributes },
            attribute_setter: ->(e, masked) { masked_copy(e, masked, strategy) },
            strategy: strategy
          )
        end

        private

        # RubyEventStore events take only event_id:, data: and metadata:.
        # Data keys may be symbols or strings (after JSON serialization);
        # the copy keeps whichever the event has.
        def masked_copy(event, masked_attributes, strategy)
          data = event.data.is_a?(Hash) ? event.data.dup : {}
          attributes_key = data.key?("attributes") ? "attributes" : :attributes
          data[attributes_key] = masked_attributes

          changes_key = data.key?("changes") ? "changes" : :changes
          if data[changes_key].is_a?(Hash)
            data[changes_key] = data[changes_key].to_h do |field, values|
              masked = Array(values).map do |v|
                v.nil? ? v : PamDsl::PIIMasker.mask_field(v, field, strategy: strategy)
              end
              [field, values.is_a?(Array) ? masked : masked.first]
            end
          end

          event.class.new(event_id: event.event_id, data: data, metadata: event.metadata.to_h)
        end
      end
    end
  end
end
