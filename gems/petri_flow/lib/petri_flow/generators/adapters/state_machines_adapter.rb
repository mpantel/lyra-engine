# frozen_string_literal: true

module PetriFlow
  module Generators
    module Adapters
      # Adapter for state_machines-activerecord gem
      # @see https://github.com/state-machines/state_machines-activerecord
      class StateMachinesAdapter < StateMachineAdapter
        def self.library_name
          "state_machines-activerecord"
        end

        def self.supports?(model_class)
          model_class.respond_to?(:state_machines)
        end

        def extract
          sm = model_class.state_machines[state_attribute]
          raise ArgumentError, "No state machine for :#{state_attribute} on #{model_class}" unless sm

          states = extract_states(sm)
          initial = extract_initial_state(sm)
          transitions = extract_transitions(sm)
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

        def extract_states(sm)
          sm.states.map(&:name).compact
        end

        def extract_initial_state(sm)
          # Try to get initial state from a new instance
          initial = sm.initial_state(model_class.new)
          initial.try(:name) || extract_states(sm).first
        end

        def extract_transitions(sm)
          transitions = []

          sm.events.each do |event|
            event.branches.each do |branch|
              branch.state_requirements.each do |req|
                from_states = extract_state_values(req[:from])
                to_states = extract_state_values(req[:to])

                from_states.each do |from|
                  to_states.each do |to|
                    transitions << {
                      name: "#{event.name}_from_#{from}".to_sym,
                      event: event.name,
                      from: from,
                      to: to
                    }
                  end
                end
              end
            end
          end

          transitions
        end

        def extract_state_values(state_matcher)
          if state_matcher.respond_to?(:values)
            state_matcher.values
          else
            [state_matcher]
          end.compact
        end
      end
    end
  end
end
