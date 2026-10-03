require "test_helper"
require "stringio"

module PamDsl
  # Strict mode blocks an invalid access; audit mode records it and lets it
  # through (Policy#validate_access!, PamDsl::Enforcement).
  class EnforcementTest < Minitest::Test
    def setup
      PamDsl.reset!
      @log = StringIO.new
      PamDsl.logger = Logger.new(@log)
      @policy = Policy.new(:user_data)
      @policy.field(:email, type: :email)
      @policy.field(:ssn, type: :ssn)
      @policy.field(:diagnosis, type: :health, sensitivity: :restricted) { allow_for :treatment }
      @policy.purpose(:marketing) { requires :email }
      @policy.purpose(:treatment) do
        basis :contract
        requires :diagnosis
      end
    end

    def teardown
      PamDsl.reset!
      PamDsl.logger = nil
    end

    def test_strict_is_the_default_and_raises_the_first_violation
      assert_equal :strict, PamDsl.enforcement_mode
      assert_raises(PurposeFieldMismatchError) { @policy.validate_access!([:ssn], :marketing, subject: 1) }
      assert_raises(UndeclaredPurposeError) { @policy.validate_access!([:email], :nonexistent, subject: 1) }
    end

    def test_audit_records_every_violation_and_lets_the_access_through
      PamDsl.enforcement_mode = :audit
      recorded = []
      PamDsl.on_violation { |v| recorded << v }

      result = @policy.validate_access!(%i[ssn nonexistent], :marketing, subject: 42)

      assert_equal false, result
      assert_equal [PurposeFieldMismatchError, InvalidFieldError], recorded.map(&:error_class)
      assert recorded.all? { _1.policy == :user_data && _1.purpose == :marketing && _1.subject == 42 }
      assert_match(/PurposeFieldMismatchError.*ssn/, @log.string)
    end

    def test_audit_records_special_category_and_undeclared_purpose_violations
      PamDsl.enforcement_mode = :audit
      recorded = []
      PamDsl.on_violation { |v| recorded << v.error_class }

      refute @policy.validate_access!([:diagnosis], :treatment, subject: 1)
      refute @policy.validate_access!([:email], :nonexistent, subject: 1)
      assert_equal [SensitivityViolationError, UndeclaredPurposeError], recorded
    end

    def test_a_valid_access_is_true_in_either_mode_and_records_nothing
      recorded = []
      PamDsl.on_violation { |v| recorded << v }

      assert @policy.validate_access!([:email], :marketing, subject: 1)
      PamDsl.enforcement_mode = :audit
      assert @policy.validate_access!([:email], :marketing, subject: 1)
      assert_empty recorded
    end

    def test_a_policy_can_override_the_global_mode
      @policy.enforcement :audit
      assert_equal :audit, @policy.enforcement_mode
      refute @policy.validate_access!([:ssn], :marketing, subject: 1)

      PamDsl.enforcement_mode = :audit
      strict = Policy.new(:other)
      strict.field(:email, type: :email)
      strict.enforcement :strict
      assert_raises(UndeclaredPurposeError) { strict.validate_access!([:email], :nope, subject: 1) }
    end

    def test_an_unknown_mode_is_rejected
      assert_raises(ArgumentError) { PamDsl.enforcement_mode = :lenient }
      assert_raises(ArgumentError) { @policy.enforcement :lenient }
    end

    def test_the_dsl_accepts_the_mode
      policy = PamDsl.define_policy(:dsl_audit) do
        enforcement :audit
        field :email, type: :email
      end
      assert_equal :audit, policy.enforcement_mode
    end
  end
end
