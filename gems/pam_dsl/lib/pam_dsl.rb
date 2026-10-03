# ActiveSupport provides convenience helpers (Numeric durations, Time.current,
# String#underscore, Object#present?). It is optional: when it is not installed
# (e.g. pam_dsl used standalone, outside Rails) a minimal standard-library
# polyfill is loaded instead. See pam_dsl/core_ext.rb.
#
# Set PAM_DSL_FORCE_POLYFILL to load the polyfill even when ActiveSupport is
# available --- used by the test suite to exercise both code paths.
if ENV["PAM_DSL_FORCE_POLYFILL"]
  require_relative "pam_dsl/core_ext"
else
  begin
    require "active_support"
    require "active_support/core_ext"
  rescue LoadError
    require_relative "pam_dsl/core_ext"
  end
end

require_relative "pam_dsl/version"
require_relative "pam_dsl/pii_detector"
require_relative "pam_dsl/pii_masker"
require_relative "pam_dsl/gdpr_compliance"
require_relative "pam_dsl/field"
require_relative "pam_dsl/purpose"
require_relative "pam_dsl/retention"
require_relative "pam_dsl/consent"
require_relative "pam_dsl/enforcement"
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
  class UndeclaredPurposeError < Error; end
  class PurposeFieldMismatchError < Error; end
  class ConsentRequiredError < Error; end
  class SensitivityViolationError < Error; end

  # Class used to recognise duration values in case/when: ActiveSupport::Duration
  # when ActiveSupport is loaded, otherwise plain Numeric (the polyfill represents
  # durations as an integer number of seconds).
  DURATION_CLASS = defined?(ActiveSupport::Duration) ? ActiveSupport::Duration : Numeric

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

    # Reset all policies, the enforcement mode and the violation handlers
    # (useful for testing)
    def reset!
      @registry = Registry.new
      @enforcement_mode = nil
      @violation_handlers = nil
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
