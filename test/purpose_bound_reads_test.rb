# frozen_string_literal: true

require "test_helper"
require "stringio"

# Lyra::PurposeBoundReads: a read made for a declared purpose is checked
# against the model's policy; every declared attribute it loaded must be
# allowed for the purpose.
class PurposeBoundReadsTest < Minitest::Test
  def setup
    skip "Requires Rails and database" unless defined?(ActiveRecord::Base) && ActiveRecord::Base.connection.table_exists?(:users)
    skip "Requires pam_dsl" unless Lyra.pam_dsl_available?

    PamDsl.reset!
    PamDsl.logger = Logger.new(nil)
    PamDsl.define_policy(:read_policy) do
      field :email, type: :email, sensitivity: :confidential
      field :name, type: :name
      purpose :contact do
        basis :contract
        requires :email
      end
      purpose :directory do
        basis :legitimate_interests
        requires :name, :email
      end
      purpose :newsletter do
        basis :consent
        requires :email
      end
      consent do
        for_purpose(:newsletter) { required! }
      end
    end
    Object.send(:remove_const, :ReadUser) if defined?(ReadUser)
    Object.const_set(:ReadUser, Class.new(ActiveRecord::Base) { self.table_name = "users" })
    ReadUser.include(Lyra::Interceptors::CrudInterceptor)
    ReadUser.monitor_with_lyra(privacy_policy: :read_policy)
    Lyra.config.monitor_model(ReadUser, privacy_policy: :read_policy)
    clean
    Lyra.config.enable_monitor!
    @user = ReadUser.create!(name: "Ann", email: "ann@example.com")
  end

  def teardown
    return unless defined?(ReadUser)

    Lyra.config.reads_without_purpose = :allow
    Lyra.config.record_access_events = false
    Lyra.config.projection_mode = :sync
    Lyra.config.enable_monitor!
    clean
    PamDsl.reset!
    PamDsl.logger = nil
  end

  def test_a_read_with_no_purpose_is_allowed_by_default
    assert_equal :allow, Lyra::Configuration.new.reads_without_purpose
    assert_equal "Ann", ReadUser.find(@user.id).name
  end

  def test_a_read_whose_purpose_covers_what_it_loaded_goes_ahead_and_is_recorded
    Lyra.config.record_access_events = true
    Lyra.with_purpose(:directory) { ReadUser.find(@user.id) }

    event = Lyra::AccessLog.for(@user).sole
    assert_equal ["directory", "granted"], event.data.values_at(:purpose, :outcome)
    assert_equal %w[email name], event.data[:fields].sort
  end

  # Data minimisation: loading a declared attribute the purpose does not
  # need is refused; selecting what it needs is not.
  def test_loading_more_than_the_purpose_needs_is_refused
    Lyra.with_purpose(:contact) do
      assert_raises(PamDsl::PurposeFieldMismatchError) { ReadUser.find(@user.id) }
      assert_equal "ann@example.com", ReadUser.select(:id, :email).find(@user.id).email
    end
  end

  def test_in_audit_mode_the_violation_is_logged_and_the_read_goes_ahead
    PamDsl.enforcement_mode = :audit
    log = StringIO.new
    PamDsl.logger = Logger.new(log)

    assert_equal "Ann", Lyra.with_purpose(:contact) { ReadUser.find(@user.id) }.name
    assert_match(/PurposeFieldMismatchError.*name/, log.string)
  end

  def test_reads_without_purpose_can_be_denied_or_audited
    Lyra.config.record_access_events = true
    Lyra.config.reads_without_purpose = :deny
    error = assert_raises(Lyra::PurposeBoundReads::PurposeRequiredError) { ReadUser.find(@user.id) }
    assert_match(/no declared purpose/, error.message)

    Lyra.config.reads_without_purpose = :audit
    Rails.logger.stub(:warn, nil) { assert ReadUser.find(@user.id) }

    events = Lyra::AccessLog.for(@user)
    assert_equal [Lyra::Events::DataAccessDenied, Lyra::Events::DataAccessed], events.map(&:class)
    assert_equal %w[none none], events.map { _1.data[:purpose] }
    assert_equal "audited", events.last.data[:outcome]
  end

  def test_an_unknown_setting_is_rejected
    assert_raises(ArgumentError) { Lyra.config.reads_without_purpose = :sometimes }
  end

  # Lyra's own reads are not processing for a purpose.
  def test_lyra_s_own_reads_are_not_checked
    Lyra.with_purpose(:contact) do
      ReadUser.where(id: @user.id).update_all(name: "Bea") # bypass-event snapshot
      assert Lyra::DualView.new(ReadUser, @user.id).compare
      assert_nil Lyra::ModeTransition.discrepancy(ReadUser, @user.id.to_s)
    end
  end

  def test_an_event_sourced_write_s_projection_is_not_checked
    Lyra.config.enable_event_sourcing!
    Lyra.config.projection_mode = :sync
    user = ReadUser.create!(name: "Cy", email: "cy@example.com")

    Lyra.with_purpose(:contact) { ReadUser.select(:id, :email).find(user.id).update!(email: "cy@new.example") }
    assert_equal "cy@new.example", ActiveRecord::Base.connection.select_value("SELECT email FROM users WHERE id = #{user.id}")
  end

  def test_pluck_and_pick_are_checked_by_the_columns_they_read
    Lyra.with_purpose(:contact) do
      assert_equal ["ann@example.com"], ReadUser.pluck(:email)
      assert_raises(PamDsl::PurposeFieldMismatchError) { ReadUser.pluck(:name) }
      assert_raises(PamDsl::PurposeFieldMismatchError) { ReadUser.where(id: @user.id).pick(:name) }
      assert_raises(PamDsl::PurposeFieldMismatchError) { ReadUser.pluck(Arel.sql("LOWER(users.name)")) }
      assert_equal [@user.id], ReadUser.pluck(:id), "no personal attribute, nothing to check"
    end
  end

  # A pluck reads many people at once: no one person's consent can be checked.
  def test_a_pluck_under_a_consent_purpose_is_refused
    Lyra.with_purpose(:newsletter) do
      assert_raises(PamDsl::ConsentRequiredError) { ReadUser.pluck(:email) }
    end
  end

  def test_a_pluck_with_no_purpose_follows_the_setting
    Lyra.config.reads_without_purpose = :deny
    assert_raises(Lyra::PurposeBoundReads::PurposeRequiredError) { ReadUser.pluck(:email) }
  end

  # ES-NoProj rebuilds whole records from events; what a query returns is
  # narrowed to its select and checked, so the rule is the same in every mode.
  def test_es_noproj_returns_and_checks_what_the_query_selected
    Lyra.config.enable_event_sourcing!
    Lyra.config.projection_mode = :disabled
    user = ReadUser.create!(name: "Cy", email: "cy@example.com")

    Lyra.with_purpose(:contact) do
      assert_raises(PamDsl::PurposeFieldMismatchError) { ReadUser.find(user.id) }
      assert_raises(PamDsl::PurposeFieldMismatchError) { ReadUser.where(id: user.id).to_a }
      selected = ReadUser.select(:id, :email).find_by(id: user.id)
      assert_equal %w[email id], selected.attribute_names.sort
      assert_equal ["cy@example.com"], ReadUser.where(id: user.id).pluck(:email)
      assert_raises(PamDsl::PurposeFieldMismatchError) { ReadUser.where(id: user.id).pluck(:name) }
    end
    assert_equal "Cy", ReadUser.find(user.id).name, "outside a purpose, as before"
  end

  def test_a_model_without_a_policy_is_not_checked
    ReadUser.monitor_with_lyra
    Lyra.config.monitor_model(ReadUser)

    assert Lyra.with_purpose(:contact) { ReadUser.find(@user.id) }
  end

  def test_purposes_nest_and_are_restored
    Lyra.with_purpose(:directory) do
      Lyra.with_purpose(:contact) { assert_equal :contact, Lyra::PurposeBoundReads.current }
      assert_equal :directory, Lyra::PurposeBoundReads.current
    end
    assert_nil Lyra::PurposeBoundReads.current
  end

  def test_controllers_and_jobs_declare_their_purpose
    assert ActionController::Base.respond_to?(:lyra_purpose) if defined?(ActionController::Base)

    skip "Requires ActiveJob" unless defined?(ActiveJob::Base)
    seen = nil
    job = Class.new(ActiveJob::Base) do
      lyra_purpose :directory
      define_method(:perform) { seen = Lyra::PurposeBoundReads.current }
    end
    job.perform_now
    assert_equal :directory, seen
  end

  private

  def clean
    conn = ActiveRecord::Base.connection
    conn.execute("DELETE FROM users")
    conn.execute("DELETE FROM event_store_events_in_streams")
    conn.execute("DELETE FROM event_store_events")
  end
end
