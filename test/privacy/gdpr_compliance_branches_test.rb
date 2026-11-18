# frozen_string_literal: true

require "test_helper"

# Lyra::Privacy::GDPRCompliance: the policy-based retention check over the
# events in the log, the retention periods it hands PAM DSL (a hash in
# config.retention_policy, a policy that cannot answer), PII detection by a
# policy, and the readers it gives PAM DSL applied to plain RubyEventStore
# events (string keys, a string operation, time in the metadata).
class GDPRComplianceBranchesTest < Minitest::Test
  def setup
    skip "Requires pam_dsl" unless Lyra.pam_dsl_available?

    @previous_store = Lyra.config.event_store
    @previous_retention = Lyra.config.retention_policy
    Lyra.config.event_store = RubyEventStore::Client.new(repository: RubyEventStore::InMemoryRepository.new)
    PamDsl.define_policy(:gdpr_branches_policy) do
      field :email, type: :email, sensitivity: :internal
      field :diagnosis, type: :health
      retention do
        default nil # kept until removed by hand
        for_model("Invoice") { keep_for 30.days }
      end
    end
    @compliance = Lyra::Privacy::GDPRCompliance.new(subject_id: 7, subject_type: "User")
  end

  def teardown
    return unless defined?(PamDsl)

    Lyra.config.event_store = @previous_store
    Lyra.config.retention_policy = @previous_retention
    PamDsl.reset!
  end

  # Each model's events against its period: expired ones by id, a model the
  # policy keeps for no period is :manual.
  def test_the_policy_retention_check_counts_expired_events_per_model
    old = publish("Invoice", 1, at: 40.days.ago)
    publish("Invoice", 2, at: 10.days.ago)
    publish("Note", 3, at: 400.days.ago)

    report = @compliance.retention_compliance_with_policy(:gdpr_branches_policy).to_h { [_1[:model_class], _1] }

    invoice = report.fetch("Invoice")
    assert_equal [2, 1, :requires_action, [old.event_id]],
                 invoice.values_at(:total_events, :expired_events, :compliance_status, :expired_event_ids)
    assert_equal 30.days, invoice[:retention_period]
    note = report.fetch("Note")
    assert_equal [1, 0, :manual, nil], note.values_at(:total_events, :expired_events, :compliance_status, :retention_period)
  end

  def test_events_within_their_period_are_compliant
    publish("Invoice", 1, at: 1.day.ago)

    report = @compliance.retention_compliance_with_policy(:gdpr_branches_policy).sole

    assert_equal [:compliant, []], report.values_at(:compliance_status, :expired_event_ids)
  end

  # config.retention_policy as a hash: a period per model, a Duration or a
  # hash with it.
  def test_a_configured_retention_hash_is_kept_per_model
    Lyra.config.retention_policy = { "Invoice" => 5.years, default: { duration: 2.years } }

    policy = Lyra::Privacy::GDPRCompliance.new(subject_id: 7).send(:retention_policy)

    assert_equal({ duration: 5.years }, policy["Invoice"])
    assert_equal({ duration: 2.years }, policy[:default])
  end

  # A monitored model whose policy cannot answer is left to the configured
  # periods, and the others are still read.
  def test_a_policy_that_cannot_answer_is_skipped
    broken = Struct.new(:name).new("Broken")
    fine = Struct.new(:name).new("Fine")
    Lyra.config.retention_policy = 1.year
    Lyra.config.stubs(:monitored_models).returns([broken, fine])
    Lyra::Privacy.stubs(:policy_for).with(broken).raises(ArgumentError, "no policy")
    Lyra::Privacy.stubs(:policy_for).with(fine).returns(stub(retention_for: 3.days))

    policy = Lyra::Privacy::GDPRCompliance.new(subject_id: 7).send(:retention_policy)

    assert_equal({ default: { duration: 1.year }, "Fine" => { duration: 3.days } }, policy)
  end

  # The policy's own field annotations first; the detector for the rest
  # unless it is turned off.
  def test_pii_is_detected_by_the_policy_then_the_detector
    attributes = { "email" => "a@example.com", "diagnosis" => "flu", "phone" => "+30 210 1234567", "title" => "x" }

    with_detector = @compliance.detect_pii_with_policy(attributes, :gdpr_branches_policy)
    without = @compliance.detect_pii_with_policy(attributes, :gdpr_branches_policy, use_detector: false)

    assert_equal [:email, :policy], with_detector["email"].values_at(:type, :source)
    assert_equal [:health, :policy], with_detector["diagnosis"].values_at(:type, :source)
    assert_equal :detector, with_detector["phone"][:source]
    refute with_detector.key?("title")
    assert_equal %w[diagnosis email], without.keys.sort
  end

  # Plain events (no Lyra::Event readers) are read from their data, as
  # Lyra's own: the subject's export finds the subject's record and its
  # update, with the update's changes.
  def test_plain_events_are_read_from_their_data
    created = RubyEventStore::Event.new(
      data: { "model_class" => "User", "model_id" => 7, "operation" => "created", "attributes" => { "email" => "a@example.com" } }
    )
    updated = RubyEventStore::Event.new(
      data: { "model_class" => "User", "model_id" => 7, "operation" => "updated",
              "changes" => { "email" => ["a@example.com", "b@example.com"] } }
    )
    other = RubyEventStore::Event.new(data: { "model_class" => "User", "model_id" => 8, "operation" => "created" })
    [created, updated, other].each { Lyra.config.event_store.publish(_1) }

    events = @compliance.send(:read_subject_events, 7, "User")
    assert_equal [created.event_id, updated.event_id], events.map(&:event_id)
    assert_equal %i[created updated], events.map { @compliance.send(:extract_operation, _1) }
    assert_equal({ "email" => ["a@example.com", "b@example.com"] }, @compliance.send(:extract_changes, updated))
    assert_equal({ "email" => "a@example.com" }, @compliance.send(:extract_attributes, created))
    assert_kind_of Time, @compliance.send(:extract_timestamp, updated), "the store's time, from the metadata"
  end

  private

  def publish(model, id, at:)
    event = RubyEventStore::Event.new(data: { "model_class" => model, "model_id" => id, "operation" => "created" },
                                      metadata: { timestamp: at })
    Lyra.config.event_store.publish(event)
    event
  end
end
