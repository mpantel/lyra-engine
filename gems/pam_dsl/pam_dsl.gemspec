require_relative "lib/pam_dsl/version"

Gem::Specification.new do |spec|
  spec.name        = "pam_dsl"
  spec.version     = PamDsl::VERSION
  spec.authors     = ["Michail Pantelelis"]
  spec.email       = ["mpantel@aegean.gr"]
  spec.homepage    = "https://github.com/mpantel/lyra-engine/gems/pam-dsl"
  spec.summary     = "Privacy Attribute Matrix (PAM) DSL for ORFEAS Framework"
  spec.description = "A declarative DSL for defining privacy policies, PII fields, consent requirements, and retention rules using the Privacy Attribute Matrix (PAM) model for privacy-aware event monitoring. Part of the ORFEAS (Object-Relational to Event-Sourcing Architecture) framework."
  spec.license     = "MIT"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "#{spec.homepage}/tree/main/gems/pam_dsl"
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/gems/pam_dsl/CHANGELOG.md"

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir["{lib}/**/*", "MIT-LICENSE", "Rakefile", "README.md"]
  end

  spec.require_paths = ["lib"]

  # Runtime dependencies
  spec.add_dependency "activesupport", ">= 6.0"

  # Development dependencies
  spec.add_development_dependency "minitest", "~> 5.0"
  spec.add_development_dependency "minitest-reporters", "~> 1.5"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "simplecov", "~> 0.22"
end
