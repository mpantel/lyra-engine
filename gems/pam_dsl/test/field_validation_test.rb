require "test_helper"
require "stringio"

module PamDsl
  # Policy#field_violations and Policy#validate_fields!: Def. 1 for a use
  # whose subjects are not known yet (a query, before it runs). Every
  # condition is checked except consent, which needs a subject.
  class FieldValidationTest < Minitest::Test
    class Recorder
      attr_reader :accesses

      def initialize = @accesses = []
      def record?(_policy) = true
      def call(access) = @accesses << access
    end

    def setup
      PamDsl.reset!
      @log = StringIO.new
      PamDsl.logger = Logger.new(@log)
      @policy = Policy.new(:user_data)
      @policy.field(:email, type: :email)
      @policy.field(:name, type: :name)
      @policy.field(:diagnosis, type: :health, sensitivity: :restricted) { allow_for :treatment }
      @policy.purpose(:contact) do
        basis :contract
        requires :email
      end
      @policy.purpose(:marketing) do
        basis :consent
        requires :email
      end
      @policy.purpose(:treatment) do
        basis :contract
        requires :diagnosis
      end
      @policy.purpose(:analytics) do
        basis :undetermined
        requires :email
      end
    end

    def teardown
      PamDsl.access_recorder = nil
      PamDsl.reset!
      PamDsl.logger = nil
    end

    def test_fields_allowed_for_the_purpose_have_no_violations
      assert_empty @policy.field_violations([:email], :contact)
      assert_equal true, @policy.validate_fields!([:email], :contact)
    end

    # Consent is per subject; with no subject it is the one step skipped.
    def test_consent_is_not_checked
      assert_empty @policy.field_violations([:email], :marketing)
      assert_equal true, @policy.validate_fields!([:email], :marketing)
      assert_raises(ConsentRequiredError) { @policy.validate_access!([:email], :marketing, subject: 7) }
    end

    def test_every_other_condition_is_checked_in_order
      errors = @policy.field_violations(%i[name nickname], :contact).map(&:class)
      assert_equal [PurposeFieldMismatchError, InvalidFieldError], errors
      assert_equal [UndeclaredPurposeError], @policy.field_violations([:email], :unknown).map(&:class)
      assert_equal [UndeterminedBasisError], @policy.field_violations([:email], :analytics).map(&:class)
      assert_equal [SpecialCategoryViolationError], @policy.field_violations([:diagnosis], :treatment).map(&:class)
    end

    def test_strict_raises_the_first_violation
      assert_raises(PurposeFieldMismatchError) { @policy.validate_fields!([:name], :contact) }
    end

    def test_audit_reports_every_violation_and_returns_false
      PamDsl.enforcement_mode = :audit
      reported = []
      PamDsl.on_violation { |v| reported << v }

      assert_equal false, @policy.validate_fields!(%i[name nickname], :contact, subject: "User$*")
      assert_equal [PurposeFieldMismatchError, InvalidFieldError], reported.map(&:error_class)
      assert reported.all? { _1.subject == "User$*" }
      assert_match(/PurposeFieldMismatchError.*name/, @log.string)
    end

    # The subject, if given, is only what the access recorder and the
    # violation report are told.
    def test_the_access_recorder_sees_the_call
      recorder = PamDsl.access_recorder = Recorder.new
      @policy.validate_fields!([:email], :marketing, subject: "User$*")
      assert_raises(PurposeFieldMismatchError) { @policy.validate_fields!([:name], :contact, subject: "User$*") }

      assert_equal %i[granted denied], recorder.accesses.map(&:outcome)
      assert_equal ["User$*", "User$*"], recorder.accesses.map(&:subject)
      assert_equal :consent, recorder.accesses.first.legal_basis
    end

    # A :consent purpose needs consent for a subject whether or not the
    # policy declares a consent block for it (Art. 6(1)(a)).
    def test_a_consent_purpose_without_a_consent_block_still_needs_consent
      assert_nil @policy.consent_policy.requirement_for(:marketing)
      assert_raises(ConsentRequiredError) { @policy.validate_access!([:email], :marketing, subject: 1) }
      @policy.consent_policy.grant_consent(purpose: :marketing, subject: 1)
      assert @policy.validate_access!([:email], :marketing, subject: 1)
    end
  end
end
