# SimpleCov must be started before loading any code
require "simplecov"
SimpleCov.start do
  add_filter "/test/"
  add_group "Core", "lib/petri_flow/core"
  add_group "Colored", "lib/petri_flow/colored"
  add_group "Simulation", "lib/petri_flow/simulation"
  add_group "Verification", "lib/petri_flow/verification"
  add_group "Matrix", "lib/petri_flow/matrix"
  add_group "Visualization", "lib/petri_flow/visualization"
  add_group "Export", "lib/petri_flow/export"
  add_group "Generators", "lib/petri_flow/generators"
  add_group "Rails Integration", %w[lib/petri_flow/workflow.rb lib/petri_flow/registry.rb lib/petri_flow/verification_runner.rb lib/petri_flow/railtie.rb]

  enable_coverage :branch
  minimum_coverage line: 80, branch: 50
end

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "petri_flow"

require "minitest/autorun"
require "minitest/reporters"

Minitest::Reporters.use! [
  Minitest::Reporters::SpecReporter.new,
  Minitest::Reporters::JUnitReporter.new
]
