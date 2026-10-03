require "test_helper"

module PamDsl
  # PamDsl.access_recorder sees every validate_access! call, whatever its
  # outcome, before it returns or raises.
  class AccessRecorderTest < Minitest::Test
    class Recorder
      attr_reader :accesses
      attr_accessor :on

      def initialize
        @accesses = []
        @on = true
      end

      def record?(_policy) = on

      def call(access) = @accesses << access
    end

    def setup
      PamDsl.reset!
      PamDsl.logger = Logger.new(nil)
      @recorder = PamDsl.access_recorder = Recorder.new
      @policy = Policy.new(:user_data)
      @policy.field(:email, type: :email)
      @policy.field(:ssn, type: :ssn)
      @policy.purpose(:marketing) do
        basis :legitimate_interests
        requires :email
      end
    end

    def teardown
      PamDsl.access_recorder = nil
      PamDsl.reset!
      PamDsl.logger = nil
    end

    def test_a_valid_access_is_recorded_as_granted
      assert @policy.validate_access!([:email], :marketing, subject: 42)

      access = @recorder.accesses.sole
      assert_equal [:user_data, :marketing, :legitimate_interests, [:email], 42, :granted, []],
                   access.to_h.values_at(:policy, :purpose, :legal_basis, :fields, :subject, :outcome, :violations)
      assert_kind_of Time, access.at
    end

    def test_a_strict_refusal_is_recorded_as_denied_before_it_raises
      assert_raises(PurposeFieldMismatchError) { @policy.validate_access!([:ssn], :marketing, subject: 42) }

      access = @recorder.accesses.sole
      assert_equal :denied, access.outcome
      assert_equal [PurposeFieldMismatchError], access.violations.map(&:class)
    end

    def test_an_audit_mode_access_with_violations_is_recorded_as_audited
      PamDsl.enforcement_mode = :audit
      refute @policy.validate_access!(%i[ssn nonexistent], :marketing, subject: 42)

      access = @recorder.accesses.sole
      assert_equal :audited, access.outcome
      assert_equal [PurposeFieldMismatchError, InvalidFieldError], access.violations.map(&:class)
    end

    def test_an_undeclared_purpose_is_recorded_without_a_legal_basis
      assert_raises(UndeclaredPurposeError) { @policy.validate_access!([:email], :nonexistent, subject: 42) }

      assert_nil @recorder.accesses.sole.legal_basis
    end

    def test_an_access_that_cannot_be_recorded_does_not_go_ahead
      def @recorder.call(_access) = raise(IOError, "store down")

      assert_raises(IOError) { @policy.validate_access!([:email], :marketing, subject: 42) }
    end

    def test_nothing_is_recorded_when_the_recorder_declines_or_none_is_set
      @recorder.on = false
      @policy.validate_access!([:email], :marketing, subject: 42)
      PamDsl.access_recorder = nil
      @policy.validate_access!([:email], :marketing, subject: 42)

      assert_empty @recorder.accesses
    end

    def test_reset_leaves_the_recorder_in_place
      PamDsl.reset!
      assert_same @recorder, PamDsl.access_recorder
    end
  end
end
