# frozen_string_literal: true

require "test_helper"

# config.mode= and config.projection_mode= accept only their documented values.
class ConfigurationValidationTest < Minitest::Test
  def setup
    @config = Lyra::Configuration.new
  end

  def test_every_mode_is_accepted
    Lyra::Configuration::MODES.each do |mode|
      @config.mode = mode
      assert_equal mode, @config.mode
    end
  end

  def test_a_mode_given_as_a_string_is_taken_as_its_symbol
    @config.mode = "event_sourcing"
    assert_equal :event_sourcing, @config.mode
    assert @config.event_sourcing_mode?
  end

  def test_an_unknown_mode_is_refused_naming_the_valid_ones
    error = assert_raises(ArgumentError) { @config.mode = :event_sorcing }
    assert_match(/config\.mode must be one of :disabled, :monitor, :hijack, :event_sourcing/, error.message)
    assert_match(/:event_sorcing/, error.message)
    assert_equal :monitor, @config.mode, "the mode is unchanged"
  end

  def test_nil_is_not_a_mode
    assert_raises(ArgumentError) { @config.mode = nil }
  end

  def test_every_projection_mode_is_accepted
    %i[sync async disabled lazy].each do |mode|
      @config.projection_mode = mode
      assert_equal mode, @config.projection_mode
    end
    assert_equal %i[sync async disabled lazy], Lyra::Configuration::PROJECTION_MODES
  end

  def test_a_projection_mode_given_as_a_string_is_taken_as_its_symbol
    @config.projection_mode = "disabled"
    assert_equal :disabled, @config.projection_mode
  end

  def test_an_unknown_projection_mode_is_refused_naming_the_valid_ones
    error = assert_raises(ArgumentError) { @config.projection_mode = :none }
    assert_match(/config\.projection_mode must be one of :sync, :async, :disabled, :lazy/, error.message)
    assert_equal :sync, @config.projection_mode
  end

  def test_dashboard_authorization_defaults_to_nil
    assert_nil @config.dashboard_authorization
  end
end
