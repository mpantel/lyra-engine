require "test_helper"

module PamDsl
  class RetentionRuleTest < Minitest::Test
    # ─────────────────────────────────────────────────────────────────────────
    # Basic RetentionRule Creation
    # ─────────────────────────────────────────────────────────────────────────

    def test_retention_rule_creation
      rule = RetentionRule.new("User")
      assert_equal "User", rule.model_class
    end

    def test_retention_rule_converts_model_to_string
      rule = RetentionRule.new(:user)
      assert_equal "user", rule.model_class
    end

    def test_retention_rule_default_duration_is_nil
      rule = RetentionRule.new("User")
      assert_nil rule.duration
    end

    def test_retention_rule_default_deletion_strategy
      rule = RetentionRule.new("User")
      assert_equal :soft_delete, rule.deletion_strategy
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Duration Settings
    # ─────────────────────────────────────────────────────────────────────────

    def test_keep_for_sets_duration
      rule = RetentionRule.new("User")
      rule.keep_for(7.years)
      assert_equal 7.years, rule.duration
    end

    def test_keep_for_returns_self_for_chaining
      rule = RetentionRule.new("User")
      result = rule.keep_for(7.years)
      assert_equal rule, result
    end

    def test_keep_for_with_different_durations
      durations = [30.days, 90.days, 1.year, 7.years, 10.years]

      durations.each do |duration|
        rule = RetentionRule.new("Test")
        rule.keep_for(duration)
        assert_equal duration, rule.duration
      end
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Deletion Strategies
    # ─────────────────────────────────────────────────────────────────────────

    def test_on_expiry_hard_delete
      rule = RetentionRule.new("TempData")
      rule.on_expiry(:hard_delete)
      assert_equal :hard_delete, rule.deletion_strategy
    end

    def test_on_expiry_soft_delete
      rule = RetentionRule.new("Archive")
      rule.on_expiry(:soft_delete)
      assert_equal :soft_delete, rule.deletion_strategy
    end

    def test_on_expiry_anonymize
      rule = RetentionRule.new("User")
      rule.on_expiry(:anonymize)
      assert_equal :anonymize, rule.deletion_strategy
    end

    def test_on_expiry_archive
      rule = RetentionRule.new("Financial")
      rule.on_expiry(:archive)
      assert_equal :archive, rule.deletion_strategy
    end

    def test_on_expiry_invalid_strategy_raises_error
      rule = RetentionRule.new("Test")
      assert_raises(PamDsl::Error) do
        rule.on_expiry(:invalid_strategy)
      end
    end

    def test_on_expiry_accepts_string
      rule = RetentionRule.new("Test")
      rule.on_expiry("anonymize")
      assert_equal :anonymize, rule.deletion_strategy
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Field Overrides
    # ─────────────────────────────────────────────────────────────────────────

    def test_field_override
      rule = RetentionRule.new("User")
      rule.keep_for(7.years)
      rule.field(:email, duration: 2.years)

      assert_equal 7.years, rule.duration
      assert_equal 2.years, rule.field_overrides[:email]
    end

    def test_multiple_field_overrides
      rule = RetentionRule.new("User")
      rule.keep_for(7.years)
      rule.field(:email, duration: 2.years)
      rule.field(:ip_address, duration: 30.days)

      assert_equal 2.years, rule.field_overrides[:email]
      assert_equal 30.days, rule.field_overrides[:ip_address]
    end

    def test_duration_for_field_with_override
      rule = RetentionRule.new("User")
      rule.keep_for(7.years)
      rule.field(:email, duration: 2.years)

      assert_equal 2.years, rule.duration_for_field(:email)
    end

    def test_duration_for_field_without_override
      rule = RetentionRule.new("User")
      rule.keep_for(7.years)

      assert_equal 7.years, rule.duration_for_field(:email)
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Expiration Checking
    # ─────────────────────────────────────────────────────────────────────────

    def test_expired_returns_false_without_duration
      rule = RetentionRule.new("User")
      refute rule.expired?(Time.current - 10.years)
    end

    def test_expired_returns_true_for_old_timestamp
      rule = RetentionRule.new("User")
      rule.keep_for(7.years)
      assert rule.expired?(Time.current - 8.years)
    end

    def test_expired_returns_false_for_recent_timestamp
      rule = RetentionRule.new("User")
      rule.keep_for(7.years)
      refute rule.expired?(Time.current - 1.year)
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Conditions
    # ─────────────────────────────────────────────────────────────────────────

    def test_when_adds_condition
      rule = RetentionRule.new("User")
      rule.when { |ctx| ctx[:status] == :inactive }

      assert_equal 1, rule.conditions.size
    end

    def test_applies_to_with_matching_condition
      rule = RetentionRule.new("User")
      rule.when { |ctx| ctx[:status] == :inactive }

      assert rule.applies_to?(status: :inactive)
      refute rule.applies_to?(status: :active)
    end

    def test_applies_to_without_conditions
      rule = RetentionRule.new("User")
      assert rule.applies_to?(status: :anything)
    end

    def test_applies_to_with_multiple_conditions
      rule = RetentionRule.new("User")
      rule.when { |ctx| ctx[:status] == :inactive }
      rule.when { |ctx| ctx[:has_consent] == false }

      assert rule.applies_to?(status: :inactive, has_consent: false)
      refute rule.applies_to?(status: :inactive, has_consent: true)
      refute rule.applies_to?(status: :active, has_consent: false)
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Method Chaining
    # ─────────────────────────────────────────────────────────────────────────

    def test_method_chaining
      rule = RetentionRule.new("User")
        .keep_for(7.years)
        .on_expiry(:anonymize)
        .field(:ip_address, duration: 30.days)

      assert_equal 7.years, rule.duration
      assert_equal :anonymize, rule.deletion_strategy
      assert_equal 30.days, rule.field_overrides[:ip_address]
    end
  end

  class RetentionPolicyTest < Minitest::Test
    # ─────────────────────────────────────────────────────────────────────────
    # Basic RetentionPolicy Creation
    # ─────────────────────────────────────────────────────────────────────────

    def test_retention_policy_creation
      policy = RetentionPolicy.new
      assert_empty policy.rules
    end

    def test_default_duration_is_7_years
      policy = RetentionPolicy.new
      assert_equal 7.years, policy.default_duration
    end

    def test_set_default_duration
      policy = RetentionPolicy.new
      policy.default(10.years)
      assert_equal 10.years, policy.default_duration
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Model Rules
    # ─────────────────────────────────────────────────────────────────────────

    def test_for_model_creates_rule
      policy = RetentionPolicy.new
      policy.for_model("User") do
        keep_for 7.years
      end

      assert_equal 1, policy.rules.size
      assert_equal "User", policy.rules.first.model_class
    end

    def test_for_model_with_block
      policy = RetentionPolicy.new
      policy.for_model("User") do
        keep_for 7.years
        on_expiry :anonymize
      end

      rule = policy.rules.first
      assert_equal 7.years, rule.duration
      assert_equal :anonymize, rule.deletion_strategy
    end

    def test_for_model_returns_rule
      policy = RetentionPolicy.new
      rule = policy.for_model("User")

      assert_instance_of RetentionRule, rule
    end

    def test_multiple_model_rules
      policy = RetentionPolicy.new
      policy.for_model("User") { keep_for 7.years }
      policy.for_model("Transaction") { keep_for 10.years }

      assert_equal 2, policy.rules.size
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Rule Lookup
    # ─────────────────────────────────────────────────────────────────────────

    def test_rule_for_finds_rule
      policy = RetentionPolicy.new
      policy.for_model("User") { keep_for 7.years }

      rule = policy.rule_for("User")
      refute_nil rule
      assert_equal "User", rule.model_class
    end

    def test_rule_for_returns_nil_if_not_found
      policy = RetentionPolicy.new
      assert_nil policy.rule_for("Unknown")
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Duration Lookup
    # ─────────────────────────────────────────────────────────────────────────

    def test_duration_for_model_with_rule
      policy = RetentionPolicy.new
      policy.for_model("User") { keep_for 7.years }

      assert_equal 7.years, policy.duration_for("User")
    end

    def test_duration_for_model_without_rule
      policy = RetentionPolicy.new
      policy.default(5.years)

      assert_equal 5.years, policy.duration_for("Unknown")
    end

    def test_duration_for_model_with_nil_duration
      policy = RetentionPolicy.new
      policy.default(5.years)
      policy.for_model("User")  # No duration set

      assert_equal 5.years, policy.duration_for("User")
    end

    def test_duration_for_field_with_override
      policy = RetentionPolicy.new
      policy.for_model("User") do
        keep_for 7.years
        field :ip_address, duration: 30.days
      end

      assert_equal 30.days, policy.duration_for("User", field_name: :ip_address)
    end

    def test_duration_for_field_without_override
      policy = RetentionPolicy.new
      policy.for_model("User") { keep_for 7.years }

      assert_equal 7.years, policy.duration_for("User", field_name: :email)
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Integration with Policy DSL
    # ─────────────────────────────────────────────────────────────────────────

    def test_retention_via_policy_dsl
      PamDsl.reset!

      PamDsl.define_policy :test_retention do
        field :email, type: :email

        retention do
          default 5.years

          for_model "User" do
            keep_for 7.years
            on_expiry :anonymize
          end

          for_model "Transaction" do
            keep_for 10.years
          end
        end
      end

      policy = PamDsl.policy(:test_retention)
      refute_nil policy.retention

      assert_equal 5.years, policy.retention.default_duration
      assert_equal 7.years, policy.retention.duration_for("User")
      assert_equal 10.years, policy.retention.duration_for("Transaction")
      assert_equal 5.years, policy.retention.duration_for("Unknown")

      user_rule = policy.retention.rule_for("User")
      assert_equal :anonymize, user_rule.deletion_strategy

      PamDsl.reset!
    end
  end
end
