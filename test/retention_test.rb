# frozen_string_literal: true

require "test_helper"

# Lyra::Retention: the policy's retention rules applied (opt-in), each
# expired record getting its rule's on_expiry strategy.
class RetentionTest < Minitest::Test
  MT = Lyra::ModeTransition

  def setup
    skip "Requires Rails and database" unless defined?(ActiveRecord::Base) && ActiveRecord::Base.connection.table_exists?(:users)
    skip "Requires pam_dsl" unless Lyra.pam_dsl_available?

    PamDsl.reset!
    define_policy { keep_for 1.year; on_expiry :anonymize; field :email, duration: 30.days }
    Object.send(:remove_const, :RetUser) if defined?(RetUser)
    Object.const_set(:RetUser, Class.new(ActiveRecord::Base) { self.table_name = "users" })
    RetUser.include(Lyra::Interceptors::CrudInterceptor)
    RetUser.monitor_with_lyra(privacy_policy: :ret_policy)
    Lyra.config.monitor_model(RetUser, privacy_policy: :ret_policy)
    clean
    Lyra.config.enable_monitor!
    Lyra.config.retention_executor = true
    @user = RetUser.create!(name: "Ann", email: "ann@example.com")
  end

  def teardown
    return unless defined?(RetUser)

    Lyra.config.retention_executor = false
    clean
    PamDsl.reset!
  end

  def test_off_by_default_but_a_dry_run_lists_what_it_would_do
    refute Lyra::Configuration.new.retention_executor
    Lyra.config.retention_executor = false

    assert_raises(Lyra::Retention::Disabled) { apply(after: 2.years) }
    result = apply(after: 2.years, dry_run: true)
    assert_equal [[:anonymize, :would_erase]], result.actions.map { [_1.strategy, _1.outcome] }
    assert_equal "Ann", raw("SELECT name FROM users WHERE id = #{@user.id}"), "nothing done"
  end

  def test_an_expired_record_is_anonymized_once
    result = apply(after: 2.years)

    assert_equal [:erased], result.actions.map(&:outcome)
    assert_equal ["erased:#{@user.id}"] * 2, rows("SELECT name, email FROM users WHERE id = #{@user.id}").first
    assert_match(/retention/, stream.last.data[:reason])
    assert_equal "lyra_retention", stream.last.metadata[:erased_by]
    assert_empty apply(after: 2.years).actions, "already erased: nothing to do"
    assert_nil MT.discrepancy(RetUser, @user.id.to_s)
  end

  def test_an_attribute_with_a_shorter_period_goes_first
    result = apply(after: 60.days)

    assert_equal [[:field_retention, ["email"]]], result.actions.map { [_1.strategy, _1.fields] }
    assert_equal ["Ann", "erased:#{@user.id}"], rows("SELECT name, email FROM users WHERE id = #{@user.id}").first
  end

  def test_a_record_still_in_its_period_is_left_alone
    assert_empty apply(after: 10.days).actions
  end

  def test_hard_delete_erases_then_destroys
    PamDsl.reset!
    define_policy { keep_for 1.year; on_expiry :hard_delete }

    assert_equal [:deleted], apply(after: 2.years).actions.map(&:outcome)
    assert_nil raw("SELECT id FROM users WHERE id = #{@user.id}")
    assert_equal ["Lyra::Events::ErasureApplied", "Lyra::Events::RetUserDestroyed"], stream.last(2).map(&:event_type)
    refute_match(/ann@example/, raw("SELECT string_agg(convert_from(data, 'UTF8'), ' ') FROM event_store_events"))
  end

  def test_soft_delete_without_a_column_and_archive_are_skipped
    PamDsl.reset!
    define_policy { keep_for 1.year; on_expiry :soft_delete }
    assert_equal [[:skipped, "no deleted_at or discarded_at column"]],
                 apply(after: 2.years).actions.map { [_1.outcome, _1.detail] }

    PamDsl.reset!
    define_policy { keep_for 1.year; on_expiry :archive }
    assert_equal [:skipped], apply(after: 2.years).actions.map(&:outcome)
    assert_equal "Ann", raw("SELECT name FROM users WHERE id = #{@user.id}")
  end

  def test_rule_conditions_are_given_the_record
    PamDsl.reset!
    define_policy { keep_for 1.year; on_expiry :anonymize; self.when { |user| user.name != "Ann" } }

    assert_empty apply(after: 2.years).actions
  end

  def test_the_period_runs_from_the_named_column
    Lyra.config.retention_anchors = { "RetUser" => :updated_at }
    ActiveRecord::Base.connection.execute("UPDATE users SET updated_at = now() + interval '3 years' WHERE id = #{@user.id}")

    assert_empty apply(after: 2.years).actions, "updated_at is in the future"
  ensure
    Lyra.config.retention_anchors = {}
  end

  def test_the_job_applies_it
    skip "Requires ActiveJob" unless defined?(Lyra::RetentionJob)

    Lyra::Retention.stub(:apply!, -> { :applied }) { assert_equal :applied, Lyra::RetentionJob.perform_now }
  end

  private

  def define_policy(&rule)
    PamDsl.define_policy(:ret_policy) do
      field :email, type: :email, sensitivity: :confidential
      field :name, type: :name
      purpose :contact do
        basis :contract
        requires :email
      end
      retention { for_model("RetUser", &rule) }
    end
  end

  def apply(after:, dry_run: false)
    Lyra::Retention.apply!(models: [RetUser], dry_run: dry_run, now: Time.current + after)
  end

  def stream = Lyra.config.event_store.read.stream("RetUser$#{@user.id}").to_a

  def raw(sql) = ActiveRecord::Base.connection.select_value(sql)

  def rows(sql) = ActiveRecord::Base.connection.select_rows(sql)

  def clean
    conn = ActiveRecord::Base.connection
    conn.execute("DELETE FROM users")
    conn.execute("DELETE FROM event_store_events_in_streams")
    conn.execute("DELETE FROM event_store_events")
  end
end
