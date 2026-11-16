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
require_relative "pam_dsl/subject_access"
require_relative "pam_dsl/field"
require_relative "pam_dsl/purpose"
require_relative "pam_dsl/retention"
require_relative "pam_dsl/duration_format"
require_relative "pam_dsl/consent"
require_relative "pam_dsl/enforcement"
require_relative "pam_dsl/rights"
require_relative "pam_dsl/rights_store"
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
  # A consent construct the Regulation does not allow, or one PAM does not enforce (granular!).
  class ConsentGrammarError < Error; end
  # Access under a purpose whose legal basis the controller has not yet decided.
  class UndeterminedBasisError < Error; end
  # Condition 5: a purpose reads a special-category (Art. 9) field without an
  # Art. 9(2) basis. Special category is decided by the field type; sensitivity
  # is a separate Art. 32 risk tier that gates nothing.
  class SpecialCategoryViolationError < Error; end
  # Deprecated alias, kept so that existing rescue clauses still work; removed in 2.0.
  SensitivityViolationError = SpecialCategoryViolationError
  deprecate_constant :SensitivityViolationError
  # A purpose reads Art. 10 data (criminal convictions and offences) without
  # declaring the official authority or the Union or Member State law that
  # authorises it (Purpose#art10_authorisation). An Art. 9(2) basis does not
  # satisfy Art. 10.
  class CriminalDataViolationError < Error; end
  # Condition 6 (Art. 18): the subject's processing is restricted, the
  # restriction covers the access, and the purpose declares no Art. 18(2)
  # exception that applies.
  class RestrictedProcessingError < Error; end
  # Condition 6 (Art. 21): the subject objected to the purpose and the
  # objection was upheld.
  class ObjectedProcessingError < Error; end
  # object! on a purpose that gives no right to object. The rejection is
  # recorded first; the message is the reason to give the subject.
  class ObjectionNotApplicableError < Error; end
  # A rights transition the state does not allow: a lift without the
  # Art. 18(3) notice, a decision on an objection already decided, ...
  class RightsTransitionError < Error; end
  # The rights store is not durable and a durable one is required
  # (PamDsl.require_durable_rights_store).
  class RightsStoreNotDurableError < Error; end
  # The subject's rights changed between reading them and recording a
  # transition (another process got there first).
  class RightsConcurrencyError < Error; end

  # Class used to recognise duration values in case/when: ActiveSupport::Duration
  # when ActiveSupport is loaded, otherwise plain Numeric (the polyfill represents
  # durations as an integer number of seconds).
  DURATION_CLASS = defined?(ActiveSupport::Duration) ? ActiveSupport::Duration : Numeric

  # Guards the lazy creation of the rights store and ledger.
  RIGHTS_LOCK = Mutex.new

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
      policy.validate_consent_grammar!
      registry.register(name, policy)
      policy
    end

    # Get a defined policy
    def policy(name)
      registry.get(name) || raise(PolicyNotFoundError, "Policy '#{name}' not found")
    end

    # Reset all policies, the enforcement mode, the violation and rights
    # event handlers, and the in-memory rights store (useful for testing)
    def reset!
      @registry = Registry.new
      @enforcement_mode = nil
      @violation_handlers = nil
      @rights_event_handlers = nil
      # The default memory store is test state, and goes; a store the host
      # installed (Lyra's durable one, or a memory store set on purpose)
      # stays, as the access recorder does.
      RIGHTS_LOCK.synchronize { @rights_store = nil if @rights_store_is_default }
    end

    # ── Arts. 18 and 21: the subject's rights (see PamDsl::Rights) ──

    # The rights API: restrict!, notify_lift!, lift!, object!, decide!,
    # withdraw_objection!, find, state, open_requests.
    def rights
      @rights || RIGHTS_LOCK.synchronize { @rights ||= Rights::Ledger.new }
    end

    # Where the rights are recorded (see RightsStore for the protocol). The
    # default, created on first use, is a RightsStore::Memory; a host
    # installs a durable one.
    def rights_store
      @rights_store || RIGHTS_LOCK.synchronize do
        @rights_store ||= begin
          @rights_store_is_default = true
          RightsStore::Memory.new
        end
      end
    end

    # Install a rights store (nil returns to the default).
    def rights_store=(store)
      RIGHTS_LOCK.synchronize do
        @rights_store_is_default = false
        @rights_store = store
      end
    end

    # When true, a store that is not durable refuses to record a right
    # (RightsStoreNotDurableError). Off by default; under Rails the railtie
    # turns it on outside development and test, unless
    # config.pam_dsl.require_durable_rights_store says otherwise.
    attr_accessor :require_durable_rights_store

    # Maps a subject to the keys its rights are recorded under: an object
    # answering call(subject) with an array of keys, or nil to use the
    # default. Lyra installs one that maps a record to its own key and to
    # the keys of the people it names. PamDsl.reset! leaves it in place.
    attr_accessor :subject_key_resolver

    # The keys Condition 6 looks up for a subject, and the first of which a
    # right is recorded under. Without a resolver (or when it answers nil):
    # a non-empty String, Symbol or Integer is its own key (7 and "7" are
    # one key), nil and a model-wide subject ("Model$*") have none, and any
    # other object raises ArgumentError (see Rights.default_subject_keys).
    def subject_keys(subject)
      keys = subject_key_resolver&.call(subject)
      return Rights.default_subject_keys(subject) if keys.nil?

      Array(keys).map(&:to_s).reject { |key| key.strip.empty? || key.end_with?("$*") }
    end

    # Register a handler called with each Rights::Event after it is
    # recorded (to notify the subject, or the recipients Art. 19 names).
    # Every handler is called with every event of a transition even when
    # one raises; then the first error is raised (the others are logged).
    # The events stay recorded, and repeating object! returns the objection
    # recorded rather than recording another.
    def on_rights_event(&handler)
      rights_event_handlers << handler
      handler
    end

    def rights_event_handlers
      @rights_event_handlers ||= []
    end

    # Convenience method to create a reporter
    def reporter(policy_name = nil, **options)
      policy_name ||= rails_config&.default_policy || registry.policies.keys.first
      raise PolicyNotFoundError, "No policy defined" unless policy_name

      Reporter.new(
        policy_name,
        organization: options[:organization] || rails_config&.organization,
        dpo_contact: options[:dpo_contact] || rails_config&.dpo_contact,
        event_store: options[:event_store],
        output: options[:output]
      )
    end
  end
end
