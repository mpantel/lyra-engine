# frozen_string_literal: true

# PAM DSL Privacy Tasks
#
# These tasks are automatically loaded in Rails apps that include the pam_dsl gem.
# Configure via config/initializers/pam_dsl.rb

namespace :pam_dsl do
  namespace :report do
    desc "Generate full privacy compliance report"
    task full: :environment do
      reporter = build_reporter
      reporter.full_report
    end

    desc "Show PAM DSL policy summary"
    task policy: :environment do
      reporter = build_reporter
      reporter.policy_summary
    end

    desc "Analyze PII in event store (requires Lyra)"
    task pii: :environment do
      reporter = build_reporter
      reporter.pii_analysis
    end

    desc "Check retention compliance (requires Lyra)"
    task retention: :environment do
      reporter = build_reporter
      reporter.retention_check
    end

    desc "Show PII access patterns (requires Lyra)"
    task access_patterns: :environment do
      reporter = build_reporter
      reporter.access_patterns
    end

    desc "Generate GDPR Article 30 report"
    task article_30: :environment do
      reporter = build_reporter
      reporter.article_30_report
    end

    desc "Export privacy report to JSON"
    task :export, [:output_path] => :environment do |_t, args|
      output_path = args[:output_path] || "tmp/privacy_report_#{Time.current.strftime('%Y%m%d_%H%M%S')}.json"
      reporter = build_reporter
      reporter.export_json(output_path)
    end

    desc "Compare two policies and generate a report"
    task :compare, [:policy1, :policy2, :output_path] => :environment do |_t, args|
      policy1_name = args[:policy1]&.to_sym
      policy2_name = args[:policy2]&.to_sym

      unless policy1_name && policy2_name
        puts "Usage: rake pam_dsl:report:compare[policy1,policy2,output_path]"
        puts ""
        puts "Available policies:"
        PamDsl.registry.policies.keys.each { |name| puts "  - #{name}" }
        abort
      end

      output_path = args[:output_path] || "reports/policy_comparison.md"

      begin
        comparator = PamDsl::PolicyComparator.new(policy1_name, policy2_name)
        comparator.generate_report(output_path: output_path)
        puts "Comparison report written to: #{output_path}"
      rescue PamDsl::PolicyNotFoundError => e
        abort "Error: #{e.message}"
      end
    end

    def build_reporter
      config = Rails.application.config.pam_dsl

      policy_name = config.default_policy
      unless policy_name
        # Try to find any defined policy
        policy_name = PamDsl.registry.policies.keys.first
        if policy_name
          puts "Using policy: #{policy_name}"
        else
          abort "No PAM DSL policy found. Define one or set config.pam_dsl.default_policy"
        end
      end

      # Try to get Lyra's event store if available
      event_store = nil
      if defined?(Lyra) && Lyra.respond_to?(:event_store)
        event_store = Lyra.event_store
      end

      PamDsl::Reporter.new(
        policy_name,
        organization: config.organization,
        dpo_contact: config.dpo_contact,
        event_store: event_store
      )
    end
  end

  namespace :generate do
    desc "Generate a PAM DSL policy file with sensible defaults"
    task :policy, [:name] => :environment do |_t, args|
      name = args[:name] || "application"
      generator = PamDsl::PolicyGenerator.new(name)
      generator.generate
    end

    desc "Generate policy from existing ActiveRecord models"
    task :from_models, [:name] => :environment do |_t, args|
      name = args[:name] || "application"
      generator = PamDsl::PolicyGenerator.new(name)
      generator.generate_from_models
    end
  end
end

# Shorthand aliases
namespace :privacy do
  desc "Generate full privacy compliance report (alias for pam_dsl:report:full)"
  task report: "pam_dsl:report:full"

  desc "Show policy summary (alias for pam_dsl:report:policy)"
  task policy: "pam_dsl:report:policy"

  desc "Check retention compliance (alias for pam_dsl:report:retention)"
  task retention: "pam_dsl:report:retention"

  desc "Generate Article 30 report (alias for pam_dsl:report:article_30)"
  task article_30: "pam_dsl:report:article_30"

  desc "Export report to JSON (alias for pam_dsl:report:export)"
  task :export, [:output_path] => "pam_dsl:report:export"
end
