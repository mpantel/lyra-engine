# frozen_string_literal: true

module PetriFlow
  module Matrix
    # Main analyzer class that combines all matrix types
    # Provides comprehensive analysis of Petri net execution
    class Analyzer
      attr_reader :crud_mapping, :correlation, :causation, :lineage, :reachability

      def initialize
        @crud_mapping = CrudEventMapping.new
        @correlation = Correlation.new
        @causation = Causation.new
        @lineage = Lineage.new
        @reachability = nil
      end

      # Analyze events and build all matrices
      def analyze_events(events)
        events.each do |event|
          analyze_event(event)
        end

        self
      end

      # Analyze a single event
      def analyze_event(event)
        event_id = event[:event_id] || event[:id]

        # CRUD mapping
        if event[:operation] && event[:event_type]
          @crud_mapping.record_mapping(event[:operation], event[:event_type])
        end

        # Correlation
        if event[:correlation_id]
          # Find other events with same correlation_id
          # (In real usage, this would query event store)
        end

        # Causation
        if event[:caused_by_event_id]
          @causation.record_causation(event[:caused_by_event_id], event_id)
        end

        # Lineage
        if event[:changes]
          event[:changes].each do |field, (old_val, new_val)|
            @lineage.record_modification(
              field,
              event_id,
              old_value: old_val,
              new_value: new_val,
              timestamp: event[:timestamp]
            )
          end
        end

        self
      end

      # Compute reachability from a Petri net
      def compute_reachability(net, initial_marking)
        @reachability = Reachability.compute_from_net(net, initial_marking)
        self
      end

      # Generate comprehensive report
      def generate_report
        {
          crud_mapping: {
            summary: @crud_mapping.to_s,
            table: @crud_mapping.to_table,
            stats: crud_mapping_stats
          },
          correlation: {
            summary: @correlation.to_s,
            stats: @correlation.stats
          },
          causation: {
            summary: @causation.to_s,
            stats: @causation.stats,
            centrality: @causation.centrality_scores
          },
          lineage: {
            summary: @lineage.to_s,
            stats: @lineage.stats
          },
          reachability: @reachability ? {
            summary: @reachability.to_s,
            stats: @reachability.stats
          } : nil
        }.compact
      end

      # Find events in causation chain
      def find_causation_chain(start_event, end_event)
        @causation.causation_chain(start_event, end_event)
      end

      # Get complete field history
      def field_history(field)
        @lineage.field_lineage(field)
      end

      # Get events in correlation group
      def correlation_group(event_id)
        @correlation.correlated_events(event_id)
      end

      # Privacy impact analysis
      def privacy_impact_analysis
        {
          fields_tracked: @lineage.fields.size,
          events_with_changes: @lineage.events.size,
          total_modifications: @lineage.stats[:total_modifications],
          most_modified_field: @lineage.stats[:most_modified_field]
        }
      end

      # Event flow completeness check
      def flow_completeness
        total_crud_ops = crud_mapping_stats[:total_mappings]
        total_events = @causation.events.size

        {
          crud_operations: total_crud_ops,
          events_generated: total_events,
          mapping_ratio: total_events.to_f / [total_crud_ops, 1].max,
          completeness: total_events >= total_crud_ops ? "✓ Complete" : "⚠ Incomplete"
        }
      end

      def to_s
        "MatrixAnalyzer(CRUD: #{@crud_mapping}, Correlation: #{@correlation}, " \
          "Causation: #{@causation}, Lineage: #{@lineage})"
      end

      private

      def crud_mapping_stats
        {
          total_mappings: @crud_mapping.crud_ops.sum { |op| @crud_mapping.total_events_for(op) },
          operations: @crud_mapping.crud_ops.size,
          event_types: @crud_mapping.event_types.size
        }
      end
    end
  end
end
