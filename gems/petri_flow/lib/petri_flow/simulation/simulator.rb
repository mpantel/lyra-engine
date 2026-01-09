# frozen_string_literal: true

module PetriFlow
  module Simulation
    # Simulator for Petri nets
    # Simulates execution and generates traces
    class Simulator
      attr_reader :net, :trace, :current_step

      def initialize(net)
        @net = net
        @trace = Trace.new
        @current_step = 0
      end

      # Run simulation for n steps or until no transitions enabled
      def run(steps: 100, strategy: :random, context: {})
        @current_step = 0
        @trace.clear
        @trace.record_initial_marking(@net.current_marking)

        steps.times do |step|
          @current_step = step

          enabled = @net.enabled_transitions(context)
          break if enabled.empty?

          transition = select_transition(enabled, strategy)
          fire_transition(transition, context)
        end

        @trace
      end

      # Run until a specific condition is met
      def run_until(strategy: :random, max_steps: 1000, context: {}, &condition)
        @current_step = 0
        @trace.clear
        @trace.record_initial_marking(@net.current_marking)

        max_steps.times do |step|
          @current_step = step

          # Check condition
          break if condition.call(@net.current_marking, @net)

          enabled = @net.enabled_transitions(context)
          break if enabled.empty?

          transition = select_transition(enabled, strategy)
          fire_transition(transition, context)
        end

        @trace
      end

      # Run simulation multiple times (Monte Carlo)
      def run_multiple(runs: 100, steps: 50, strategy: :random, context: {})
        traces = []
        initial_marking = @net.current_marking.dup

        runs.times do
          # Reset to initial state
          @net.set_marking(initial_marking.dup)

          # Run simulation
          trace = run(steps: steps, strategy: strategy, context: context)
          traces << trace

          # Reset for next run
          @net.set_marking(initial_marking.dup)
        end

        analyze_traces(traces)
      end

      # Interactive simulation (step by step)
      def step(transition_id = nil, context: {})
        if transition_id
          transition = @net.transition(transition_id)
          raise "Transition #{transition_id} not found" unless transition
          raise "Transition #{transition_id} not enabled" unless transition.enabled?(context)

          fire_transition(transition, context)
        else
          enabled = @net.enabled_transitions(context)
          return nil if enabled.empty?

          transition = enabled.first
          fire_transition(transition, context)
        end

        @current_step += 1
        transition
      end

      # Reset simulation
      def reset(initial_marking = nil)
        @current_step = 0
        @trace.clear

        if initial_marking
          @net.set_marking(initial_marking)
        end

        @trace.record_initial_marking(@net.current_marking)
      end

      private

      def select_transition(enabled_transitions, strategy)
        case strategy
        when :random
          enabled_transitions.sample
        when :first
          enabled_transitions.first
        when :priority
          # Transitions with higher priority (more input arcs) first
          enabled_transitions.max_by { |t| t.input_arcs.size }
        when :least_used
          # Select least fired transition
          firing_counts = @trace.transition_firing_counts
          enabled_transitions.min_by { |t| firing_counts[t.id] || 0 }
        else
          enabled_transitions.first
        end
      end

      def fire_transition(transition, context)
        # Record state before firing
        marking_before = @net.current_marking.dup

        # Fire transition
        transition.fire!(context)

        # Record state after firing
        marking_after = @net.current_marking.dup

        # Add to trace
        @trace.record_transition(
          step: @current_step,
          transition_id: transition.id,
          transition_name: transition.name,
          marking_before: marking_before,
          marking_after: marking_after
        )
      end

      def analyze_traces(traces)
        {
          total_runs: traces.size,
          average_steps: traces.map(&:steps).sum.to_f / traces.size,
          min_steps: traces.map(&:steps).min,
          max_steps: traces.map(&:steps).max,
          deadlocked_runs: traces.count { |t| t.deadlocked? },
          transition_frequencies: aggregate_transition_frequencies(traces),
          state_coverage: aggregate_state_coverage(traces),
          traces: traces
        }
      end

      def aggregate_transition_frequencies(traces)
        frequencies = Hash.new(0)

        traces.each do |trace|
          trace.transition_firing_counts.each do |transition_id, count|
            frequencies[transition_id] += count
          end
        end

        total_firings = frequencies.values.sum
        frequencies.transform_values { |count| count.to_f / total_firings }
      end

      def aggregate_state_coverage(traces)
        all_states = Set.new

        traces.each do |trace|
          trace.visited_markings.each do |marking|
            all_states.add(marking.to_h.sort.to_s)
          end
        end

        all_states.size
      end
    end
  end
end
