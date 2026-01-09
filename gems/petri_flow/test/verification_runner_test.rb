# frozen_string_literal: true

require "test_helper"
require "stringio"
require "tmpdir"

module PetriFlow
  class VerificationRunnerTest < Minitest::Test
    def setup
      Registry.clear
      @tmpdir = Dir.mktmpdir("petri_flow_test")
      @output = StringIO.new
    end

    def teardown
      Registry.clear
      FileUtils.rm_rf(@tmpdir) if @tmpdir && Dir.exist?(@tmpdir)
    end

    # ===========================================
    # Setup Helpers
    # ===========================================

    def create_test_workflow
      klass = Class.new(Workflow) do
        workflow_name "Test Verification Workflow"
        places :start, :middle, :end
        initial_place :start
        terminal_places :end

        transition :step1, from: :start, to: :middle
        transition :step2, from: :middle, to: :end
      end
      Object.const_set(:TestVerificationWorkflow, klass)
      Registry.clear
      Registry.register(klass)
      klass
    end

    def create_flawed_workflow
      klass = Class.new(Workflow) do
        workflow_name "Flawed Verification Workflow"
        places :a, :b, :c, :orphan
        initial_place :a
        terminal_places :c, :orphan

        transition :go1, from: :a, to: :b
        transition :go2, from: :b, to: :c
        # No transition to :orphan - it's unreachable
      end
      Object.const_set(:FlawedVerificationWorkflow, klass)
      Registry.register(klass)
      klass
    end

    # ===========================================
    # Initialization Tests
    # ===========================================

    def test_initialization_creates_timestamped_reports_dir
      runner = VerificationRunner.new(base_dir: @tmpdir, output: @output)

      assert_match %r{reports/petri_flow_\d{8}_\d{6}$}, runner.reports_dir
    end

    def test_results_starts_empty
      runner = VerificationRunner.new(base_dir: @tmpdir, output: @output)

      assert_empty runner.results
    end

    # ===========================================
    # run_workflow Tests
    # ===========================================

    def test_run_workflow_returns_verification_results
      workflow_class = create_test_workflow
      runner = VerificationRunner.new(base_dir: @tmpdir, output: @output)

      results = runner.run_workflow(workflow_class)

      assert results.key?(:reachability)
      assert results.key?(:boundedness)
      assert results.key?(:liveness)
    ensure
      Object.send(:remove_const, :TestVerificationWorkflow) if defined?(TestVerificationWorkflow)
    end

    def test_run_workflow_stores_results
      workflow_class = create_test_workflow
      runner = VerificationRunner.new(base_dir: @tmpdir, output: @output)

      runner.run_workflow(workflow_class)

      assert_equal 1, runner.results.count
      workflow_id = "test_verification_workflow"
      assert runner.results.key?(workflow_id)
      assert_equal "TestVerificationWorkflow", runner.results[workflow_id][:class_name]
    ensure
      Object.send(:remove_const, :TestVerificationWorkflow) if defined?(TestVerificationWorkflow)
    end

    def test_run_workflow_exports_diagrams
      workflow_class = create_test_workflow
      runner = VerificationRunner.new(base_dir: @tmpdir, output: @output)
      FileUtils.mkdir_p(runner.reports_dir)

      runner.run_workflow(workflow_class)

      assert File.exist?(File.join(runner.reports_dir, "test_verification_workflow_petri.mmd"))
      assert File.exist?(File.join(runner.reports_dir, "test_verification_workflow_petri.dot"))
    ensure
      Object.send(:remove_const, :TestVerificationWorkflow) if defined?(TestVerificationWorkflow)
    end

    def test_run_workflow_prints_to_output
      workflow_class = create_test_workflow
      runner = VerificationRunner.new(base_dir: @tmpdir, output: @output)

      runner.run_workflow(workflow_class)

      output_text = @output.string
      assert_includes output_text, "TESTVERIFICATIONWORKFLOW"
      assert_includes output_text, "Reachable states:"
    ensure
      Object.send(:remove_const, :TestVerificationWorkflow) if defined?(TestVerificationWorkflow)
    end

    # ===========================================
    # run_all Tests
    # ===========================================

    def test_run_all_processes_all_registered_workflows
      klass1 = create_test_workflow
      klass2 = create_flawed_workflow
      runner = VerificationRunner.new(base_dir: @tmpdir, output: @output)

      runner.run_all

      assert_equal 2, runner.results.count
    ensure
      Object.send(:remove_const, :TestVerificationWorkflow) if defined?(TestVerificationWorkflow)
      Object.send(:remove_const, :FlawedVerificationWorkflow) if defined?(FlawedVerificationWorkflow)
    end

    def test_run_all_generates_summary_report
      create_test_workflow
      runner = VerificationRunner.new(base_dir: @tmpdir, output: @output)

      runner.run_all

      summary_file = File.join(runner.reports_dir, "verification_report.md")
      assert File.exist?(summary_file)

      content = File.read(summary_file)
      assert_includes content, "PetriFlow Verification Summary"
      assert_includes content, "Test Verification Workflow"
    ensure
      Object.send(:remove_const, :TestVerificationWorkflow) if defined?(TestVerificationWorkflow)
    end

    def test_run_all_generates_individual_workflow_reports
      create_test_workflow
      runner = VerificationRunner.new(base_dir: @tmpdir, output: @output)

      runner.run_all

      report_file = File.join(runner.reports_dir, "test_verification_workflow.md")
      assert File.exist?(report_file)

      content = File.read(report_file)
      assert_includes content, "Test Verification Workflow"
      assert_includes content, "Verification Results"
    ensure
      Object.send(:remove_const, :TestVerificationWorkflow) if defined?(TestVerificationWorkflow)
    end

    def test_run_all_prints_header_and_footer
      create_test_workflow
      runner = VerificationRunner.new(base_dir: @tmpdir, output: @output)

      runner.run_all

      output_text = @output.string
      assert_includes output_text, "PETRIFLOW VERIFICATION"
      assert_includes output_text, "VERIFICATION COMPLETE"
    ensure
      Object.send(:remove_const, :TestVerificationWorkflow) if defined?(TestVerificationWorkflow)
    end

    def test_run_all_returns_results
      create_test_workflow
      runner = VerificationRunner.new(base_dir: @tmpdir, output: @output)

      results = runner.run_all

      assert_kind_of Hash, results
      assert_equal 1, results.count
    ensure
      Object.send(:remove_const, :TestVerificationWorkflow) if defined?(TestVerificationWorkflow)
    end

    # ===========================================
    # run_by_name Tests
    # ===========================================

    def test_run_by_name_finds_and_verifies_workflow
      create_test_workflow
      runner = VerificationRunner.new(base_dir: @tmpdir, output: @output)

      results = runner.run_by_name("TestVerificationWorkflow")

      assert_equal 1, results.count
      assert results.key?("test_verification_workflow")
    ensure
      Object.send(:remove_const, :TestVerificationWorkflow) if defined?(TestVerificationWorkflow)
    end

    def test_run_by_name_raises_for_unknown_workflow
      runner = VerificationRunner.new(base_dir: @tmpdir, output: @output)

      assert_raises(RuntimeError) do
        runner.run_by_name("NonExistentWorkflow")
      end
    end

    def test_run_by_name_generates_reports
      create_test_workflow
      runner = VerificationRunner.new(base_dir: @tmpdir, output: @output)

      runner.run_by_name("TestVerificationWorkflow")

      assert File.exist?(File.join(runner.reports_dir, "verification_report.md"))
      assert File.exist?(File.join(runner.reports_dir, "test_verification_workflow.md"))
    ensure
      Object.send(:remove_const, :TestVerificationWorkflow) if defined?(TestVerificationWorkflow)
    end

    # ===========================================
    # Report Content Tests
    # ===========================================

    def test_report_marks_unreachable_states
      create_flawed_workflow
      runner = VerificationRunner.new(base_dir: @tmpdir, output: @output)

      runner.run_all

      report_file = File.join(runner.reports_dir, "flawed_verification_workflow.md")
      content = File.read(report_file)

      assert_includes content, "UNREACHABLE"
      assert_includes content, "orphan"
      assert_includes content, "WARNING"
    ensure
      Object.send(:remove_const, :FlawedVerificationWorkflow) if defined?(FlawedVerificationWorkflow)
    end

    def test_report_marks_reachable_states
      create_test_workflow
      runner = VerificationRunner.new(base_dir: @tmpdir, output: @output)

      runner.run_all

      report_file = File.join(runner.reports_dir, "test_verification_workflow.md")
      content = File.read(report_file)

      assert_includes content, "All terminal states reachable"
      refute_includes content, "UNREACHABLE"
    ensure
      Object.send(:remove_const, :TestVerificationWorkflow) if defined?(TestVerificationWorkflow)
    end

    def test_summary_report_includes_all_workflows
      create_test_workflow
      create_flawed_workflow
      runner = VerificationRunner.new(base_dir: @tmpdir, output: @output)

      runner.run_all

      summary_file = File.join(runner.reports_dir, "verification_report.md")
      content = File.read(summary_file)

      assert_includes content, "Test Verification Workflow"
      assert_includes content, "Flawed Verification Workflow"
      assert_includes content, "Workflows Verified:** 2"
    ensure
      Object.send(:remove_const, :TestVerificationWorkflow) if defined?(TestVerificationWorkflow)
      Object.send(:remove_const, :FlawedVerificationWorkflow) if defined?(FlawedVerificationWorkflow)
    end

    # ===========================================
    # Edge Case Tests
    # ===========================================

    def test_run_all_with_no_workflows
      runner = VerificationRunner.new(base_dir: @tmpdir, output: @output)

      results = runner.run_all

      assert_empty results
      assert File.exist?(File.join(runner.reports_dir, "verification_report.md"))
    end

    def test_creates_reports_directory
      runner = VerificationRunner.new(base_dir: @tmpdir, output: @output)

      refute Dir.exist?(runner.reports_dir)

      create_test_workflow
      runner.run_all

      assert Dir.exist?(runner.reports_dir)
    ensure
      Object.send(:remove_const, :TestVerificationWorkflow) if defined?(TestVerificationWorkflow)
    end
  end
end
