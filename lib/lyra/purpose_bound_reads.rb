# frozen_string_literal: true

module Lyra
  # A read of a model with a privacy policy, made for a declared purpose, is
  # checked against the policy: every declared attribute the query loaded
  # must be allowed for that purpose (Def. 1, through the policy's
  # validate_access!, with the record as the subject). Loading a declared
  # attribute the purpose does not need is refused, as data minimisation
  # (Art. 5(1)(c)) asks: select what the purpose needs. With the access log
  # on (config.record_access_events), each checked read is recorded.
  #
  # The policy decides which attributes are checked; the purpose comes from
  # where the read is made:
  #
  #   Lyra.with_purpose(:invoicing) { Registration.select(:id, :vat_number, :address).find(id) }
  #
  #   class PaymentsController < ApplicationController
  #     lyra_purpose :payment_processing                  # around every action
  #     lyra_purpose :invoicing, only: :invoice
  #   end
  #
  #   class ExportJob < ApplicationJob
  #     lyra_purpose :audit_trail
  #   end
  #
  # No configuration turns it on: any monitored model with a policy is
  # checked wherever a purpose is in scope. A read with no purpose follows
  # config.reads_without_purpose: :allow (the default; nothing breaks when a
  # policy is added), :audit (allowed, logged, and recorded as an audited
  # access when the access log is on), or :deny (refused with
  # PurposeRequiredError: privacy by default, once every read path declares
  # its purpose).
  #
  # What the policy enforces on a violation is its enforcement mode: strict
  # raises the policy error from the read, audit logs it and lets the read
  # through.
  #
  # Lyra's own reads (projections, bypass-event snapshots, Genesis, DualView,
  # mode checks, repair, erasure) are not data processing for a purpose and
  # are not checked. Reads that load no model (pluck, select_value, raw SQL)
  # are not checked either.
  module PurposeBoundReads
    MODES = %i[allow audit deny].freeze

    class PurposeRequiredError < StandardError; end

    class << self
      def current
        Thread.current[:lyra_purpose]
      end

      def with_purpose(purpose)
        previous = Thread.current[:lyra_purpose]
        Thread.current[:lyra_purpose] = purpose&.to_sym
        yield
      ensure
        Thread.current[:lyra_purpose] = previous
      end

      # Lyra's own reads, not checked.
      def internal
        previous = Thread.current[:lyra_internal_read]
        Thread.current[:lyra_internal_read] = true
        yield
      ensure
        Thread.current[:lyra_internal_read] = previous
      end

      # after_find on monitored models.
      def check(record)
        purpose = current
        return if purpose.nil? && Lyra.config.reads_without_purpose == :allow
        return if Thread.current[:lyra_internal_read] || Thread.current[:lyra_projection_write]
        return if Lyra.config.disabled_mode?

        policy = Lyra::Privacy.policy_for(record.class)
        return unless policy.loaded?

        fields = loaded_declared_fields(record, policy)
        return if fields.empty?

        if purpose
          policy.validate_access!(fields, purpose, subject: record)
        else
          without_purpose(record, policy, fields)
        end
      end

      def validate_mode!(mode)
        mode = mode&.to_sym
        return mode if MODES.include?(mode)

        raise ArgumentError, "Unknown reads_without_purpose #{mode.inspect}. Must be one of: #{MODES.join(', ')}"
      end

      private

      def loaded_declared_fields(record, policy)
        declared = policy.declared_fields.map(&:to_s)
        (record.attribute_names & declared).map(&:to_sym)
      end

      def without_purpose(record, policy, fields)
        error = PurposeRequiredError.new(
          "#{record.class.name} #{record.id}: read of #{fields.join(', ')} with no declared purpose " \
          "(Lyra.with_purpose or lyra_purpose)"
        )
        denied = Lyra.config.reads_without_purpose == :deny
        record_access(policy, fields, record, denied ? :denied : :audited, error)
        raise error if denied

        Rails.logger.warn("Lyra: #{error.message}")
      end

      def record_access(policy, fields, record, outcome, error)
        return unless defined?(Lyra::AccessLog) && defined?(PamDsl::Enforcement::Access)
        return unless Lyra::AccessLog.record?(policy)

        Lyra::AccessLog.call(PamDsl::Enforcement::Access.new(
          policy: policy.name, purpose: :none, legal_basis: nil, fields: fields, subject: record,
          outcome: outcome, violations: [error], at: Time.now
        ))
      end
    end

    # lyra_purpose for controllers (around_action) and jobs (around_perform).
    module ControllerMethods
      def lyra_purpose(purpose, **options)
        around_action(**options) { |_controller, action| Lyra.with_purpose(purpose, &action) }
      end
    end

    module JobMethods
      def lyra_purpose(purpose)
        around_perform { |_job, block| Lyra.with_purpose(purpose, &block) }
      end
    end
  end

  def self.with_purpose(purpose, &block) = PurposeBoundReads.with_purpose(purpose, &block)
end

if defined?(ActiveSupport)
  ActiveSupport.on_load(:action_controller) { extend Lyra::PurposeBoundReads::ControllerMethods }
  ActiveSupport.on_load(:active_job) { extend Lyra::PurposeBoundReads::JobMethods }
end
