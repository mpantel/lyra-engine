# frozen_string_literal: true

require "digest"

module Lyra
  module Schema
    # Generates event schemas from monitored ActiveRecord models
    class Generator
      STANDARD_DATA_FIELDS = %w[model_class model_id operation attributes changes timestamp].freeze
      STANDARD_METADATA_FIELDS = %w[user_id request_id correlation_id causation_id source].freeze

      class << self
        def generate
          new.generate
        end
      end

      def generate
        schema = {
          version: next_version,
          created_at: Time.current.iso8601,
          lyra_version: Lyra::VERSION,
          rails_version: rails_version,
          models: generate_models_schema,
          configuration: generate_configuration_schema,
          summary: nil  # Placeholder, filled after models generated
        }

        schema[:summary] = generate_summary(schema[:models])
        schema[:fingerprint] = compute_fingerprint(schema)

        schema
      end

      private

      def generate_models_schema
        Lyra.config.monitored_models.each_with_object({}) do |model_class, hash|
          hash[model_class.name] = generate_model_schema(model_class)
        end
      end

      def generate_model_schema(model_class)
        config = Lyra.config.model_config(model_class)

        schema = {
          table_name: safe_table_name(model_class),
          event_prefix: config.event_prefix,
          aggregate_class: config.aggregate_class&.name,
          columns: generate_columns_schema(model_class),
          events: generate_events_schema(model_class, config),
          custom_events: extract_custom_events(config),
          privacy_policy: config.privacy_policy&.to_s
        }

        schema
      end

      def generate_columns_schema(model_class)
        return {} unless model_class.respond_to?(:columns)

        model_class.columns.each_with_object({}) do |column, hash|
          pii_info = detect_pii_for_column(column.name)

          hash[column.name] = {
            type: column.type.to_s,
            nullable: column.null,
            limit: column.limit,
            default: safe_default(column.default),
            primary_key: column.name == safe_primary_key(model_class),
            pii: pii_info[:is_pii],
            pii_type: pii_info[:type]&.to_s
          }
        end
      end

      def generate_events_schema(model_class, config)
        [:created, :updated, :destroyed].each_with_object({}) do |operation, hash|
          event_name = config.event_name_for(operation)
          pii_fields = detect_pii_fields(model_class)

          hash[event_name] = {
            operation: operation.to_s,
            data_fields: STANDARD_DATA_FIELDS,
            metadata_fields: STANDARD_METADATA_FIELDS,
            attribute_fields: safe_column_names(model_class),
            pii_fields: pii_fields
          }
        end
      end

      def extract_custom_events(config)
        # Access private instance variable for custom event mappings
        custom_mapping = config.instance_variable_get(:@custom_event_mapping) || {}
        custom_mapping.transform_keys(&:to_s).transform_values(&:to_s)
      end

      def detect_pii_for_column(column_name)
        return { is_pii: false, type: nil } unless Lyra.privacy_features_available?

        is_pii = Lyra::Privacy::PIIDetector.contains_pii?(column_name)

        if is_pii
          # Get the PII type by detecting on a dummy hash
          pii_info = Lyra::Privacy::PIIDetector.detect({ column_name.to_sym => nil })
          type = pii_info.dig(column_name.to_sym, :type)
          { is_pii: true, type: type }
        else
          { is_pii: false, type: nil }
        end
      end

      def detect_pii_fields(model_class)
        return [] unless Lyra.privacy_features_available?
        return [] unless model_class.respond_to?(:column_names)

        model_class.column_names.select do |name|
          Lyra::Privacy::PIIDetector.contains_pii?(name)
        end
      end

      def generate_configuration_schema
        config = Lyra.config
        {
          mode: config.mode.to_s,
          strict_schema: config.strict_schema,
          projection_mode: config.projection_mode.to_s,
          retention_policy: config.retention_policy
        }
      end

      def generate_summary(models)
        total_columns = 0
        total_pii = 0
        total_events = 0

        models.each_value do |model|
          total_columns += model[:columns]&.size || 0
          total_pii += model[:columns]&.count { |_, c| c[:pii] } || 0
          total_events += model[:events]&.size || 0
        end

        {
          models_count: models.size,
          total_columns: total_columns,
          pii_fields_count: total_pii,
          events_count: total_events
        }
      end

      def compute_fingerprint(schema)
        # Exclude version, timestamps, and fingerprint from hash calculation
        content = schema.except(:fingerprint, :version, :created_at).to_yaml
        "sha256:#{Digest::SHA256.hexdigest(content)}"
      end

      def next_version
        Store.latest_version + 1
      end

      def rails_version
        defined?(Rails::VERSION::STRING) ? Rails::VERSION::STRING : "unknown"
      end

      def safe_table_name(model_class)
        model_class.respond_to?(:table_name) ? model_class.table_name : nil
      end

      def safe_primary_key(model_class)
        model_class.respond_to?(:primary_key) ? model_class.primary_key : "id"
      end

      def safe_column_names(model_class)
        model_class.respond_to?(:column_names) ? model_class.column_names : []
      end

      def safe_default(default_value)
        # Convert Proc defaults to string representation
        case default_value
        when Proc
          "(dynamic)"
        when nil
          nil
        else
          default_value.to_s
        end
      end
    end
  end
end
