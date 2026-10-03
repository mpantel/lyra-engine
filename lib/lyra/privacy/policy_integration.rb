module Lyra
  module Privacy
    # Combines a declared policy with the provider's PII detector
    #
    # Declared fields come from the named policy (explicit configuration);
    # other fields fall back to the detector's name-based heuristic.
    # Works through Lyra::Privacy's Policy and Detector interface, so it
    # behaves the same whichever provider is installed; without one, no
    # policy loads and the detector finds nothing.
    #
    # @example With policy and detector fallback (default)
    #   integration = PolicyIntegration.new(:my_policy)
    #   integration.detect_pii(attrs)  # Uses policy + detector
    #
    # @example Policy-only mode
    #   integration = PolicyIntegration.new(:my_policy, use_detector: false)
    #   integration.detect_pii(attrs)  # Only fields defined in policy
    #
    class PolicyIntegration
      attr_reader :policy, :use_detector

      def initialize(policy_name, use_detector: true)
        @policy = Lyra::Privacy.policy(policy_name)
        @use_detector = use_detector && Lyra::Privacy.provider.available?
      end

      # Check if a privacy provider (PAM DSL) is installed
      def pam_dsl_available?
        Lyra::Privacy.provider.available?
      end

      # Check if policy is loaded
      def policy_loaded?
        @policy.loaded?
      end

      # Validate data access for a (fields, purpose, subject) triple.
      def validate_access!(field_names, purpose, subject:)
        @policy.validate_access!(field_names, purpose, subject: subject)
      end

      # Get PII fields from attributes using policy and/or detector
      #
      # Priority:
      # 1. Fields declared in the policy (explicit configuration)
      # 2. Fields found by the detector (pattern-based, if use_detector: true)
      #
      # @param attributes [Hash] Key-value pairs to check for PII
      # @return [Hash] PII fields with type, value, sensitivity
      #
      def detect_pii(attributes)
        attributes.each_with_object({}) do |(key, value), pii_fields|
          annotation = @policy.annotation(key)
          if annotation
            pii_fields[key] = {
              type: annotation.type,
              value: value,
              sensitive: annotation.sensitive,
              sensitivity: annotation.sensitivity,
              source: :policy
            }
          elsif @use_detector
            detected = Lyra::Privacy.detector.detect({ key => value })
            pii_fields[key] = detected[key].merge(source: :detector) if detected[key]
          end
        end
      end

      # Mask PII using policy transformations or the detector
      #
      # @param field_name [Symbol, String] Field name
      # @param value [Object] Value to mask
      # @param context [Symbol] Transformation context (default: :display)
      # @return [Object] Masked value, or original if no masking available
      #
      def mask_pii(field_name, value, context = :display)
        return @policy.mask(field_name, value, context) if @policy.declared?(field_name)

        if @use_detector
          pii_type = Lyra::Privacy.detector.pii_type(field_name)
          return Lyra::Privacy.detector.mask(value, pii_type) if pii_type
        end

        value
      end

      # Get retention duration for model and field
      # Returns nil if no policy loaded (infinite/manual retention)
      def retention_duration(model_class, field_name: nil)
        @policy.retention_for(model_class, field_name: field_name)
      end

      # Check if consent is required for purpose
      def consent_required?(purpose)
        @policy.consent_required?(purpose)
      end

      # Get allowed purposes for a field
      def allowed_purposes(field_name)
        @policy.allowed_purposes(field_name)
      end

      # Check if field is allowed for purpose
      def allowed?(field_name, purpose)
        @policy.allowed?(field_name, purpose)
      end

      # Get all sensitive fields
      def sensitive_fields
        @policy.sensitive_fields
      end

      # Get all restricted fields
      def restricted_fields
        @policy.restricted_fields
      end

      # Get policy metadata
      def metadata
        @policy.metadata
      end

      # Export policy information
      def to_h
        {
          pam_dsl_available: pam_dsl_available?,
          policy_loaded: policy_loaded?,
          use_detector: @use_detector
        }.tap do |info|
          if policy_loaded?
            info.merge!(
              policy_name: @policy.name,
              fields_count: @policy.declared_fields.count,
              purposes_count: @policy.purposes_count,
              sensitive_fields: sensitive_fields,
              restricted_fields: restricted_fields,
              metadata: @policy.metadata
            )
          end
        end
      end
    end
  end
end
