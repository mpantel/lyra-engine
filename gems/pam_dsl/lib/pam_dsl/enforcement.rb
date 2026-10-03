# frozen_string_literal: true

require "logger"

module PamDsl
  # What happens when an access fails validation (Policy#validate_access!).
  #
  # - :strict (the default) blocks it: the first violation is raised as its
  #   typed exception (UndeclaredPurposeError, InvalidFieldError,
  #   PurposeFieldMismatchError, ConsentRequiredError,
  #   SensitivityViolationError).
  # - :audit lets it through and records every violation found, not only
  #   the first: each is logged and passed to the on_violation handlers, and
  #   validate_access! returns false. Audit mode is for introducing a policy
  #   to a running system, to see what it would block before it blocks
  #   anything.
  #
  # The mode is global (PamDsl.enforcement_mode) and can be overridden per
  # policy (`enforcement :audit` in its definition).
  module Enforcement
    MODES = %i[strict audit].freeze

    # One failed access, as recorded in audit mode.
    Violation = Struct.new(:policy, :purpose, :fields, :subject, :error_class, :message, :at, keyword_init: true) do
      def to_s
        "PAM #{error_class.name.split('::').last} (policy #{policy}, purpose #{purpose}, " \
          "fields #{Array(fields).join(', ')}, subject #{subject.inspect}): #{message}"
      end
    end

    # One validated access, as passed to PamDsl.access_recorder: the
    # outcome is :granted (no violation), :audited (violations, let through
    # in audit mode) or :denied (strict mode, about to raise). +violations+
    # holds the errors found, in the order validation checks them.
    Access = Struct.new(:policy, :purpose, :legal_basis, :fields, :subject, :outcome, :violations, :at,
                        keyword_init: true)

    def self.validate_mode!(mode)
      mode = mode&.to_sym
      return mode if MODES.include?(mode)

      raise ArgumentError, "Unknown enforcement mode #{mode.inspect}. Must be one of: #{MODES.join(', ')}"
    end
  end

  class << self
    # Global enforcement mode: :strict (default) or :audit. See Enforcement.
    def enforcement_mode
      @enforcement_mode || :strict
    end

    def enforcement_mode=(mode)
      @enforcement_mode = Enforcement.validate_mode!(mode)
    end

    # Register a handler called with each Enforcement::Violation recorded in
    # audit mode (to store it, publish it as an event, count it, ...).
    def on_violation(&handler)
      violation_handlers << handler
      handler
    end

    def violation_handlers
      @violation_handlers ||= []
    end

    # Where audit-mode violations are logged: Rails.logger under Rails,
    # standard error otherwise.
    def logger
      @logger ||= (defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger) || Logger.new($stderr)
    end

    attr_writer :logger

    def report_violation(violation)
      logger.warn(violation.to_s)
      violation_handlers.each { |handler| handler.call(violation) }
    end

    # Records every validate_access! call, whatever its outcome: an object
    # answering record?(policy) and call(access), passed an
    # Enforcement::Access. It runs before validate_access! returns or
    # raises, and an error it raises propagates, so an access it cannot
    # record does not go ahead. One recorder per process, set by the host
    # (Lyra's access log); PamDsl.reset! leaves it in place.
    attr_accessor :access_recorder

    def record_access(policy, field_names, purpose_name, subject, violations)
      recorder = access_recorder
      return unless recorder&.record?(policy)

      outcome = if violations.empty? then :granted
                elsif policy.enforcement_mode == :strict then :denied
                else :audited
                end
      purpose = policy.purposes[purpose_name.to_sym]
      recorder.call(Enforcement::Access.new(
        policy: policy.name, purpose: purpose_name.to_sym, legal_basis: purpose&.legal_basis,
        fields: Array(field_names).map(&:to_sym), subject: subject, outcome: outcome,
        violations: violations, at: Time.now
      ))
    end
  end
end
