# frozen_string_literal: true

module PetriFlow
  module Matrix
    # Correlation Matrix (C)
    # Tracks which events share correlation IDs (belong to same user action)
    class Correlation
      attr_reader :matrix, :events

      def initialize
        @matrix = Hash.new { |h, k| h[k] = {} }
        @events = []
      end

      # Record correlation between two events
      def record_correlation(event1_id, event2_id, correlation_id)
        @events << event1_id unless @events.include?(event1_id)
        @events << event2_id unless @events.include?(event2_id)

        @matrix[event1_id][event2_id] = correlation_id
        @matrix[event2_id][event1_id] = correlation_id # Symmetric
      end

      # Check if two events are correlated
      def correlated?(event1_id, event2_id)
        !@matrix.dig(event1_id, event2_id).nil?
      end

      # Get correlation ID between two events
      def get_correlation_id(event1_id, event2_id)
        @matrix.dig(event1_id, event2_id)
      end

      # Get all events correlated with a given event
      def correlated_events(event_id)
        return [] unless @matrix[event_id]

        @matrix[event_id].select { |_, corr_id| !corr_id.nil? }.keys
      end

      # Group events by correlation ID
      def correlation_groups
        groups = Hash.new { |h, k| h[k] = [] }

        @matrix.each do |event1_id, correlations|
          correlations.each do |event2_id, correlation_id|
            next if correlation_id.nil?

            groups[correlation_id] << event1_id unless groups[correlation_id].include?(event1_id)
            groups[correlation_id] << event2_id unless groups[correlation_id].include?(event2_id)
          end
        end

        groups.transform_values(&:uniq)
      end

      # Convert to 2D matrix representation
      def to_matrix
        size = @events.size
        rows = @events.map do |event1|
          @events.map { |event2| correlated?(event1, event2) ? 1 : 0 }
        end
        ::Matrix.rows(rows)
      end

      def stats
        {
          total_events: @events.size,
          correlation_groups: correlation_groups.size,
          average_group_size: correlation_groups.values.map(&:size).sum.to_f / [correlation_groups.size, 1].max
        }
      end

      def to_s
        "CorrelationMatrix(#{@events.size} events, #{correlation_groups.size} groups)"
      end
    end
  end
end
