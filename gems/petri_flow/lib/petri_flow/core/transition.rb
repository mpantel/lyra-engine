# frozen_string_literal: true

module PetriFlow
  module Core
    # Represents a transition in a Petri net
    # Transitions are the active components that consume and produce tokens
    class Transition
      attr_reader :id, :name, :input_arcs, :output_arcs
      attr_accessor :guard

      def initialize(id:, name: nil, guard: nil)
        @id = id
        @name = name || id.to_s
        @guard = guard
        @input_arcs = []
        @output_arcs = []
      end

      # Add an input arc from a place
      def add_input_arc(arc)
        @input_arcs << arc
      end

      # Add an output arc to a place
      def add_output_arc(arc)
        @output_arcs << arc
      end

      # Check if transition is enabled (can fire)
      # A transition is enabled if all input places have sufficient tokens
      # and all output places can accept tokens
      #
      # @param context [Hash] Context for guard evaluation
      # @option context [Boolean] :ignore_guards Skip guard evaluation (P/T abstraction)
      def enabled?(context = {})
        ignore_guards = context[:ignore_guards]
        return false unless ignore_guards || guard_satisfied?(context)

        # Check input places have sufficient tokens
        @input_arcs.all? { |arc| arc.source.has_tokens?(arc.weight) } &&
          # Check output places can accept tokens
          @output_arcs.all? { |arc| arc.target.can_accept?(arc.weight) }
      end

      # Fire the transition
      # Consumes tokens from input places and produces tokens in output places
      def fire!(context = {})
        raise TransitionNotEnabledError, "Transition #{@name} is not enabled" unless enabled?(context)

        # Remove tokens from input places
        @input_arcs.each { |arc| arc.source.remove_tokens(arc.weight) }

        # Add tokens to output places
        @output_arcs.each { |arc| arc.target.add_tokens(arc.weight) }

        # Return the transition for chaining
        self
      end

      def to_s
        "Transition(#{@name})"
      end

      def inspect
        "#<PetriFlow::Core::Transition id=#{@id} name=#{@name} " \
          "inputs=#{@input_arcs.size} outputs=#{@output_arcs.size}>"
      end

      private

      def guard_satisfied?(context)
        return true unless @guard

        if @guard.respond_to?(:satisfied?)
          @guard.satisfied?(context)
        elsif @guard.respond_to?(:call)
          @guard.call(context)
        elsif @guard.is_a?(Symbol)
          context[@guard]
        else
          !!@guard
        end
      end
    end

    class TransitionNotEnabledError < StandardError; end
  end
end
