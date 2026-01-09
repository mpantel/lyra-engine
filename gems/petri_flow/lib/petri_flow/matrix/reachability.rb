# frozen_string_literal: true

module PetriFlow
  module Matrix
    # Reachability Matrix (R)
    # Tracks which markings (states) are reachable from other markings
    class Reachability
      attr_reader :matrix, :markings

      def initialize
        @matrix = Hash.new { |h, k| h[k] = Hash.new(0) }
        @markings = []
      end

      # Record that marking_j is reachable from marking_i
      def record_reachability(marking_i, marking_j)
        marking_i_key = marking_key(marking_i)
        marking_j_key = marking_key(marking_j)

        @markings << marking_i_key unless @markings.include?(marking_i_key)
        @markings << marking_j_key unless @markings.include?(marking_j_key)

        @matrix[marking_i_key][marking_j_key] = 1
      end

      # Check if marking_j is reachable from marking_i
      def reachable?(marking_i, marking_j)
        marking_i_key = marking_key(marking_i)
        marking_j_key = marking_key(marking_j)

        @matrix[marking_i_key][marking_j_key] == 1
      end

      # Get all markings reachable from a given marking
      def reachable_from(marking)
        marking_key_val = marking_key(marking)
        return [] unless @matrix[marking_key_val]

        @matrix[marking_key_val].select { |_, v| v == 1 }.keys
      end

      # Compute reachability graph from a Petri net and initial marking
      def self.compute_from_net(net, initial_marking)
        reachability = new
        visited = Set.new
        queue = [initial_marking.dup]

        reachability.record_reachability(initial_marking, initial_marking)

        while queue.any?
          current_marking = queue.shift
          current_key = reachability.send(:marking_key, current_marking)

          next if visited.include?(current_key)
          visited.add(current_key)

          # Set net to current marking
          net.set_marking(current_marking)

          # Try firing each enabled transition
          net.enabled_transitions.each do |transition|
            # Save current state
            saved_marking = net.current_marking.dup

            # Fire transition
            begin
              transition.fire!
              new_marking = net.current_marking

              # Record reachability
              reachability.record_reachability(initial_marking, new_marking)
              reachability.record_reachability(current_marking, new_marking)

              # Add to queue if not visited
              new_key = reachability.send(:marking_key, new_marking)
              queue << new_marking.dup unless visited.include?(new_key)
            ensure
              # Restore marking for next iteration
              net.set_marking(saved_marking)
            end
          end
        end

        reachability
      end

      # Convert to 2D matrix representation
      def to_matrix
        rows = @markings.map do |marking_i|
          @markings.map { |marking_j| @matrix[marking_i][marking_j] }
        end
        ::Matrix.rows(rows)
      end

      # Check for deadlock states (markings with no successors)
      def deadlock_states
        @markings.select do |marking|
          reachable_from(marking).empty?
        end
      end

      def stats
        {
          total_markings: @markings.size,
          total_transitions: @matrix.values.map { |h| h.values.sum }.sum,
          deadlock_states: deadlock_states.size
        }
      end

      def to_s
        "ReachabilityMatrix(#{@markings.size} markings, #{stats[:total_transitions]} transitions)"
      end

      private

      def marking_key(marking)
        case marking
        when Core::Marking
          marking.to_h.sort.to_s
        when Hash
          marking.sort.to_s
        else
          marking.to_s
        end
      end
    end
  end
end
