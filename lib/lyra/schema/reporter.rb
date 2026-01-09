# frozen_string_literal: true

module Lyra
  module Schema
    # Generates human-readable reports of model->event mappings
    class Reporter
      class << self
        def generate
          new.generate
        end

        def to_s
          new.to_s
        end
      end

      def generate
        schema = Store.load_current || Generator.generate

        {
          header: generate_header(schema),
          models: generate_models_report(schema),
          events: generate_events_report(schema),
          pii: generate_pii_report(schema),
          configuration: schema[:configuration]
        }
      end

      def to_s
        report = generate
        format_report(report)
      end

      private

      def format_report(report)
        lines = []

        # Header
        lines << "=" * 70
        lines << center_text("Lyra Event Schema Report", 70)
        lines << "=" * 70
        lines << ""

        # Version info
        if report[:header][:version]
          lines << "Schema Version: v#{report[:header][:version]}"
          lines << "Created: #{report[:header][:created_at]}"
        else
          lines << "Schema: (not yet saved - showing current configuration)"
        end
        lines << "Lyra Version: #{report[:header][:lyra_version]}"
        lines << ""

        # Configuration
        lines << "-" * 70
        lines << "CONFIGURATION"
        lines << "-" * 70
        config = report[:configuration] || {}
        lines << "  Mode: #{config[:mode] || 'unknown'}"
        lines << "  Strict Schema: #{config[:strict_schema]}"
        lines << "  Projection Mode: #{config[:projection_mode]}"
        lines << ""

        # Model mappings
        lines << "-" * 70
        lines << "MODEL -> EVENT MAPPINGS"
        lines << "-" * 70

        report[:models].each do |model_name, model_info|
          lines << ""
          lines << "#{model_name}"
          lines << "  Table: #{model_info[:table_name]}"
          lines << "  Event Prefix: #{model_info[:event_prefix]}"
          lines << "  Columns: #{model_info[:column_count]}"

          if model_info[:pii_fields].any?
            lines << "  PII Fields: #{model_info[:pii_fields].join(', ')}"
          end

          lines << ""
          lines << "  Events:"
          model_info[:events].each do |event_name, event_info|
            pii_note = event_info[:pii_fields]&.any? ? " [PII]" : ""
            lines << "    -> #{event_name} (#{event_info[:operation]})#{pii_note}"
          end
        end

        # PII Summary
        if report[:pii].any?
          lines << ""
          lines << "-" * 70
          lines << "PII SUMMARY BY TYPE"
          lines << "-" * 70
          lines << ""

          report[:pii].each do |type, fields|
            lines << "  #{type}:"
            fields.each { |f| lines << "    - #{f}" }
          end
        end

        # Events Summary
        lines << ""
        lines << "-" * 70
        lines << "ALL EVENTS"
        lines << "-" * 70
        lines << ""
        lines << "  %-30s %-20s %-12s" % ["Event Name", "Model", "Operation"]
        lines << "  " + "-" * 62

        report[:events].each do |event|
          lines << "  %-30s %-20s %-12s" % [
            event[:event_name],
            event[:model],
            event[:operation]
          ]
        end

        lines << ""
        lines << "=" * 70

        lines.join("\n")
      end

      def generate_header(schema)
        {
          version: schema[:version],
          created_at: schema[:created_at],
          lyra_version: schema[:lyra_version],
          fingerprint: schema[:fingerprint]
        }
      end

      def generate_models_report(schema)
        (schema[:models] || {}).transform_values do |model|
          pii_fields = (model[:columns] || {}).select { |_, c| c[:pii] }.keys

          {
            table_name: model[:table_name],
            event_prefix: model[:event_prefix],
            aggregate_class: model[:aggregate_class],
            column_count: model[:columns]&.size || 0,
            pii_fields: pii_fields,
            events: model[:events] || {}
          }
        end
      end

      def generate_events_report(schema)
        events = []

        (schema[:models] || {}).each do |model_name, model|
          (model[:events] || {}).each do |event_name, event_info|
            events << {
              event_name: event_name,
              model: model_name,
              operation: event_info[:operation],
              pii_fields: event_info[:pii_fields]
            }
          end
        end

        events.sort_by { |e| [e[:model], e[:operation]] }
      end

      def generate_pii_report(schema)
        pii_by_type = Hash.new { |h, k| h[k] = [] }

        (schema[:models] || {}).each do |model_name, model|
          (model[:columns] || {}).each do |col_name, col_info|
            next unless col_info[:pii]

            pii_type = col_info[:pii_type] || "unknown"
            pii_by_type[pii_type] << "#{model_name}.#{col_name}"
          end
        end

        pii_by_type.sort.to_h
      end

      def center_text(text, width)
        padding = [(width - text.length) / 2, 0].max
        " " * padding + text
      end
    end
  end
end
