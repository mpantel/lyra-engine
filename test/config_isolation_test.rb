# frozen_string_literal: true

require "test_helper"

# Lyra.config is process-global; test_helper gives every test its own copy of
# the suite's baseline configuration. These tests run a deliberately
# misbehaving test and check that nothing it did to the configuration survives.
class ConfigIsolationTest < Minitest::Test
  def test_a_test_starts_from_the_baseline
    baseline = LyraConfigIsolation.baseline
    refute_same baseline, Lyra.config
    assert_equal baseline.mode, Lyra.config.mode
    assert_same baseline.event_store, Lyra.config.event_store
    assert_equal baseline.monitored_models.map(&:name), Lyra.config.monitored_models.map(&:name)
  end

  def test_changes_made_by_one_test_do_not_reach_the_next
    run_polluting_test

    assert_equal LyraConfigIsolation.baseline.mode, Lyra.config.mode
    refute_includes Lyra.config.monitored_models.map(&:name), "LeakyStub"
    assert_same LyraConfigIsolation.baseline.event_store, Lyra.config.event_store
  end

  def test_the_baseline_itself_is_never_modified
    names = LyraConfigIsolation.baseline.monitored_models.map(&:name)

    run_polluting_test

    assert_equal names, LyraConfigIsolation.baseline.monitored_models.map(&:name)
  end

  def test_a_reset_in_one_test_does_not_remove_the_baseline_for_others
    resetting = Class.new(Minitest::Test) do
      def test_reset = Lyra.reset_config!
    end
    Minitest::Runnable.runnables.delete(resetting)

    resetting.new(:test_reset).run

    refute_nil Lyra.config.event_store
  end

  private

  # A test that changes the mode and registers a stub model, in place, and
  # never cleans up.
  def run_polluting_test
    polluter = Class.new(Minitest::Test) do
      def test_pollute
        stub = Class.new { def self.name = "LeakyStub" }
        Lyra.config.mode = :event_sourcing
        Lyra.config.monitor_model(stub)
      end
    end
    Minitest::Runnable.runnables.delete(polluter)

    result = polluter.new(:test_pollute).run
    assert result.passed?, result.failures.map(&:message).join
  end
end
