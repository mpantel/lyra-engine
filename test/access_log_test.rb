# frozen_string_literal: true

require "test_helper"

# Lyra::AccessLog: with config.record_access_events on, every access the
# privacy policy validates is recorded in the subject's access stream,
# granted or not.
class AccessLogTest < Minitest::Test
  def setup
    skip "Requires Rails and database" unless defined?(ActiveRecord::Base) && ActiveRecord::Base.connection.table_exists?(:users)
    skip "Requires pam_dsl" unless Lyra.pam_dsl_available?

    PamDsl.reset!
    PamDsl.logger = Logger.new(nil)
    @policy = PamDsl.define_policy(:access_policy) do
      field :email, type: :email, sensitivity: :confidential do
        allow_for :contact
      end
      field :ssn, type: :ssn, sensitivity: :restricted
      purpose :contact do
        basis :contract
        requires :email
      end
    end
    Object.send(:remove_const, :AccessUser) if defined?(AccessUser)
    Object.const_set(:AccessUser, Class.new(ActiveRecord::Base) { self.table_name = "users" })
    clean
    Lyra.config.record_access_events = true
    Lyra.config.mode = :monitor
    @user = AccessUser.create!(name: "Ann", email: "ann@example.com")
  end

  def teardown
    return unless defined?(AccessUser)

    Lyra.config.record_access_events = false
    clean
    PamDsl.reset!
    PamDsl.logger = nil
  end

  def test_lyra_installs_itself_as_pam_s_access_recorder
    assert_same Lyra::AccessLog, PamDsl.access_recorder
  end

  def test_a_granted_access_is_recorded_in_the_subject_s_access_stream
    assert @policy.validate_access!([:email], :contact, subject: @user)

    event = Lyra::AccessLog.for(@user).sole
    assert_equal "Lyra::DataAccess$AccessUser$#{@user.id}", Lyra::AccessLog.stream_for("AccessUser$#{@user.id}")
    assert_kind_of Lyra::Events::DataAccessed, event
    assert_equal({ policy: "access_policy", purpose: "contact", legal_basis: "contract", fields: ["email"],
                   subject: "AccessUser$#{@user.id}", outcome: "granted" },
                 event.data.slice(:policy, :purpose, :legal_basis, :fields, :subject, :outcome))
    assert_equal "lyra_access_log", event.metadata[:source]
    refute_includes event.data.to_s, "ann@example.com", "field names, never values"
  end

  def test_a_strict_refusal_is_recorded_and_still_raises
    assert_raises(PamDsl::PurposeFieldMismatchError) { @policy.validate_access!([:ssn], :contact, subject: @user) }

    event = Lyra::AccessLog.for(@user).sole
    assert_kind_of Lyra::Events::DataAccessDenied, event
    assert_equal "denied", event.data[:outcome]
    assert_equal ["PamDsl::PurposeFieldMismatchError"], event.data[:violations].map { _1[:error] }
  end

  def test_an_audit_mode_violation_is_recorded_as_an_access_that_went_ahead
    PamDsl.enforcement_mode = :audit
    refute @policy.validate_access!([:ssn], :contact, subject: @user)

    event = Lyra::AccessLog.for(@user).sole
    assert_kind_of Lyra::Events::DataAccessed, event
    assert_equal "audited", event.data[:outcome]
    assert_equal 1, event.data[:violations].size
  end

  def test_every_access_is_recorded_with_no_sampling
    5.times { @policy.validate_access!([:email], :contact, subject: @user) }
    @policy.validate_access!([:email], :contact, subject: 99)

    assert_equal 5, Lyra::AccessLog.for(@user).size
    assert_equal 1, Lyra::AccessLog.for(99).size
  end

  def test_the_record_s_own_stream_and_replay_are_untouched
    @policy.validate_access!([:email], :contact, subject: @user)

    assert_empty Lyra.config.event_store.read.stream("AccessUser$#{@user.id}").to_a
    assert_nil Lyra::Event.operation_of(Lyra::AccessLog.for(@user).sole)
  end

  def test_an_access_that_cannot_be_recorded_does_not_go_ahead
    Lyra.config.event_store.stub(:publish, ->(*_a, **_k) { raise "store down" }) do
      assert_raises(RuntimeError) { @policy.validate_access!([:email], :contact, subject: @user) }
    end
  end

  def test_off_by_default_and_in_disabled_mode_nothing_is_recorded
    refute Lyra::Configuration.new.record_access_events

    Lyra.config.record_access_events = false
    @policy.validate_access!([:email], :contact, subject: @user)
    Lyra.config.record_access_events = true
    Lyra.config.mode = :disabled
    @policy.validate_access!([:email], :contact, subject: @user)

    assert_empty Lyra::AccessLog.for(@user)
  ensure
    Lyra.config.mode = :monitor
  end

  private

  def clean
    conn = ActiveRecord::Base.connection
    conn.execute("DELETE FROM users")
    conn.execute("DELETE FROM event_store_events_in_streams")
    conn.execute("DELETE FROM event_store_events")
  end
end
