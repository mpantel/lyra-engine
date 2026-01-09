# frozen_string_literal: true

require "test_helper"

class EventSourcingModeTest < Minitest::Test
  def setup
    Lyra.reset_config!
  end

  def teardown
    Lyra.reset_config!
  end

  # ===========================================================================
  # Mode Configuration Tests
  # ===========================================================================

  def test_default_mode_is_monitor
    assert_equal :monitor, Lyra.config.mode
    assert Lyra.monitor_mode?
    refute Lyra.event_sourcing_mode?
  end

  def test_enable_event_sourcing_mode
    Lyra.config.enable_event_sourcing!

    assert_equal :event_sourcing, Lyra.config.mode
    assert Lyra.event_sourcing_mode?
    refute Lyra.hijack_mode?
    refute Lyra.monitor_mode?
  end

  def test_modes_constant_includes_event_sourcing
    assert_includes Lyra::Configuration::MODES, :event_sourcing
    assert_includes Lyra::Configuration::MODES, :disabled
    assert_includes Lyra::Configuration::MODES, :monitor
    assert_includes Lyra::Configuration::MODES, :hijack
  end

  def test_mode_can_be_set_directly
    Lyra.configure do |config|
      config.mode = :event_sourcing
    end

    assert_equal :event_sourcing, Lyra.config.mode
    assert Lyra.event_sourcing_mode?
  end

  def test_disable_mode
    Lyra.config.disable!

    assert_equal :disabled, Lyra.config.mode
    assert Lyra.disabled_mode?
    refute Lyra.event_sourcing_mode?
  end

  # ===========================================================================
  # Projection Mode Tests
  # ===========================================================================

  def test_projection_mode_defaults_to_sync
    assert_equal :sync, Lyra.config.projection_mode
  end

  def test_projection_mode_can_be_set_to_sync
    Lyra.configure do |config|
      config.projection_mode = :sync
    end

    assert_equal :sync, Lyra.config.projection_mode
  end

  def test_projection_mode_can_be_set_to_async
    Lyra.configure do |config|
      config.projection_mode = :async
    end

    assert_equal :async, Lyra.config.projection_mode
  end

  def test_projection_mode_can_be_set_to_disabled
    Lyra.configure do |config|
      config.projection_mode = :disabled
    end

    assert_equal :disabled, Lyra.config.projection_mode
  end

  # ===========================================================================
  # Strict Projections Tests
  # ===========================================================================

  def test_strict_projections_defaults_to_false
    refute Lyra.config.strict_projections
  end

  def test_strict_projections_can_be_enabled
    Lyra.configure do |config|
      config.strict_projections = true
    end

    assert Lyra.config.strict_projections
  end

  def test_projection_error_handler_can_be_set
    handler = ->(error, record, operation) { puts error }

    Lyra.configure do |config|
      config.projection_error_handler = handler
    end

    assert_equal handler, Lyra.config.projection_error_handler
  end

  def test_projection_error_handler_defaults_to_nil
    assert_nil Lyra.config.projection_error_handler
  end

  # ===========================================================================
  # Mode Switching Tests
  # ===========================================================================

  def test_switching_from_event_sourcing_to_monitor
    Lyra.config.enable_event_sourcing!
    assert Lyra.event_sourcing_mode?

    Lyra.config.enable_monitor!
    assert Lyra.monitor_mode?
    refute Lyra.event_sourcing_mode?
  end

  def test_switching_from_event_sourcing_to_hijack
    Lyra.config.enable_event_sourcing!
    assert Lyra.event_sourcing_mode?

    Lyra.config.enable_hijack!
    assert Lyra.hijack_mode?
    refute Lyra.event_sourcing_mode?
  end

  def test_switching_from_monitor_to_event_sourcing
    Lyra.config.enable_monitor!
    assert Lyra.monitor_mode?

    Lyra.config.enable_event_sourcing!
    assert Lyra.event_sourcing_mode?
    refute Lyra.monitor_mode?
  end

  def test_switching_from_hijack_to_event_sourcing
    Lyra.config.enable_hijack!
    assert Lyra.hijack_mode?

    Lyra.config.enable_event_sourcing!
    assert Lyra.event_sourcing_mode?
    refute Lyra.hijack_mode?
  end

  # ===========================================================================
  # Mode Isolation Tests
  # ===========================================================================

  def test_event_sourcing_mode_disables_hijack_enabled_flag
    Lyra.config.enable_hijack!
    assert Lyra.config.hijack_enabled

    Lyra.config.enable_event_sourcing!
    refute Lyra.config.hijack_enabled, "Event sourcing should disable hijack_enabled"
  end

  def test_all_modes_are_mutually_exclusive
    Lyra.config.enable_event_sourcing!

    refute Lyra.monitor_mode?
    refute Lyra.hijack_mode?
    refute Lyra.disabled_mode?
    assert Lyra.event_sourcing_mode?
  end

  # ===========================================================================
  # Helper Method Tests
  # ===========================================================================

  def test_event_sourcing_mode_helper_at_module_level
    refute Lyra.event_sourcing_mode?

    Lyra.config.enable_event_sourcing!

    assert Lyra.event_sourcing_mode?
  end

  def test_disabled_mode_helper_at_module_level
    refute Lyra.disabled_mode?

    Lyra.config.disable!

    assert Lyra.disabled_mode?
  end

  def test_monitor_mode_helper_at_module_level
    # Default is monitor
    assert Lyra.monitor_mode?

    Lyra.config.enable_event_sourcing!
    refute Lyra.monitor_mode?

    Lyra.config.enable_monitor!
    assert Lyra.monitor_mode?
  end

  def test_hijack_mode_helper_at_module_level
    refute Lyra.hijack_mode?

    Lyra.config.enable_hijack!
    assert Lyra.hijack_mode?

    Lyra.config.enable_event_sourcing!
    refute Lyra.hijack_mode?
  end

  # ===========================================================================
  # Configuration Combination Tests
  # ===========================================================================

  def test_event_sourcing_with_sync_projections
    Lyra.configure do |config|
      config.mode = :event_sourcing
      config.projection_mode = :sync
    end

    assert Lyra.event_sourcing_mode?
    assert_equal :sync, Lyra.config.projection_mode
  end

  def test_event_sourcing_with_async_projections
    Lyra.configure do |config|
      config.mode = :event_sourcing
      config.projection_mode = :async
    end

    assert Lyra.event_sourcing_mode?
    assert_equal :async, Lyra.config.projection_mode
  end

  def test_event_sourcing_with_disabled_projections
    Lyra.configure do |config|
      config.mode = :event_sourcing
      config.projection_mode = :disabled
    end

    assert Lyra.event_sourcing_mode?
    assert_equal :disabled, Lyra.config.projection_mode
  end

  def test_event_sourcing_with_strict_projections
    Lyra.configure do |config|
      config.mode = :event_sourcing
      config.strict_projections = true
    end

    assert Lyra.event_sourcing_mode?
    assert Lyra.config.strict_projections
  end

  def test_full_event_sourcing_configuration
    error_handler = ->(e, r, o) { Rails.logger.error(e) }

    Lyra.configure do |config|
      config.mode = :event_sourcing
      config.projection_mode = :async
      config.strict_projections = true
      config.projection_error_handler = error_handler
    end

    assert Lyra.event_sourcing_mode?
    assert_equal :async, Lyra.config.projection_mode
    assert Lyra.config.strict_projections
    assert_equal error_handler, Lyra.config.projection_error_handler
  end
end
