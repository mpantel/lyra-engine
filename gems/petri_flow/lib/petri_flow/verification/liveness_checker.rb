# frozen_string_literal: true

module PetriFlow
  module Verification
    # Liveness checker for Petri nets
    # Checks various liveness properties
    class LivenessChecker
      attr_reader :net, :reachability_analyzer

      # Liveness levels:
      # L0 (Dead): Never fires
      # L1 (Potentially firable): Can fire at least once
      # L2 (Potentially firable k times): Can fire k times
      # L3 (Potentially firable infinitely): Can fire infinitely
      # L4 (Live): Can always eventually fire

      # terminal_places: places whose marking means the net finished rather
      # than got stuck. See #terminates_properly?.
      def initialize(net, reachability_analyzer = nil, terminal_places: [])
        @net = net
        @reachability_analyzer = reachability_analyzer ||
                                 ReachabilityAnalyzer.new(net)
        @terminal_places = Array(terminal_places).map(&:to_sym)
      end

      # Check if transition is dead (L0)
      def dead?(transition_id)
        !firable?(transition_id)
      end

      # Check if transition is potentially firable (L1)
      def firable?(transition_id)
        @reachability_analyzer.reachable_markings.any? do |marking|
          @net.set_marking(marking)
          transition = @net.transition(transition_id)
          transition&.enabled?
        end
      end

      # Check if transition is live (L4)
      # A transition is live if from every reachable marking,
      # it can eventually fire
      def live?(transition_id, max_depth: 100)
        @reachability_analyzer.reachable_markings.all? do |marking|
          can_eventually_fire?(transition_id, marking, max_depth: max_depth)
        end
      end

      # Check if net is deadlock-free
      def deadlock_free?
        @reachability_analyzer.reachable_markings.all? do |marking|
          @net.set_marking(marking)
          !@net.deadlocked?
        end
      end

      # Deadlock-freedom relative to designated terminal places: a reachable
      # marking in which no transition is enabled is a deadlock unless it
      # marks at least one terminal place. deadlock_free? counts every dead
      # marking, so it is false for any net that is meant to finish; with no
      # terminal places the two agree.
      def terminates_properly?
        improper_dead_markings.empty?
      end

      # Reachable dead markings that mark no terminal place.
      def improper_dead_markings
        @reachability_analyzer.reachable_markings.select do |marking|
          @net.set_marking(marking)
          @net.deadlocked? && @terminal_places.none? { |place| marking.tokens_at(place).positive? }
        end
      end

      # Find dead transitions
      def dead_transitions
        @net.transitions.keys.select { |tid| dead?(tid) }
      end

      # Find live transitions
      def live_transitions(max_depth: 100)
        @net.transitions.keys.select { |tid| live?(tid, max_depth: max_depth) }
      end

      # Classify all transitions by liveness level
      def classify_transitions
        classification = {}

        @net.transitions.each_key do |transition_id|
          classification[transition_id] = if dead?(transition_id)
                                            :dead # L0
                                          elsif live?(transition_id)
                                            :live # L4
                                          elsif firable?(transition_id)
                                            :potentially_firable # L1
                                          else
                                            :unknown
                                          end
        end

        classification
      end

      # Generate liveness report
      def report
        classification = classify_transitions

        {
          deadlock_free: deadlock_free?,
          terminal_places: @terminal_places,
          terminates_properly: terminates_properly?,
          improper_dead_markings: improper_dead_markings.size,
          dead_transitions: classification.select { |_, v| v == :dead }.keys,
          live_transitions: classification.select { |_, v| v == :live }.keys,
          potentially_firable: classification.select { |_, v| v == :potentially_firable }.keys,
          classification: classification,
          liveness_score: calculate_liveness_score(classification)
        }
      end

      private

      def can_eventually_fire?(transition_id, from_marking, max_depth:)
        # BFS to find if transition can fire within max_depth steps
        queue = [[from_marking, 0]]
        visited = Set.new([marking_to_key(from_marking)])

        while queue.any?
          current_marking, depth = queue.shift

          return false if depth > max_depth

          @net.set_marking(current_marking)

          # Check if target transition is enabled
          transition = @net.transition(transition_id)
          return true if transition&.enabled?

          # Try all enabled transitions
          @net.enabled_transitions.each do |enabled_transition|
            saved_marking = @net.current_marking.dup

            begin
              enabled_transition.fire!
              new_marking = @net.current_marking.dup
              new_key = marking_to_key(new_marking)

              unless visited.include?(new_key)
                visited.add(new_key)
                queue << [new_marking, depth + 1]
              end
            ensure
              @net.set_marking(saved_marking)
            end
          end
        end

        false
      end

      def marking_to_key(marking)
        marking.to_h.sort.to_s
      end

      def calculate_liveness_score(classification)
        total = classification.size
        return 0 if total.zero?

        live_count = classification.count { |_, v| v == :live }
        firable_count = classification.count { |_, v| v == :potentially_firable }

        # Score: (live * 1.0 + firable * 0.5) / total
        ((live_count * 1.0) + (firable_count * 0.5)) / total
      end
    end
  end
end
