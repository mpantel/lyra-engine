# frozen_string_literal: true

module PetriFlow
  # Registry for storing and retrieving workflow classes.
  # Workflows are auto-registered when they inherit from PetriFlow::Workflow.
  #
  # @example Register a workflow manually
  #   PetriFlow::Registry.register(RefundRequestWorkflow)
  #
  # @example Get all workflows
  #   PetriFlow::Registry.all
  #
  # @example Discover workflows in a directory
  #   PetriFlow::Registry.discover_in("app/workflows")
  #
  class Registry
    class << self
      # Register a workflow class
      # @param workflow_class [Class] A class that inherits from PetriFlow::Workflow
      def register(workflow_class)
        workflows[workflow_class.name] = workflow_class
      end

      # Get a workflow class by name
      # @param name [String, Symbol] The workflow class name
      # @return [Class, nil] The workflow class or nil if not found
      def get(name)
        workflows[name.to_s]
      end

      # Get all registered workflow classes
      # @return [Array<Class>] All registered workflow classes
      def all
        workflows.values
      end

      # Get all workflow names
      # @return [Array<String>] All registered workflow class names
      def names
        workflows.keys
      end

      # Check if a workflow exists
      # @param name [String, Symbol] The workflow class name
      # @return [Boolean] True if workflow is registered
      def exists?(name)
        workflows.key?(name.to_s)
      end

      # Unregister a workflow
      # @param name [String, Symbol] The workflow class name to remove
      def unregister(name)
        workflows.delete(name.to_s)
      end

      # Clear all workflows (useful for testing)
      def clear
        @workflows = {}
      end

      # Count of registered workflows
      # @return [Integer] Number of registered workflows
      def count
        workflows.count
      end

      # Discover and load workflows from a directory
      # Loads all files matching *_workflow.rb pattern
      # @param directory [String] Path to the workflows directory
      def discover_in(directory)
        return unless directory && Dir.exist?(directory)

        Dir.glob(File.join(directory, "**", "*_workflow.rb")).sort.each do |file|
          require file
        end
      end

      private

      def workflows
        @workflows ||= {}
      end
    end
  end
end
