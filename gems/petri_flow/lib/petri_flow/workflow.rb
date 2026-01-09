# frozen_string_literal: true

module PetriFlow
  # Base class for defining workflow Petri nets using a declarative DSL.
  #
  # @example Define a workflow
  #   class RefundRequestWorkflow < PetriFlow::Workflow
  #     workflow_name "RefundRequestWorkflow"
  #
  #     places :requested, :under_review, :approved, :rejected, :processed, :cancelled
  #     initial_place :requested
  #     terminal_places :rejected, :processed, :cancelled
  #
  #     transition :start_review, from: :requested, to: :under_review
  #     transition :approve, from: :under_review, to: :approved
  #     transition :reject, from: :requested, to: :rejected
  #     transition :reject, from: :under_review, to: :rejected
  #     transition :process, from: :approved, to: :processed
  #     transition :cancel, from: :requested, to: :cancelled
  #     transition :cancel, from: :under_review, to: :cancelled
  #   end
  #
  class Workflow
    class << self
      attr_reader :defined_places, :defined_transitions, :defined_initial_place,
                  :defined_terminal_places, :defined_workflow_name

      # DSL: Set workflow name
      # @param name [String] The name for this workflow
      def workflow_name(name)
        @defined_workflow_name = name
      end

      # DSL: Define places (states) in the workflow
      # @param place_ids [Array<Symbol>] List of place identifiers
      # Note: This also resets transitions to handle file reloading gracefully
      def places(*place_ids)
        @defined_places = place_ids.flatten.map(&:to_sym)
        # Reset transitions when places are redefined (handles `load` being called multiple times)
        @defined_transitions = []
      end

      # DSL: Set the initial place (starting state)
      # @param place_id [Symbol] The initial place identifier
      def initial_place(place_id)
        @defined_initial_place = place_id.to_sym
      end

      # DSL: Set terminal places (end states)
      # @param place_ids [Array<Symbol>] List of terminal place identifiers
      def terminal_places(*place_ids)
        @defined_terminal_places = place_ids.flatten.map(&:to_sym)
      end

      # DSL: Define a transition between places
      #
      # Supports three patterns:
      # - Simple: `from: :a, to: :b` (one input, one output)
      # - Fork: `from: :a, to: [:b, :c]` (one input, multiple outputs - parallel split)
      # - Join: `from: [:a, :b], to: :c` (multiple inputs, one output - synchronization)
      #
      # @param name [Symbol] Transition name (e.g., :approve, :reject)
      # @param from [Symbol, Array<Symbol>] Source place(s) - array for join pattern
      # @param to [Symbol, Array<Symbol>] Target place(s) - array for fork pattern
      # @param method [String] Optional method name for audit trail
      # @param trigger [String] Optional trigger description
      def transition(name, from:, to:, method: nil, trigger: nil)
        @defined_transitions ||= []

        # Normalize to arrays for uniform handling
        from_places = Array(from).map(&:to_sym)
        to_places = Array(to).map(&:to_sym)

        # Generate unique ID based on all input places
        transition_id = generate_transition_id(name, from_places.first)

        @defined_transitions << {
          id: transition_id,
          name: name.to_sym,
          from: from_places,
          to: to_places,
          method: method || "#{name}!",
          trigger: trigger
        }
      end

      # Hook called when a class inherits from Workflow
      # Registers the subclass with the Registry
      def inherited(subclass)
        super
        Registry.register(subclass) if defined?(Registry) && Registry.respond_to?(:register)
      end

      private

      def generate_transition_id(name, from)
        :"t_#{name}_from_#{from}"
      end
    end

    attr_reader :net, :verification_results, :terminal_reachability

    def initialize
      @net = PetriFlow.create_net(name: workflow_name)
      @verification_results = {}
      @terminal_reachability = {}
      build_net
    end

    # Get the workflow name
    # @return [String] The workflow name
    def workflow_name
      self.class.defined_workflow_name || self.class.name
    end

    # Get a URL-safe identifier for this workflow
    # @return [String] Underscored workflow name
    def workflow_id
      workflow_name.underscore.gsub("::", "_").gsub(/\s+/, "_")
    end

    # Build the Petri net from class definitions
    def build_net
      add_places
      add_transitions
    end

    # Create initial marking (token distribution)
    # @return [PetriFlow::Core::Marking] The initial marking
    def initial_marking
      tokens = self.class.defined_places.each_with_object({}) do |place, hash|
        hash[place] = (place == self.class.defined_initial_place) ? 1 : 0
      end
      PetriFlow::Core::Marking.new(tokens)
    end

    # Reset net to initial state
    def reset_to_initial!
      @net.set_marking(initial_marking)
    end

    # Run full verification
    # @return [Hash] Verification results
    def verify!
      reset_to_initial!
      @verification_results = PetriFlow.verify(@net)
      verify_terminal_reachability
      @verification_results
    end

    # Export as Mermaid diagram
    # @return [String] Mermaid diagram source
    def to_mermaid
      PetriFlow.visualize(@net, format: :mermaid)
    end

    # Export as DOT diagram
    # @return [String] GraphViz DOT source
    def to_dot
      PetriFlow.visualize(@net, format: :dot)
    end

    # Run simulation
    # @param steps [Integer] Number of simulation steps
    # @param strategy [Symbol] Simulation strategy (:random, :priority, :least_used)
    # @return [PetriFlow::Simulation::Trace] Simulation trace
    def simulate(steps: 20, strategy: :random)
      reset_to_initial!
      simulator = PetriFlow::Simulation::Simulator.new(@net)
      simulator.run(steps: steps, strategy: strategy)
    end

    private

    def add_places
      self.class.defined_places.each do |place_id|
        initial_tokens = (place_id == self.class.defined_initial_place) ? 1 : 0
        @net.add_place(
          id: place_id,
          name: place_id.to_s.titleize,
          initial_tokens: initial_tokens
        )
      end
    end

    def add_transitions
      self.class.defined_transitions.each do |transition|
        @net.add_transition(
          id: transition[:id],
          name: transition[:method] || transition[:trigger] || transition[:name].to_s
        )

        # Handle fork pattern: multiple output places
        # Handle join pattern: multiple input places
        from_places = Array(transition[:from])
        to_places = Array(transition[:to])

        # Add input arcs (place → transition)
        from_places.each do |place_id|
          @net.add_arc(source_id: place_id, target_id: transition[:id])
        end

        # Add output arcs (transition → place)
        to_places.each do |place_id|
          @net.add_arc(source_id: transition[:id], target_id: place_id)
        end
      end
    end

    def verify_terminal_reachability
      analyzer = PetriFlow::Verification::ReachabilityAnalyzer.new(@net, initial_marking)
      analyzer.analyze

      # Get all reachable markings
      reachable_markings = analyzer.reachable_markings

      self.class.defined_terminal_places&.each do |state|
        # Check if ANY reachable marking has a token in this terminal place
        # This correctly handles fork patterns where multiple places have tokens
        @terminal_reachability[state] = reachable_markings.any? do |marking|
          marking.tokens_at(state) > 0
        end
      end

      reset_to_initial!
    end
  end
end
