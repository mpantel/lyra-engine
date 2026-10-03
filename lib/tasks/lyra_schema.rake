# frozen_string_literal: true

namespace :lyra do
  namespace :schema do
    desc "Generate initial event schema from current model configuration"
    task create: :environment do
      require_lyra_schema

      if Lyra::Schema::Store.exists?
        puts "Schema already exists at #{Lyra::Schema::Store.schema_path}"
        puts ""
        puts "Options:"
        puts "  - Run 'rake lyra:schema:update' to create a new version"
        puts "  - Run 'rake lyra:schema:verify' to check for changes"
        puts "  - Delete #{Lyra::Schema::Store.schema_path}/ to start fresh"
        exit 1
      end

      # Monitored models register as their classes load.
      Rails.application.eager_load! unless Rails.application.config.eager_load
      if Lyra.config.monitored_models.empty?
        puts "No models are configured for monitoring."
        puts "Configure models with Lyra.config.monitor_model(YourModel) first."
        exit 1
      end

      schema = Lyra::Schema::Generator.generate
      file_path = Lyra::Schema::Store.save(schema)

      puts ""
      puts "=" * 60
      puts "Lyra Event Schema Created"
      puts "=" * 60
      puts ""
      puts "Version:    v#{schema[:version]}"
      puts "File:       #{file_path}"
      puts "Models:     #{schema[:summary][:models_count]}"
      puts "Columns:    #{schema[:summary][:total_columns]}"
      puts "Events:     #{schema[:summary][:events_count]}"
      puts "PII Fields: #{schema[:summary][:pii_fields_count]}"
      puts ""
      puts "=" * 60
      puts ""
      puts "Next steps:"
      puts "  - Commit #{Lyra::Schema::Store.schema_path}/ to version control"
      puts "  - Run 'rake lyra:schema:report' to view mappings"
      puts ""
    end

    desc "Update schema (creates new version with current configuration)"
    task update: :environment do
      require_lyra_schema

      validator = Lyra::Schema::Validator.new

      unless validator.schema_exists?
        puts "No existing schema found."
        puts "Run 'rake lyra:schema:create' first."
        exit 1
      end

      if validator.valid?
        puts "No changes detected. Schema is up to date."
        puts ""
        puts "Current version: v#{Lyra::Schema::Store.latest_version}"
        puts "Fingerprint: #{Lyra::Schema::Store.load_current[:fingerprint]}"
        exit 0
      end

      puts validator.report
      puts ""

      print "Create new schema version? [y/N] "
      response = $stdin.gets&.chomp&.downcase

      unless response == "y"
        puts "Aborted."
        exit 0
      end

      schema = Lyra::Schema::Generator.generate
      file_path = Lyra::Schema::Store.save(schema)

      puts ""
      puts "New schema version created!"
      puts "Version: v#{schema[:version]}"
      puts "File: #{file_path}"
      puts ""
      puts "Don't forget to commit the new schema file."
    end

    desc "Verify current schema against stored schema"
    task verify: :environment do
      require_lyra_schema

      validator = Lyra::Schema::Validator.new

      unless validator.schema_exists?
        puts "No schema found."
        puts ""
        puts "Run 'rake lyra:schema:create' to generate initial schema."
        exit 1
      end

      if validator.valid?
        current = Lyra::Schema::Store.load_current
        puts "Schema verification PASSED"
        puts ""
        puts "Version:     v#{current[:version]}"
        puts "Fingerprint: #{current[:fingerprint]}"
        puts "No changes detected."
        exit 0
      else
        puts validator.report
        puts ""

        if validator.breaking_changes?
          puts "VERIFICATION FAILED: Breaking changes detected!"
          puts ""
          puts "To resolve:"
          puts "  1. Run 'rake lyra:schema:update' to create a new version"
          puts "  2. Or revert the model/database changes"
          exit 1
        else
          puts "Non-breaking changes detected."
          puts "Consider running 'rake lyra:schema:update' to update the schema."
          exit 0
        end
      end
    end

    desc "Display current schema report (model->event mappings)"
    task report: :environment do
      require_lyra_schema

      # Monitored models register as their classes load.
      Rails.application.eager_load! unless Rails.application.config.eager_load
      if Lyra.config.monitored_models.empty?
        puts "No models are configured for monitoring."
        puts "Configure models with Lyra.config.monitor_model(YourModel) first."
        exit 1
      end

      reporter = Lyra::Schema::Reporter.new
      puts reporter.to_s
    end

    desc "Show schema version history"
    task history: :environment do
      require_lyra_schema

      history = Lyra::Schema::Store.history

      if history.empty?
        puts "No schema versions found."
        puts ""
        puts "Run 'rake lyra:schema:create' to generate initial schema."
        exit 0
      end

      puts ""
      puts "=" * 80
      puts "Lyra Schema Version History"
      puts "=" * 80
      puts ""
      puts "%-10s %-25s %-15s %-10s %-20s" % ["Version", "Created At", "Lyra Version", "Models", "File"]
      puts "-" * 80

      history.each do |h|
        puts "%-10s %-25s %-15s %-10s %-20s" % [
          "v#{h[:version]}",
          h[:created_at],
          h[:lyra_version],
          h[:models_count],
          h[:file]
        ]
      end

      puts "-" * 80
      puts ""
      puts "Current version: v#{Lyra::Schema::Store.latest_version}"
      puts "Schema path: #{Lyra::Schema::Store.schema_path}"
      puts ""
    end

    desc "Compare two schema versions"
    task :diff, [:v1, :v2] => :environment do |_t, args|
      require_lyra_schema

      v1 = args[:v1]&.to_i
      v2 = args[:v2]&.to_i || Lyra::Schema::Store.latest_version

      unless v1
        puts "Usage: rake lyra:schema:diff[v1,v2]"
        puts "Example: rake lyra:schema:diff[1,2]"
        puts "         rake lyra:schema:diff[1]  (compare v1 to latest)"
        exit 1
      end

      schema1 = Lyra::Schema::Store.load_version(v1)
      schema2 = Lyra::Schema::Store.load_version(v2)

      unless schema1
        puts "Could not load schema version #{v1}"
        exit 1
      end

      unless schema2
        puts "Could not load schema version #{v2}"
        exit 1
      end

      puts ""
      puts "=" * 60
      puts "Comparing v#{v1} -> v#{v2}"
      puts "=" * 60
      puts ""

      differences = Lyra::Schema::Diff.compare(schema1, schema2)
      report = Lyra::Schema::Diff.format_report(differences)

      puts report
    end

    private

    def require_lyra_schema
      require "lyra/schema/store"
      require "lyra/schema/generator"
      require "lyra/schema/diff"
      require "lyra/schema/validator"
      require "lyra/schema/reporter"
    end
  end
end
