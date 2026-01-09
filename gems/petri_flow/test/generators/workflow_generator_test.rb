# frozen_string_literal: true

require "test_helper"
require "fileutils"

class WorkflowGeneratorTest < Minitest::Test
  def setup
    @temp_dir = File.join(Dir.tmpdir, "petri_flow_generator_test_#{$$}")
    FileUtils.mkdir_p(@temp_dir)
  end

  def teardown
    FileUtils.rm_rf(@temp_dir) if @temp_dir && Dir.exist?(@temp_dir)
  end

  # ===========================================================================
  # Class Method Tests
  # ===========================================================================

  def test_supported_libraries_returns_array
    libs = PetriFlow::Generators::WorkflowGenerator.supported_libraries
    assert_kind_of Array, libs
    assert libs.include?("state_machines-activerecord")
    assert libs.include?("aasm")
  end

  def test_supports_returns_false_for_plain_class
    plain_class = Class.new
    refute PetriFlow::Generators::WorkflowGenerator.supports?(plain_class)
  end

  def test_supports_returns_true_for_state_machines_model
    model = create_state_machines_model
    assert PetriFlow::Generators::WorkflowGenerator.supports?(model)
  end

  def test_supports_returns_true_for_aasm_model
    model = create_aasm_model
    assert PetriFlow::Generators::WorkflowGenerator.supports?(model)
  end

  def test_detect_library_for_state_machines
    model = create_state_machines_model
    assert_equal "state_machines-activerecord",
                 PetriFlow::Generators::WorkflowGenerator.detect_library(model)
  end

  def test_detect_library_for_aasm
    model = create_aasm_model
    assert_equal "aasm",
                 PetriFlow::Generators::WorkflowGenerator.detect_library(model)
  end

  def test_detect_library_returns_nil_for_unsupported
    plain_class = Class.new
    assert_nil PetriFlow::Generators::WorkflowGenerator.detect_library(plain_class)
  end

  # ===========================================================================
  # State Machines Adapter Tests
  # ===========================================================================

  def test_state_machines_adapter_extracts_states
    model = create_state_machines_model
    generator = PetriFlow::Generators::WorkflowGenerator.new(model, :state)

    data = generator.extract
    assert_includes data[:states], :pending
    assert_includes data[:states], :active
    assert_includes data[:states], :completed
    assert_includes data[:states], :cancelled
  end

  def test_state_machines_adapter_extracts_initial_state
    model = create_state_machines_model
    generator = PetriFlow::Generators::WorkflowGenerator.new(model, :state)

    data = generator.extract
    assert_equal :pending, data[:initial_state]
  end

  def test_state_machines_adapter_extracts_transitions
    model = create_state_machines_model
    generator = PetriFlow::Generators::WorkflowGenerator.new(model, :state)

    data = generator.extract
    assert data[:transitions].any?, "Should extract transitions"

    # Check for expected transition
    activate_transition = data[:transitions].find { |t| t[:event] == :activate }
    assert activate_transition, "Should find activate transition"
    assert_equal :pending, activate_transition[:from]
    assert_equal :active, activate_transition[:to]
  end

  def test_state_machines_adapter_finds_terminal_states
    model = create_state_machines_model
    generator = PetriFlow::Generators::WorkflowGenerator.new(model, :state)

    data = generator.extract
    assert_includes data[:terminal_states], :completed
    assert_includes data[:terminal_states], :cancelled
  end

  def test_state_machines_adapter_includes_library_name
    model = create_state_machines_model
    generator = PetriFlow::Generators::WorkflowGenerator.new(model, :state)

    data = generator.extract
    assert_equal "state_machines-activerecord", data[:library]
  end

  # ===========================================================================
  # AASM Adapter Tests
  # ===========================================================================

  def test_aasm_adapter_extracts_states
    model = create_aasm_model
    generator = PetriFlow::Generators::WorkflowGenerator.new(model, :state)

    data = generator.extract
    assert_includes data[:states], :draft
    assert_includes data[:states], :published
    assert_includes data[:states], :archived
  end

  def test_aasm_adapter_extracts_initial_state
    model = create_aasm_model
    generator = PetriFlow::Generators::WorkflowGenerator.new(model, :state)

    data = generator.extract
    assert_equal :draft, data[:initial_state]
  end

  def test_aasm_adapter_extracts_transitions
    model = create_aasm_model
    generator = PetriFlow::Generators::WorkflowGenerator.new(model, :state)

    data = generator.extract
    assert data[:transitions].any?, "Should extract transitions"

    # Check for expected transition
    publish_transition = data[:transitions].find { |t| t[:event] == :publish }
    assert publish_transition, "Should find publish transition"
    assert_equal :draft, publish_transition[:from]
    assert_equal :published, publish_transition[:to]
  end

  def test_aasm_adapter_includes_library_name
    model = create_aasm_model
    generator = PetriFlow::Generators::WorkflowGenerator.new(model, :state)

    data = generator.extract
    assert_equal "aasm", data[:library]
  end

  # ===========================================================================
  # Code Generation Tests
  # ===========================================================================

  def test_generate_code_produces_valid_ruby
    model = create_state_machines_model
    generator = PetriFlow::Generators::WorkflowGenerator.new(model, :state)

    code = generator.generate_code

    # Should compile without error
    begin
      RubyVM::InstructionSequence.compile(code)
    rescue SyntaxError => e
      flunk "Generated code should be valid Ruby: #{e.message}"
    end
  end

  def test_generate_code_includes_class_definition
    model = create_state_machines_model
    generator = PetriFlow::Generators::WorkflowGenerator.new(model, :state)

    code = generator.generate_code

    assert_match(/class \w+Workflow < PetriFlow::Workflow/, code)
  end

  def test_generate_code_includes_places
    model = create_state_machines_model
    generator = PetriFlow::Generators::WorkflowGenerator.new(model, :state)

    code = generator.generate_code

    assert_match(/places :pending/, code)
    assert_match(/:active/, code)
    assert_match(/:completed/, code)
  end

  def test_generate_code_includes_initial_place
    model = create_state_machines_model
    generator = PetriFlow::Generators::WorkflowGenerator.new(model, :state)

    code = generator.generate_code

    assert_match(/initial_place :pending/, code)
  end

  def test_generate_code_includes_transitions
    model = create_state_machines_model
    generator = PetriFlow::Generators::WorkflowGenerator.new(model, :state)

    code = generator.generate_code

    assert_match(/transition/, code)
    assert_match(/from:/, code)
    assert_match(/to:/, code)
  end

  def test_generate_code_includes_auto_generated_comment
    model = create_state_machines_model
    generator = PetriFlow::Generators::WorkflowGenerator.new(model, :state)

    code = generator.generate_code

    assert_match(/Auto-generated from/, code)
    assert_match(/state_machines-activerecord/, code)
  end

  # ===========================================================================
  # File Generation Tests
  # ===========================================================================

  def test_generate_creates_file
    model = create_state_machines_model
    generator = PetriFlow::Generators::WorkflowGenerator.new(model, :state)

    filepath = generator.generate!(output_dir: @temp_dir)

    assert File.exist?(filepath), "File should be created"
  end

  def test_generate_uses_correct_filename
    model = create_state_machines_model
    generator = PetriFlow::Generators::WorkflowGenerator.new(model, :state)

    filepath = generator.generate!(output_dir: @temp_dir)

    assert_match(/_workflow\.rb$/, filepath)
  end

  def test_workflow_class_name_uses_demodulized_name
    model = create_namespaced_model
    generator = PetriFlow::Generators::WorkflowGenerator.new(model, :state)

    assert_equal "NestedModelWorkflow", generator.workflow_class_name
  end

  # ===========================================================================
  # Dynamic Workflow Building Tests
  # ===========================================================================

  def test_build_workflow_class_creates_valid_workflow
    model = create_state_machines_model
    generator = PetriFlow::Generators::WorkflowGenerator.new(model, :state)

    workflow_class = generator.build_workflow_class

    assert workflow_class < PetriFlow::Workflow, "Should inherit from PetriFlow::Workflow"
  end

  def test_build_workflow_class_can_be_instantiated
    model = create_state_machines_model
    generator = PetriFlow::Generators::WorkflowGenerator.new(model, :state)

    workflow_class = generator.build_workflow_class
    workflow = workflow_class.new

    assert_kind_of PetriFlow::Workflow, workflow
  end

  def test_verify_returns_verification_results
    model = create_state_machines_model
    generator = PetriFlow::Generators::WorkflowGenerator.new(model, :state)

    results = generator.verify

    assert results.key?(:reachability)
    assert results.key?(:boundedness)
    assert results.key?(:liveness)
  end

  def test_verify_workflow_is_safe
    model = create_state_machines_model
    generator = PetriFlow::Generators::WorkflowGenerator.new(model, :state)

    results = generator.verify

    assert results[:boundedness][:is_safe], "Generated workflow should be safe (1-bounded)"
  end

  # ===========================================================================
  # Error Handling Tests
  # ===========================================================================

  def test_raises_for_unsupported_model
    plain_class = Class.new

    error = assert_raises(ArgumentError) do
      PetriFlow::Generators::WorkflowGenerator.new(plain_class, :state)
    end

    assert_match(/does not have a supported state machine/, error.message)
  end

  def test_raises_for_invalid_state_attribute
    model = create_state_machines_model

    error = assert_raises(ArgumentError) do
      generator = PetriFlow::Generators::WorkflowGenerator.new(model, :nonexistent_attr)
      generator.extract
    end

    assert_match(/No state machine for/, error.message)
  end

  private

  # Create a mock model with state_machines-activerecord style API
  def create_state_machines_model
    # Mock state
    mock_state = Struct.new(:name)
    pending_state = mock_state.new(:pending)
    active_state = mock_state.new(:active)
    completed_state = mock_state.new(:completed)
    cancelled_state = mock_state.new(:cancelled)

    # Mock state requirement
    mock_req = lambda do |from, to|
      from_matcher = Struct.new(:values).new([from])
      to_matcher = Struct.new(:values).new([to])
      { from: from_matcher, to: to_matcher }
    end

    # Mock branch
    mock_branch = Struct.new(:state_requirements)

    # Mock event
    mock_event = Struct.new(:name, :branches)
    activate_event = mock_event.new(:activate, [mock_branch.new([mock_req.call(:pending, :active)])])
    complete_event = mock_event.new(:complete, [mock_branch.new([mock_req.call(:active, :completed)])])
    cancel_event = mock_event.new(:cancel, [mock_branch.new([
      mock_req.call(:pending, :cancelled),
      mock_req.call(:active, :cancelled)
    ])])

    # Mock state machine
    mock_sm = Struct.new(:states, :events) do
      def initial_state(_instance)
        Struct.new(:name).new(:pending)
      end
    end.new(
      [pending_state, active_state, completed_state, cancelled_state],
      [activate_event, complete_event, cancel_event]
    )

    # Mock model class
    Class.new do
      define_singleton_method(:state_machines) { { state: mock_sm } }
      define_singleton_method(:new) { Object.new }
      define_singleton_method(:name) { "TestOrder" }
    end
  end

  # Create a mock model with AASM style API
  def create_aasm_model
    # Mock state
    mock_state = Struct.new(:name)
    draft_state = mock_state.new(:draft)
    published_state = mock_state.new(:published)
    archived_state = mock_state.new(:archived)

    # Mock transition
    mock_transition = Struct.new(:from, :to)

    # Mock event
    mock_event = Struct.new(:name, :transitions)
    publish_event = mock_event.new(:publish, [mock_transition.new(:draft, :published)])
    archive_event = mock_event.new(:archive, [mock_transition.new(:published, :archived)])
    unpublish_event = mock_event.new(:unpublish, [mock_transition.new(:published, :draft)])

    # Mock AASM instance
    mock_aasm = Struct.new(:states, :events, :initial_state).new(
      [draft_state, published_state, archived_state],
      [publish_event, archive_event, unpublish_event],
      :draft
    )

    # Mock model class
    Class.new do
      define_singleton_method(:aasm) { |_attr = nil| mock_aasm }
      define_singleton_method(:name) { "TestArticle" }
    end
  end

  # Create a namespaced mock model
  def create_namespaced_model
    model = create_state_machines_model
    model.define_singleton_method(:name) { "MyApp::Nested::NestedModel" }
    model
  end
end
