require "test_helper"

module PamDsl
  class RegistryTest < Minitest::Test
    def setup
      @registry = Registry.new
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Basic Registry Operations
    # ─────────────────────────────────────────────────────────────────────────

    def test_register_policy
      policy = Policy.new(:test_policy)
      @registry.register(:test_policy, policy)

      assert_equal policy, @registry.get(:test_policy)
    end

    def test_register_multiple_policies
      policy1 = Policy.new(:policy1)
      policy2 = Policy.new(:policy2)

      @registry.register(:policy1, policy1)
      @registry.register(:policy2, policy2)

      assert_equal 2, @registry.all.size
    end

    def test_get_nonexistent_policy
      assert_nil @registry.get(:nonexistent)
    end

    def test_clear_registry
      policy = Policy.new(:test)
      @registry.register(:test, policy)

      @registry.clear

      assert_empty @registry.all
    end

    def test_policy_exists
      policy = Policy.new(:test)
      @registry.register(:test, policy)

      assert @registry.exists?(:test)
      refute @registry.exists?(:nonexistent)
    end

    def test_overwrite_policy
      policy1 = Policy.new(:test)
      policy2 = Policy.new(:test)

      @registry.register(:test, policy1)
      @registry.register(:test, policy2)

      assert_equal policy2, @registry.get(:test)
      assert_equal 1, @registry.all.size
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Name and Count
    # ─────────────────────────────────────────────────────────────────────────

    def test_names_returns_policy_names
      @registry.register(:alpha, Policy.new(:alpha))
      @registry.register(:beta, Policy.new(:beta))

      assert_includes @registry.names, :alpha
      assert_includes @registry.names, :beta
    end

    def test_count_returns_number_of_policies
      assert_equal 0, @registry.count

      @registry.register(:test1, Policy.new(:test1))
      assert_equal 1, @registry.count

      @registry.register(:test2, Policy.new(:test2))
      assert_equal 2, @registry.count
    end

    def test_remove_policy
      @registry.register(:test, Policy.new(:test))
      assert @registry.exists?(:test)

      @registry.remove(:test)
      refute @registry.exists?(:test)
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Symbol/String Handling
    # ─────────────────────────────────────────────────────────────────────────

    def test_register_with_string_name
      policy = Policy.new(:test)
      @registry.register("test", policy)

      assert @registry.exists?(:test)
      assert @registry.exists?("test")
    end

    def test_get_with_string_name
      @registry.register(:test, Policy.new(:test))

      refute_nil @registry.get("test")
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Access to policies hash
    # ─────────────────────────────────────────────────────────────────────────

    def test_policies_hash_is_accessible
      @registry.register(:test, Policy.new(:test))

      assert @registry.policies.is_a?(Hash)
      assert @registry.policies.key?(:test)
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Integration with PamDsl module
    # ─────────────────────────────────────────────────────────────────────────

    def test_module_registry_access
      PamDsl.reset!

      refute_nil PamDsl.registry
      assert_instance_of Registry, PamDsl.registry
    end

    def test_define_policy_registers_in_module_registry
      PamDsl.reset!

      PamDsl.define_policy :integration_test do
        field :email, type: :email
      end

      assert PamDsl.registry.exists?(:integration_test)

      PamDsl.reset!
    end

    def test_reset_clears_module_registry
      PamDsl.reset!

      PamDsl.define_policy :temp do
        field :email, type: :email
      end

      assert PamDsl.registry.exists?(:temp)

      PamDsl.reset!

      refute PamDsl.registry.exists?(:temp)
    end
  end
end
