# frozen_string_literal: true

require "test_helper"

# Unit tests for Lyra's multi-mode behavior.
# These tests verify mode configuration without requiring a database.
module Lyra
  class MultiModeTest < Minitest::Test
    MODES = [:disabled, :monitor, :hijack, :event_sourcing].freeze

    def setup
      Lyra.reset_config!
    end

    def teardown
      Lyra.reset_config!
    end

    # =========================================================================
    # Mode Activation Tests
    # =========================================================================

    def test_disabled_mode_activates_correctly
      Lyra.config.disable!

      assert_equal :disabled, Lyra.config.mode
      assert Lyra.disabled_mode?
      refute Lyra.monitor_mode?
      refute Lyra.hijack_mode?
      refute Lyra.event_sourcing_mode?
    end

    def test_monitor_mode_activates_correctly
      Lyra.config.enable_monitor!

      assert_equal :monitor, Lyra.config.mode
      assert Lyra.monitor_mode?
      refute Lyra.disabled_mode?
      refute Lyra.hijack_mode?
      refute Lyra.event_sourcing_mode?
    end

    def test_hijack_mode_activates_correctly
      Lyra.config.enable_hijack!

      assert_equal :hijack, Lyra.config.mode
      assert Lyra.hijack_mode?
      assert Lyra.config.hijack_enabled
      refute Lyra.disabled_mode?
      refute Lyra.monitor_mode?
      refute Lyra.event_sourcing_mode?
    end

    def test_event_sourcing_mode_activates_correctly
      Lyra.config.enable_event_sourcing!

      assert_equal :event_sourcing, Lyra.config.mode
      assert Lyra.event_sourcing_mode?
      refute Lyra.disabled_mode?
      refute Lyra.monitor_mode?
      refute Lyra.hijack_mode?
    end

    # =========================================================================
    # Mode Mutual Exclusivity Tests
    # =========================================================================

    def test_modes_are_mutually_exclusive
      MODES.each do |mode|
        with_mode(mode) do
          active_modes = MODES.select { |m| mode_active?(m) }
          assert_equal [mode], active_modes,
            "Expected only #{mode} to be active, but #{active_modes} were active"
        end
      end
    end

    def test_each_mode_only_has_one_predicate_true
      MODES.each do |mode|
        with_mode(mode) do
          predicates = {
            disabled: Lyra.disabled_mode?,
            monitor: Lyra.monitor_mode?,
            hijack: Lyra.hijack_mode?,
            event_sourcing: Lyra.event_sourcing_mode?
          }

          true_predicates = predicates.select { |_, v| v }.keys
          assert_equal [mode], true_predicates,
            "In #{mode} mode, expected only #{mode} predicate true, got #{true_predicates}"
        end
      end
    end

    # =========================================================================
    # Mode Switching Tests
    # =========================================================================

    def test_switching_from_disabled_to_monitor
      Lyra.config.disable!
      assert Lyra.disabled_mode?

      Lyra.config.enable_monitor!
      assert Lyra.monitor_mode?
      refute Lyra.disabled_mode?
    end

    def test_switching_from_monitor_to_hijack
      Lyra.config.enable_monitor!
      assert Lyra.monitor_mode?

      Lyra.config.enable_hijack!
      assert Lyra.hijack_mode?
      refute Lyra.monitor_mode?
    end

    def test_switching_from_hijack_to_event_sourcing
      Lyra.config.enable_hijack!
      assert Lyra.hijack_mode?

      Lyra.config.enable_event_sourcing!
      assert Lyra.event_sourcing_mode?
      refute Lyra.hijack_mode?
    end

    def test_switching_from_event_sourcing_to_disabled
      Lyra.config.enable_event_sourcing!
      assert Lyra.event_sourcing_mode?

      Lyra.config.disable!
      assert Lyra.disabled_mode?
      refute Lyra.event_sourcing_mode?
    end

    def test_full_mode_cycle
      # Test cycling through all modes
      Lyra.config.disable!
      assert Lyra.disabled_mode?

      Lyra.config.enable_monitor!
      assert Lyra.monitor_mode?

      Lyra.config.enable_hijack!
      assert Lyra.hijack_mode?

      Lyra.config.enable_event_sourcing!
      assert Lyra.event_sourcing_mode?

      Lyra.config.disable!
      assert Lyra.disabled_mode?
    end

    # =========================================================================
    # Configuration Flag Tests
    # =========================================================================

    def test_hijack_enabled_flag_in_hijack_mode
      Lyra.config.enable_hijack!
      assert Lyra.config.hijack_enabled
    end

    def test_hijack_enabled_flag_disabled_in_other_modes
      [:disabled, :monitor, :event_sourcing].each do |mode|
        with_mode(mode) do
          refute Lyra.config.hijack_enabled,
            "hijack_enabled should be false in #{mode} mode"
        end
      end
    end

    def test_event_sourcing_disables_hijack_enabled
      Lyra.config.enable_hijack!
      assert Lyra.config.hijack_enabled

      Lyra.config.enable_event_sourcing!
      refute Lyra.config.hijack_enabled,
        "Switching to event_sourcing should disable hijack_enabled"
    end

    # =========================================================================
    # Direct Mode Assignment Tests
    # =========================================================================

    def test_mode_can_be_set_directly_via_configure
      MODES.each do |mode|
        Lyra.reset_config!
        Lyra.configure do |config|
          config.mode = mode
        end

        assert_equal mode, Lyra.config.mode,
          "Expected mode to be #{mode} after direct assignment"
      end
    end

    def test_modes_constant_contains_all_modes
      assert_equal MODES.sort, Lyra::Configuration::MODES.sort,
        "MODES constant should contain all expected modes"
    end

    # =========================================================================
    # Projection Mode Tests (Event Sourcing only)
    # =========================================================================

    def test_projection_mode_defaults_to_sync
      assert_equal :sync, Lyra.config.projection_mode
    end

    def test_projection_mode_can_be_set_in_event_sourcing
      Lyra.configure do |config|
        config.mode = :event_sourcing
        config.projection_mode = :async
      end

      assert Lyra.event_sourcing_mode?
      assert_equal :async, Lyra.config.projection_mode
    end

    def test_all_projection_modes_configurable
      [:sync, :async, :disabled].each do |proj_mode|
        Lyra.reset_config!
        Lyra.configure do |config|
          config.mode = :event_sourcing
          config.projection_mode = proj_mode
        end

        assert_equal proj_mode, Lyra.config.projection_mode,
          "Projection mode should be #{proj_mode}"
      end
    end

    def test_projection_mode_preserved_when_switching_to_event_sourcing
      # Set projection mode first
      Lyra.configure do |config|
        config.projection_mode = :async
      end

      # Switch to event sourcing
      Lyra.config.enable_event_sourcing!

      assert Lyra.event_sourcing_mode?
      assert_equal :async, Lyra.config.projection_mode
    end

    def test_each_projection_mode_with_event_sourcing
      [:sync, :async, :disabled].each do |proj_mode|
        Lyra.reset_config!
        Lyra.config.enable_event_sourcing!
        Lyra.config.projection_mode = proj_mode

        assert Lyra.event_sourcing_mode?,
          "Should be in event_sourcing mode"
        assert_equal proj_mode, Lyra.config.projection_mode,
          "Projection mode should be #{proj_mode}"
      end
    end

    def test_projection_mode_independent_of_operation_mode
      # Projection mode should be configurable regardless of operation mode
      MODES.each do |mode|
        [:sync, :async, :disabled].each do |proj_mode|
          Lyra.reset_config!
          with_mode(mode) do
            Lyra.config.projection_mode = proj_mode
            assert_equal proj_mode, Lyra.config.projection_mode,
              "Projection mode #{proj_mode} should be settable in #{mode} mode"
          end
        end
      end
    end

    # =========================================================================
    # Default Mode Test
    # =========================================================================

    def test_default_mode_is_monitor
      Lyra.reset_config!
      assert_equal :monitor, Lyra.config.mode
      assert Lyra.monitor_mode?
    end

    private

    def with_mode(mode)
      Lyra.reset_config!
      case mode
      when :disabled then Lyra.config.disable!
      when :monitor then Lyra.config.enable_monitor!
      when :hijack then Lyra.config.enable_hijack!
      when :event_sourcing then Lyra.config.enable_event_sourcing!
      end
      yield
    ensure
      Lyra.reset_config!
    end

    def mode_active?(mode)
      case mode
      when :disabled then Lyra.disabled_mode?
      when :monitor then Lyra.monitor_mode?
      when :hijack then Lyra.hijack_mode?
      when :event_sourcing then Lyra.event_sourcing_mode?
      end
    end
  end
end
