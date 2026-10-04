require "test_helper"

module Lyra
  class ConfigurationTest < Minitest::Test
    def setup
      @config = Configuration.new
    end

    def test_default_configuration
      assert_equal :monitor, @config.mode
      refute @config.hijack_enabled
      assert_equal [], @config.monitored_models
    end

    def test_configure_event_store
      @config.event_store = :custom_store
      assert_equal :custom_store, @config.event_store
    end

    def test_monitor_mode_detection
      @config.mode = :monitor
      assert @config.monitor_mode?
      refute @config.hijack_mode?
    end

    def test_hijack_mode_detection
      @config.mode = :hijack
      assert @config.hijack_mode?
      refute @config.monitor_mode?
    end

    def test_enable_hijack
      @config.enable_hijack!
      assert @config.hijack_enabled
      assert_equal :hijack, @config.mode
      assert @config.hijack_mode?
    end

    def test_enable_monitor
      @config.enable_monitor!
      refute @config.hijack_enabled
      assert_equal :monitor, @config.mode
      assert @config.monitor_mode?
    end

    def test_monitor_model
      dummy_user = Class.new
      stub_const("DummyUser", dummy_user)

      @config.monitor_model(dummy_user, event_prefix: "User")

      assert_includes @config.monitored_models, dummy_user
      assert_equal "User", @config.model_config(dummy_user).event_prefix
    end

    def test_model_configuration
      dummy_post = Class.new
      stub_const("DummyPost", dummy_post)

      @config.monitor_model(dummy_post,
        event_prefix: "BlogPost",
        aggregate_class: "PostAggregate"
      )

      config = @config.model_config(dummy_post)
      assert_equal "BlogPost", config.event_prefix
      assert_equal "PostAggregate", config.aggregate_class
    end

    def test_retention_policy
      @config.retention_policy = 90
      assert_equal 90, @config.retention_policy
    end

    def test_metadata_proc_defaults_to_nil
      assert_nil @config.metadata_proc
    end

    def test_metadata_proc_can_be_set_to_lambda
      my_proc = ->(record, operation) { { custom: true } }
      @config.metadata_proc = my_proc

      assert_equal my_proc, @config.metadata_proc
    end

    def test_metadata_proc_can_be_set_to_proc
      my_proc = Proc.new { |record, operation| { source: "test" } }
      @config.metadata_proc = my_proc

      assert_equal my_proc, @config.metadata_proc
    end

    private

    def stub_const(name, klass)
      klass.define_singleton_method(:name) { name }
    end
  end
end
