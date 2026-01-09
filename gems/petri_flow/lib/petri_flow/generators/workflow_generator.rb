# frozen_string_literal: true

module PetriFlow
  module Generators
    # Generates PetriFlow workflows from ActiveRecord state machines.
    #
    # Supports multiple state machine libraries:
    # - state_machines-activerecord (Solidus, many Rails apps)
    # - AASM (acts_as_state_machine)
    #
    # @example Generate a workflow from a model
    #   generator = PetriFlow::Generators::WorkflowGenerator.new(Order, :state)
    #   generator.generate!
    #   # => Creates app/workflows/order_workflow.rb
    #
    # @example Get workflow data without writing file
    #   data = generator.extract
    #   # => { states: [...], transitions: [...], ... }
    #
    class WorkflowGenerator
      ADAPTERS = [
        Adapters::StateMachinesAdapter,
        Adapters::AasmAdapter
      ].freeze

      attr_reader :model_class, :state_attribute, :adapter

      # @param model_class [Class] ActiveRecord model class with state machine
      # @param state_attribute [Symbol] The state attribute name (default: :state)
      # @raise [ArgumentError] if no supported state machine is found
      def initialize(model_class, state_attribute = :state)
        @model_class = model_class
        @state_attribute = state_attribute.to_sym
        @adapter = find_adapter
      end

      # Extract state machine data
      # @return [Hash] extracted state machine definition
      def extract
        adapter.extract
      end

      # Generate workflow class code
      # @return [String] Ruby code for the workflow class
      def generate_code
        data = extract
        generate_workflow_code(data)
      end

      # Generate workflow file
      # @param output_dir [String, Pathname] directory to write the file
      # @return [String] path to generated file
      def generate!(output_dir: nil)
        output_dir ||= default_output_dir
        FileUtils.mkdir_p(output_dir)

        filepath = File.join(output_dir, filename)
        File.write(filepath, generate_code)
        filepath
      end

      # Build a workflow class dynamically (without writing file)
      # @return [Class] the generated workflow class
      def build_workflow_class
        data = extract
        class_name = workflow_class_name

        Class.new(PetriFlow::Workflow) do
          workflow_name data[:workflow_name] || "#{class_name} Workflow"
          places(*data[:states])
          initial_place data[:initial_state]
          terminal_places(*data[:terminal_states])

          data[:transitions].each do |t|
            transition t[:name], from: t[:from], to: t[:to]
          end
        end
      end

      # Verify the generated workflow
      # @return [Hash] verification results
      def verify
        workflow = build_workflow_class.new
        workflow.verify!
      end

      # Class name for the generated workflow
      # @return [String]
      def workflow_class_name
        "#{model_class.name.demodulize}Workflow"
      end

      # Filename for the generated workflow
      # @return [String]
      def filename
        "#{model_class.name.demodulize.underscore}_workflow.rb"
      end

      # List of supported state machine libraries
      # @return [Array<String>]
      def self.supported_libraries
        ADAPTERS.map(&:library_name)
      end

      # Check if a model has a supported state machine
      # @param model_class [Class]
      # @return [Boolean]
      def self.supports?(model_class)
        ADAPTERS.any? { |adapter| adapter.supports?(model_class) }
      end

      # Detect which state machine library a model uses
      # @param model_class [Class]
      # @return [String, nil] library name or nil
      def self.detect_library(model_class)
        adapter = ADAPTERS.find { |a| a.supports?(model_class) }
        adapter&.library_name
      end

      private

      def find_adapter
        adapter_class = ADAPTERS.find { |a| a.supports?(model_class) }

        unless adapter_class
          raise ArgumentError,
                "#{model_class} does not have a supported state machine. " \
                "Supported: #{self.class.supported_libraries.join(', ')}"
        end

        adapter_class.new(model_class, state_attribute)
      end

      def default_output_dir
        if defined?(Rails)
          Rails.root.join("app", "workflows")
        else
          File.expand_path("app/workflows", Dir.pwd)
        end
      end

      def generate_workflow_code(data)
        class_name = workflow_class_name
        workflow_name = "#{model_class.name.demodulize} State Workflow"

        lines = []
        lines << "# frozen_string_literal: true"
        lines << "# Auto-generated from #{model_class.name} state machine (#{data[:library]})"
        lines << "# Generated at: #{Time.now.utc.strftime('%Y-%m-%d %H:%M:%S UTC')}"
        lines << ""
        lines << "# #{workflow_name}"
        lines << "# Models the state transitions for #{model_class.name}"
        lines << "class #{class_name} < PetriFlow::Workflow"
        lines << "  workflow_name #{workflow_name.inspect}"
        lines << ""
        lines << "  # States from #{model_class.name}"
        lines << "  places #{data[:states].map(&:inspect).join(', ')}"
        lines << "  initial_place #{data[:initial_state].inspect}"
        lines << "  terminal_places #{data[:terminal_states].map(&:inspect).join(', ')}"
        lines << ""
        lines << "  # Transitions from state machine events"

        data[:transitions].each do |t|
          lines << "  transition #{t[:name].inspect},"
          lines << "             from: #{t[:from].inspect},"
          lines << "             to: #{t[:to].inspect},"
          lines << "             trigger: #{t[:event].to_s.inspect}"
          lines << ""
        end

        lines << "end"
        lines.join("\n")
      end
    end
  end
end
