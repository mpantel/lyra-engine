# frozen_string_literal: true

require "test_helper"

# The warnings logged while the block runs (Lyra warns through Rails.logger).
module RetentionWarnings
  def warnings
    io = StringIO.new
    saved = Rails.logger
    Rails.logger = Logger.new(io)
    yield
    io.string.lines.grep(/WARN/)
  ensure
    Rails.logger = saved
  end
end

# Lyra::Retention: the policy's retention rules applied (opt-in), each
# expired record getting its rule's on_expiry strategy.
class RetentionTest < Minitest::Test
  include RetentionWarnings

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

  # 0.16 (from 1.0.0): a field's retention period erases that field; the
  # record is still in use, so its access log stays even with erase_access_log.
  def test_a_field_level_expiry_keeps_the_access_log
    Lyra.config.erase_access_log = true
    read_twice

    assert_equal [:erased], apply(after: 60.days).actions.map(&:outcome)
    assert_equal 2, Lyra::AccessLog.for(@user).size
  ensure
    Lyra.config.erase_access_log = false
  end

  # A record erased earlier with its log kept, then deleted under
  # erase_access_log: the log goes with the record, and that is recorded.
  def test_hard_delete_of_an_already_erased_record_deletes_its_access_log
    read_twice
    Lyra::Erasure.erase!(RetUser, @user.id, reason: "Art. 17", access_log: false)
    Lyra.config.erase_access_log = true
    PamDsl.reset!
    define_policy { keep_for 1.year; on_expiry :hard_delete }

    assert_equal [:deleted], apply(after: 2.years).actions.map(&:outcome)
    assert_empty Lyra::AccessLog.for("RetUser$#{@user.id}")
    applied = stream.select { _1.is_a?(Lyra::Events::ErasureApplied) }.last
    assert_equal [[], "erased", 2], applied.data.values_at(:fields, :access_log, :access_log_entries)
  ensure
    Lyra.config.erase_access_log = false
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

  # :soft_delete is a rule's strategy when it names none, and a table with
  # neither deleted_at nor discarded_at gives it nothing to set: every
  # record past its period is kept. The executor says so once per model
  # per run, not once per record.
  def test_a_soft_delete_rule_without_its_column_warns_once_per_run
    RetUser.create!(name: "Bob", email: "bob@example.com")
    PamDsl.reset!
    define_policy { keep_for 1.year } # no on_expiry: :soft_delete

    2.times do
      found = warnings { assert_equal %i[skipped skipped], apply(after: 2.years).actions.map(&:outcome) }
      assert_equal 1, found.size, found.join
      assert_match(/RetUser/, found.first)
      assert_match(/:ret_policy/, found.first)
      assert_match(/:soft_delete/, found.first)
      assert_match(/2 records/, found.first)
      assert_match(/deleted_at or discarded_at/, found.first)
      assert_match(/on_expiry :anonymize or :hard_delete/, found.first)
    end
  end

  def test_a_soft_delete_rule_with_nothing_due_does_not_warn_at_run_time
    PamDsl.reset!
    define_policy { keep_for 1.year; on_expiry :soft_delete }

    assert_empty warnings { apply(after: 10.days) }
  end

  def test_other_strategies_do_not_warn
    %i[anonymize hard_delete].each do |strategy|
      PamDsl.reset!
      define_policy { keep_for 1.year; on_expiry strategy }

      assert_empty warnings { Lyra::Retention.check_rules!(models: [RetUser]) }, strategy
      assert_empty warnings { apply(after: 2.years, dry_run: true) }, strategy
    end
  end

  # The same check without a run, as Lyra makes it at boot for the models
  # enrolled by then: the model, the rule and the fix, and the model's name
  # returned.
  def test_check_rules_names_a_soft_delete_rule_without_its_column
    PamDsl.reset!
    define_policy { keep_for 1.year }

    found = warnings { assert_equal ["RetUser"], Lyra::Retention.check_rules!(models: [RetUser]) }
    assert_equal 1, found.size
    assert_match(/RetUser.*:soft_delete.*users has no deleted_at or discarded_at column/m, found.first)
  end

  def test_check_rules_ignores_a_model_without_a_rule
    PamDsl.reset!
    PamDsl.define_policy(:ret_policy) { field :email, type: :email }

    assert_empty warnings { assert_empty Lyra::Retention.check_rules!(models: [RetUser]) }
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

  # Two entries in the record's access log, as Lyra::AccessLog writes them.
  def read_twice
    2.times do
      Lyra.append_events(Lyra::Events::DataAccessed.new(data: { purpose: "contact", fields: ["email"], outcome: "granted" }),
                         stream_name: Lyra::AccessLog.stream_for("RetUser$#{@user.id}"))
    end
  end

  def rows(sql) = ActiveRecord::Base.connection.select_rows(sql)

  def clean
    conn = ActiveRecord::Base.connection
    conn.execute("DELETE FROM users")
    conn.execute("DELETE FROM event_store_events_in_streams")
    conn.execute("DELETE FROM event_store_events")
  end
