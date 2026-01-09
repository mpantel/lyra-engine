module Lyra
  module Visualization
    # Activity heatmap visualization for D3.js
    # Shows event activity patterns across time (hour of day vs day of week)
    class ActivityHeatmap
      DAYS_OF_WEEK = %w[Sunday Monday Tuesday Wednesday Thursday Friday Saturday].freeze
      HOURS_OF_DAY = (0..23).to_a.freeze

      def initialize(events)
        @events = events.sort_by { |e| event_timestamp(e) }
      end

      # Generate heatmap data for D3.js
      def to_d3_json
        {
          data: build_heatmap_data,
          x_labels: hour_labels,
          y_labels: DAYS_OF_WEEK,
          metadata: heatmap_metadata
        }.to_json
      end

      # Generate data hash (for API responses)
      def to_data
        {
          data: build_heatmap_data,
          x_labels: hour_labels,
          y_labels: DAYS_OF_WEEK,
          metadata: heatmap_metadata
        }
      end

      # Generate hourly breakdown for a specific model
      def hourly_breakdown(model_class = nil)
        filtered = model_class ? @events.select { |e| event_model_class(e) == model_class } : @events

        HOURS_OF_DAY.map do |hour|
          count = filtered.count { |e| event_timestamp(e).hour == hour }
          {
            hour: hour,
            label: format_hour(hour),
            count: count,
            percentage: filtered.empty? ? 0 : (count.to_f / filtered.size * 100).round(2)
          }
        end
      end

      # Generate daily breakdown
      def daily_breakdown(model_class = nil)
        filtered = model_class ? @events.select { |e| event_model_class(e) == model_class } : @events

        DAYS_OF_WEEK.each_with_index.map do |day, i|
          count = filtered.count { |e| event_timestamp(e).wday == i }
          {
            day: day,
            day_index: i,
            count: count,
            percentage: filtered.empty? ? 0 : (count.to_f / filtered.size * 100).round(2)
          }
        end
      end

      # Generate operation-based heatmap
      def operation_heatmap
        operations = @events.map { |e| event_operation(e) }.uniq

        operations.map do |operation|
          op_events = @events.select { |e| event_operation(e) == operation }
          {
            operation: operation.to_s,
            hourly: HOURS_OF_DAY.map { |h| op_events.count { |e| event_timestamp(e).hour == h } },
            total: op_events.count
          }
        end
      end

      # Generate model-based heatmap
      def model_heatmap
        model_classes = @events.map { |e| event_model_class(e) }.uniq

        model_classes.map do |model_class|
          model_events = @events.select { |e| event_model_class(e) == model_class }
          {
            model_class: model_class,
            hourly: HOURS_OF_DAY.map { |h| model_events.count { |e| event_timestamp(e).hour == h } },
            daily: DAYS_OF_WEEK.each_with_index.map { |_d, i| model_events.count { |e| event_timestamp(e).wday == i } },
            total: model_events.count
          }
        end
      end

      private

      def build_heatmap_data
        # Create a 7x24 matrix (days x hours)
        matrix = Array.new(7) { Array.new(24, 0) }

        @events.each do |event|
          ts = event_timestamp(event)
          day = ts.wday
          hour = ts.hour
          matrix[day][hour] += 1
        end

        # Convert to D3.js-friendly format
        data = []
        matrix.each_with_index do |day_data, day_index|
          day_data.each_with_index do |count, hour|
            data << {
              day: day_index,
              day_name: DAYS_OF_WEEK[day_index],
              hour: hour,
              hour_label: format_hour(hour),
              count: count,
              intensity: calculate_intensity(count)
            }
          end
        end

        data
      end

      def hour_labels
        HOURS_OF_DAY.map { |h| format_hour(h) }
      end

      def format_hour(hour)
        if hour == 0
          "12 AM"
        elsif hour < 12
          "#{hour} AM"
        elsif hour == 12
          "12 PM"
        else
          "#{hour - 12} PM"
        end
      end

      def calculate_intensity(count)
        return 0 if @events.empty?

        max_count = @events.group_by { |e| ts = event_timestamp(e); [ts.wday, ts.hour] }
                          .values.map(&:count).max || 1

        (count.to_f / max_count * 100).round(2)
      end

      def heatmap_metadata
        {
          total_events: @events.count,
          time_range: {
            start: @events.first ? event_timestamp(@events.first) : nil,
            end: @events.last ? event_timestamp(@events.last) : nil
          },
          peak_hour: find_peak_hour,
          peak_day: find_peak_day,
          busiest_slot: find_busiest_slot,
          operations_breakdown: @events.group_by { |e| event_operation(e) }.transform_values(&:count),
          models_breakdown: @events.group_by { |e| event_model_class(e) }.transform_values(&:count)
        }
      end

      def find_peak_hour
        return nil if @events.empty?

        hourly_counts = @events.group_by { |e| event_timestamp(e).hour }
                               .transform_values(&:count)
        peak = hourly_counts.max_by { |_h, c| c }
        { hour: peak[0], label: format_hour(peak[0]), count: peak[1] }
      end

      def find_peak_day
        return nil if @events.empty?

        daily_counts = @events.group_by { |e| event_timestamp(e).wday }
                              .transform_values(&:count)
        peak = daily_counts.max_by { |_d, c| c }
        { day: peak[0], label: DAYS_OF_WEEK[peak[0]], count: peak[1] }
      end

      def find_busiest_slot
        return nil if @events.empty?

        slots = @events.group_by { |e| ts = event_timestamp(e); [ts.wday, ts.hour] }
                       .transform_values(&:count)
        peak = slots.max_by { |_slot, c| c }
        day, hour = peak[0]
        {
          day: day,
          day_label: DAYS_OF_WEEK[day],
          hour: hour,
          hour_label: format_hour(hour),
          count: peak[1]
        }
      end

      # Helper methods to handle both Lyra::Event and RubyEventStore::Event
      def event_model_class(event)
        return event.model_class if event.respond_to?(:model_class)
        event.data[:model_class] || event.data["model_class"]
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
    end
  end
end
