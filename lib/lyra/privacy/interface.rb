# frozen_string_literal: true

module Lyra
  # What Lyra needs from a privacy layer, independent of any one policy
  # language.
  #
  # A provider supplies two things:
  #
  # - a Policy per name: the attributes declared personal and an annotation
  #   for each (type, sensitivity, allowed purposes), plus the access,
  #   retention and masking rules. This is the pair Pi_C = (D_C, ann_C) of
  #   the Privacy Policy Coverage theorem.
  # - a Detector: a heuristic that proposes which attributes look personal
  #   when no policy declares them.
  #
  # The base classes below are the null implementations: no policy declares
  # anything, every access is allowed, and the detector finds nothing. They
  # are what Lyra runs with when no provider is installed. PAM plugs in as
  # Lyra::Privacy::Adapters::Pam (loaded when the pam_dsl gem is present).
  module Privacy
    Annotation = Struct.new(:field, :type, :sensitivity, :sensitive, :purposes, :source, keyword_init: true)

    class Policy
      def name
        nil
      end

      def loaded?
        false
      end

      def declared_fields
        []
      end

      # The annotation for a declared field, or nil if the field isn't declared.
      def annotation(_field)
        nil
      end

      def declared?(field)
        !annotation(field).nil?
      end

      def allowed?(_field, _purpose)
        true
      end

      def validate_access!(_fields, _purpose, subject:)
        true
      end

      def allowed_purposes(_field)
        []
      end

      def consent_required?(_purpose)
        false
      end

      # nil means no retention limit is declared.
      def retention_for(_model_class, field_name: nil)
        nil
      end

      def mask(_field, value, _context = :display)
        value
      end

      def sensitive_fields
        []
      end

      def restricted_fields
        []
      end

      def purposes_count
        0
      end

      def metadata
        {}
      end
    end

    class Detector
      # { attribute => { type:, value:, sensitive: } } for attributes that look personal
      def detect(_attributes)
        {}
      end

      def contains_pii?(_field)
        false
      end

      def pii_type(_field)
        nil
      end

      def mask(value, _pii_type)
        value
      end

      def sensitive?(_pii_type)
        false
      end

      def extract_from_records(_records, attribute_extractor:, metadata_extractor:)
        {}
      end
    end

    class Provider
      def name
        :none
      end

      def available?
        false
      end

      def policy(_name)
        Policy.new
      end

      def detector
        @detector ||= Detector.new
      end
    end

    class << self
      attr_writer :provider

      def provider
        @provider ||= default_provider
      end

      def policy(name)
        name ? provider.policy(name) : Policy.new
      end

      # The policy named by a monitored model's privacy_policy option, or
      # else the default policy (Lyra.config.privacy_policy).
      def policy_for(model_class)
        config = model_class.respond_to?(:lyra_config) && model_class.lyra_config
        config ||= Lyra.config.model_config(model_class)
        policy(config&.privacy_policy || Lyra.config.privacy_policy)
      end

      def detector
        provider.detector
      end

      # Step 1 of the Privacy Policy Coverage theorem: an event carries its
      # entity class and the attribute names it touched, so the annotation of
      # every declared attribute can be recovered from the event alone. Keyed
      # by attribute name.
      def annotations_for(event)
        model_class = event.model_class.to_s.safe_constantize
        return {} unless model_class

        policy = policy_for(model_class)
        return {} unless policy.loaded?

        touched = (event.attributes || {}).keys | (event.changes || {}).keys
        touched.each_with_object({}) do |field, acc|
          annotation = policy.annotation(field)
          acc[field.to_s] = annotation if annotation
        end
      end

      private

      def default_provider
        defined?(Adapters::Pam) ? Adapters::Pam.new : Provider.new
      end
    end
  end
end
