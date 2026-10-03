module Lyra
  module Privacy
    # Detects personally identifiable information (PII) in data
    #
    # Delegates to the installed privacy provider's Detector (PAM's
    # name-based detector when pam_dsl is present). Without a provider it
    # finds nothing.
    #
    # @example Detect PII in attributes
    #   PIIDetector.detect({ email: "test@example.com", name: "John" })
    #   # => { email: { type: :email, value: "test@example.com", sensitive: false }, ... }
    #
    # @example Check if a field contains PII
    #   PIIDetector.contains_pii?(:email)  # => true
    #   PIIDetector.contains_pii?(:count)  # => false
    #
    class PIIDetector
      class << self
        # Detect PII in attributes
        #
        # @param attributes [Hash] Key-value pairs to check for PII
        # @return [Hash] Keys that contain PII, with their type, value, and sensitivity
        #
        def detect(attributes)
          Lyra::Privacy.detector.detect(attributes)
        end

        # Check if a field contains PII
        #
        # @param field_name [String, Symbol] Field name to check
        # @return [Boolean] true if field contains PII
        #
        def contains_pii?(field_name)
          Lyra::Privacy.detector.contains_pii?(field_name)
        end

        # Mask PII for display
        #
        # @param value [Object] The value to mask
        # @param pii_type [Symbol] The type of PII
        # @return [String] Masked value
        #
        def mask(value, pii_type)
          Lyra::Privacy.detector.mask(value, pii_type)
        end

        # Extract all PII from event stream
        #
        # @param events [Array<Lyra::Event>] Events to scan for PII
        # @return [Hash] PII inventory grouped by type
        #
        # @example
        #   events = Lyra.config.event_store.read.stream("User$123").to_a
        #   pii = PIIDetector.extract_from_event_stream(events)
        #   # => { email: [{ field: :email, value: "...", event_id: "...", ... }], ... }
        #
        def extract_from_event_stream(events)
          Lyra::Privacy.detector.extract_from_records(
            events,
            attribute_extractor: ->(e) { e.attributes },
            metadata_extractor: ->(e) {
              {
                event_id: e.event_id,
                timestamp: e.timestamp,
                model_class: e.model_class,
                model_id: e.model_id
              }
            }
          )
        end

        # Check if a PII type is considered sensitive
        #
        # @param pii_type [Symbol] The PII type
        # @return [Boolean]
        #
        def sensitive?(pii_type)
          Lyra::Privacy.detector.sensitive?(pii_type)
        end
      end
    end
  end
end
