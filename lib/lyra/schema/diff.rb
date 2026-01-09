# frozen_string_literal: true

module Lyra
  module Schema
    # Compares schemas and produces human-readable difference reports
    class Diff
      # Severity levels for different types of changes
      SEVERITIES = {
        model_added: :info,
        model_removed: :breaking,
        column_added: :info,
        column_removed: :breaking,
        column_type_changed: :breaking,
        column_nullable_changed: :warning,
        column_limit_changed: :warning,
        pii_field_added: :warning,
        pii_field_removed: :info,
        event_name_changed: :breaking,
        event_prefix_changed: :warning,
        config_changed: :info
      }.freeze

      class << self
        def compare(old_schema, new_schema)
          new.compare(old_schema, new_schema)
        end

        def format_report(differences)
          new.format_report(differences)
        end
      end

      def compare(old_schema, new_schema)
        differences = []

        # Compare models (normalize keys to strings for comparison)
        old_models = normalize_keys(old_schema[:models] || {})
        new_models = normalize_keys(new_schema[:models] || {})

        # Check for removed models
        (old_models.keys - new_models.keys).each do |model_name|
          differences << {
            type: :model_removed,
            severity: SEVERITIES[:model_removed],
            model: model_name,
            message: "Model '#{model_name}' was removed from monitoring"
          }
        end

        # Check for added models
        (new_models.keys - old_models.keys).each do |model_name|
          differences << {
            type: :model_added,
            severity: SEVERITIES[:model_added],
            model: model_name,
            message: "Model '#{model_name}' was added to monitoring"
          }
        end

        # Compare existing models
        (old_models.keys & new_models.keys).each do |model_name|
          differences += compare_model(
            model_name,
            old_models[model_name],
            new_models[model_name]
          )
        end

        # Compare configuration changes
        differences += compare_configuration(
          old_schema[:configuration] || {},
          new_schema[:configuration] || {}
        )

        differences
      end

      def compare_model(model_name, old_model, new_model)
        differences = []

        # Access with string keys (models are already normalized)
        old_prefix = old_model["event_prefix"]
        new_prefix = new_model["event_prefix"]

        # Compare event prefix
        if old_prefix != new_prefix
          differences << {
            type: :event_prefix_changed,
            severity: SEVERITIES[:event_prefix_changed],
            model: model_name,
            old_value: old_prefix,
            new_value: new_prefix,
            message: "#{model_name} event_prefix changed: '#{old_prefix}' -> '#{new_prefix}'"
          }
        end

        # Compare columns
        differences += compare_columns(model_name, old_model["columns"] || {}, new_model["columns"] || {})

        # Compare events
        differences += compare_events(model_name, old_model["events"] || {}, new_model["events"] || {})

        differences
      end

      def compare_columns(model_name, old_columns, new_columns)
        differences = []

        # Removed columns
        (old_columns.keys - new_columns.keys).each do |col_name|
          differences << {
            type: :column_removed,
            severity: SEVERITIES[:column_removed],
            model: model_name,
            column: col_name,
            message: "Column '#{col_name}' removed from #{model_name}"
          }
        end

        # Added columns
        (new_columns.keys - old_columns.keys).each do |col_name|
          col_info = new_columns[col_name]
          msg = "Column '#{col_name}' added to #{model_name}"
          msg += " (PII: #{col_info["pii_type"]})" if col_info["pii"]

          differences << {
            type: :column_added,
            severity: SEVERITIES[:column_added],
            model: model_name,
            column: col_name,
            pii: col_info["pii"],
            message: msg
          }
        end

        # Changed columns
        (old_columns.keys & new_columns.keys).each do |col_name|
          differences += compare_column(model_name, col_name, old_columns[col_name], new_columns[col_name])
        end

        differences
      end

      def compare_column(model_name, col_name, old_col, new_col)
        differences = []

        # Use string keys (columns are already normalized)
        old_type = old_col["type"]
        new_type = new_col["type"]
        old_nullable = old_col["nullable"]
        new_nullable = new_col["nullable"]
        old_limit = old_col["limit"]
        new_limit = new_col["limit"]
        old_pii = old_col["pii"]
        new_pii = new_col["pii"]

        # Type change
        if old_type != new_type
          differences << {
            type: :column_type_changed,
            severity: SEVERITIES[:column_type_changed],
            model: model_name,
            column: col_name,
            old_value: old_type,
            new_value: new_type,
            message: "#{model_name}.#{col_name} type changed: #{old_type} -> #{new_type}"
          }
        end

        # Nullable change
        if old_nullable != new_nullable
          differences << {
            type: :column_nullable_changed,
            severity: SEVERITIES[:column_nullable_changed],
            model: model_name,
            column: col_name,
            old_value: old_nullable,
            new_value: new_nullable,
            message: "#{model_name}.#{col_name} nullable changed: #{old_nullable} -> #{new_nullable}"
          }
        end

        # Limit change
        if old_limit != new_limit
          differences << {
            type: :column_limit_changed,
            severity: SEVERITIES[:column_limit_changed],
            model: model_name,
            column: col_name,
            old_value: old_limit,
            new_value: new_limit,
            message: "#{model_name}.#{col_name} limit changed: #{old_limit} -> #{new_limit}"
          }
        end

        # PII detection change
        if old_pii != new_pii
          type = new_pii ? :pii_field_added : :pii_field_removed
          differences << {
            type: type,
            severity: SEVERITIES[type],
            model: model_name,
            column: col_name,
            message: "#{model_name}.#{col_name} PII status changed: #{old_pii} -> #{new_pii}"
          }
        end

        differences
      end

      def compare_events(model_name, old_events, new_events)
        differences = []

        # Check for event name changes (removed + added = renamed)
        removed_events = old_events.keys - new_events.keys
        added_events = new_events.keys - old_events.keys

        # Detect renames by matching operations
        removed_events.each do |old_name|
          old_op = old_events[old_name]["operation"]

          matching_new = added_events.find do |new_name|
            new_events[new_name]["operation"] == old_op
          end

          if matching_new
            differences << {
              type: :event_name_changed,
              severity: SEVERITIES[:event_name_changed],
              model: model_name,
              old_value: old_name,
              new_value: matching_new,
              operation: old_op,
              message: "#{model_name} event renamed: #{old_name} -> #{matching_new}"
            }
            added_events.delete(matching_new)
          end
        end

        differences
      end

      def compare_configuration(old_config, new_config)
        differences = []

        # Normalize to string keys for comparison
        old_cfg = normalize_keys(old_config)
        new_cfg = normalize_keys(new_config)

        %w[mode strict_schema projection_mode].each do |key|
          old_val = old_cfg[key]
          new_val = new_cfg[key]

          # Normalize values to strings for comparison
          old_val_str = old_val.to_s if old_val
          new_val_str = new_val.to_s if new_val

          if old_val_str != new_val_str
            differences << {
              type: :config_changed,
              severity: SEVERITIES[:config_changed],
              key: key,
              old_value: old_val,
              new_value: new_val,
              message: "Configuration '#{key}' changed: #{old_val} -> #{new_val}"
            }
          end
        end

        differences
      end

      def format_report(differences)
        return "No schema changes detected." if differences.empty?

        lines = ["Schema Changes Detected:"]
        lines << "=" * 60

        grouped = differences.group_by { |d| d[:severity] }

        [:breaking, :warning, :info].each do |severity|
          next unless grouped[severity]&.any?

          lines << ""
          icon = severity_icon(severity)
          lines << "#{icon} #{severity.to_s.upcase} (#{grouped[severity].size}):"
          lines << "-" * 40

          grouped[severity].each do |diff|
            lines << "  - #{diff[:message]}"
          end
        end

        lines << ""
        lines << "=" * 60

        # Add action suggestions
        if grouped[:breaking]&.any?
          lines << ""
          lines << "ACTION REQUIRED: Breaking changes detected."
          lines << "Run 'rake lyra:schema:update' to create a new schema version."
        end

        lines.join("\n")
      end

      private

      def severity_icon(severity)
        case severity
        when :breaking then "[!]"
        when :warning then "[?]"
        when :info then "[i]"
        else "[ ]"
        end
      end

      # Normalize hash keys to strings recursively for consistent comparison
      def normalize_keys(hash)
        return {} unless hash.is_a?(Hash)

        hash.transform_keys(&:to_s).transform_values do |value|
          case value
          when Hash then normalize_keys(value)
          else value
          end
        end
      end
    end
  end
end
