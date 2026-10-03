# frozen_string_literal: true

module Lyra
  module Privacy
    module Adapters
      # PAM as a Lyra privacy provider. The only place in Lyra's privacy
      # layer that talks to the pam_dsl gem; everything else goes through
      # Lyra::Privacy's Policy and Detector interface.
      class Pam < Provider
        def name
          :pam
        end

        def available?
          true
        end

        def policy(name)
          PamPolicy.new(PamDsl.policy(name))
        rescue PamDsl::PolicyNotFoundError
          Policy.new
        end

        def detector
          @detector ||= PamDetector.new
        end
      end

      class PamPolicy < Policy
        attr_reader :pam_policy

        def initialize(pam_policy)
          @pam_policy = pam_policy
        end

        def name
          pam_policy.name
        end

        def loaded?
          true
        end

        def declared_fields
          pam_policy.fields.keys
        end

        def annotation(field)
          pam_field = find_field(field)
          return nil unless pam_field

          Annotation.new(field: pam_field.name, type: pam_field.type, sensitivity: pam_field.sensitivity,
                         sensitive: pam_field.sensitive?, purposes: pam_field.purposes, source: :policy,
                         transformations: pam_field.transformations.keys)
        end

        def allowed?(field, purpose)
          pam_policy.allowed?(field, purpose)
        end

        def validate_access!(fields, purpose, subject:)
          pam_policy.validate_access!(fields, purpose, subject: subject)
        end

        def allowed_purposes(field)
          find_field(field)&.purposes || []
        end

        def consent_required?(purpose)
          pam_policy.get_purpose(purpose).requires_consent?
        rescue PamDsl::Error
          false
        end

        def retention_for(model_class, field_name: nil)
          pam_policy.retention_for(model_class, field_name: field_name)
        end

        def mask(field, value, context = :display)
          pam_field = find_field(field)
          pam_field ? pam_field.apply_transformation(context, value) : value
        end

        def sensitive_fields
          pam_policy.sensitive_fields.map(&:name)
        end

        def restricted_fields
          pam_policy.restricted_fields.map(&:name)
        end

        def purposes_count
          pam_policy.purposes.count
        end

        def metadata
          pam_policy.metadata
        end

        private

        def find_field(field)
          pam_policy.get_field(field.to_sym)
        rescue PamDsl::InvalidFieldError
          nil
        end
      end

      class PamDetector < Detector
        def detect(attributes)
          PamDsl::PIIDetector.detect(attributes)
        end

        def contains_pii?(field)
          PamDsl::PIIDetector.contains_pii?(field)
        end

        def pii_type(field)
          PamDsl::PIIDetector.pii_type(field)
        end

        def mask(value, pii_type)
          PamDsl::PIIDetector.mask(value, pii_type)
        end

        def sensitive?(pii_type)
          PamDsl::PIIDetector.sensitive?(pii_type)
        end

        def extract_from_records(records, attribute_extractor:, metadata_extractor:)
          PamDsl::PIIDetector.extract_pii_from_records(
            records, attribute_extractor: attribute_extractor, metadata_extractor: metadata_extractor
          )
        end
      end
    end
  end
end
