# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class OptionalDependencyTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    $LOAD_PATH.unshift(@dir)
  end

  def teardown
    $LOAD_PATH.delete(@dir)
    FileUtils.remove_entry(@dir)
  end

  def test_a_gem_that_is_not_installed_is_unavailable
    refute Lyra::OptionalDependency.load("lyra_test_gem_that_does_not_exist")
  end

  def test_an_installed_gem_loads
    File.write(File.join(@dir, "lyra_test_present_gem.rb"), "module LyraTestPresentGem; end\n")
    assert Lyra::OptionalDependency.load("lyra_test_present_gem")
  end

  # The PetriFlow-without-rexml case: the gem is there, one of its own
  # dependencies is not. That must fail loudly, not read as "not installed".
  def test_an_installed_gem_with_a_missing_dependency_raises
    File.write(File.join(@dir, "lyra_test_broken_gem.rb"), %(require "lyra_test_missing_dependency"\n))
    error = assert_raises(LoadError) { Lyra::OptionalDependency.load("lyra_test_broken_gem") }
    assert_equal "lyra_test_missing_dependency", error.path
  end
end
