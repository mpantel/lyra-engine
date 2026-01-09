# frozen_string_literal: true

module PetriFlow
  module Matrix
    # Causation Matrix (Cau)
    # Tracks which events cause other events (event flow)
    class Causation
      attr_reader :matrix, :events

      def initialize
        @matrix = Hash.new { |h, k| h[k] = Hash.new(0) }
        @events = []
      end

      # Record that event1 causes event2
      def record_causation(cause_event_id, effect_event_id)
        @events << cause_event_id unless @events.include?(cause_event_id)
        @events << effect_event_id unless @events.include?(effect_event_id)

        @matrix[cause_event_id][effect_event_id] = 1
      end

      # Check if event1 directly causes event2
      def causes?(cause_event_id, effect_event_id)
        @matrix[cause_event_id][effect_event_id] == 1
      end

      # Get all events directly caused by an event
      def effects_of(event_id)
        return [] unless @matrix[event_id]

        @matrix[event_id].select { |_, v| v == 1 }.keys
      end

      # Get all events that directly cause an event
      def causes_of(event_id)
        @matrix.select { |_, effects| effects[event_id] == 1 }.keys
      end

      # Compute transitive closure (Cau*)
      # Returns matrix showing all reachable events (direct + indirect causation)
      def transitive_closure
        closure = Causation.new
        @events.each { |e| closure.instance_variable_get(:@events) << e }

        # Copy direct causations
        @matrix.each do |cause, effects|
          effects.each do |effect, value|
            closure.matrix[cause][effect] = value if value == 1
          end
        end

        # Warshall's algorithm for transitive closure
        @events.each do |k|
          @events.each do |i|
            @events.each do |j|
              if closure.matrix[i][k] == 1 && closure.matrix[k][j] == 1
                closure.matrix[i][j] = 1
              end
            end
          end
        end

        closure
      end

      # Find causation chain from event1 to event2
      def causation_chain(start_event_id, end_event_id)
        return [] unless @events.include?(start_event_id) && @events.include?(end_event_id)
        return [start_event_id] if start_event_id == end_event_id

        # BFS to find shortest path
        queue = [[start_event_id]]
        visited = Set.new([start_event_id])

        while queue.any?
          path = queue.shift
          current = path.last

          effects_of(current).each do |effect|
            return path + [effect] if effect == end_event_id

            unless visited.include?(effect)
              visited.add(effect)
              queue << (path + [effect])
            end
          end
        end

        [] # No path found
      end

      # Convert to 2D matrix representation
      def to_matrix
        rows = @events.map do |cause|
          @events.map { |effect| @matrix[cause][effect] }
        end
        ::Matrix.rows(rows)
      end

      # Calculate centrality scores (which events are most influential)
      def centrality_scores
        scores = Hash.new(0)

        @matrix.each do |cause, effects|
          scores[cause] += effects.values.sum
        end

        scores
      end

      def stats
        {
          total_events: @events.size,
          total_causations: @matrix.values.map { |h| h.values.sum }.sum,
          root_events: @events.count { |e| causes_of(e).empty? },
          leaf_events: @events.count { |e| effects_of(e).empty? }
        }
      end

      def to_s
        "CausationMatrix(#{@events.size} events, #{stats[:total_causations]} causations)"
      end
    end
  end
end