end

# Lyra::Retention in every mode, from one table of expectations. In ES-NoProj
# the event store is the only store (the table is empty): the candidates, and
# the records retention acts on, come from the events, and a deletion is an
# event. A record its model's default scope leaves out (soft-deleted) is
# still retention's to act on, in every mode.
class RetentionModesTest < Minitest::Test
  include RetentionWarnings

  TABLE = :ret_items

  MODES = {
    monitor: -> { Lyra.config.enable_monitor! },
    hijack: -> { Lyra.config.enable_hijack! },
    es_sync: lambda {
      Lyra.config.enable_event_sourcing!
      Lyra.config.projection_mode = :sync
    },
    es_lazy: lambda {
      Lyra.config.enable_event_sourcing!
      Lyra.config.projection_mode = :lazy
    },
    es_noproj: lambda {
      Lyra.config.enable_event_sourcing!
      Lyra.config.projection_mode = :disabled
    }
  }.freeze

  # scenario => [the rule's on_expiry, the run's outcome, the record after it]
  SCENARIOS = {
    dry_run: [:anonymize, :would_erase, :untouched],
    anonymize: [:anonymize, :erased, :anonymized],
    anonymize_soft_deleted: [:anonymize, :erased, :anonymized],
    hard_delete: [:hard_delete, :deleted, :destroyed],
    soft_delete: [:soft_delete, :soft_deleted, :soft_deleted],
    restricted_anonymize: [:anonymize, :restricted, :untouched],
    restricted_hard_delete: [:hard_delete, :restricted, :untouched],
    restricted_soft_delete: [:soft_delete, :restricted, :untouched]
  }.freeze

  def setup
    skip "Requires Rails and database" unless defined?(ActiveRecord::Base) && ActiveRecord::Base.connection.table_exists?(:users)
    skip "Requires pam_dsl" unless Lyra.pam_dsl_available?

    PamDsl.reset!
    ActiveRecord::Base.connection.create_table(TABLE, force: true) do |t|
      t.string :name
      t.string :email
      t.datetime :deleted_at
      t.timestamps
    end
    Object.send(:remove_const, :RetItem) if defined?(RetItem)
    Object.const_set(:RetItem, Class.new(ActiveRecord::Base) do
      self.table_name = "ret_items"
      default_scope { where(deleted_at: nil) }
    end)
    RetItem.reset_column_information
    RetItem.include(Lyra::Interceptors::CrudInterceptor)
    RetItem.monitor_with_lyra(privacy_policy: :ret_item_policy)
    Lyra.config.monitor_model(RetItem, privacy_policy: :ret_item_policy)
    clean
    Lyra.config.retention_executor = true
  end

  def teardown
    return unless defined?(RetItem)

    Lyra.config.retention_executor = false
    Lyra.config.projection_mode = :sync
    Lyra.config.enable_monitor!
    clean
    Lyra.config.monitored_models.delete_if { |m| m.name == "RetItem" }
    Object.send(:remove_const, :RetItem)
    ActiveRecord::Base.connection.drop_table(TABLE, if_exists: true)
    PamDsl.reset!
  end

  MODES.each_key do |mode|
    SCENARIOS.each do |scenario, (strategy, outcome, after)|
      define_method("test_#{scenario}_in_#{mode}") { run_scenario(mode, scenario, strategy, outcome, after) }
    end
  end

  # The anchor column (config.retention_anchors) is read from the state the
  # events give the record.
  def test_the_named_anchor_is_read_from_the_events_in_es_noproj
    MODES.fetch(:es_noproj).call
    define_policy(:anonymize)
    Lyra.config.retention_anchors = { "RetItem" => :deleted_at }
    item = RetItem.create!(name: "Ann", email: "ann@example.com")
    assert_empty apply(dry_run: true).actions, "no deleted_at: the period has not started"

    RetItem.unscoped.find(item.id).update!(deleted_at: Time.current)
    assert_equal [:would_erase], apply(dry_run: true).actions.map(&:outcome)
  ensure
    Lyra.config.retention_anchors = {}
  end

  # A soft-delete rule on a table that has deleted_at acts, and nothing warns.
  def test_a_soft_delete_rule_with_its_column_does_not_warn
    define_policy(:soft_delete)
    RetItem.create!(name: "Ann", email: "ann@example.com")

    found = warnings do
      assert_empty Lyra::Retention.check_rules!(models: [RetItem])
      assert_equal [:soft_deleted], apply.actions.map(&:outcome)
    end
    assert_empty found
  end

  # lyra:retention:apply in ES-NoProj: what it would do, then what it did.
  def test_the_rake_task_in_es_noproj
    MODES.fetch(:es_noproj).call
    define_policy(:anonymize)
    item = RetItem.create!(name: "Ann", email: "ann@example.com")

    dry = rake_retention("DRY_RUN" => "1")
    assert_match(/would act on 1 records: 1 would_erase/, dry)
    assert_match(/RetItem #{item.id}: anonymize email, name -> would_erase/, dry)

    done = rake_retention
    assert_match(/acted on 1 records: 1 erased/, done)
    assert_equal [nil, nil], state_of(item).values_at("name", "email")
  end

  private

  def run_scenario(mode, scenario, strategy, outcome, after)
    MODES.fetch(mode).call
    define_policy(strategy)
    item = RetItem.create!(name: "Ann", email: "ann@example.com")
    RetItem.unscoped.find(item.id).update!(deleted_at: Time.current) if scenario == :anonymize_soft_deleted
    if scenario.to_s.start_with?("restricted")
      PamDsl.rights.restrict!(subject: "RetItem$#{item.id}", ground: :needed_for_legal_claims)
    end
    before = state_of(item)

    result = nil
    table_reads = statements(/ret_items/) { result = apply(dry_run: scenario == :dry_run) }

    if mode == :es_noproj
      assert_nil row_of(item), "es_noproj: the events are the only store"
      assert_empty table_reads, "es_noproj: retention does not read or write the table"
    end
    assert_equal [[item.id.to_s, strategy, outcome]], result.actions.map { [_1.id.to_s, _1.strategy, _1.outcome] },
                 "#{mode}: #{result.actions.map(&:to_s)}"
    case after
    when :untouched
      assert_equal before, state_of(item), "#{mode}: nothing done"
    when :anonymized
      # (nullable columns: erasure leaves nil)
      assert_equal [nil, nil], state_of(item).values_at("name", "email"), "#{mode}: events"
      refute_match(/Ann|ann@example/, stream(item).map { _1.data.to_s }.join, "#{mode}: no event keeps them")
      assert_equal [nil, nil], row_of(item).values_at("name", "email"), "#{mode}: row" if row_kept?(mode)
    when :destroyed
      assert_equal :destroyed, Lyra::Event.operation_of(stream(item).last), "#{mode}: a destroy event"
      assert_nil row_of(item), "#{mode}: row" if row_kept?(mode)
    when :soft_deleted
      assert_equal :updated, Lyra::Event.operation_of(stream(item).last), "#{mode}: an update event"
      refute_nil state_of(item)["deleted_at"], "#{mode}: events"
      refute_nil row_of(item)["deleted_at"], "#{mode}: row" if row_kept?(mode)
    end
    return if %i[dry_run restricted].include?(scenario) || outcome == :restricted

    assert_empty apply.actions, "#{mode}: a second run has nothing to do"
  end

  # The modes whose table follows each write (ES-Lazy's catches up on reads).
  def row_kept?(mode) = %i[monitor hijack es_sync].include?(mode)

  def define_policy(strategy)
    PamDsl.reset!
    PamDsl.define_policy(:ret_item_policy) do
      field :email, type: :email, sensitivity: :confidential
      field :name, type: :name
      purpose :contact do
        basis :contract
        requires :email, :name
      end
      retention do
        for_model("RetItem") do
          keep_for 1.year
          on_expiry strategy
        end
      end
    end
  end

  def apply(dry_run: false)
    Lyra::Retention.apply!(models: [RetItem], dry_run: dry_run, now: Time.current + 2.years)
  end

  def rake_retention(env = {})
    require "rake"
    saved = %w[MODELS DRY_RUN].to_h { [_1, ENV[_1]] }
    ENV["MODELS"] = "RetItem"
    ENV.delete("DRY_RUN")
    ENV.update(env)
    Rake.application = Rake::Application.new
    Rake::Task.define_task(:environment)
    load File.expand_path("../lib/tasks/lyra_mode.rake", __dir__)
    later = Time.current + 2.years
    out, = capture_io { Time.stub(:current, later) { Rake::Task["lyra:retention:apply"].invoke } }
    out
  ensure
    saved&.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    Rake.application = nil
  end

  # The record as its events give it (attribute names as strings).
  def state_of(item)
    (Lyra::DualView.new(RetItem, item.id).event_sourced_state[:state] || {}).transform_keys(&:to_s)
  end

  def row_of(item) = ActiveRecord::Base.connection.select_one("SELECT * FROM ret_items WHERE id = #{item.id}")

  def stream(item) = Lyra.config.event_store.read.stream("RetItem$#{item.id}").to_a

  # The SQL statements matching +pattern+ run in the block.
  def statements(pattern)
    found = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      found << payload[:sql] if payload[:sql].match?(pattern)
    end
    yield
    found
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  def clean
    conn = ActiveRecord::Base.connection
    conn.execute("DELETE FROM ret_items") if conn.table_exists?(TABLE)
    conn.execute("DELETE FROM event_store_events_in_streams")
    conn.execute("DELETE FROM event_store_events")
  end
end
