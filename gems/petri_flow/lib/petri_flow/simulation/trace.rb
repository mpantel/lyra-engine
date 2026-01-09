# frozen_string_literal: true

module PetriFlow
  module Simulation
    # Trace of a Petri net execution
    # Records the sequence of transitions fired and markings visited
    class Trace
      attr_reader :transitions, :markings, :initial_marking

      def initialize
        @transitions = []
        @markings = []
        @initial_marking = nil
      end

      # Record initial marking
      def record_initial_marking(marking)
        @initial_marking = marking.dup
        @markings << marking.dup
      end

      # Record a transition firing
      def record_transition(step:, transition_id:, transition_name:, marking_before:, marking_after:)
        @transitions << {
          step: step,
          transition_id: transition_id,
          transition_name: transition_name,
          marking_before: marking_before.dup,
          marking_after: marking_after.dup,
          timestamp: Time.current
        }

        @markings << marking_after.dup
      end

      # Get number of steps
      def steps
        @transitions.size
      end

      # Check if trace ended in deadlock
      def deadlocked?
        # If trace has transitions, check if last marking had no enabled transitions
        # This is a heuristic - in practice we'd need to check the net state
        false # Placeholder - would need net reference
      end

      # Get transition firing counts
      def transition_firing_counts
        counts = Hash.new(0)
        @transitions.each do |t|
          counts[t[:transition_id]] += 1
        end
        counts
      end

      # Get visited markings (unique states)
      def visited_markings
        @markings.uniq { |m| m.to_h.sort.to_s }
      end

      # Get firing sequence (just transition IDs)
      def firing_sequence
        @transitions.map { |t| t[:transition_id] }
      end

      # Get firing sequence with names
      def firing_sequence_names
        @transitions.map { |t| t[:transition_name] }
      end

      # Export trace data
      def to_h
        {
          initial_marking: @initial_marking&.to_h,
          steps: steps,
          transitions: @transitions,
          markings: @markings.map(&:to_h),
          firing_sequence: firing_sequence,
          unique_states: visited_markings.size
        }
      end

      # Pretty print trace
      def to_s
        lines = []
        lines << "Trace (#{steps} steps)"
        lines << "Initial: #{@initial_marking&.to_h}"
        lines << ""

        @transitions.each_with_index do |transition, idx|
          lines << "Step #{transition[:step]}: #{transition[:transition_name]} (#{transition[:transition_id]})"
          lines << "  Before: #{transition[:marking_before].to_h}"
          lines << "  After:  #{transition[:marking_after].to_h}"
        end

        lines.join("\n")
      end

      # Clear trace
      def clear
        @transitions.clear
        @markings.clear
        @initial_marking = nil
      end

      # Statistics about the trace
      def stats
        {
          steps: steps,
          unique_states: visited_markings.size,
          unique_transitions: transition_firing_counts.size,
          most_fired_transition: transition_firing_counts.max_by { |_, c| c }&.first,
          firing_counts: transition_firing_counts
        }
      end
    end
  end
end
