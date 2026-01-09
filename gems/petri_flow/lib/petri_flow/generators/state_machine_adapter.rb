# frozen_string_literal: true

module PetriFlow
  module Generators
    # Base class for state machine adapters.
    # Subclasses extract states and transitions from different state machine libraries.
    #
    # @abstract Subclass and implement {#extract}
    class StateMachineAdapter
      attr_reader :model_class, :state_attribute

      # @param model_class [Class] ActiveRecord model class
      # @param state_attribute [Symbol] The state attribute name (default: :state)
      def initialize(model_class, state_attribute = :state)
        @model_class = model_class
        @state_attribute = state_attribute.to_sym
      end

      # Check if this adapter can handle the given model
      # @return [Boolean]
      def self.supports?(model_class)
        raise NotImplementedError, "Subclasses must implement .supports?"
      end

      # Extract state machine definition
      # @return [Hash] with :states, :initial_state, :terminal_states, :transitions
      def extract
        raise NotImplementedError, "Subclasses must implement #extract"
      end

      # Human-readable name of the state machine library
      # @return [String]
      def self.library_name
        raise NotImplementedError, "Subclasses must implement .library_name"
      end

      protected

      # Find terminal states (states with no outgoing transitions)
      def find_terminal_states(states, transitions)
        states_with_outgoing = Set.new(transitions.map { |t| t[:from] })
        terminal = states.reject { |s| states_with_outgoing.include?(s) }
        terminal.empty? ? [states.last] : terminal
      end
    end
  end
end
