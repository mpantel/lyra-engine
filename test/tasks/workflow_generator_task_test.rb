# frozen_string_literal: true

require "test_helper"
require "rake"
require "fileutils"

class WorkflowGeneratorTaskTest < Minitest::Test
  def setup
    # Load rake tasks
    @rake = Rake::Application.new
    Rake.application = @rake
    Rake.application.rake_require("lyra_workflows", [File.expand_path("../../lib/tasks", __dir__)])

    # Create temp directory for test outputs
    @temp_dir = File.join(Dir.tmpdir, "lyra_workflow_test_#{$$}")
    FileUtils.mkdir_p(@temp_dir)
    @original_rails_root = Rails.root if defined?(Rails)
  end

  def teardown
    FileUtils.rm_rf(@temp_dir) if @temp_dir && Dir.exist?(@temp_dir)
    Rake.application = nil
  end

  def test_generated_workflow_files_are_valid_ruby
    skip "Integration test requires full Rails environment" unless defined?(Rails) && Rails.application

    workflows_dir = Rails.root.join("app", "workflows")
    return unless Dir.exist?(workflows_dir)

    Dir.glob("#{workflows_dir}/*.rb").each do |file|
      # Check syntax is valid by parsing
      content = File.read(file)
      # Use begin/rescue instead of assert_nothing_raised (not in Minitest)
      begin
        RubyVM::InstructionSequence.compile(content)
      rescue SyntaxError => e
        flunk "#{File.basename(file)} should be valid Ruby: #{e.message}"
      end
    end
  end

  def test_generated_workflows_inherit_from_petriflow
    skip "Integration test requires full Rails environment" unless defined?(Rails) && Rails.application
    skip "PetriFlow not available" unless defined?(PetriFlow)

    workflows_dir = Rails.root.join("app", "workflows")
    return unless Dir.exist?(workflows_dir)

    Dir.glob("#{workflows_dir}/*_workflow.rb").each do |file|
      content = File.read(file)
      assert content.include?("< PetriFlow::Workflow"),
        "#{File.basename(file)} should inherit from PetriFlow::Workflow"
    end
  end

  def test_generated_workflows_have_required_dsl_elements
    skip "Integration test requires full Rails environment" unless defined?(Rails) && Rails.application

    workflows_dir = Rails.root.join("app", "workflows")
    return unless Dir.exist?(workflows_dir)

    Dir.glob("#{workflows_dir}/*_mode_workflow.rb").each do |file|
      content = File.read(file)
      filename = File.basename(file)

      # Check for required PetriFlow DSL elements
      assert content.include?("workflow_name"), "#{filename} should have workflow_name"
      assert content.include?("places"), "#{filename} should have places"
      assert content.include?("initial_place"), "#{filename} should have initial_place"
      assert content.include?("terminal_places"), "#{filename} should have terminal_places"
      assert content.include?("transition"), "#{filename} should have at least one transition"
    end
  end

  def test_workflow_class_names_match_filenames
    skip "Integration test requires full Rails environment" unless defined?(Rails) && Rails.application

    workflows_dir = Rails.root.join("app", "workflows")
    return unless Dir.exist?(workflows_dir)

    Dir.glob("#{workflows_dir}/*.rb").each do |file|
      content = File.read(file)
      filename = File.basename(file, ".rb")

      # Convert filename to expected class name (snake_case -> PascalCase)
      expected_class = filename.split("_").map(&:capitalize).join

      assert content.match?(/class\s+#{expected_class}\s*</),
        "#{filename}.rb should define class #{expected_class}"
    end
  end

  def test_workflows_can_be_instantiated
    skip "Integration test requires full Rails environment" unless defined?(Rails) && Rails.application
    skip "PetriFlow not available" unless defined?(PetriFlow)

    # Try to load and instantiate each workflow class
    workflow_classes = %w[
      MonitorModeWorkflow
      HijackModeWorkflow
      EsSyncModeWorkflow
      EsAsyncModeWorkflow
      LifecycleWorkflow
    ]

    workflow_classes.each do |class_name|
      next unless Object.const_defined?(class_name)

      klass = Object.const_get(class_name)
      workflow = klass.new
      assert workflow.is_a?(PetriFlow::Workflow), "#{class_name} should be a PetriFlow::Workflow"
    end
  end

  def test_workflows_can_be_verified
    skip "Integration test requires full Rails environment" unless defined?(Rails) && Rails.application
    skip "PetriFlow not available" unless defined?(PetriFlow)

    workflow_classes = %w[MonitorModeWorkflow HijackModeWorkflow]

    workflow_classes.each do |class_name|
      next unless Object.const_defined?(class_name)

      klass = Object.const_get(class_name)
      workflow = klass.new

      results = workflow.verify!

      assert results.key?(:reachability), "#{class_name} verification should include reachability"
      assert results.key?(:boundedness), "#{class_name} verification should include boundedness"
      assert results.key?(:liveness), "#{class_name} verification should include liveness"

      # All Lyra workflows should be safe (1-bounded)
      assert results[:boundedness][:is_safe], "#{class_name} should be safe (1-bounded)"
    end
  end

  # The generator names each mode's file and class alike, the way Zeitwerk
  # maps one to the other. MODE=monitor once named the class
  # MonitorModeWorkflowWorkflow, in a file Zeitwerk expects to define
  # MonitorModeWorkflow.
  def test_class_name_follows_file_name_for_every_mode
    Lyra::Verification::WorkflowGenerator::AVAILABLE_MODES.each do |mode|
      basename = Lyra::Verification::WorkflowGenerator.workflow_file_basename(mode)
      assert_equal "#{mode}_mode_workflow", basename
      assert_equal basename.camelize, Lyra::Verification::WorkflowGenerator.workflow_class_name(mode)
    end
  end

  def test_generate_for_one_mode_writes_a_file_zeitwerk_can_load
    skip "PetriFlow not available" unless Lyra.petri_flow_available?

    run_generate(mode: "monitor")

    assert_equal %w[lifecycle_workflow.rb monitor_mode_workflow.rb], generated_files
    assert_match(/^class MonitorModeWorkflow < PetriFlow::Workflow$/,
                 File.read(File.join(@temp_dir, "monitor_mode_workflow.rb")))
    assert_loads_under_zeitwerk(%w[LifecycleWorkflow MonitorModeWorkflow])
  end

  def test_generate_for_one_mode_and_for_all_modes_name_files_alike
    skip "PetriFlow not available" unless Lyra.petri_flow_available?

    run_generate(mode: "es_sync")
    assert_equal %w[es_sync_mode_workflow.rb lifecycle_workflow.rb], generated_files

    run_generate(mode: nil)
    assert_equal %w[es_async_mode_workflow.rb es_sync_mode_workflow.rb hijack_mode_workflow.rb
                    lifecycle_workflow.rb monitor_mode_workflow.rb], generated_files
    assert_loads_under_zeitwerk(%w[EsAsyncModeWorkflow EsSyncModeWorkflow HijackModeWorkflow
                                   LifecycleWorkflow MonitorModeWorkflow])
  end

  private

  def run_generate(mode:)
    saved = ENV.to_h.slice("MODE", "OUTPUT_DIR", "REPORTS_DIR")
    # rake_require in setup loads the file only once per process
    load File.expand_path("../../lib/tasks/lyra_workflows.rake", __dir__) unless Rake::Task.task_defined?("lyra:workflows:generate")
    Rake::Task.define_task(:environment) unless Rake::Task.task_defined?(:environment)
    task = Rake::Task["lyra:workflows:generate"]
    task.reenable
    ENV["MODE"] = mode
    ENV["OUTPUT_DIR"] = @temp_dir
    ENV["REPORTS_DIR"] = File.join(@temp_dir, "reports")
    capture_io { task.invoke }
  ensure
    %w[MODE OUTPUT_DIR REPORTS_DIR].each { |key| ENV[key] = saved[key] }
  end

  def generated_files
    Dir.children(@temp_dir).grep(/\.rb\z/).sort
  end

  # Each generated file must define the constant Zeitwerk's inflector derives
  # from its name (Zeitwerk raises Zeitwerk::NameError otherwise). The files
  # define top-level classes, which may already be loaded from app/workflows,
  # so each is evaluated in a scratch module rather than at the top level.
  def assert_loads_under_zeitwerk(expected_constants)
    inflector = Zeitwerk::Inflector.new
    defined = Dir.glob(File.join(@temp_dir, "*.rb")).sort.map do |path|
      constant = inflector.camelize(File.basename(path, ".rb"), path)
      scratch = Module.new
      scratch.module_eval(File.read(path), path)
      assert scratch.const_defined?(constant, false),
             "#{File.basename(path)} should define #{constant}, the constant Zeitwerk expects"
      assert_kind_of PetriFlow::Workflow, scratch.const_get(constant, false).new
      constant
    end

    assert_equal expected_constants, defined
  end

  # Note: State machine workflow generator tests are in PetriFlow gem
  # See: gems/petri_flow/test/generators/workflow_generator_test.rb
end
