source "https://rubygems.org"

# Specify your gem's dependencies in lyra.gemspec
gemspec

# Local gems in monorepo (orfeas_ prefix for RubyGems publication)
gem "orfeas_pam_dsl", path: "gems/pam_dsl"
gem "orfeas_petri_flow", path: "gems/petri_flow"

group :development, :test do
  gem "rspec", "~> 3.0"
  gem "rspec-rails"
  gem "factory_bot_rails"
  gem "sqlite3"
  gem "solid_cache"  # PostgreSQL/SQLite-backed caching for projection tests
  gem "simplecov", require: false
  gem "rexml"  # Required for PetriFlow PNML export
  gem "rails-controller-testing"  # For assigns and assert_template in controller tests
  gem "csv"  # Required for Ruby 3.4+ (moved from stdlib to bundled gem)
  gem "ostruct"  # Required for Ruby 3.4+ (moved from stdlib to bundled gem)
end

group :development do
  gem "rake"
  gem "rubocop"
end
