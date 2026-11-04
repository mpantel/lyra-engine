# frozen_string_literal: true

require "test_helper"

# Which events the Art. 15/20 export gathers for a data subject: those of the
# subject's own record and of records that refer to the subject by foreign
# key, never those the subject merely made (0.9.3: before, an event whose
# metadata named the subject as its actor was exported too).
class GDPRComplianceTest < Minitest::Test
  Event = Struct.new(:data, :metadata)

  def setup
    skip "Requires pam_dsl" unless Lyra.pam_dsl_available?

    @compliance = Lyra::Privacy::GDPRCompliance.new(subject_id: 7, subject_type: "User")
  end

  def relates?(event)
    @compliance.send(:event_relates_to_subject?, event, 7, "User")
  end

  def test_the_subject_s_own_record_is_theirs
    assert relates?(Event.new({ model_class: "User", model_id: "7", attributes: { "email" => "a@b" } }, {}))
  end

  def test_a_record_referring_to_the_subject_by_foreign_key_is_theirs
    assert relates?(Event.new({ model_class: "Registration", model_id: 31, attributes: { "user_id" => 7 } }, {}))
  end

  def test_a_record_the_subject_only_edited_is_not
    other = Event.new({ model_class: "Registration", model_id: 32, attributes: { "user_id" => 9 } }, { user_id: 7 })
    refute relates?(other), "the actor of a write is not its data subject"
  end

  def test_another_subject_type_with_the_same_id_is_not
    refute relates?(Event.new({ model_class: "Student", model_id: 7, attributes: {} }, {}))
  end

  # A single duration in config.retention_policy (as an application sets
  # it) raised TypeError in the retention check before 0.9.3.
  def test_a_single_configured_duration_is_a_default
    with_store_and_retention(7.years) do
      compliance = Lyra::Privacy::GDPRCompliance.new(subject_id: 7, subject_type: "User")
      assert_equal({ default: { duration: 7.years } }, compliance.send(:retention_policy))
      assert_equal [], compliance.retention_compliance_check
    end
  end

  # It called an undefined method before 0.9.3.
  def test_the_policy_based_retention_check_runs
    with_store_and_retention(nil) do
      compliance = Lyra::Privacy::GDPRCompliance.new(subject_id: 7, subject_type: "User")
      PamDsl.define_policy(:retention_check_policy) { field :email, type: :email }
      assert_equal [], compliance.retention_compliance_with_policy(:retention_check_policy)
    ensure
      PamDsl.reset!
    end
  end

  def test_an_explicit_subject_must_match_type_and_id
    assert relates?(Event.new({ subject_id: 7, subject_type: "User" }, {}))
    refute relates?(Event.new({ subject_id: 7, subject_type: "Student" }, {}))
  end

  private

  def with_store_and_retention(retention)
    previous_store = Lyra.config.event_store
    previous_retention = Lyra.config.retention_policy
    Lyra.config.event_store = RubyEventStore::Client.new(repository: RubyEventStore::InMemoryRepository.new)
    Lyra.config.retention_policy = retention
    yield
  ensure
    Lyra.config.event_store = previous_store
    Lyra.config.retention_policy = previous_retention
  end
end
