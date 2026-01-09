module Lyra
  module Visualization
    # Timeline visualization for event flows
    class Timeline
      def initialize(events)
        @events = events.sort_by { |e| event_timestamp(e) }
      end

      private

      # Helper methods to extract data from events (works with both Lyra::Event and RubyEventStore::Event)
      def event_timestamp(event)
        return event.timestamp if event.respond_to?(:timestamp) && event.timestamp
        data = event.respond_to?(:data) ? event.data : nil
        return nil unless data
        data[:timestamp] || data["timestamp"] || event.metadata[:timestamp]
      end

      def event_operation(event)
        return event.operation if event.respond_to?(:operation)
        data = event.respond_to?(:data) ? event.data : nil
        return nil unless data
        op = data[:operation] || data["operation"]
        op.is_a?(String) ? op.to_sym : op
      end

      def event_model_class(event)
        return event.model_class if event.respond_to?(:model_class)
        data = event.respond_to?(:data) ? event.data : nil
        return nil unless data
        data[:model_class] || data["model_class"]
      end

      def event_model_id(event)
        return event.model_id if event.respond_to?(:model_id)
        data = event.respond_to?(:data) ? event.data : nil
        return nil unless data
        data[:model_id] || data["model_id"]
      end

      def event_attributes(event)
        return event.attributes if event.respond_to?(:attributes) && !event.attributes.is_a?(Hash)
        data = event.respond_to?(:data) ? event.data : nil
        return {} unless data
        data[:attributes] || data["attributes"] || {}
      end

      def event_changes(event)
        return event.changes if event.respond_to?(:changes) && event.method(:changes).owner != ActiveRecord::AttributeMethods::Dirty rescue event.changes
        data = event.respond_to?(:data) ? event.data : nil
        return {} unless data
        data[:changes] || data["changes"] || {}
      end

      public

      # Generate timeline data for visualization
      def to_data
        {
          events: timeline_events,
          groups: event_groups,
          metadata: timeline_metadata
        }
      end

      # Generate timeline HTML
      def to_html
        TimelineHtmlBuilder.new(@events).build
      end

      # Generate Mermaid diagram
      def to_mermaid
        lines = ["gantt"]
        lines << "    title Event Timeline"
        lines << "    dateFormat YYYY-MM-DD HH:mm:ss"
        lines << ""

        @events.group_by { |e| event_model_class(e) }.each do |model_class, events|
          lines << "    section #{model_class}"
          events.each do |event|
            label = "#{event_operation(event)} ##{event_model_id(event)}"
            timestamp = event_timestamp(event).strftime("%Y-%m-%d %H:%M:%S")
            lines << "    #{label} :#{timestamp}, 1s"
          end
        end

        lines.join("\n")
      end

      # Generate ASCII timeline
      def to_ascii
        lines = ["Event Timeline", "=" * 80, ""]

        @events.each do |event|
          time_str = event_timestamp(event).strftime("%Y-%m-%d %H:%M:%S")
          pii_marker = has_pii?(event) ? " [PII]" : ""

          lines << "#{time_str} | #{event_model_class(event)}##{event_model_id(event)}"
          lines << "  └─ #{event_operation(event).to_s.upcase}#{pii_marker}"

          changes = event_changes(event)
          if changes.any?
            changes.each do |field, (old_val, new_val)|
              lines << "     • #{field}: #{old_val} → #{new_val}"
            end
          end

          lines << ""
        end

        lines.join("\n")
      end

      # Generate JSON for D3.js visualization
      def to_d3_json
        {
          nodes: @events.map.with_index do |event, i|
            {
              id: event.event_id,
              index: i,
              timestamp: event_timestamp(event).to_i,
              label: "#{event_model_class(event)}##{event_model_id(event)}",
              operation: event_operation(event),
              has_pii: has_pii?(event),
              group: event_model_class(event),
              user_id: event.metadata[:user_id]
            }
          end,
          links: build_links(@events)
        }.to_json
      end

      private

      def timeline_events
        @events.map do |event|
          {
            id: event.event_id,
            start: event_timestamp(event),
            content: event_label(event),
            group: event_model_class(event),
            className: event_css_class(event),
            title: event_tooltip(event)
          }
        end
      end

      def event_groups
        @events.map { |e| event_model_class(e) }.uniq.map.with_index do |model_class, i|
          {
            id: model_class,
            content: model_class,
            order: i
          }
        end
      end

      def timeline_metadata
        {
          start: @events.first ? event_timestamp(@events.first) : nil,
          end: @events.last ? event_timestamp(@events.last) : nil,
          count: @events.count,
          models: @events.map { |e| event_model_class(e) }.uniq
        }
      end

      def event_label(event)
        "#{event_operation(event).to_s.capitalize} ##{event_model_id(event)}"
      end

      def event_css_class(event)
        classes = ["event", "event-#{event_operation(event)}"]
        classes << "event-pii" if has_pii?(event)
        classes.join(" ")
      end

      def event_tooltip(event)
        parts = [
          "Operation: #{event_operation(event)}",
          "Model: #{event_model_class(event)}",
          "ID: #{event_model_id(event)}",
          "Time: #{event_timestamp(event)}"
        ]
        parts << "Contains PII" if has_pii?(event)
        parts.join("\n")
      end

      def has_pii?(event)
        return false unless Lyra.privacy_features_available?

        Lyra::Privacy::PIIDetector.detect(event_attributes(event)).any?
      end

      def build_links(events)
        links = []

        # Link events by correlation ID
        events.group_by { |e| e.metadata[:correlation_id] }.each do |corr_id, group|
          next if group.size < 2

          group.sort_by { |e| event_timestamp(e) }.each_cons(2) do |source, target|
            links << {
              source: source.event_id,
              target: target.event_id,
              type: 'correlation'
            }
          end
        end

        # Link events on same record
        events.group_by { |e| "#{event_model_class(e)}-#{event_model_id(e)}" }.each do |key, group|
          next if group.size < 2

          group.sort_by { |e| event_timestamp(e) }.each_cons(2) do |source, target|
            links << {
              source: source.event_id,
              target: target.event_id,
              type: 'same_record'
            }
          end
        end

        links
      end
    end

    # HTML builder for timeline visualization (replaces Phlex dependency)
    class TimelineHtmlBuilder
      def initialize(events)
        @events = events.sort_by { |e| event_timestamp(e) }
      end

      def build
        html = []
        html << '<div class="lyra-timeline">'
        html << "<style>#{timeline_styles}</style>"
        html << build_header
        html << build_body
        html << '</div>'
        html.join("\n")
      end

      private

      def event_timestamp(event)
        return event.timestamp if event.respond_to?(:timestamp) && event.timestamp
        data = event.respond_to?(:data) ? event.data : nil
        return Time.current unless data
        data[:timestamp] || data["timestamp"] || event.metadata[:timestamp] || Time.current
      end

      def event_operation(event)
        return event.operation if event.respond_to?(:operation)
        data = event.respond_to?(:data) ? event.data : nil
        return :unknown unless data
        op = data[:operation] || data["operation"]
        op.is_a?(String) ? op.to_sym : (op || :unknown)
      end

      def event_model_class(event)
        return event.model_class if event.respond_to?(:model_class)
        data = event.respond_to?(:data) ? event.data : nil
        return "Unknown" unless data
        data[:model_class] || data["model_class"] || "Unknown"
      end

      def event_model_id(event)
        return event.model_id if event.respond_to?(:model_id)
        data = event.respond_to?(:data) ? event.data : nil
        return "?" unless data
        data[:model_id] || data["model_id"] || "?"
      end

      def event_attributes(event)
        return event.attributes if event.respond_to?(:attributes) && event.attributes.is_a?(Hash)
        data = event.respond_to?(:data) ? event.data : nil
        return {} unless data
        data[:attributes] || data["attributes"] || {}
      end

      def event_changes(event)
        return event.changes if event.respond_to?(:changes) && event.changes.is_a?(Hash)
        data = event.respond_to?(:data) ? event.data : nil
        return {} unless data
        data[:changes] || data["changes"] || {}
      end

      def has_pii?(event)
        return false unless Lyra.privacy_features_available?
        Lyra::Privacy::PIIDetector.detect(event_attributes(event)).any?
      end

      def h(text)
        ERB::Util.html_escape(text.to_s)
      end

      def build_header
        model_count = @events.map { |e| event_model_class(e) }.uniq.count
        <<~HTML
          <div class="timeline-header">
            <h2>Event Timeline</h2>
            <div class="timeline-stats">
              <span>#{h(@events.count)} events</span>
              <span>#{h(model_count)} models</span>
            </div>
          </div>
        HTML
      end

      def build_body
        html = ['<div class="timeline-body">']
        @events.each { |event| html << build_event(event) }
        html << '</div>'
        html.join("\n")
      end

      def build_event(event)
        pii = has_pii?(event)
        op = event_operation(event)
        pii_class = pii ? ' with-pii' : ''

        html = []
        html << %(<div class="timeline-event #{h(op)}#{pii_class}">)
        html << %(<div class="event-time">#{h(event_timestamp(event).strftime("%Y-%m-%d %H:%M:%S"))}</div>)
        html << '<div class="event-content">'
        html << build_event_header(event, pii)
        html << build_event_changes(event)
        html << build_user_action(event)
        html << '</div>'
        html << '</div>'
        html.join("\n")
      end

      def build_event_header(event, has_pii)
        pii_badge = has_pii ? '<span class="pii-badge">PII</span>' : ''
        <<~HTML
          <div class="event-header">
            <span class="event-operation">#{h(event_operation(event).to_s.upcase)}</span>
            <span class="event-model">#{h(event_model_class(event))}##{h(event_model_id(event))}</span>
            #{pii_badge}
          </div>
        HTML
      end

      def build_event_changes(event)
        changes = event_changes(event)
        return '' if changes.empty?

        html = ['<div class="event-changes">']
        changes.each do |field, values|
          old_val, new_val = values.is_a?(Array) ? values : [nil, values]
          html << <<~HTML
            <div class="change">
              <span class="field">#{h(field)}</span>
              <span class="arrow">→</span>
              <span class="value">#{h(new_val)}</span>
            </div>
          HTML
        end
        html << '</div>'
        html.join("\n")
      end

      def build_user_action(event)
        user_action = event.respond_to?(:metadata) ? event.metadata[:user_action] : nil
        return '' unless user_action
        %(<div class="event-action">User Action: #{h(user_action)}</div>)
      end

      def timeline_styles
        <<~CSS
          .lyra-timeline { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; max-width: 1200px; margin: 0 auto; padding: 2rem; }
          .timeline-header { margin-bottom: 2rem; }
          .timeline-header h2 { margin: 0 0 1rem 0; color: #1f2937; }
          .timeline-stats { display: flex; gap: 2rem; color: #6b7280; font-size: 0.875rem; }
          .timeline-body { position: relative; padding-left: 2rem; border-left: 2px solid #e5e7eb; }
          .timeline-event { position: relative; margin-bottom: 2rem; padding: 1rem; background: white; border-radius: 8px; border: 1px solid #e5e7eb; box-shadow: 0 1px 3px rgba(0,0,0,0.1); }
          .timeline-event::before { content: ''; position: absolute; left: -2.5rem; top: 1.5rem; width: 12px; height: 12px; border-radius: 50%; background: #667eea; border: 2px solid white; }
          .timeline-event.with-pii::before { background: #f59e0b; }
          .event-time { font-size: 0.75rem; color: #6b7280; margin-bottom: 0.5rem; }
          .event-header { display: flex; align-items: center; gap: 1rem; margin-bottom: 0.5rem; }
          .event-operation { font-weight: 600; padding: 0.25rem 0.5rem; border-radius: 4px; font-size: 0.75rem; }
          .timeline-event.created .event-operation { background: #d1fae5; color: #065f46; }
          .timeline-event.updated .event-operation { background: #dbeafe; color: #1e40af; }
          .timeline-event.destroyed .event-operation { background: #fee2e2; color: #991b1b; }
          .event-model { font-family: monospace; color: #4b5563; }
          .pii-badge { background: #fef3c7; color: #92400e; padding: 0.25rem 0.5rem; border-radius: 4px; font-size: 0.75rem; font-weight: 600; }
          .event-changes { margin-top: 0.5rem; padding-left: 1rem; }
          .change { display: flex; align-items: center; gap: 0.5rem; margin: 0.25rem 0; font-size: 0.875rem; }
          .change .field { font-weight: 500; color: #374151; }
          .change .arrow { color: #9ca3af; }
          .change .value { font-family: monospace; background: #f3f4f6; padding: 0.125rem 0.375rem; border-radius: 3px; }
          .event-action { margin-top: 0.5rem; font-size: 0.875rem; color: #6b7280; font-style: italic; }
        CSS
      end
    end
  end
end
