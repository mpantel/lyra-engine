require_relative "lib/lyra/version"

Gem::Specification.new do |spec|
  spec.name        = "lyra"
  spec.version     = Lyra::VERSION
  spec.authors     = ["Michail Pantelelis"]
  spec.email       = ["mpantel@aegean.gr"]
  spec.homepage = "https://github.com/mpantel/lyra-engine"
  spec.summary     = "CRUD to Event Sourcing transformation engine"
  spec.description = "Non-intrusive Rails engine for monitoring CRUD operations and transforming them to event sourcing"
  spec.license     = "MIT"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir["{app,config,db,lib}/**/*", "MIT-LICENSE", "Rakefile", "README.md"]
  end

  spec.require_paths = ["lib"]

  spec.required_ruby_version = ">= 3.4.5"

  # Rails dependencies
  spec.add_dependency "rails", ">= 8.0"
  spec.add_dependency "rails_event_store", "~> 2.0"

  # Database dependencies
  spec.add_dependency "pg", "~> 1.0"

  # Development dependencies
  spec.add_development_dependency "sqlite3"
  spec.add_development_dependency "minitest", "~> 5.0"
  spec.add_development_dependency "minitest-reporters", "~> 1.5"
  spec.add_development_dependency "mocha", "~> 3.0"
end
