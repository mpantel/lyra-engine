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
          event_reader: method(:read_subject_events),
          attribute_extractor: method(:extract_attributes),
          timestamp_extractor: method(:extract_timestamp),
          operation_extractor: method(:extract_operation),
          model_class_extractor: method(:extract_model_class),
          model_id_extractor: method(:extract_model_id),
          changes_extractor: method(:extract_changes),
          retention_policy: Lyra.config.retention_policy || default_retention_policy
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

      # Check if an event relates to the subject
      def event_relates_to_subject?(event, subject_id, subject_type)
        metadata = event.respond_to?(:metadata) ? event.metadata : {}
        data = event.respond_to?(:data) ? event.data : {}

        metadata[:user_id] == subject_id ||
        data[:user_id] == subject_id ||
        data[:subject_id] == subject_id ||
        (extract_model_class(event) == subject_type && extract_model_id(event) == subject_id)
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

      def default_retention_policy
        {
          default: { duration: 7.years },
          'Payment' => { duration: 10.years },
          'Invoice' => { duration: 10.years },
          'Student' => { duration: 10.years },
          'Enrollment' => { duration: 10.years }
        }
      end
    end
  end
end
