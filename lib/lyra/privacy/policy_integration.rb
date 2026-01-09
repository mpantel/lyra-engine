module Lyra
  module Privacy
    # Integration layer between Lyra and PAM DSL
    #
    # When PAM DSL is available, combines policy-defined fields with
    # pattern-based PIIDetector for comprehensive PII detection.
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
        @use_detector = use_detector
        @policy = PamDsl.policy(policy_name)
      rescue PamDsl::PolicyNotFoundError
        @policy = nil
      rescue NameError
        # PAM DSL not available
        @policy = nil
        @use_detector = false
      end

      # Check if PAM DSL is available
      def pam_dsl_available?
        defined?(PamDsl)
      end

      # Check if policy is loaded
      def policy_loaded?
        !@policy.nil?
      end

      # Validate data access for a purpose
      def validate_access!(field_names, purpose, consent_status = {})
        return true unless policy_loaded?

        @policy.validate_access!(
          field_names,
          purpose,
          consent_granted: consent_status[:granted] || false,
          consent_granted_at: consent_status[:granted_at]
        )
      end

      # Get PII fields from attributes using policy and/or detector
      #
      # Priority:
      # 1. Fields defined in policy (explicit configuration)
      # 2. Fields detected by PIIDetector (pattern-based, if use_detector: true)
      #
      # @param attributes [Hash] Key-value pairs to check for PII
      # @return [Hash] PII fields with type, value, sensitivity
      #
      def detect_pii(attributes)
        return {} unless pam_dsl_available?

        pii_fields = {}

        attributes.each do |key, value|
          field_name = key.to_sym

          # Try policy first
          if policy_loaded?
            begin
              field = @policy.get_field(field_name)
              pii_fields[key] = {
                type: field.type,
                value: value,
                sensitive: field.sensitive?,
                sensitivity: field.sensitivity,
                source: :policy
              }
              next
            rescue PamDsl::InvalidFieldError
              # Field not in policy, try detector below
            end
          end

          # Fall back to PIIDetector if enabled
          if @use_detector
            detected = PamDsl::PIIDetector.detect({ key => value })
            if detected[key]
              pii_fields[key] = detected[key].merge(source: :detector)
            end
          end
        end

        pii_fields
      end

      # Mask PII using policy transformations or PIIDetector
      #
      # @param field_name [Symbol, String] Field name
      # @param value [Object] Value to mask
      # @param context [Symbol] Transformation context (default: :display)
      # @return [Object] Masked value, or original if no masking available
      #
      def mask_pii(field_name, value, context = :display)
        return value unless pam_dsl_available?

        # Try policy transformation first
        if policy_loaded?
          begin
            field = @policy.get_field(field_name)
            return field.apply_transformation(context, value)
          rescue PamDsl::InvalidFieldError
            # Field not in policy, try detector below
          end
        end

        # Fall back to PIIDetector masking if enabled
        if @use_detector
          pii_type = PamDsl::PIIDetector.pii_type(field_name)
          return PamDsl::PIIDetector.mask(value, pii_type) if pii_type
        end

        value
      end

      # Get retention duration for model and field
      # Returns nil if no policy loaded (infinite/manual retention)
      def retention_duration(model_class, field_name: nil)
        return nil unless policy_loaded?
        @policy.retention_for(model_class, field_name: field_name)
      end

      # Check if consent is required for purpose
      def consent_required?(purpose)
        return false unless policy_loaded?

        begin
          purpose_obj = @policy.get_purpose(purpose)
          purpose_obj.requires_consent?
        rescue PamDsl::Error
          false
        end
      end

      # Get allowed purposes for a field
      def allowed_purposes(field_name)
        return [] unless policy_loaded?

        begin
          field = @policy.get_field(field_name)
          field.purposes
        rescue PamDsl::InvalidFieldError
          []
        end
      end

      # Check if field is allowed for purpose
      def allowed?(field_name, purpose)
        return true unless policy_loaded?
        @policy.allowed?(field_name, purpose)
      end

      # Get all sensitive fields
      def sensitive_fields
        return [] unless policy_loaded?
        @policy.sensitive_fields.map(&:name)
      end

      # Get all restricted fields
      def restricted_fields
        return [] unless policy_loaded?
        @policy.restricted_fields.map(&:name)
      end

      # Get policy metadata
      def metadata
        return {} unless policy_loaded?
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
              fields_count: @policy.fields.count,
              purposes_count: @policy.purposes.count,
              sensitive_fields: sensitive_fields,
              restricted_fields: restricted_fields,
              metadata: @policy.metadata
            )
          end
        end
      end
    end

    # Extend GDPRCompliance with policy integration
    class GDPRCompliance
      # Use privacy policy for PII detection if available
      #
      # @param attributes [Hash] Attributes to check
      # @param policy_name [Symbol] Policy name
      # @param use_detector [Boolean] Fall back to PIIDetector (default: true)
      #
      def detect_pii_with_policy(attributes, policy_name, use_detector: true)
        integration = PolicyIntegration.new(policy_name, use_detector: use_detector)
        integration.detect_pii(attributes)
      end

      # Check retention compliance with policy
      # Returns nil for models without defined retention (infinite/manual)
      def retention_compliance_with_policy(policy_name)
        integration = PolicyIntegration.new(policy_name)
        events = collect_all_events

        events.group_by { |e| e.model_class }.map do |model_class, model_events|
          retention_duration = integration.retention_duration(model_class)

          # nil means infinite/manual retention - always compliant
          if retention_duration.nil?
            {
              model_class: model_class,
              total_events: model_events.count,
              expired_events: 0,
              retention_period: nil,
              compliance_status: :manual,
              expired_event_ids: []
            }
          else
            expired = model_events.select do |event|
              event.timestamp && event.timestamp < (Time.current - retention_duration)
            end

            {
              model_class: model_class,
              total_events: model_events.count,
              expired_events: expired.count,
              retention_period: retention_duration,
              compliance_status: expired.empty? ? :compliant : :requires_action,
              expired_event_ids: expired.map(&:event_id)
            }
          end
        end
      end
    end
  end
end
