# frozen_string_literal: true

require "test_helper"
require "rbconfig"

# PetriFlow is optional. app/workflows/*.rb subclass PetriFlow::Workflow, so
# eager loading the application without the gem (production boot, and the
# rake tasks that eager-load: lyra:mode:*, lyra:repair, lyra:schema:*) raised
# NameError. Without PetriFlow, Lyra::Engine leaves app/workflows to neither
# autoload nor eager load. LYRA_DISABLE_PETRI_FLOW=true runs Lyra as without
# the gem, in a subprocess so this process keeps PetriFlow.
class LyraWithoutPetriFlowTest < Minitest::Test
  DUMMY = File.expand_path("../dummy", __dir__)

  def setup
    skip "Requires the dummy Rails app" unless defined?(Lyra::Engine)
  end

  def test_the_application_eager_loads_without_petri_flow
    script = <<~RUBY
      require "./config/environment"
      Rails.application.eager_load!
      puts "available=\#{Lyra.petri_flow_available?}"
      puts "workflow=\#{defined?(EsSyncModeWorkflow).inspect}"
    RUBY
    # IO.popen, not Open3: under SimpleCov, Open3 made the test process print
    # a spurious coverage failure.
    out = IO.popen({ "LYRA_DISABLE_PETRI_FLOW" => "true" }, [RbConfig.ruby, "-e", script],
                   chdir: DUMMY, err: %i[child out], &:read)

    assert $?.success?, "eager load failed without PetriFlow:\n#{out.lines.grep_v(/warning:/).first(5).join}"
    assert_includes out, "available=false"
    assert_includes out, "workflow=nil", "app/workflows was not loaded"
  end

  def test_with_petri_flow_the_workflows_are_loadable
    skip "PetriFlow not installed" unless Lyra.petri_flow_available?

    assert Lyra::Engine.workflows_loadable?
    assert_operator EsSyncModeWorkflow, :<, PetriFlow::Workflow
  end
end
