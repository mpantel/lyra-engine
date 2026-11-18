# frozen_string_literal: true

require "test_helper"

# Lyra::Rights::ConsentStore (PamDsl.consent_store): what the rights store
# tests leave out. A grant repeated with the same times records nothing; a
# subject that names no one is refused; a concurrent append is retried, and
# given up after RETRIES; a transaction sees the consent it granted until it
# rolls back.
class ConsentStoreBranchesTest < Minitest::Test
  ANN = "Payer$7"

  def setup
    skip "Requires Rails and database" unless defined?(ActiveRecord::Base) && ActiveRecord::Base.connection.table_exists?(:users)
    skip "Requires pam_dsl" unless Lyra.pam_dsl_available?

    PamDsl.reset!
    PamDsl.logger = Logger.new(nil)
    LyraRightsIsolation.purge!
    @store = Lyra::Rights.consent_store
    @store.forget!
  end

  def teardown
    return unless defined?(PamDsl)

    LyraRightsIsolation.purge!
    @store&.forget!
    PamDsl.reset!
    PamDsl.logger = nil
  end

  def test_a_grant_repeated_with_the_same_times_records_nothing
    at = Time.current.change(usec: 0)
    @store.grant(purpose: :newsletter, subject: ANN, granted_at: at)
    @store.grant(purpose: :newsletter, subject: ANN, granted_at: at)
    assert_equal 1, @store.events_for(ANN).size

    @store.grant(purpose: :newsletter, subject: ANN, granted_at: at, expires_at: at + 1.year)
    assert_equal 2, @store.events_for(ANN).size, "a new expiry is a new grant"
    assert_in_delta (at + 1.year).to_f, @store.record_for(:newsletter, ANN).expires_at.to_f, 0.001
  end

  def test_consent_needs_a_subject_that_names_someone
    error = assert_raises(ArgumentError) { @store.grant(purpose: :newsletter, subject: "Payer$*") }
    assert_includes error.message, "names none"
    assert_nil @store.record_for(:newsletter, "Payer$*")
  end

  # Another process appended to the subject's stream after this one read it:
  # the append fails on the stream's version, and the change is made again
  # on what is there now.
  def test_a_concurrent_append_is_retried
    @store.request(purpose: :newsletter, subject: ANN)
    real = @store.events_for(ANN)
    @store.stubs(:events_for).with(ANN).returns([]).then.returns(real)

    record = @store.grant(purpose: :newsletter, subject: ANN)

    @store.unstub(:events_for)
    assert_equal :granted, record.state
    assert_equal %w[ConsentRequested ConsentGranted], @store.events_for(ANN).map { _1[:type] }
  end

  def test_it_gives_up_after_its_retries
    @store.request(purpose: :newsletter, subject: ANN)
    @store.stubs(:events_for).with(ANN).returns([])

    assert_raises(PamDsl::RightsConcurrencyError) { @store.grant(purpose: :newsletter, subject: ANN) }

    @store.unstub(:events_for)
    assert_equal %w[ConsentRequested], @store.events_for(ANN).map { _1[:type] }
    assert_equal :pending, @store.record_for(:newsletter, ANN).state
  end

  # Read afresh through the connection that granted it, while its
  # transaction is open; gone when the transaction rolls back.
  def test_a_transaction_sees_the_consent_it_granted_until_it_rolls_back
    refute @store.granted?(:newsletter, ANN)

    ActiveRecord::Base.transaction do
      @store.grant(purpose: :newsletter, subject: ANN)
      assert @store.granted?(:newsletter, ANN)
      raise ActiveRecord::Rollback
    end

    refute @store.granted?(:newsletter, ANN)
    assert_empty @store.events_for(ANN)
  end

  # The audit's view: one entry per purpose, with its history.
  def test_the_consent_audit_lists_each_purpose_with_its_history
    @store.request(purpose: :newsletter, subject: ANN)
    @store.grant(purpose: :newsletter, subject: ANN)
    @store.withdraw(purpose: :newsletter, subject: ANN)
    @store.grant(purpose: :survey, subject: ANN)

    audit = @store.consents_for(ANN).to_h { [_1[:purpose], _1] }

    newsletter = audit.fetch(:newsletter)
    assert_equal :withdrawn, newsletter[:state]
    assert_kind_of Time, newsletter[:requested_at]
    assert_kind_of Time, newsletter[:withdrawn_at]
    assert_equal %w[ConsentRequested ConsentGranted ConsentWithdrawn], newsletter[:history].map { _1[:type] }
    survey = audit.fetch(:survey)
    assert_equal [:granted, nil], survey.values_at(:state, :requested_at), "granted without a request"
  end
end
