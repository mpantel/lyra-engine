module Lyra
  module Privacy
    # GDPR compliance tools for Lyra events
    #
    # This class provides a Lyra-specific wrapper around PamDsl::GDPRCompliance,
    # automatically configuring it to work with Lyra's event store and event format.
    #
    # @example Basic usage
    #   compliance = Lyra::Privacy::GDPRCompliance.new(subject_id: user.id)
    #   report = compliance.data_export
    #
    # @example With custom subject type
    #   compliance = Lyra::Privacy::GDPRCompliance.new(
    #     subject_id: student.id,
    #     subject_type: 'Student'
    #   )
    #
    class GDPRCompliance
      attr_reader :pam_compliance

      # Initialize GDPR compliance handler
      #
      # @param subject_id [Object] The data subject's identifier
      # @param subject_type [String] The type/class of the subject (default: 'User')
      #
      def initialize(subject_id:, subject_type: 'User')
        @subject_id = subject_id
        @subject_type = subject_type

        @pam_compliance = PamDsl::GDPRCompliance.new(
          subject_id: subject_id,
          subject_type: subject_type,
          record_reader: method(:read_subject_events),
          attribute_extractor: method(:extract_attributes),
          timestamp_extractor: method(:extract_timestamp),
          operation_extractor: method(:extract_operation),
          model_class_extractor: method(:extract_model_class),
          model_id_extractor: method(:extract_model_id),
          changes_extractor: method(:extract_changes),
          retention_policy: retention_policy
        )
      end

      # Delegate all GDPR methods to the PAM DSL implementation

      # Right to Access (Article 15)
      def data_export
        pam_compliance.data_export
      end

      # Right to be Forgotten (Article 17)
      def right_to_be_forgotten_report
        pam_compliance.right_to_be_forgotten_report
      end

      # Right to Data Portability (Article 20)
      def portable_export(format: :json)
        pam_compliance.portable_export(format: format)
      end

      # Right to Rectification (Article 16)
      def rectification_history
        pam_compliance.rectification_history
      end

      # Processing Activities Record (Article 30)
      def processing_activities
        pam_compliance.processing_activities
      end

      # Data Retention Compliance Check
      def retention_compliance_check
        pam_compliance.retention_compliance_check
      end

      # Consent Audit
      def consent_audit
        pam_compliance.consent_audit
      end

      # Full GDPR Compliance Report
      def full_report
        pam_compliance.full_report
      end

      private

      # Read all events related to the subject from Lyra's event store
      def read_subject_events(subject_id, subject_type)
        Lyra.config.event_store.read.to_a.select do |event|
          event_relates_to_subject?(event, subject_id, subject_type)
        end
      end

      # Whether an event holds the subject's data: an event of the subject's
      # own record, or of a record that refers to the subject through its
      # foreign key (a Registration's user_id, for subject type User).
      #
      # Who *made* a change is not whose data it is: before 0.9.3 an event
      # whose metadata named the subject as its actor (metadata[:user_id])
      # was exported too, so a staff member's export held every record they
      # had edited, other people's data, while a subject's own records written
      # by staff could be missed.
      def event_relates_to_subject?(event, subject_id, subject_type)
        data = event.respond_to?(:data) ? event.data : {}
        id = subject_id.to_s
        return true if extract_model_class(event).to_s == subject_type.to_s && extract_model_id(event).to_s == id

        explicit = data[:subject_id] || data["subject_id"]
        if explicit
          type = data[:subject_type] || data["subject_type"]
          return explicit.to_s == id && (type.nil? || type.to_s == subject_type.to_s)
        end

        attributes = extract_attributes(event)
        value = attributes[subject_foreign_key(subject_type)] || attributes[subject_foreign_key(subject_type).to_sym]
        !value.nil? && value.to_s == id
      end

      # The foreign key a record uses to refer to a subject of +subject_type+.
      def subject_foreign_key(subject_type)
        "#{subject_type.to_s.demodulize.underscore}_id"
      end

      # Lyra-specific extractors

      def extract_attributes(event)
        return event.attributes if event.respond_to?(:attributes) && !event.attributes.is_a?(Method)
        return event.data[:attributes] || event.data["attributes"] || {} if event.respond_to?(:data)
        {}
      end

      def extract_timestamp(event)
        return event.timestamp if event.respond_to?(:timestamp) && event.timestamp
        return event.data[:timestamp] || event.data["timestamp"] if event.respond_to?(:data)
        event.metadata[:timestamp] if event.respond_to?(:metadata)
      end

      def extract_operation(event)
        return event.operation if event.respond_to?(:operation)
        if event.respond_to?(:data)
          op = event.data[:operation] || event.data["operation"]
          op.is_a?(String) ? op.to_sym : op
        end
      end

      def extract_model_class(event)
        return event.model_class if event.respond_to?(:model_class)
        event.data[:model_class] || event.data["model_class"] if event.respond_to?(:data)
      end

      def extract_model_id(event)
        return event.model_id if event.respond_to?(:model_id)
        event.data[:model_id] || event.data["model_id"] if event.respond_to?(:data)
      end

      def extract_changes(event)
        if event.respond_to?(:changes) && !event.changes.is_a?(Method)
          begin
            return event.changes unless event.method(:changes).owner.to_s.include?('ActiveRecord')
          rescue
            return event.changes
          end
        end
        return event.data[:changes] || event.data["changes"] || {} if event.respond_to?(:data)
        {}
      end

      # The retention periods the compliance check applies, as PAM's check
      # expects them ({ "Model" => { duration: d }, default: { duration: d } }):
      # each monitored model's period from its privacy policy's retention block,
      # over config.retention_policy, which may be a single duration (7.years) or
      # such a hash.
      #
      # Before 0.9.3 the policies' retention blocks were ignored in favour of
      # hard-coded periods for models named Payment, Invoice, Student and
      # Enrollment, and a single duration in config.retention_policy raised
      # TypeError.
      def retention_policy
        configured = Lyra.config.retention_policy
        policy =
          case configured
          when nil then { default: { duration: 7.years } }
          when Hash then configured.transform_values { |v| v.is_a?(Hash) ? v : { duration: v } }
          else { default: { duration: configured } }
          end

        Lyra.config.monitored_models.each do |model|
          duration = Lyra::Privacy.policy_for(model).retention_for(model)
          policy[model.name] = { duration: duration } if duration.is_a?(ActiveSupport::Duration)
        rescue StandardError
          next
        end
        policy
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
        events = Lyra.config.event_store.read.to_a

        events.group_by { |e| extract_model_class(e) }.map do |model_class, model_events|
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
              timestamp = extract_timestamp(event)
              timestamp && timestamp < (Time.current - retention_duration)
            end

            {
              model_class: model_class,
              total_events: model_events.count,
              expired_events: expired.count,
              retention_period: retention_duration,
              compliance_status: expired.empty? ? :compliant : :requires_action,
              expired_event_ids: expired.map { |e| e.respond_to?(:event_id) ? e.event_id : e.object_id }
            }
          end
        end
      end
    end
  end
end
