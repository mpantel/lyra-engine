# frozen_string_literal: true

module PetriFlow
  module Verification
    # Reachability analysis for Petri nets
    # Determines which states are reachable from initial state
    #
    # Supports P/T abstraction mode for colored nets: when enabled,
    # guards are ignored and all transitions fire non-deterministically
    # based only on token availability. This is sound for structural
    # properties (boundedness, liveness, reachability).
    class ReachabilityAnalyzer
      attr_reader :net, :initial_marking, :reachable_markings, :state_graph, :pt_abstraction

      # @param net [PetriFlow::Core::Net] The Petri net to analyze
      # @param initial_marking [PetriFlow::Core::Marking] Initial marking (default: net's current marking)
      # @param pt_abstraction [Boolean] Enable P/T abstraction (ignore guards)
      def initialize(net, initial_marking = nil, pt_abstraction: false)
        @net = net
        @initial_marking = initial_marking || net.current_marking
        @reachable_markings = Set.new
        @state_graph = {} # marking => { transition => next_marking }
        @pt_abstraction = pt_abstraction
      end

      # Compute all reachable markings using BFS
      def analyze(max_states: 10000)
        @reachable_markings.clear
        @state_graph.clear

        queue = [@initial_marking.dup]
        visited = Set.new

        iteration = 0
        while queue.any? && iteration < max_states
          current_marking = queue.shift
          marking_key = marking_to_key(current_marking)

          next if visited.include?(marking_key)
          visited.add(marking_key)

          @reachable_markings.add(current_marking.dup)
          @state_graph[marking_key] = {}

          # Set net to current marking
          @net.set_marking(current_marking)

          # Try firing each enabled transition
          # In P/T abstraction mode, ignore guards (non-deterministic choice)
          context = @pt_abstraction ? { ignore_guards: true } : {}
          @net.enabled_transitions(context).each do |transition|
            # Save current state
            saved_marking = @net.current_marking.dup

            # Fire transition (pass context for P/T abstraction)
            begin
              transition.fire!(context)
              new_marking = @net.current_marking.dup
              new_marking_key = marking_to_key(new_marking)

              # Record state transition
              @state_graph[marking_key][transition.id] = new_marking_key

              # Add to queue if not visited
              queue << new_marking unless visited.include?(new_marking_key)
            ensure
              # Restore marking for next iteration
              @net.set_marking(saved_marking)
            end
          end

          iteration += 1
        end

        # Restore initial marking
        @net.set_marking(@initial_marking)

        {
          total_states: @reachable_markings.size,
          state_graph_size: @state_graph.size,
          max_states_reached: iteration >= max_states
        }
      end

      # Check if a specific marking is reachable
      def reachable?(target_marking)
        target_key = marking_to_key(target_marking)
        @reachable_markings.any? { |m| marking_to_key(m) == target_key }
      end

      # Find path from initial marking to target marking
      def find_path(target_marking)
        target_key = marking_to_key(target_marking)
        initial_key = marking_to_key(@initial_marking)

        return [] if initial_key == target_key

        # BFS to find shortest path
        queue = [[initial_key]]
        visited = Set.new([initial_key])

        while queue.any?
          path = queue.shift
          current_key = path.last

          next unless @state_graph[current_key]

          @state_graph[current_key].each do |transition_id, next_key|
            return path + [transition_id, next_key] if next_key == target_key

            unless visited.include?(next_key)
              visited.add(next_key)
              queue << (path + [transition_id, next_key])
            end
          end
        end

        nil # No path found
      end

      # Check for terminal states (no outgoing transitions)
      def terminal_states
        @state_graph.select { |_marking, transitions| transitions.empty? }.keys
      end

      # Generate reachability report
      def report
        {
          initial_marking: @initial_marking.to_h,
          total_reachable_states: @reachable_markings.size,
          terminal_states: terminal_states.size,
          state_graph_edges: @state_graph.values.map(&:size).sum,
          is_bounded: bounded?,
          deadlock_states: terminal_states,
          pt_abstraction: @pt_abstraction
        }
      end

      private

      def marking_to_key(marking)
        marking.to_h.sort.to_s
      end

      def bounded?
        # Check if token count in any place exceeds a reasonable bound
        max_tokens = @reachable_markings.flat_map { |m| m.to_h.values }.max || 0
        max_tokens < 1000 # Arbitrary bound
      end
    end
  end
end
