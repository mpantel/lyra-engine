# frozen_string_literal: true

module PetriFlow
  module Generators
    module Adapters
      # Adapter for AASM (acts_as_state_machine) gem
      # @see https://github.com/aasm/aasm
      class AasmAdapter < StateMachineAdapter
        def self.library_name
          "aasm"
        end

        def self.supports?(model_class)
          model_class.respond_to?(:aasm)
        end

        def extract
          aasm = model_class.aasm(state_attribute)
          raise ArgumentError, "No AASM state machine for :#{state_attribute} on #{model_class}" unless aasm

          states = extract_states(aasm)
          initial = extract_initial_state(aasm)
          transitions = extract_transitions(aasm)
          terminal = find_terminal_states(states, transitions)

          {
            states: states,
            initial_state: initial,
            terminal_states: terminal,
            transitions: transitions,
            library: self.class.library_name
          }
        end

        private

        def extract_states(aasm)
          aasm.states.map(&:name)
        end

        def extract_initial_state(aasm)
          aasm.initial_state
        end

        def extract_transitions(aasm)
          transitions = []

          aasm.events.each do |event|
            event.transitions.each do |transition|
              from_states = Array(transition.from)
              to_state = transition.to

              from_states.each do |from|
                transitions << {
                  name: "#{event.name}_from_#{from}".to_sym,
                  event: event.name,
                  from: from,
                  to: to_state
                }
              end
            end
          end

          transitions
        end
      end
    end
  end
end
