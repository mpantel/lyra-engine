require_relative "lib/pam_dsl/version"

Gem::Specification.new do |spec|
  spec.name        = "orfeas_pam_dsl"
  spec.version     = PamDsl::VERSION
  spec.authors     = ["Michail Pantelelis"]
  spec.email       = ["mpantel@aegean.gr"]
  spec.homepage    = "https://github.com/mpantel/lyra-engine/tree/main/gems/pam_dsl"
  spec.summary     = "Privacy Attribute Matrix (PAM) DSL for ORFEAS Framework"
  spec.description = "A declarative DSL for defining privacy policies, PII fields, consent requirements, and retention rules using the Privacy Attribute Matrix (PAM) model for privacy-aware event monitoring. Part of the ORFEAS (Object-Relational to Event-Sourcing Architecture) framework."
  spec.license     = "MIT"
  spec.required_ruby_version = ">= 4.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "https://github.com/mpantel/lyra-engine/blob/main/gems/pam_dsl/CHANGELOG.md"

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir["{lib}/**/*", "MIT-LICENSE", "Rakefile", "README.md", "CHANGELOG.md"]
  end

  spec.require_paths = ["lib"]

  # Runtime dependencies: none. ActiveSupport is used when present (e.g. in Rails
  # apps) but is optional --- lib/pam_dsl/core_ext.rb provides a stdlib polyfill
  # when it is absent, so the gem is self-contained. It is kept as a development
  # dependency so the ActiveSupport code path is exercised by the test suite.

  # Development dependencies
  spec.add_development_dependency "activesupport", ">= 6.0"
  spec.add_development_dependency "minitest", "~> 5.0"
  spec.add_development_dependency "minitest-reporters", "~> 1.5"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "simplecov", "~> 0.22"
end
