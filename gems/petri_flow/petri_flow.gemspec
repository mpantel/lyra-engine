require_relative "lib/petri_flow/version"

Gem::Specification.new do |spec|
  spec.name        = "orfeas_petri_flow"
  spec.version     = PetriFlow::VERSION
  spec.authors     = ["Michail Pantelelis"]
  spec.email       = ["mpantel@aegean.gr"]
  spec.homepage    = "https://github.com/mpantel/lyra-engine/gems/petri-flow"
  spec.summary     = "Petri Net and Matrix Analysis for ORFEAS Framework"
  spec.description = "A comprehensive gem for Petri net modeling, colored Petri nets, matrix analysis, visualization, and formal verification for event sourcing and CRUD-to-Event mapping analysis. Part of the ORFEAS (Object-Relational to Event-Sourcing Architecture) framework."
  spec.license     = "MIT"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "#{spec.homepage}/tree/main/gems/petri_flow"
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/gems/petri_flow/CHANGELOG.md"

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir["{lib}/**/*", "MIT-LICENSE", "Rakefile", "README.md", "CHANGELOG.md"]
  end

  spec.require_paths = ["lib"]

  # Runtime dependencies
  spec.add_dependency "activesupport", ">= 6.0"
  spec.add_dependency "matrix", "~> 0.4"  # For matrix operations
  spec.add_dependency "rexml", "~> 3.2"  # PNML / CPN Tools export; not a default gem since Ruby 3.4

  # Development dependencies
  spec.add_development_dependency "minitest", "~> 5.0"
  spec.add_development_dependency "minitest-reporters", "~> 1.5"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "simplecov", "~> 0.22"
end
