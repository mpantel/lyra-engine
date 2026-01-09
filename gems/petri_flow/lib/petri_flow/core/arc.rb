# frozen_string_literal: true

module PetriFlow
  module Core
    # Represents an arc in a Petri net
    # Arcs connect places to transitions or transitions to places
    class Arc
      attr_reader :source, :target, :weight
      attr_accessor :expression

      # Create a new arc
      # @param source [Place, Transition] The source node
      # @param target [Transition, Place] The target node
      # @param weight [Integer] Number of tokens consumed/produced (default: 1)
      # @param expression [Proc] Arc expression for colored nets (optional)
      def initialize(source:, target:, weight: 1, expression: nil)
        validate_arc!(source, target)

        @source = source
        @target = target
        @weight = weight
        @expression = expression
      end

      # Check if this is an input arc (place -> transition)
      def input_arc?
        @source.is_a?(Place) && @target.is_a?(Transition)
      end

      # Check if this is an output arc (transition -> place)
      def output_arc?
        @source.is_a?(Transition) && @target.is_a?(Place)
      end

      # Execute arc expression (for colored Petri nets)
      def execute_expression(token_data)
        return token_data unless @expression

        @expression.call(token_data)
      end

      def to_s
        "Arc(#{@source.name} -> #{@target.name}, weight: #{@weight})"
      end

      def inspect
        "#<PetriFlow::Core::Arc #{@source.class.name}(#{@source.name}) -> " \
          "#{@target.class.name}(#{@target.name}) weight=#{@weight}>"
      end

      private

      def validate_arc!(source, target)
        valid = (source.is_a?(Place) && target.is_a?(Transition)) ||
                (source.is_a?(Transition) && target.is_a?(Place))

        raise ArcValidationError, "Arc must connect Place<->Transition or Transition<->Place" unless valid
      end
    end

    class ArcValidationError < StandardError; end
  end
end
