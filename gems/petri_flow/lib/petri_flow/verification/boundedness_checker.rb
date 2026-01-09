# frozen_string_literal: true

module PetriFlow
  module Verification
    # Boundedness checker for Petri nets
    # Checks if token count in places is bounded
    class BoundednessChecker
      attr_reader :net, :reachability_analyzer

      def initialize(net, reachability_analyzer = nil)
        @net = net
        @reachability_analyzer = reachability_analyzer ||
                                 ReachabilityAnalyzer.new(net)
      end

      # Check if the net is bounded
      # A net is k-bounded if no place ever contains more than k tokens
      def bounded?(k = nil, max_states: 10000)
        # First compute reachability
        @reachability_analyzer.analyze(max_states: max_states)

        if k.nil?
          # Check if there's any bound
          check_general_boundedness
        else
          # Check if bounded by k
          check_k_boundedness(k)
        end
      end

      # Find the bound for each place
      def place_bounds
        bounds = {}

        @reachability_analyzer.reachable_markings.each do |marking|
          marking.to_h.each do |place_id, token_count|
            bounds[place_id] ||= 0
            bounds[place_id] = [bounds[place_id], token_count].max
          end
        end

        bounds
      end

      # Check if net is safe (1-bounded)
      def safe?
        bounded?(1)
      end

      # Check if net is structurally bounded
      # (bounded regardless of initial marking)
      def structurally_bounded?
        # This requires computing the incidence matrix
        # and checking if the system is structurally bounded
        # For now, we'll return a simplified check
        incidence_matrix = compute_incidence_matrix

        # Check if the rank of incidence matrix indicates structural boundedness
        # This is a simplified heuristic
        places_count = @net.places.size
        transitions_count = @net.transitions.size

        # If places >= transitions, likely bounded
        places_count >= transitions_count
      end

      # Generate boundedness report
      def report
        {
          is_bounded: bounded?,
          is_safe: safe?,
          place_bounds: place_bounds,
          max_tokens: place_bounds.values.max || 0,
          unbounded_places: unbounded_places,
          structurally_bounded: structurally_bounded?
        }
      end

      private

      def check_general_boundedness
        bounds = place_bounds

        # Check if any place has "infinite" tokens (we use 1000 as threshold)
        bounds.values.all? { |bound| bound < 1000 }
      end

      def check_k_boundedness(k)
        bounds = place_bounds
        bounds.values.all? { |bound| bound <= k }
      end

      def unbounded_places
        bounds = place_bounds
        bounds.select { |_place, bound| bound >= 1000 }.keys
      end

      def compute_incidence_matrix
        places = @net.places.keys
        transitions = @net.transitions.keys

        matrix = {}
        places.each do |place_id|
          matrix[place_id] = {}
          transitions.each do |transition_id|
            matrix[place_id][transition_id] = 0
          end
        end

        # Calculate incidence matrix: C = C+ - C-
        @net.arcs.each do |arc|
          if arc.input_arc? # place -> transition
            place_id = arc.source.id
            transition_id = arc.target.id
            matrix[place_id][transition_id] -= arc.weight
          elsif arc.output_arc? # transition -> place
            place_id = arc.target.id
            transition_id = arc.source.id
            matrix[place_id][transition_id] += arc.weight
          end
        end

        matrix
      end
    end
  end
end
