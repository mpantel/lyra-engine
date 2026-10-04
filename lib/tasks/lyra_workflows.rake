# frozen_string_literal: true

namespace :lyra do
  namespace :workflows do
    desc "Generate verification workflow models from Lyra implementation via metaprogramming"
    task generate: :environment do
      require "fileutils"

      unless Lyra.petri_flow_available?
        puts "Error: PetriFlow gem is required"
        puts "Add 'petri_flow' to your Gemfile and run 'bundle install'"
        exit 1
      end

      require "lyra/verification/workflow_generator"

      # Parse mode argument: MODE=monitor or MODE=all (default).
      # OUTPUT_DIR=path writes the workflow files there; REPORTS_DIR=path the reports.
      requested_mode = ENV["MODE"]&.to_sym
      if requested_mode && requested_mode != :all
        unless Lyra::Verification::WorkflowGenerator::AVAILABLE_MODES.include?(requested_mode)
          puts "Error: Invalid mode '#{requested_mode}'"
          puts "Available modes: #{Lyra::Verification::WorkflowGenerator::AVAILABLE_MODES.join(', ')}, all"
          exit 1
        end
      end

      # Determine Lyra gem root using multiple strategies
      lyra_gem_root = Gem.loaded_specs['lyra']&.gem_dir
      lyra_gem_root ||= Lyra::Engine.root.to_s if defined?(Lyra::Engine)
      lyra_gem_root ||= begin
        # Find lyra.gemspec by traversing up from Rails.root
        dir = Rails.root
        while dir.to_s != "/"
          if File.exist?(File.join(dir, 'lyra.gemspec'))
            break dir.to_s
          end
          dir = dir.parent
        end
      end

      # Determine output directory
      # Both Lyra gem and applications use app/workflows with top-level constants
      # This is Zeitwerk-compatible: app/workflows/monitor_mode_workflow.rb -> MonitorModeWorkflow
      is_lyra_context = lyra_gem_root && (
        Rails.root.to_s.start_with?(lyra_gem_root) ||
        File.exist?(File.join(Rails.root, 'lyra.gemspec'))
      )

      if ENV["OUTPUT_DIR"].present?
        # Explicit destination (a scratch directory, say)
        workflows_dir = File.expand_path(ENV["OUTPUT_DIR"])
      elsif is_lyra_context && lyra_gem_root
        # Lyra gem context - use app/workflows in the gem root
        workflows_dir = File.join(lyra_gem_root, 'app', 'workflows')
      else
        # Normal application
        workflows_dir = Rails.root.join('app', 'workflows')
      end

      # Always use top-level constants for Zeitwerk compatibility
      @use_lyra_namespace = false

      reports_dir = Pathname.new(ENV["REPORTS_DIR"].presence || Rails.root.join('reports')).expand_path

      FileUtils.mkdir_p(workflows_dir)
      FileUtils.mkdir_p(reports_dir)

      puts "Analyzing Lyra implementation..."
      puts "Mode: #{requested_mode || 'all'}"
      puts "Workflows directory: #{workflows_dir}"
      puts "Reports directory: #{reports_dir}"
      puts ""

      generator = Lyra::Verification::WorkflowGenerator.new
      result = if requested_mode && requested_mode != :all
                 generator.generate!(mode: requested_mode)
               else
                 generator.generate!
               end

      # Output analysis results
      puts "=" * 60
      puts "LYRA IMPLEMENTATION ANALYSIS"
      puts "=" * 60
      puts ""

      analysis = result[:analysis]

      # Modes
      puts "MODES:"
      puts "  Current mode: #{analysis[:current_mode] || 'not set'}"
      puts "  Available modes: #{analysis[:modes].join(', ')}"
      puts ""

      # Callbacks
      puts "CALLBACKS DETECTED:"
      hooks = analysis[:callback_hooks]
      if hooks[:after].any?
        puts "  After callbacks:"
        hooks[:after].each { |h| puts "    - after_#{h[:type]} :#{h[:method]}" }
      end
      if hooks[:before].any?
        puts "  Before callbacks:"
        hooks[:before].each { |h| puts "    - before_#{h[:type]} :#{h[:method]}" }
      end
      puts ""

      # Monitored models
      puts "MONITORED MODELS: #{analysis[:models].count}"
      analysis[:models].each do |model|
        puts "  - #{model[:name]}"
        puts "    Event prefix: #{model[:event_prefix]}" if model[:event_prefix]
        if model[:callbacks]&.any?
          puts "    Callbacks:"
          model[:callbacks].each { |k, v| puts "      #{k}: #{v.join(', ')}" }
        end
      end
      puts ""

      # Event types
      puts "EVENT TYPES:"
      analysis[:event_types].each { |e| puts "  - #{e[:name]}" }
      puts ""

      # Generated workflows
      puts "=" * 60
      puts "GENERATED WORKFLOWS"
      puts "=" * 60
      puts ""

      lifecycle = result[:lifecycle_workflow]
      if lifecycle
        puts "LIFECYCLE WORKFLOW: #{lifecycle[:name]}"
        puts "  Places: #{lifecycle[:places].join(' -> ')}"
        puts "  Initial: #{lifecycle[:initial_place]}"
        puts "  Terminal: #{lifecycle[:terminal_places].join(', ')}"
        puts "  Transitions:"
        lifecycle[:transitions].each do |t|
          puts "    #{t[:from]} --[#{t[:name]}]--> #{t[:to]}"
          puts "      trigger: #{t[:trigger]}"
        end
        puts ""
      end

      # Single mode workflow (when specific mode requested)
      if result[:mode_workflow]
        print_workflow(result[:mode_workflow])
      end

      # Multiple mode workflows (when all modes requested)
      if result[:mode_workflows]
        result[:mode_workflows].each do |_mode, workflow|
          puts "-" * 40
          print_workflow(workflow)
        end
      end

      # Save workflow files
      generated_files = []

      # Generate lifecycle workflow file
      if result[:lifecycle_workflow]
        lifecycle_file = File.join(workflows_dir, "lifecycle_workflow.rb")
        File.write(lifecycle_file, generate_workflow_file(result[:lifecycle_workflow], "LifecycleWorkflow", use_lyra_namespace: @use_lyra_namespace))
        generated_files << lifecycle_file
        puts "Generated: #{lifecycle_file}"
      end

      # Generate individual mode workflow files
      # One mode (MODE=x) or all of them. Either way a mode's file and class are
      # named alike (es_sync_mode_workflow.rb defines EsSyncModeWorkflow), the
      # constant Zeitwerk expects from the file's path.
      mode_workflows = if result[:mode_workflow]
                         { requested_mode => result[:mode_workflow] }
                       else
                         result[:mode_workflows] || {}
                       end
      mode_workflows.each do |mode, workflow|
        next unless workflow

        generator_class = Lyra::Verification::WorkflowGenerator
        mode_file = File.join(workflows_dir, "#{generator_class.workflow_file_basename(mode)}.rb")
        class_name = generator_class.workflow_class_name(mode)
        File.write(mode_file, generate_workflow_file(workflow, class_name, use_lyra_namespace: @use_lyra_namespace))
        generated_files << mode_file
        puts "Generated: #{mode_file}"
      end

      # Generate Markdown report
      timestamp = Time.now.strftime("%Y%m%d_%H%M%S")
      md_file = reports_dir.join("workflow_analysis_#{timestamp}.md")
      File.write(md_file, generate_markdown_report(result))
      puts "Generated analysis report: #{md_file}"

      # Also generate a "latest" report
      latest_md = reports_dir.join("workflow_analysis_latest.md")
      File.write(latest_md, generate_markdown_report(result))
      puts "Generated latest report: #{latest_md}"

      puts ""
      puts "Generated #{generated_files.count} workflow files in #{workflows_dir}"
    end

    desc "Verify generated workflows with PetriFlow"
    task verify: :environment do
      unless Lyra.petri_flow_available?
        puts "Error: PetriFlow gem is required"
        exit 1
      end

      require "lyra/verification/workflow_generator"

      generator = Lyra::Verification::WorkflowGenerator.new
      result = generator.generate!

      puts "=" * 60
      puts "PETRIFLOW VERIFICATION"
      puts "=" * 60
      puts ""

      if result[:mode_workflows]
        result[:mode_workflows].each do |mode, wf_data|
          puts "Verifying #{mode} mode workflow..."

          # Create a PetriFlow workflow from the data
          workflow_class = Class.new(PetriFlow::Workflow) do
            workflow_name wf_data[:name]
            places(*wf_data[:places])
            initial_place wf_data[:initial_place]
            terminal_places(*wf_data[:terminal_places])

            wf_data[:transitions].each do |t|
              transition t[:name], from: t[:from], to: t[:to]
            end
          end

          workflow = workflow_class.new
          results = workflow.verify!

          reachability = results[:reachability]
          boundedness = results[:boundedness]
          liveness = results[:liveness]

          puts "  Reachable states: #{reachability[:total_reachable_states]}"
          puts "  Terminal states: #{reachability[:terminal_states]}"
          puts "  Is safe (1-bounded): #{boundedness[:is_safe]}"
          puts "  Is bounded: #{boundedness[:is_bounded]}"
          puts "  Max tokens: #{boundedness[:max_tokens]}"
          puts "  Terminates properly (deadlock-free except at terminal places): #{liveness[:terminates_properly]}"
          puts "  Deadlock-free (raw, counts the terminal marking): #{liveness[:deadlock_free]}"
          puts "  Liveness score: #{liveness[:liveness_score]}"
          puts ""
        end
      else
        puts "No workflows generated"
      end
    end

    # Helper methods
    def print_workflow(workflow)
      return unless workflow

      puts "MODE WORKFLOW: #{workflow[:name]}"
      puts "  #{workflow[:description]}" if workflow[:description]
      puts "  Places: #{workflow[:places].join(' -> ')}"
      puts "  Initial: #{workflow[:initial_place]}"
      puts "  Terminal: #{workflow[:terminal_places].join(', ')}"
      puts "  Transitions:"
      workflow[:transitions].each do |t|
        puts "    #{t[:from]} --[#{t[:name]}]--> #{t[:to]}"
        puts "      trigger: #{t[:trigger]}"
      end
      puts ""
    end

    def generate_workflow_file(workflow, class_name, use_lyra_namespace: true)
      lines = []
      lines << "# frozen_string_literal: true"
      lines << "# Auto-generated by Lyra::Verification::WorkflowGenerator"
      lines << "# Generated at: #{Time.current}"
      lines << ""

      if use_lyra_namespace
        # Lyra gem context - nested namespace
        lines << "module Lyra"
        lines << "  module Verification"
        lines << "    module Generated"
        lines << ""
        lines << generate_workflow_class(workflow, class_name, indent: 6)
        lines << ""
        lines << "    end"
        lines << "  end"
        lines << "end"
      else
        # Application context - top-level class for Zeitwerk compatibility
        lines << generate_workflow_class(workflow, class_name, indent: 0)
      end

      lines.join("\n")
    end

    def generate_workflow_class(workflow, class_name, indent: 6)
      pad = " " * indent
      lines = []
      lines << "#{pad}# #{workflow[:name]}"
      lines << "#{pad}# #{workflow[:description]}" if workflow[:description]
      lines << "#{pad}class #{class_name} < PetriFlow::Workflow"
      lines << "#{pad}  workflow_name #{workflow[:name].inspect}"
      lines << ""
      lines << "#{pad}  places #{workflow[:places].map(&:inspect).join(', ')}"
      lines << "#{pad}  initial_place #{workflow[:initial_place].inspect}"
      lines << "#{pad}  terminal_places #{workflow[:terminal_places].map(&:inspect).join(', ')}"
      lines << ""
      workflow[:transitions].each do |t|
        lines << "#{pad}  transition #{t[:name].inspect},"
        lines << "#{pad}             from: #{t[:from].inspect},"
        lines << "#{pad}             to: #{t[:to].inspect},"
        lines << "#{pad}             trigger: #{t[:trigger].inspect}"
        lines << ""
      end
      lines << "#{pad}end"
      lines.join("\n")
    end

    def generate_markdown_report(result)
      analysis = result[:analysis]
      lifecycle = result[:lifecycle_workflow]

      md = []
      md << "# Lyra Verification Workflow Analysis"
      md << ""
      md << "**Generated:** #{Time.current}"
      md << "**Method:** Metaprogramming introspection of Lyra implementation"
      md << ""

      md << "## Implementation Analysis"
      md << ""

      md << "### Lyra Modes"
      md << ""
      md << "| Mode | Available |"
      md << "|------|-----------|"
      analysis[:modes].each do |mode|
        md << "| #{mode} | Yes |"
      end
      md << ""
      md << "**Current mode:** `#{analysis[:current_mode] || 'not configured'}`"
      md << ""

      md << "### Detected Callbacks"
      md << ""
      hooks = analysis[:callback_hooks]
      if hooks[:after].any? || hooks[:before].any?
        md << "| Timing | Type | Method |"
        md << "|--------|------|--------|"
        hooks[:before].each { |h| md << "| before | #{h[:type]} | `#{h[:method]}` |" }
        hooks[:after].each { |h| md << "| after | #{h[:type]} | `#{h[:method]}` |" }
      else
        md << "*No callbacks detected in source*"
      end
      md << ""

      md << "### Monitored Models"
      md << ""
      if analysis[:models].any?
        analysis[:models].each do |model|
          md << "#### #{model[:name]}"
          md << ""
          md << "- **Table:** `#{model[:table_name]}`" if model[:table_name]
          md << "- **Event prefix:** `#{model[:event_prefix]}`" if model[:event_prefix]
          md << ""
        end
      else
        md << "*No models currently monitored*"
      end
      md << ""

      if lifecycle
        md << generate_workflow_markdown(lifecycle, "Lifecycle")
      end

      # Single mode workflow
      if result[:mode_workflow]
        md << generate_workflow_markdown(result[:mode_workflow], result[:mode_workflow][:name])
      end

      # Multiple mode workflows
      if result[:mode_workflows]
        md << "## Mode-Specific Workflows"
        md << ""
        result[:mode_workflows].each do |_mode, workflow|
          md << generate_workflow_markdown(workflow, workflow[:name])
        end
      end

      md << "---"
      md << "*Generated by Lyra::Verification::WorkflowGenerator via metaprogramming*"

      md.join("\n")
    end

    def generate_workflow_markdown(workflow, title)
      md = []
      md << "## #{title}"
      md << ""
      md << "**Name:** #{workflow[:name]}"
      md << ""
      md << "**Description:** #{workflow[:description]}" if workflow[:description]
      md << ""
      md << "### State Machine"
      md << ""
      md << "```"
      md << "Initial: [#{workflow[:initial_place]}]"
      md << "Terminal: [#{workflow[:terminal_places].join(', ')}]"
      md << ""
      md << "Places: #{workflow[:places].join(' -> ')}"
      md << "```"
      md << ""
      md << "### Transitions"
      md << ""
      md << "| From | Transition | To | Trigger |"
      md << "|------|------------|-----|---------|"
      workflow[:transitions].each do |t|
        md << "| #{t[:from]} | #{t[:name]} | #{t[:to]} | #{t[:trigger]} |"
      end
      md << ""

      # Generate Mermaid diagram
      md << "### Petri Net Diagram"
      md << ""
      md << "```mermaid"
      md << "flowchart TB"
      workflow[:places].each do |place|
        md << "  #{place}((\"#{place.to_s.gsub('_', ' ').split.map(&:capitalize).join(' ')}\"))"
      end
      workflow[:transitions].each do |t|
        md << "  t_#{t[:name]}[\"#{t[:name]}\"]"
        md << "  #{t[:from]} --> t_#{t[:name]}"
        md << "  t_#{t[:name]} --> #{t[:to]}"
      end
      md << "```"
      md << ""

      md.join("\n")
    end

  end

  # Aliases for convenience
  desc "Generate workflows (alias for lyra:workflows:generate)"
  task generate_workflows: "lyra:workflows:generate"
end
