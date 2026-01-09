module Lyra
  # Analyzes collections of events for patterns and metrics
  class EventAnalyzer
    attr_reader :events

    def initialize(events)
      @events = events
    end

    # Analyze events and return comprehensive metrics
    def analyze
      {
        timeline: calculate_timeline,
        operations: calculate_operations,
        metrics: calculate_metrics,
        privacy: analyze_privacy
      }
    end

    private

    def calculate_timeline
      return {} if @events.empty?

      first_time = extract_timestamp(@events.first)
      last_time = extract_timestamp(@events.last)

      return {} if first_time.nil? || last_time.nil?

      duration_seconds = last_time - first_time

      {
        first_event: first_time,
        last_event: last_time,
        duration_seconds: duration_seconds,
        duration_minutes: duration_seconds / 60.0,
        duration_hours: duration_seconds / 3600.0,
        duration_days: duration_seconds / 86400.0
      }
    end

    def extract_timestamp(event)
      if event.respond_to?(:timestamp) && event.timestamp
        event.timestamp
      elsif event.respond_to?(:data) && event.data.is_a?(Hash) && event.data[:timestamp]
        event.data[:timestamp]
      elsif event.respond_to?(:metadata) && event.metadata.is_a?(Hash) && event.metadata[:timestamp]
        event.metadata[:timestamp]
      else
        nil
      end
    end

    def calculate_operations
      operations = Hash.new(0)

      @events.each do |event|
        operation = if event.respond_to?(:operation)
                     event.operation
                   elsif event.respond_to?(:data)
                     event.data[:operation]
                   end

        operations[operation] += 1 if operation
      end

      operations
    end

    def calculate_metrics
      timeline = calculate_timeline

      {
        total_events: @events.length,
        operations_per_day: if timeline[:duration_days] && timeline[:duration_days] > 0
                             @events.length.to_f / timeline[:duration_days]
                           else
                             0
                           end,
        average_time_between_events: if @events.length > 1 && timeline[:duration_seconds]
                                       timeline[:duration_seconds] / (@events.length - 1)
                                     else
                                       0
                                     end
      }
    end

    def analyze_privacy
      pii_fields = {}
      events_with_pii = 0

      @events.each do |event|
        event_pii = detect_event_pii(event)

        if event_pii.any?
          events_with_pii += 1
          event_pii.each do |field, info|
            pii_fields[field] ||= info
          end
        end
      end

      percentage = @events.empty? ? 0.0 : (events_with_pii.to_f / @events.length * 100.0)

      {
        pii_fields: pii_fields,
        events_with_pii: events_with_pii,
        percentage: percentage
      }
    end

    def detect_event_pii(event)
      attributes = if event.respond_to?(:attributes)
                    event.attributes
                  elsif event.respond_to?(:data)
                    event.data[:attributes] || {}
                  else
                    {}
                  end

      changes = if event.respond_to?(:changes)
                 event.changes
               elsif event.respond_to?(:data)
                 event.data[:changes] || {}
               else
                 {}
               end

      return {} unless Lyra.privacy_features_available?

      all_data = attributes.merge(changes)
      Lyra::Privacy::PIIDetector.detect(all_data)
    end
  end
end
