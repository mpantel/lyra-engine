# frozen_string_literal: true

require "fileutils"
require "time"

module PetriFlow
  # Runs verification on registered workflows and generates reports.
  # Reports are saved to reports/petri_flow_<timestamp>/ directory.
  #
  # @example Run verification for all workflows
  #   runner = PetriFlow::VerificationRunner.new
  #   runner.run_all
  #
  # @example Run for a specific workflow
  #   runner.run_workflow(RefundRequestWorkflow)
  #
  # @example Run by workflow name
  #   runner.run_by_name("RefundRequestWorkflow")
  #
  class VerificationRunner
    attr_reader :reports_dir, :results

    # @param base_dir [String] Base directory for reports (default: Rails.root or current dir)
    # @param output [IO] Output stream for console messages (default: $stdout)
    def initialize(base_dir: nil, output: $stdout)
      @base_dir = base_dir || default_base_dir
      @timestamp = Time.now.strftime("%Y%m%d_%H%M%S")
      @reports_dir = File.join(@base_dir, "reports", "petri_flow_#{@timestamp}")
      @output = output
      @results = {}
    end

    # Run verification for all registered workflows
    # @return [Hash] Results for all workflows
    def run_all
      ensure_reports_dir
      print_header

      Registry.all.each do |workflow_class|
        run_workflow(workflow_class)
      end

      generate_summary_report
      print_footer

      @results
    end

    # Run verification for a specific workflow class
    # @param workflow_class [Class] The workflow class to verify
    # @return [Hash] Verification results
    def run_workflow(workflow_class)
      workflow = workflow_class.new
      workflow_id = workflow.workflow_id

      puts "\n" + "=" * 70
      puts " #{workflow_class.name.upcase}"
      puts "=" * 70

      results = workflow.verify!
      @results[workflow_id] = {
        class_name: workflow_class.name,
        workflow_name: workflow.workflow_name,
        verification: results,
        terminal_reachability: workflow.terminal_reachability.dup
      }

      export_workflow_diagrams(workflow)
      print_verification_summary(workflow)

      results
    end

    # Run verification for a workflow by name
    # @param name [String] The workflow class name
    # @return [Hash] Verification results
    # @raise [RuntimeError] If workflow not found
    def run_by_name(name)
      workflow_class = Registry.get(name)
      raise "Workflow '#{name}' not found in registry" unless workflow_class

      ensure_reports_dir
      print_header
      run_workflow(workflow_class)
      generate_summary_report
      print_footer

      @results
    end

    private

    def default_base_dir
      if defined?(Rails) && Rails.respond_to?(:root) && Rails.root
        Rails.root.to_s
      else
        Dir.pwd
      end
    end

    def ensure_reports_dir
      FileUtils.mkdir_p(@reports_dir)
    end

    def puts(message = "")
      @output.puts(message)
    end

    def print_header
      puts
      puts "╔═══════════════════════════════════════════════════════════════════════╗"
      puts "║                                                                       ║"
      puts "║   PETRIFLOW VERIFICATION                                              ║"
      puts "║   Formal Verification of Business Workflows                           ║"
      puts "║                                                                       ║"
      puts "╚═══════════════════════════════════════════════════════════════════════╝"
      puts
      puts "  PetriFlow Version: #{PetriFlow::VERSION}"
      puts "  Timestamp: #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}"
      puts "  Workflows: #{Registry.count}"
      puts "  Output: #{@reports_dir}"
      puts
    end

    def print_footer
      puts
      puts "╔═══════════════════════════════════════════════════════════════════════╗"
      puts "║  VERIFICATION COMPLETE                                                ║"
      puts "║                                                                       ║"
      puts "║  Reports saved to: #{@reports_dir.split('/').last.ljust(49)}║"
      puts "╚═══════════════════════════════════════════════════════════════════════╝"
      puts
    end

    def print_verification_summary(workflow)
      results = workflow.verification_results
      reachability = results[:reachability]
      boundedness = results[:boundedness]
      liveness = results[:liveness]

      puts "\n┌─ Verification Results ──────────────────────────────────────────────┐"
      puts "│ Reachable states: #{reachability[:total_reachable_states].to_s.ljust(50)}│"
      puts "│ Terminal states: #{reachability[:terminal_states].to_s.ljust(51)}│"
      puts "│ Is safe (1-bounded): #{boundedness[:is_safe].to_s.ljust(47)}│"
      puts "│ Deadlock-free: #{liveness[:deadlock_free].to_s.ljust(53)}│"
      puts "└─────────────────────────────────────────────────────────────────────┘"

      puts "\n  Terminal State Reachability:"
      workflow.terminal_reachability.each do |state, reachable|
        status = reachable ? "✓ REACHABLE" : "✗ UNREACHABLE"
        puts "    #{state.to_s.ljust(20)} #{status}"
      end
    end

    def export_workflow_diagrams(workflow)
      workflow_id = workflow.workflow_id
      ensure_reports_dir

      # Mermaid
      mermaid_file = File.join(@reports_dir, "#{workflow_id}_petri.mmd")
      File.write(mermaid_file, workflow.to_mermaid)

      # DOT
      dot_file = File.join(@reports_dir, "#{workflow_id}_petri.dot")
      File.write(dot_file, workflow.to_dot)

      # Generate images if GraphViz available
      generate_graphviz_images(dot_file, workflow_id) if graphviz_available?
    end

    def graphviz_available?
      system("which dot > /dev/null 2>&1")
    end

    def generate_graphviz_images(dot_file, workflow_id)
      %w[png pdf svg].each do |format|
        output_file = File.join(@reports_dir, "#{workflow_id}_petri.#{format}")
        system("dot -T#{format} #{dot_file} -o #{output_file} 2>/dev/null")
      end
    end

    def generate_summary_report
      # Generate individual report for each workflow
      @results.each do |workflow_id, data|
        generate_workflow_report(workflow_id, data)
      end

      # Generate summary report
      report_file = File.join(@reports_dir, "verification_report.md")
      content = build_summary_report
      File.write(report_file, content)
    end

    def generate_workflow_report(workflow_id, data)
      report_file = File.join(@reports_dir, "#{workflow_id}.md")
      content = build_workflow_report(workflow_id, data)
      File.write(report_file, content)
    end

    def build_workflow_report(workflow_id, data)
      verification = data[:verification]
      all_reachable = data[:terminal_reachability].values.all?
      status_icon = all_reachable ? "✓" : "✗"

      lines = []
      lines << "# #{data[:workflow_name]}"
      lines << ""
      lines << "**Generated:** #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}"
      lines << "**PetriFlow Version:** #{PetriFlow::VERSION}"
      lines << "**Status:** #{status_icon} #{all_reachable ? 'All terminal states reachable' : 'UNREACHABLE STATES DETECTED'}"
      lines << ""
      lines << "---"
      lines << ""
      lines << "## Verification Results"
      lines << ""
      lines << "| Property | Value |"
      lines << "|----------|-------|"
      lines << "| Reachable states | #{verification[:reachability][:total_reachable_states]} |"
      lines << "| Terminal states | #{verification[:reachability][:terminal_states]} |"
      lines << "| Is bounded | #{verification[:boundedness][:is_bounded]} |"
      lines << "| Is safe (1-bounded) | #{verification[:boundedness][:is_safe]} |"
      lines << "| Deadlock-free | #{verification[:liveness][:deadlock_free]} |"
      lines << ""
      lines << "---"
      lines << ""
      lines << "## Terminal State Reachability"
      lines << ""

      data[:terminal_reachability].each do |state, reachable|
        icon = reachable ? "✓" : "✗"
        status = reachable ? "Reachable" : "**UNREACHABLE**"
        lines << "| #{icon} | **#{state}** | #{status} |"
      end

      lines << ""

      unless all_reachable
        lines << ""
        lines << "> **WARNING:** Some terminal states are unreachable from the initial state."
        lines << "> This indicates a workflow design issue that should be investigated."
        lines << ""
      end

      lines << "---"
      lines << ""
      lines << "## Petri Net Diagram"
      lines << ""
      lines << "![#{data[:workflow_name]} Petri Net](#{workflow_id}_petri.png)"
      lines << ""
      lines << "---"
      lines << ""
      lines << "*Generated by PetriFlow verification tool*"
      lines.join("\n")
    end

    def build_summary_report
      lines = []
      lines << "# PetriFlow Verification Summary"
      lines << ""
      lines << "**Generated:** #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}"
      lines << "**PetriFlow Version:** #{PetriFlow::VERSION}"
      lines << "**Workflows Verified:** #{@results.count}"
      lines << ""
      lines << "---"
      lines << ""
      lines << "## Results"
      lines << ""
      lines << "| Workflow | States | Safe | Terminals Reachable | Report |"
      lines << "|----------|--------|------|---------------------|--------|"

      @results.each do |workflow_id, data|
        reachability = data[:verification][:reachability]
        boundedness = data[:verification][:boundedness]
        all_reachable = data[:terminal_reachability].values.all?
        status_icon = all_reachable ? "✓" : "✗"

        lines << "| #{data[:workflow_name]} | #{reachability[:total_reachable_states]} | #{boundedness[:is_safe]} | #{status_icon} #{all_reachable} | [View](#{workflow_id}.md) |"
      end

      lines << ""
      lines << "---"
      lines << ""
      lines << "*Generated by PetriFlow verification tool*"
      lines.join("\n")
    end
  end
end
