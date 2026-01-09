module Lyra
  module Visualization
    # Force-directed event graph visualization for D3.js
    class EventGraph
      def initialize(events)
        @events = events.sort_by { |e| event_timestamp(e) }
      end

      # Generate graph data for D3.js force-directed layout
      def to_d3_json
        {
          nodes: build_nodes,
          links: build_links,
          metadata: graph_metadata
        }.to_json
      end

      # Generate data hash (for API responses)
      def to_data
        {
          nodes: build_nodes,
          links: build_links,
          metadata: graph_metadata
        }
      end

      # Generate Mermaid flowchart
      def to_mermaid
        lines = ["flowchart TD"]

        @events.each do |event|
          node_id = sanitize_id(event_id(event))
          operation = event_operation(event).to_s.upcase
          model_info = "#{event_model_class(event)}##{event_model_id(event)}"
          changed_fields = format_changed_fields(event)

          label = if changed_fields.present?
            "#{operation}\\n#{model_info}\\n#{changed_fields}"
          else
            "#{operation}\\n#{model_info}"
          end

          lines << "    #{node_id}[\"#{label}\"]"
        end

        lines << ""

        build_links.each do |link|
          source_id = sanitize_id(link[:source])
          target_id = sanitize_id(link[:target])
          link_style = link[:type] == 'correlation' ? '-->' : '-.->'
          lines << "    #{source_id} #{link_style} #{target_id}"
        end

        lines.join("\n")
      end

      private

      def build_nodes
        model_groups = @events.map { |e| event_model_class(e) }.uniq
        color_scale = generate_color_scale(model_groups)

        @events.map.with_index do |event, i|
          has_pii = detect_pii?(event)
          model_class = event_model_class(event)
          model_id = event_model_id(event)
          timestamp = event_timestamp(event)
          metadata = event_metadata(event)
          changes = event_changes(event)
          changed_fields = extract_changed_field_names(changes)

          {
            id: event_id(event),
            index: i,
            label: "#{model_class}##{model_id}",
            operation: event_operation(event).to_s,
            model_class: model_class,
            model_id: model_id,
            timestamp: timestamp.to_i * 1000, # JavaScript timestamp
            timestamp_formatted: timestamp.strftime("%Y-%m-%d %H:%M:%S"),
            has_pii: has_pii,
            group: model_groups.index(model_class),
            color: color_scale[model_class],
            size: calculate_node_size(event),
            user_id: metadata[:user_id],
            correlation_id: metadata[:correlation_id],
            changed_fields: changed_fields,
            changes: format_changes_for_display(changes)
          }
        end
      end

      def build_links
        links = []
        events_by_id = @events.index_by { |e| event_id(e) }

        # Link events by correlation ID (same workflow/transaction)
        @events.group_by { |e| event_metadata(e)[:correlation_id] }.each do |corr_id, group|
          next if corr_id.nil? || group.size < 2

          sorted = group.sort_by { |e| event_timestamp(e) }
          sorted.each_cons(2) do |source, target|
            links << {
              source: event_id(source),
              target: event_id(target),
              type: 'correlation',
              strength: 1.0,
              label: 'correlated'
            }
          end
        end

        # Link events on same record (entity lifecycle)
        @events.group_by { |e| "#{event_model_class(e)}-#{event_model_id(e)}" }.each do |_key, group|
          next if group.size < 2

          sorted = group.sort_by { |e| event_timestamp(e) }
          sorted.each_cons(2) do |source, target|
            links << {
              source: event_id(source),
              target: event_id(target),
              type: 'same_record',
              strength: 0.5,
              label: 'same entity'
            }
          end
        end

        # Link events by same user (user activity pattern)
        @events.group_by { |e| event_metadata(e)[:user_id] }.each do |user_id, group|
          next if user_id.nil? || group.size < 2

          sorted = group.sort_by { |e| event_timestamp(e) }
          sorted.each_cons(2) do |source, target|
            # Only link if within 5 minutes of each other
            if (event_timestamp(target) - event_timestamp(source)) < 300
              links << {
                source: event_id(source),
                target: event_id(target),
                type: 'same_user',
                strength: 0.3,
                label: 'same user'
              }
            end
          end
        end

        links.uniq { |l| [l[:source], l[:target]] }
      end

      def graph_metadata
        {
          total_nodes: @events.count,
          total_links: build_links.count,
          model_classes: @events.map { |e| event_model_class(e) }.uniq,
          time_range: {
            start: @events.first ? event_timestamp(@events.first) : nil,
            end: @events.last ? event_timestamp(@events.last) : nil
          },
          operations: @events.group_by { |e| event_operation(e) }.transform_values(&:count),
          pii_count: @events.count { |e| detect_pii?(e) }
        }
      end

      def detect_pii?(event)
        return false unless Lyra.privacy_features_available?

        Lyra::Privacy::PIIDetector.detect(event_attributes(event)).any?
      rescue
        false
      end

      def calculate_node_size(event)
        base_size = 10
        # Larger nodes for events with more changes
        changes = event_changes(event)
        change_bonus = (changes&.size || 0) * 2
        # Larger nodes for PII-containing events
        pii_bonus = detect_pii?(event) ? 5 : 0

        [base_size + change_bonus + pii_bonus, 30].min
      end

      def generate_color_scale(model_classes)
        colors = %w[
          #667eea #764ba2 #f59e0b #10b981 #ef4444
          #8b5cf6 #06b6d4 #ec4899 #84cc16 #f97316
        ]

        model_classes.each_with_index.to_h do |model_class, i|
          [model_class, colors[i % colors.length]]
        end
      end

      def sanitize_id(id)
        id.to_s.gsub(/[^a-zA-Z0-9]/, '_')
      end

      # Helper methods to handle both Lyra::Event and RubyEventStore::Event
      def event_id(event)
        return event.event_id if event.respond_to?(:event_id)
        event.data[:event_id] || event.data["event_id"]
      end

      def event_model_class(event)
        return event.model_class if event.respond_to?(:model_class)
        event.data[:model_class] || event.data["model_class"]
      end

      def event_model_id(event)
        return event.model_id if event.respond_to?(:model_id)
        event.data[:model_id] || event.data["model_id"]
      end

      def event_operation(event)
        return event.operation if event.respond_to?(:operation)
        op = event.data[:operation] || event.data["operation"]
        op.is_a?(String) ? op.to_sym : op
      end

      def event_timestamp(event)
        return event.timestamp if event.respond_to?(:timestamp) && event.timestamp
        event.data[:timestamp] || event.data["timestamp"] || event.metadata[:timestamp] || Time.now
      end

      def event_attributes(event)
        return event.attributes if event.respond_to?(:attributes) && !event.attributes.is_a?(Hash)
        event.data[:attributes] || event.data["attributes"] || {}
      end

      def event_changes(event)
        return event.changes if event.respond_to?(:changes) && event.method(:changes).owner != ActiveRecord::AttributeMethods::Dirty
        event.data[:changes] || event.data["changes"] || {}
      end

      def event_metadata(event)
        return event.metadata if event.respond_to?(:metadata)
        {}
      end

      # Extract just the field names that changed
      def extract_changed_field_names(changes)
        return [] if changes.blank?

        changes.keys.map(&:to_s).reject { |k| k.end_with?("_at") }
      end

      # Format changes for display in node details (with before/after values)
      def format_changes_for_display(changes)
        return [] if changes.blank?

        changes.map do |field, values|
          field_name = field.to_s
          # Skip timestamp fields for cleaner display
          next if field_name.end_with?("_at")

          result = if values.is_a?(Array) && values.size == 2
            { field: field_name, from: truncate_value(values[0]), to: truncate_value(values[1]) }
          else
            { field: field_name, value: truncate_value(values) }
          end

          # Add PII type if field contains PII
          pii_type = detect_field_pii_type(field_name)
          result[:pii_type] = pii_type if pii_type

          result
        end.compact
      end

      # Detect PII type for a specific field
      def detect_field_pii_type(field_name)
        return nil unless Lyra.privacy_features_available?

        # Check if field name matches known PII patterns
        pii_info = Lyra::Privacy::PIIDetector.detect({ field_name.to_sym => "sample" })
        return nil if pii_info.empty?

        pii_info.values.first[:type]&.to_s
      rescue
        nil
      end

      # Format changed fields for Mermaid label (compact)
      def format_changed_fields(event)
        changes = event_changes(event)
        return nil if changes.blank?

        fields = changes.keys.map(&:to_s).reject { |k| k.end_with?("_at") }
        return nil if fields.empty?

        # Limit to 3 fields to keep labels readable
        if fields.size > 3
          "📝 #{fields.first(3).join(', ')}..."
        else
          "📝 #{fields.join(', ')}"
        end
      end

      # Truncate long values for display
      def truncate_value(value)
        return nil if value.nil?

        str = value.to_s
        str.length > 30 ? "#{str[0..27]}..." : str
      end
    end
  end
end
