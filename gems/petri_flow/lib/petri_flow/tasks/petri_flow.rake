# frozen_string_literal: true

# PetriFlow Verification Tasks
#
# These tasks are automatically loaded in Rails apps that include the petri_flow gem.
# Workflows are discovered in app/workflows/*_workflow.rb
#
# Usage:
#   rake petri_flow:verify                    # Verify all workflows
#   rake petri_flow:verify:list               # List registered workflows
#   rake petri_flow:verify:workflow[Name]     # Verify specific workflow
#   rake petri_flow:generate:from_state_machine[Model,attr]  # Generate from state machine
#   rake petri_flow:generate:scan             # Scan for models with state machines
#
#   rake workflows:verify                     # Alias for petri_flow:verify
#   rake workflows:list                       # Alias for petri_flow:verify:list

namespace :petri_flow do
  desc "Verify all registered workflows and generate reports"
  task verify: :environment do
    ensure_workflows_loaded

    if PetriFlow::Registry.count.zero?
      puts "No workflows registered."
      puts "Create workflows in #{workflows_path}/*_workflow.rb"
      exit 1
    end

    runner = PetriFlow::VerificationRunner.new
    runner.run_all
  end

  namespace :verify do
    desc "List all registered workflows"
    task list: :environment do
      ensure_workflows_loaded

      puts "Registered PetriFlow Workflows:"
      puts "-" * 40

      if PetriFlow::Registry.count.zero?
        puts "  No workflows registered."
        puts "  Create workflows in #{workflows_path}/*_workflow.rb"
      else
        PetriFlow::Registry.all.each do |workflow_class|
          workflow = workflow_class.new
          places_count = workflow_class.defined_places&.size || 0
          terminal_count = workflow_class.defined_terminal_places&.size || 0
          puts "  - #{workflow_class.name}"
          puts "      Places: #{places_count}, Terminal: #{terminal_count}"
        end
      end
    end

    desc "Verify a specific workflow by class name"
    task :workflow, [:name] => :environment do |_t, args|
      ensure_workflows_loaded

      name = args[:name]
      unless name
        puts "Usage: rake petri_flow:verify:workflow[WorkflowClassName]"
        puts ""
        puts "Available workflows:"
        PetriFlow::Registry.names.each { |n| puts "  - #{n}" }
        exit 1
      end

      unless PetriFlow::Registry.exists?(name)
        puts "Error: Workflow '#{name}' not found."
        puts ""
        puts "Available workflows:"
        PetriFlow::Registry.names.each { |n| puts "  - #{n}" }
        exit 1
      end

      runner = PetriFlow::VerificationRunner.new
      runner.run_by_name(name)
    end
  end

  desc "Show PetriFlow configuration"
  task config: :environment do
    config = Rails.application.config.petri_flow

    puts "PetriFlow Configuration:"
    puts "-" * 40
    puts "  Workflows path: #{config.workflows_path}"
    puts "  Auto-discover:  #{config.auto_discover}"
    puts "  Full path:      #{workflows_path}"
    puts ""

    ensure_workflows_loaded
    puts "Registered workflows: #{PetriFlow::Registry.count}"
    PetriFlow::Registry.names.each { |n| puts "  - #{n}" }
  end

  namespace :generate do
    desc "Generate a PetriFlow workflow from a model's state machine"
    task :from_state_machine, [:model_class, :state_attr] => :environment do |_t, args|
      model_class_name = args[:model_class]
      state_attr = (args[:state_attr] || :state).to_sym

      unless model_class_name
        puts "Usage: rake petri_flow:generate:from_state_machine[ModelClass,state_attribute]"
        puts ""
        puts "Examples:"
        puts "  rake petri_flow:generate:from_state_machine[Order,state]"
        puts "  rake petri_flow:generate:from_state_machine[Spree::Order,state]"
        puts "  rake petri_flow:generate:from_state_machine[User,status]"
        puts ""
        puts "Supported state machine libraries:"
        PetriFlow::Generators::WorkflowGenerator.supported_libraries.each do |lib|
          puts "  - #{lib}"
        end
        exit 1
      end

      begin
        model_class = model_class_name.constantize
      rescue NameError
        puts "Error: Model class '#{model_class_name}' not found"
        exit 1
      end

      unless PetriFlow::Generators::WorkflowGenerator.supports?(model_class)
        puts "Error: #{model_class_name} does not have a supported state machine"
        puts ""
        puts "Supported libraries:"
        PetriFlow::Generators::WorkflowGenerator.supported_libraries.each do |lib|
          puts "  - #{lib}"
        end
        exit 1
      end

      generator = PetriFlow::Generators::WorkflowGenerator.new(model_class, state_attr)
      data = generator.extract

      puts "=" * 60
      puts "GENERATING WORKFLOW FROM STATE MACHINE"
      puts "=" * 60
      puts ""
      puts "Model: #{model_class_name}"
      puts "State attribute: #{state_attr}"
      puts "Library: #{data[:library]}"
      puts "States: #{data[:states].join(', ')}"
      puts "Initial: #{data[:initial_state]}"
      puts "Terminal: #{data[:terminal_states].join(', ')}"
      puts "Transitions: #{data[:transitions].count}"
      puts ""

      filepath = generator.generate!
      puts "Generated: #{filepath}"
      puts ""

      # Verify the generated workflow
      puts "Verifying workflow..."
      results = generator.verify

      puts "  Reachable states: #{results[:reachability][:total_reachable_states]}"
      puts "  Is safe (1-bounded): #{results[:boundedness][:is_safe]}"
      puts "  Deadlock-free: #{results[:liveness][:deadlock_free]}"
    end

    desc "List models with supported state machines"
    task scan: :environment do
      puts "Scanning for models with state machines..."
      puts ""

      found = []
      Rails.application.eager_load! if defined?(Rails)

      ActiveRecord::Base.descendants.each do |model|
        next if model.abstract_class?

        library = PetriFlow::Generators::WorkflowGenerator.detect_library(model)
        if library
          found << { model: model.name, library: library }
        end
      end

      if found.empty?
        puts "No models with supported state machines found."
        puts ""
        puts "Supported libraries:"
        PetriFlow::Generators::WorkflowGenerator.supported_libraries.each do |lib|
          puts "  - #{lib}"
        end
      else
        puts "Found #{found.count} model(s) with state machines:"
        puts ""
        puts "| Model | Library |"
        puts "|-------|---------|"
        found.each do |f|
          puts "| #{f[:model]} | #{f[:library]} |"
        end
        puts ""
        puts "Generate with:"
        puts "  rake petri_flow:generate:from_state_machine[ModelClass,state]"
      end
    end
  end

  # Helper methods

  def ensure_workflows_loaded
    path = workflows_path
    PetriFlow::Registry.discover_in(path) if Dir.exist?(path)
  end

  def workflows_path
    config = Rails.application.config.petri_flow
    Rails.root.join(config.workflows_path).to_s
  end
end

# Shorthand aliases
namespace :workflows do
  desc "Verify all workflows (alias for petri_flow:verify)"
  task verify: "petri_flow:verify"

  desc "List all workflows (alias for petri_flow:verify:list)"
  task list: "petri_flow:verify:list"

  desc "Generate workflow from state machine (alias)"
  task :from_state_machine, [:model_class, :state_attr] => "petri_flow:generate:from_state_machine"

  desc "Scan for models with state machines (alias)"
  task scan: "petri_flow:generate:scan"
end
