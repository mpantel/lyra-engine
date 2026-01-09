# SimpleCov must be started before loading any code
require "simplecov"
SimpleCov.start do
  add_filter "/test/"
  add_group "Core", ["lib/pam_dsl/field.rb", "lib/pam_dsl/purpose.rb", "lib/pam_dsl/policy.rb"]
  add_group "Privacy", ["lib/pam_dsl/retention.rb", "lib/pam_dsl/consent.rb"]
  add_group "Tools", ["lib/pam_dsl/reporter.rb", "lib/pam_dsl/policy_generator.rb", "lib/pam_dsl/policy_comparator.rb"]
  add_group "Infrastructure", ["lib/pam_dsl/registry.rb", "lib/pam_dsl/railtie.rb"]

  enable_coverage :branch
  minimum_coverage line: 85, branch: 55
end

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "pam_dsl"

require "minitest/autorun"
require "minitest/reporters"

Minitest::Reporters.use! [
  Minitest::Reporters::SpecReporter.new,
  Minitest::Reporters::JUnitReporter.new
]
