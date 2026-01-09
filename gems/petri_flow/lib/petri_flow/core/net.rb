# frozen_string_literal: true

module PetriFlow
  module Core
    # Represents a Petri net
    # A Petri net consists of places, transitions, and arcs connecting them
    class Net
      attr_reader :places, :transitions, :arcs, :name

      def initialize(name: "PetriNet")
        @name = name
        @places = {}
        @transitions = {}
        @arcs = []
      end

      # Add a place to the net
      def add_place(id:, name: nil, initial_tokens: 0, capacity: Float::INFINITY)
        place = Place.new(
          id: id,
          name: name,
          initial_tokens: initial_tokens,
          capacity: capacity
        )
        @places[id] = place
        place
      end

      # Add a transition to the net
      def add_transition(id:, name: nil, guard: nil)
        transition = Transition.new(id: id, name: name, guard: guard)
        @transitions[id] = transition
        transition
      end

      # Add an arc connecting a place and transition
      def add_arc(source_id:, target_id:, weight: 1, expression: nil)
        source = @places[source_id] || @transitions[source_id]
        target = @transitions[target_id] || @places[target_id]

        raise "Source #{source_id} not found" unless source
        raise "Target #{target_id} not found" unless target

        arc = Arc.new(source: source, target: target, weight: weight, expression: expression)
        @arcs << arc

        # Register arc with transition
        if arc.input_arc?
          target.add_input_arc(arc)
        else
          source.add_output_arc(arc)
        end

        arc
      end

      # Get current marking
      def current_marking
        marking = Marking.new
        @places.each do |id, place|
          marking.set_tokens(id, place.tokens)
        end
        marking
      end

      # Set marking (restore state)
      def set_marking(marking)
        @places.each do |id, place|
          place.instance_variable_set(:@tokens, marking.tokens_at(id))
        end
      end

      # Get all enabled transitions
      def enabled_transitions(context = {})
        @transitions.values.select { |t| t.enabled?(context) }
      end

      # Fire a transition by id
      def fire_transition(transition_id, context = {})
        transition = @transitions[transition_id]
        raise "Transition #{transition_id} not found" unless transition

        transition.fire!(context)
      end

      # Check if net is in a deadlock state (no transitions enabled)
      def deadlocked?(context = {})
        enabled_transitions(context).empty?
      end

      # Get place by id
      def place(id)
        @places[id]
      end

      # Get transition by id
      def transition(id)
        @transitions[id]
      end

      # Get statistics about the net
      def stats
        {
          places: @places.size,
          transitions: @transitions.size,
          arcs: @arcs.size,
          total_tokens: @places.values.sum(&:tokens),
          enabled_transitions: enabled_transitions.size
        }
      end

      def to_s
        "Net(#{@name}, P=#{@places.size}, T=#{@transitions.size}, A=#{@arcs.size})"
      end

      def inspect
        "#<PetriFlow::Core::Net name=#{@name} #{stats}>"
      end
    end
  end
end
