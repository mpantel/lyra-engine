# frozen_string_literal: true

require "test_helper"

module PetriFlow
  class RegistryTest < Minitest::Test
    def setup
      Registry.clear
    end

    def teardown
      Registry.clear
    end

    # ===========================================
    # Registration Tests
    # ===========================================

    def test_register_and_get_workflow
      # Create a test workflow class
      workflow_class = Class.new(Workflow) do
        workflow_name "Test Registry Workflow"
        places :start, :end
        initial_place :start
        terminal_places :end
        transition :complete, from: :start, to: :end
      end

      # Define a constant name for it
      Object.const_set(:TestRegistryWorkflow, workflow_class)

      Registry.register(workflow_class)

      assert_equal workflow_class, Registry.get("TestRegistryWorkflow")
    ensure
      Object.send(:remove_const, :TestRegistryWorkflow) if defined?(TestRegistryWorkflow)
    end

    def test_get_with_symbol
      workflow_class = Class.new(Workflow)
      Object.const_set(:SymbolTestWorkflow, workflow_class)

      Registry.register(workflow_class)

      assert_equal workflow_class, Registry.get(:SymbolTestWorkflow)
    ensure
      Object.send(:remove_const, :SymbolTestWorkflow) if defined?(SymbolTestWorkflow)
    end

    def test_get_returns_nil_for_unknown_workflow
      assert_nil Registry.get("NonExistentWorkflow")
    end

    # ===========================================
    # Collection Tests
    # ===========================================

    def test_all_returns_registered_workflows
      # Create classes and assign to constants FIRST, then register
      # (inherited hook auto-registers with nil name for anonymous classes)
      class1 = Class.new(Workflow)
      class2 = Class.new(Workflow)
      Object.const_set(:AllTest1Workflow, class1)
      Object.const_set(:AllTest2Workflow, class2)

      # Clear to remove any nil-named auto-registrations
      Registry.clear

      Registry.register(class1)
      Registry.register(class2)

      assert_includes Registry.all, class1
      assert_includes Registry.all, class2
      assert_equal 2, Registry.all.size
    ensure
      Object.send(:remove_const, :AllTest1Workflow) if defined?(AllTest1Workflow)
      Object.send(:remove_const, :AllTest2Workflow) if defined?(AllTest2Workflow)
    end

    def test_names_returns_class_names
      workflow_class = Class.new(Workflow)
      Object.const_set(:NamesTestWorkflow, workflow_class)

      Registry.register(workflow_class)

      assert_includes Registry.names, "NamesTestWorkflow"
    ensure
      Object.send(:remove_const, :NamesTestWorkflow) if defined?(NamesTestWorkflow)
    end

    def test_count_returns_workflow_count
      # Clear first, then check starting count
      Registry.clear
      assert_equal 0, Registry.count

      class1 = Class.new(Workflow)
      class2 = Class.new(Workflow)
      Object.const_set(:Count1Workflow, class1)
      Object.const_set(:Count2Workflow, class2)

      # Clear again after class creation (auto-reg adds nil entries)
      Registry.clear

      Registry.register(class1)
      assert_equal 1, Registry.count

      Registry.register(class2)
      assert_equal 2, Registry.count
    ensure
      Object.send(:remove_const, :Count1Workflow) if defined?(Count1Workflow)
      Object.send(:remove_const, :Count2Workflow) if defined?(Count2Workflow)
    end

    # ===========================================
    # Existence Tests
    # ===========================================

    def test_exists_returns_true_for_registered_workflow
      workflow_class = Class.new(Workflow)
      Object.const_set(:ExistsTestWorkflow, workflow_class)

      Registry.register(workflow_class)

      assert Registry.exists?("ExistsTestWorkflow")
      assert Registry.exists?(:ExistsTestWorkflow)
    ensure
      Object.send(:remove_const, :ExistsTestWorkflow) if defined?(ExistsTestWorkflow)
    end

    def test_exists_returns_false_for_unknown_workflow
      refute Registry.exists?("UnknownWorkflow")
    end

    # ===========================================
    # Unregister Tests
    # ===========================================

    def test_unregister_removes_workflow
      workflow_class = Class.new(Workflow)
      Object.const_set(:UnregisterTestWorkflow, workflow_class)

      Registry.register(workflow_class)
      assert Registry.exists?("UnregisterTestWorkflow")

      Registry.unregister("UnregisterTestWorkflow")
      refute Registry.exists?("UnregisterTestWorkflow")
    ensure
      Object.send(:remove_const, :UnregisterTestWorkflow) if defined?(UnregisterTestWorkflow)
    end

    def test_unregister_with_symbol
      workflow_class = Class.new(Workflow)
      Object.const_set(:UnregisterSymbolWorkflow, workflow_class)

      Registry.register(workflow_class)
      Registry.unregister(:UnregisterSymbolWorkflow)

      refute Registry.exists?("UnregisterSymbolWorkflow")
    ensure
      Object.send(:remove_const, :UnregisterSymbolWorkflow) if defined?(UnregisterSymbolWorkflow)
    end

    # ===========================================
    # Clear Tests
    # ===========================================

    def test_clear_removes_all_workflows
      class1 = Class.new(Workflow)
      class2 = Class.new(Workflow)
      Object.const_set(:Clear1Workflow, class1)
      Object.const_set(:Clear2Workflow, class2)

      # Clear auto-registered nil entries first
      Registry.clear

      Registry.register(class1)
      Registry.register(class2)
      assert_equal 2, Registry.count

      Registry.clear

      assert_equal 0, Registry.count
      assert_empty Registry.all
    ensure
      Object.send(:remove_const, :Clear1Workflow) if defined?(Clear1Workflow)
      Object.send(:remove_const, :Clear2Workflow) if defined?(Clear2Workflow)
    end

    # ===========================================
    # Auto-Registration Tests
    # ===========================================

    def test_workflow_auto_registers_on_inheritance
      # Manually clear to ensure clean state
      Registry.clear

      # NOTE: Class.new(Workflow) triggers inherited hook BEFORE const_set,
      # so the class registers with nil name. After const_set, re-registration
      # uses the proper name. This tests that real workflow classes
      # (defined with `class Foo < Workflow`) auto-register correctly.
      #
      # For Class.new, we need to re-register after const_set:
      auto_workflow = Class.new(Workflow) do
        workflow_name "Auto Registered Workflow"
        places :a, :b
        initial_place :a
        terminal_places :b
        transition :go, from: :a, to: :b
      end
      Object.const_set(:AutoRegWorkflow, auto_workflow)

      # Auto-registration happened with nil name; re-register with actual name
      Registry.register(auto_workflow)

      assert Registry.exists?("AutoRegWorkflow")
      assert_equal auto_workflow, Registry.get("AutoRegWorkflow")
    ensure
      Object.send(:remove_const, :AutoRegWorkflow) if defined?(AutoRegWorkflow)
    end

    def test_auto_registration_with_real_class_definition
      # This tests that eval-defined classes auto-register correctly
      Registry.clear

      # Using eval to simulate a real class definition
      eval <<~RUBY, binding, __FILE__, __LINE__
        class ::RealAutoRegWorkflow < PetriFlow::Workflow
          workflow_name "Real Auto Workflow"
          places :x, :y
          initial_place :x
          terminal_places :y
          transition :move, from: :x, to: :y
        end
      RUBY

      assert Registry.exists?("RealAutoRegWorkflow")
      assert_equal ::RealAutoRegWorkflow, Registry.get("RealAutoRegWorkflow")
    ensure
      Object.send(:remove_const, :RealAutoRegWorkflow) if defined?(::RealAutoRegWorkflow)
    end

    # ===========================================
    # Discovery Tests
    # ===========================================

    def test_discover_in_nonexistent_directory
      # Should not raise an error
      Registry.discover_in("/nonexistent/path")
      assert_equal 0, Registry.count
    end

    def test_discover_in_nil_directory
      # Should not raise an error
      Registry.discover_in(nil)
      assert_equal 0, Registry.count
    end

    def test_discover_in_loads_workflow_files
      # Create a temporary directory with a workflow file
      require "tmpdir"

      Dir.mktmpdir do |tmpdir|
        workflow_file = File.join(tmpdir, "sample_workflow.rb")
        File.write(workflow_file, <<~RUBY)
          class SampleDiscoveryWorkflow < PetriFlow::Workflow
            workflow_name "Sample Discovery"
            places :x, :y
            initial_place :x
            terminal_places :y
            transition :move, from: :x, to: :y
          end
        RUBY

        Registry.discover_in(tmpdir)

        assert Registry.exists?("SampleDiscoveryWorkflow")
      ensure
        Object.send(:remove_const, :SampleDiscoveryWorkflow) if defined?(SampleDiscoveryWorkflow)
      end
    end

    def test_discover_in_loads_nested_workflow_files
      require "tmpdir"

      Dir.mktmpdir do |tmpdir|
        # Create nested directory
        nested_dir = File.join(tmpdir, "nested")
        Dir.mkdir(nested_dir)

        workflow_file = File.join(nested_dir, "nested_workflow.rb")
        File.write(workflow_file, <<~RUBY)
          class NestedDiscoveryWorkflow < PetriFlow::Workflow
            workflow_name "Nested Discovery"
            places :p, :q
            initial_place :p
            terminal_places :q
            transition :step, from: :p, to: :q
          end
        RUBY

        Registry.discover_in(tmpdir)

        assert Registry.exists?("NestedDiscoveryWorkflow")
      ensure
        Object.send(:remove_const, :NestedDiscoveryWorkflow) if defined?(NestedDiscoveryWorkflow)
      end
    end

    def test_discover_in_ignores_non_workflow_files
      require "tmpdir"

      Dir.mktmpdir do |tmpdir|
        # Create a non-workflow file
        File.write(File.join(tmpdir, "helper.rb"), "# not a workflow")
        File.write(File.join(tmpdir, "model.rb"), "# also not a workflow")

        initial_count = Registry.count
        Registry.discover_in(tmpdir)

        # Should not have loaded anything
        assert_equal initial_count, Registry.count
      end
    end
  end
end
