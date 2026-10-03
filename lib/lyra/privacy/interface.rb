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
    Annotation = Struct.new(:field, :type, :sensitivity, :sensitive, :purposes, :source, :transformations,
                            keyword_init: true)

    # A model's retention rule: how long its records are kept (+duration+,
    # with per-attribute +field_durations+), what happens on expiry
    # (+strategy+: :anonymize, :hard_delete, :soft_delete or :archive), and
    # +applies+, a predicate on the record for the rule's conditions.
    RetentionRule = Struct.new(:duration, :field_durations, :strategy, :applies, keyword_init: true)

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

      # The RetentionRule the policy declares for +model_class+, or nil.
      def retention_rule(_model_class)
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

      # Stamp an event's metadata with the privacy annotation of the personal
      # data it carries (config.annotate_privacy, off by default): the policy's
      # name and, for each declared attribute, its type, sensitivity, allowed
      # purposes (purpose limitation), retention period (ISO 8601) and the
      # contexts it has a transformation for. Never a value.
      #
      # This is step 1 of the Privacy Policy Coverage theorem done when the
      # event is built, as the theorem states it, rather than recovered later
      # (annotations_for): the annotation records the policy as it was when
      # the data was written, so reclassifying a field later does not rewrite
      # the history, and it can be read without the policy or PAM.
      #
      # A create (or import, or destroy) annotates the attributes it carries;
      # an update only the ones it changed. An event with no declared
      # attribute, or a model without a loaded policy, is left unstamped.
      #
      # @return [Hash] the metadata, with metadata[:privacy] added when there
      #   is something to annotate
      def stamp(model_class, data, metadata)
        return metadata unless Lyra.config.annotate_privacy

        policy = policy_for(model_class)
        return metadata unless policy.loaded?

        attributes = data[:attributes] || data["attributes"] || {}
        changes = data[:changes] || data["changes"] || {}
        # Every declared attribute the event carries: an update's own changes
        # and, in Monitor, the whole row it also carries. Stamping only the
        # changes left 28,374 of the Olist replay's events carrying personal
        # data unannotated, against Theorem 3's premise.
        touched = attributes.keys | changes.keys

        fields = touched.each_with_object({}) do |field, acc|
          annotation = policy.annotation(field)
          next unless annotation

          entry = {
            "type" => annotation.type.to_s,
            "sensitivity" => annotation.sensitivity.to_s,
            "purposes" => Array(annotation.purposes).map(&:to_s)
          }
          retention = policy.retention_for(model_class.name, field_name: field.to_s)
          entry["retention"] = retention.respond_to?(:iso8601) ? retention.iso8601 : "PT#{retention.to_i}S" if retention
          transformations = Array(annotation.transformations).map(&:to_s)
          entry["transformations"] = transformations if transformations.any?
          acc[field.to_s] = entry
        end
        return metadata if fields.empty?

        metadata.to_h.merge(privacy: { "policy" => policy.name.to_s, "fields" => fields })
      end

      # The stamp of a stored event, with string keys at every level (the
      # event store's serializer may hand nested keys back as symbols), or nil
      # if it was not stamped.
      def stamp_of(event)
        metadata = event.metadata.to_h
        privacy = metadata[:privacy] || metadata["privacy"]
        privacy && deep_stringify(privacy)
      end

      private

      def deep_stringify(value)
        case value
        when Hash then value.to_h { |k, v| [k.to_s, deep_stringify(v)] }
        when Array then value.map { deep_stringify(_1) }
        when Symbol then value.to_s
        else value
        end
      end

      def default_provider
        defined?(Adapters::Pam) ? Adapters::Pam.new : Provider.new
      end
    end
  end
end
