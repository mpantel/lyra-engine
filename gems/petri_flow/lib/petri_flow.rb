# frozen_string_literal: true

require "active_support"
require "active_support/core_ext"
require "matrix"
require "securerandom"
require "digest"
require "set"

require_relative "petri_flow/version"

# Core Petri net components
require_relative "petri_flow/core/place"
require_relative "petri_flow/core/transition"
require_relative "petri_flow/core/arc"
require_relative "petri_flow/core/token"
require_relative "petri_flow/core/marking"
require_relative "petri_flow/core/net"

# Colored Petri net extensions
require_relative "petri_flow/colored/color"
require_relative "petri_flow/colored/guard"
require_relative "petri_flow/colored/arc_expression"
require_relative "petri_flow/colored/colored_net"

# Matrix analysis
require_relative "petri_flow/matrix/crud_event_mapping"
require_relative "petri_flow/matrix/correlation"
require_relative "petri_flow/matrix/causation"
require_relative "petri_flow/matrix/lineage"
require_relative "petri_flow/matrix/reachability"
require_relative "petri_flow/matrix/analyzer"

# Visualization
require_relative "petri_flow/visualization/graphviz"
require_relative "petri_flow/visualization/mermaid"

# Formal verification
require_relative "petri_flow/verification/reachability_analyzer"
require_relative "petri_flow/verification/boundedness_checker"
require_relative "petri_flow/verification/liveness_checker"
require_relative "petri_flow/verification/invariant_checker"

# Simulation
require_relative "petri_flow/simulation/simulator"
require_relative "petri_flow/simulation/trace"

# Export functionality
require_relative "petri_flow/export"

# Workflow base class and registry (always available)
require_relative "petri_flow/registry"
require_relative "petri_flow/workflow"
require_relative "petri_flow/verification_runner"

# Generators for creating workflows from state machines
require_relative "petri_flow/generators/state_machine_adapter"
require_relative "petri_flow/generators/adapters/state_machines_adapter"
require_relative "petri_flow/generators/adapters/aasm_adapter"
require_relative "petri_flow/generators/workflow_generator"

# Load Rails integration if Rails is available
require_relative "petri_flow/railtie" if defined?(Rails::Railtie)

module PetriFlow
  class Error < StandardError; end

  class << self
    # Rails configuration (set by Railtie)
    attr_accessor :rails_config

    # Create a new Petri net
    def create_net(name: "PetriNet")
      Core::Net.new(name: name)
    end

    # Create a new Colored Petri net
    def create_colored_net(name: "ColoredPetriNet")
      Colored::ColoredNet.new(name: name)
    end

    # Create a matrix analyzer
    def create_analyzer
      Matrix::Analyzer.new
    end

    # Quick visualization
    def visualize(net, format: :dot)
      case format
      when :dot, :graphviz
        Visualization::Graphviz.new(net).to_dot
      when :mermaid
        Visualization::Mermaid.new(net).to_mermaid
      when :ascii
        Visualization::Graphviz.new(net).to_ascii
      else
        raise Error, "Unknown visualization format: #{format}"
      end
    end

    # Quick verification
    #
    # @param net [PetriFlow::Core::Net] The Petri net to verify
    # @param initial_marking [PetriFlow::Core::Marking] Initial marking
    # @param pt_abstraction [Boolean] Enable P/T abstraction (ignore guards)
    #   Use true for full state-space exploration of colored nets.
    #   Guards are treated as non-deterministic choice, which is sound
    #   for structural properties (boundedness, liveness, reachability).
    # @param terminal_places [Array<Symbol>] Places whose marking means the
    #   net has finished; liveness[:terminates_properly] is deadlock-freedom
    #   except at markings that mark one of them.
    # The analysis fires transitions to explore the state space; the net's
    # marking is restored afterwards, so verifying a net does not change it.
    def verify(net, initial_marking: nil, pt_abstraction: false, terminal_places: [])
      marking_before = net.current_marking
      initial_marking ||= marking_before

      reachability = Verification::ReachabilityAnalyzer.new(net, initial_marking, pt_abstraction: pt_abstraction)
      reachability.analyze

      boundedness = Verification::BoundednessChecker.new(net, reachability)
      liveness = Verification::LivenessChecker.new(net, reachability, terminal_places: terminal_places)

      {
        reachability: reachability.report,
        boundedness: boundedness.report,
        liveness: liveness.report
      }
    ensure
      net.set_marking(marking_before) if marking_before
    end

    # Quick simulation
    def simulate(net, steps: 100, strategy: :random)
      simulator = Simulation::Simulator.new(net)
      simulator.run(steps: steps, strategy: strategy)
    end

    # Quick export
    def export(net, format:, **options)
      Export.export(net, format: format, **options)
    end

    # Save net to file
    def save(net, filename, format: nil, **options)
      Export.save(net, filename, format: format, **options)
    end

    # Version info
    def version
      VERSION
    end

    # Gem info
    def info
      {
        name: "PetriFlow",
        version: VERSION,
        description: "Petri Net and Matrix Analysis for Event Sourcing",
        components: {
          core: "Basic Petri nets with places, transitions, arcs",
          colored: "Colored Petri nets with guards and arc expressions",
          matrix: "Matrix analysis for CRUD-Event mapping, causation, lineage",
          visualization: "GraphViz, Mermaid, and ASCII visualization",
          verification: "Reachability, boundedness, liveness, invariants",
          simulation: "Monte Carlo simulation and trace analysis",
          export: "PNML, CPN Tools XML, JSON, and YAML export formats"
        }
      }
    end
  end
end
