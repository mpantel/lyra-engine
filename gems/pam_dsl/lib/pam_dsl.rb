require "active_support"
require "active_support/core_ext"

require_relative "pam_dsl/version"
require_relative "pam_dsl/pii_detector"
require_relative "pam_dsl/pii_masker"
require_relative "pam_dsl/gdpr_compliance"
require_relative "pam_dsl/field"
require_relative "pam_dsl/purpose"
require_relative "pam_dsl/retention"
require_relative "pam_dsl/consent"
require_relative "pam_dsl/policy"
require_relative "pam_dsl/registry"
require_relative "pam_dsl/reporter"
require_relative "pam_dsl/policy_generator"
require_relative "pam_dsl/policy_comparator"

# Load Rails integration if Rails is available
require_relative "pam_dsl/railtie" if defined?(Rails::Railtie)

module PamDsl
  class Error < StandardError; end
  class PolicyNotFoundError < Error; end
  class InvalidFieldError < Error; end
  class ConsentRequiredError < Error; end

  class << self
    # Rails configuration (set by Railtie)
    attr_accessor :rails_config

    # Global registry for policies
    def registry
      @registry ||= Registry.new
    end

    # Define a privacy policy using block DSL
    def define_policy(name, &block)
      policy = Policy.new(name)
      policy.instance_eval(&block)
      registry.register(name, policy)
      policy
    end

    # Get a defined policy
    def policy(name)
      registry.get(name) || raise(PolicyNotFoundError, "Policy '#{name}' not found")
    end

    # Reset all policies (useful for testing)
    def reset!
      @registry = Registry.new
    end

    # Convenience method to create a reporter
    def reporter(policy_name = nil, **options)
      policy_name ||= rails_config&.default_policy || registry.policies.keys.first
      raise PolicyNotFoundError, "No policy defined" unless policy_name

      Reporter.new(
        policy_name,
        organization: options[:organization] || rails_config&.organization,
        dpo_contact: options[:dpo_contact] || rails_config&.dpo_contact,
        event_store: options[:event_store]
      )
    end
  end
end
