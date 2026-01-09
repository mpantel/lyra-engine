# frozen_string_literal: true

module PetriFlow
  module Matrix
    # Data Lineage Matrix (L)
    # Tracks which events modified which fields (data lineage)
    class Lineage
      attr_reader :matrix, :fields, :events

      def initialize
        @matrix = Hash.new { |h, k| h[k] = Hash.new(0) }
        @fields = []
        @events = []
      end

      # Record that an event modified a field
      def record_modification(field, event_id, old_value: nil, new_value: nil, timestamp: nil)
        @fields << field unless @fields.include?(field)
        @events << event_id unless @events.include?(event_id)

        @matrix[field][event_id] = {
          modified: 1,
          old_value: old_value,
          new_value: new_value,
          timestamp: timestamp || Time.current
        }
      end

      # Check if an event modified a field
      def modified?(field, event_id)
        value = @matrix.dig(field, event_id)
        value.is_a?(Hash) && value[:modified] == 1
      end

      # Get all events that modified a field
      def events_for_field(field)
        return [] unless @matrix[field]

        @matrix[field].select { |_, v| v.is_a?(Hash) && v[:modified] == 1 }.keys
      end

      # Get all fields modified by an event
      def fields_for_event(event_id)
        @fields.select { |field| modified?(field, event_id) }
      end

      # Get complete lineage for a field (temporal history)
      def field_lineage(field)
        return [] unless @matrix[field]

        modifications = @matrix[field]
                        .select { |_, v| v.is_a?(Hash) && v[:modified] == 1 }
                        .map do |event_id, data|
          {
            event_id: event_id,
            old_value: data[:old_value],
            new_value: data[:new_value],
            timestamp: data[:timestamp]
          }
        end

        modifications.sort_by { |m| m[:timestamp] }
      end

      # Reconstruct field value at a specific point in time
      def reconstruct_value(field, at_time)
        lineage = field_lineage(field)
        return nil if lineage.empty?

        # Find last modification before at_time
        applicable_mods = lineage.select { |m| m[:timestamp] <= at_time }
        return nil if applicable_mods.empty?

        applicable_mods.last[:new_value]
      end

      # Get field value chain (how value evolved)
      def value_chain(field)
        lineage = field_lineage(field)
        return [] if lineage.empty?

        chain = []
        lineage.each do |mod|
          chain << mod[:old_value] if chain.empty? && !mod[:old_value].nil?
          chain << mod[:new_value] unless mod[:new_value].nil?
        end

        chain.uniq
      end

      # Convert to 2D matrix representation
      def to_matrix
        rows = @fields.map do |field|
          @events.map { |event| modified?(field, event) ? 1 : 0 }
        end
        ::Matrix.rows(rows)
      end

      def stats
        {
          total_fields: @fields.size,
          total_events: @events.size,
          total_modifications: @matrix.values.map { |h| h.values.count { |v| v.is_a?(Hash) && v[:modified] == 1 } }.sum,
          most_modified_field: @fields.max_by { |f| events_for_field(f).size }
        }
      end

      def to_s
        "LineageMatrix(#{@fields.size} fields, #{@events.size} events)"
      end
    end
  end
end
