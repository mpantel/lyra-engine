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

  # Note: State machine workflow generator tests are in PetriFlow gem
  # See: gems/petri_flow/test/generators/workflow_generator_test.rb
end
