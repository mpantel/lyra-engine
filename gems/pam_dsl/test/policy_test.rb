require "test_helper"
require "stringio"

module PamDsl
  class PolicyTest < Minitest::Test
    def setup
      PamDsl.reset!
    end

    def test_policy_creation
      policy = Policy.new(:user_data)

      assert_equal :user_data, policy.name
      assert_empty policy.fields
      assert_empty policy.purposes
    end

    def test_define_field
      policy = Policy.new(:user_data)

      policy.field(:email, type: :email, sensitivity: :confidential)
      policy.field(:name, type: :name, sensitivity: :internal)

      assert_equal 2, policy.fields.size
      assert policy.fields.key?(:email)
      assert policy.fields.key?(:name)
      assert_equal :email, policy.fields[:email].type
      assert_equal :confidential, policy.fields[:email].sensitivity
    end

    def test_define_purpose
      policy = Policy.new(:user_data)

      policy.purpose(:marketing)
      policy.purpose(:analytics)

      assert_equal 2, policy.purposes.size
      assert policy.purposes.key?(:marketing)
      assert policy.purposes.key?(:analytics)
    end

    def test_retention_policy
      policy = Policy.new(:user_data)

      policy.retention do
        default 90.days

        for_model("User") do
          keep_for 7.years
          field :email, duration: 2.years
        end
      end

      assert_equal 90.days, policy.retention_policy.default_duration
      assert_equal 1, policy.retention_policy.rules.size

      rule = policy.retention_policy.rules.first
      assert_equal "User", rule.model_class
      assert_equal 7.years, rule.duration
    end

    def test_consent_policy
      policy = Policy.new(:user_data)

      policy.consent do
        for_purpose(:marketing) do
          required! true
          withdrawable! true
          describe "Used for marketing emails"
        end
      end

      assert_equal 1, policy.consent_policy.requirements.size

      requirement = policy.consent_policy.requirements.first
      assert_equal :marketing, requirement.purpose
      assert requirement.required?
      assert requirement.withdrawable?
    end

    def test_policy_registration
      policy = Policy.new(:user_data)
      PamDsl.registry.register(:user_data, policy)

      assert_equal policy, PamDsl.registry.get(:user_data)
    end

    def test_get_field
      policy = Policy.new(:user_data)
      policy.field(:email, type: :email)

      field = policy.get_field(:email)
      assert_equal :email, field.name
    end

    def test_get_field_raises_on_missing
      policy = Policy.new(:user_data)

      assert_raises(InvalidFieldError) do
        policy.get_field(:nonexistent)
      end
    end

    def test_undeclared_purpose_raises_undeclared_purpose_error
      policy = Policy.new(:user_data)

      assert_raises(UndeclaredPurposeError) do
        policy.get_purpose(:nonexistent)
      end
    end

    def test_validate_access_undeclared_purpose_raises_undeclared_purpose_error
      policy = Policy.new(:user_data)
      policy.field(:email, type: :email)

      assert_raises(UndeclaredPurposeError) do
        policy.validate_access!([:email], :nonexistent, subject: 1)
      end
    end

    def test_purpose_field_mismatch_raises_purpose_field_mismatch_error
      policy = Policy.new(:user_data)
      policy.field(:email, type: :email)
      policy.field(:ssn, type: :ssn)
      policy.purpose(:marketing) { requires :email }

      assert_raises(PurposeFieldMismatchError) do
        policy.validate_access!([:ssn], :marketing, subject: 1)
      end
    end

    # The detector reports logins/usernames as online identifiers (Art. 4(1));
    # a policy must be able to declare that type too.
    def test_policy_can_declare_online_identifier_field
      PamDsl.define_policy :accounts do
        field :username, type: :online_identifier, sensitivity: :internal
        purpose(:authentication) { requires :username }
      end
      policy = PamDsl.registry.get(:accounts)
      field = policy.get_field(:username)

      assert_equal :online_identifier, field.type
      refute field.special_category?
      refute field.sensitive?
      assert policy.validate_access!([:username], :authentication, subject: 1)

      output = StringIO.new
      PamDsl::Reporter.new(:accounts, output: output).full_report
      assert_includes output.string, "username"
    end

    def test_undeclared_field_still_raises_invalid_field_error
      policy = Policy.new(:user_data)
      policy.purpose(:marketing) { requires :email }

      assert_raises(InvalidFieldError) do
        policy.validate_access!([:nonexistent], :marketing, subject: 1)
      end
    end

    def test_sensitive_fields
      policy = Policy.new(:user_data)
      policy.field(:email, type: :email, sensitivity: :restricted)
      policy.field(:name, type: :name, sensitivity: :confidential)
      policy.field(:id, type: :identifier, sensitivity: :internal)

      # Get sensitive fields (those marked as restricted or confidential)
      sensitive = policy.sensitive_fields
      assert sensitive.is_a?(Array)
      # Should include email and name (restricted/confidential) but not id (internal)
      assert_equal 2, sensitive.length
    end

    def test_policy_to_hash
      policy = Policy.new(:user_data)
      policy.field(:email, type: :email)
      policy.purpose(:marketing)

      hash = policy.to_h

      assert_equal :user_data, hash[:name]
      assert hash[:fields].key?(:email)
      assert hash[:purposes].key?(:marketing)
      assert hash.key?(:retention)
      assert hash.key?(:consent)
    end

    def test_define_policy_dsl
      policy = PamDsl.define_policy(:customer_data) do
        field :customer_id, type: :identifier
        field :email, type: :email

        purpose :order_processing
        purpose :marketing

        retention do
          default 7.years
        end

        consent do
          for_purpose(:marketing) do
            required!
          end
        end
      end

      assert_equal :customer_data, policy.name
      assert_equal 2, policy.fields.size
      assert_equal 2, policy.purposes.size
      assert_equal 1, policy.consent_policy.requirements.size
    end

    def test_policy_can_be_retrieved
      PamDsl.define_policy(:test_policy) do
        field :email, type: :email
      end

      retrieved = PamDsl.policy(:test_policy)
      assert_equal :test_policy, retrieved.name
    end

    def test_policy_not_found_raises_error
      assert_raises(PolicyNotFoundError) do
        PamDsl.policy(:nonexistent)
      end
    end

    # --- LIA compliance gaps (Def. 2: legitimate_interests basis_ok) ---

    def test_lia_compliance_gaps_returns_undocumented_li_purposes
      policy = Policy.new(:test)
      policy.purpose(:analytics) { basis :legitimate_interests }
      policy.purpose(:billing)   { basis :contract }

      gaps = policy.lia_compliance_gaps
      assert_equal 1, gaps.size
      assert_equal :analytics, gaps.first.name
    end

    def test_lia_compliance_gaps_empty_when_all_documented
      policy = Policy.new(:test)
      policy.purpose(:analytics) { basis :legitimate_interests; lia_documented! }

      assert_empty policy.lia_compliance_gaps
    end

    def test_lia_compliance_gaps_ignores_non_li_purposes
      policy = Policy.new(:test)
      policy.purpose(:marketing) { basis :consent }
      policy.purpose(:billing)   { basis :contract }

      assert_empty policy.lia_compliance_gaps
    end

    def test_lia_documented_predicate
      p = Purpose.new(:analytics)
      refute p.lia_documented?
      p.lia_documented!
      assert p.lia_documented?
    end

    def test_lia_documented_can_be_unset
      p = Purpose.new(:analytics)
      p.lia_documented!
      p.lia_documented!(false)
      refute p.lia_documented?
    end

    def test_validate_access_not_blocked_by_undocumented_lia
      policy = Policy.new(:test)
      policy.field(:email, type: :email) { allow_for :analytics }
      policy.purpose(:analytics) do
        basis :legitimate_interests
        requires :email
        # deliberately no lia_documented!
      end

      # access is permitted — LIA is a compliance check, not an enforcement gate
      assert policy.validate_access!([:email], :analytics, subject: 1)
    end

    def test_multiple_li_purposes_all_surface_as_gaps
      policy = Policy.new(:test)
      policy.purpose(:analytics)  { basis :legitimate_interests }
      policy.purpose(:profiling)  { basis :legitimate_interests }
      policy.purpose(:billing)    { basis :contract }

      gaps = policy.lia_compliance_gaps
      assert_equal 2, gaps.size
      assert_equal %i[analytics profiling], gaps.map(&:name)
    end

    # --- allow_for / requires equivalence (paper §3.2) ---

    def test_allow_for_alone_is_sufficient_for_access
      policy = Policy.new(:test)
      policy.field(:email, type: :email) { allow_for :marketing }
      policy.purpose(:marketing) { basis :consent }  # no requires/optionally

      assert policy.allowed?(:email, :marketing)
    end

    def test_purpose_side_alone_is_sufficient_when_field_has_no_allow_for
      policy = Policy.new(:test)
      policy.field(:email, type: :email)             # no allow_for
      policy.purpose(:marketing) { requires :email }

      assert policy.allowed?(:email, :marketing)
    end

    def test_neither_notation_denies_access
      policy = Policy.new(:test)
      policy.field(:email, type: :email)             # no allow_for
      policy.purpose(:marketing) { basis :consent }  # no requires/optionally

      refute policy.allowed?(:email, :marketing)
    end

    def test_both_notations_together_permit_access
      policy = Policy.new(:test)
      policy.field(:email, type: :email) { allow_for :marketing }
      policy.purpose(:marketing) { requires :email }

      assert policy.allowed?(:email, :marketing)
    end

    def test_allow_for_does_not_grant_access_to_other_purposes
      policy = Policy.new(:test)
      policy.field(:email, type: :email) { allow_for :marketing }
      policy.purpose(:marketing) { basis :consent }
      policy.purpose(:analytics) { basis :legitimate_interests }

      assert policy.allowed?(:email, :marketing)
      refute policy.allowed?(:email, :analytics)
    end

    # --- Art. 9 (Def. 1, Condition 5) ---

    def test_restricted_field_without_art9_basis_raises_sensitivity_violation
      policy = Policy.new(:health_data)
      policy.field(:diagnosis, type: :health, sensitivity: :restricted) do
        allow_for :treatment
      end
      policy.purpose(:treatment) do
        basis :contract
        requires :diagnosis
      end

      assert_raises(SensitivityViolationError) do
        policy.validate_access!([:diagnosis], :treatment, subject: 1)
      end
    end

    def test_restricted_field_with_art9_basis_permits_access
      policy = Policy.new(:health_data)
      policy.field(:diagnosis, type: :health, sensitivity: :restricted) do
        allow_for :treatment
      end
      policy.purpose(:treatment) do
        basis :contract
        art9_basis :health_care
        requires :diagnosis
      end

      assert policy.validate_access!([:diagnosis], :treatment, subject: 1)
    end

    # Condition 5 keys off the Art. 9 data *type*, not the :restricted risk *level*.
    # A :restricted financial/identifier field (high risk, but not Art. 9 special
    # category) does NOT require an Art. 9(2) basis — e.g. a tax or bank identifier.
    def test_restricted_but_non_special_category_field_needs_no_art9_basis
      policy = Policy.new(:finance_data)
      policy.field(:iban, type: :financial, sensitivity: :restricted) do
        allow_for :payment_processing
      end
      policy.purpose(:payment_processing) do
        basis :contract
        requires :iban
      end

      assert policy.validate_access!([:iban], :payment_processing, subject: 1)
    end

    # Conversely, an Art. 9 *type* triggers Condition 5 even when its sensitivity
    # level is below :restricted — the type, not the label, drives the requirement.
    def test_special_category_type_below_restricted_still_requires_art9_basis
      policy = Policy.new(:health_data)
      policy.field(:vitals, type: :health, sensitivity: :confidential) do
        allow_for :treatment
      end
      policy.purpose(:treatment) do
        basis :contract
        requires :vitals
      end

      assert_raises(SensitivityViolationError) do
        policy.validate_access!([:vitals], :treatment, subject: 1)
      end
    end

    def test_art9_basis_accepts_multiple_bases
      purpose = Purpose.new(:research)
      purpose.art9_basis(:health_care, :research_archiving)

      assert_equal [:health_care, :research_archiving], purpose.art9_bases
      assert purpose.art9_basis?
    end

    def test_art9_basis_accumulates_across_calls
      purpose = Purpose.new(:research)
      purpose.art9_basis(:health_care)
      purpose.art9_basis(:research_archiving)

      assert_equal [:health_care, :research_archiving], purpose.art9_bases
    end

    def test_art9_basis_rejects_invalid_value
      purpose = Purpose.new(:invalid)
      assert_raises(PamDsl::Error) do
        purpose.art9_basis(:made_up_basis)
      end
    end

    def test_non_restricted_field_needs_no_art9_basis
      policy = Policy.new(:user_data)
      policy.field(:email, type: :email, sensitivity: :confidential) do
        allow_for :marketing
      end
      policy.purpose(:marketing) do
        basis :consent
        requires :email
      end
      policy.consent_policy.grant_consent(purpose: :marketing, subject: 1)

      assert policy.validate_access!([:email], :marketing, subject: 1)
    end

    def test_mixed_batch_with_restricted_field_requires_art9_basis
      policy = Policy.new(:mixed)
      policy.field(:name, type: :name, sensitivity: :internal) do
        allow_for :treatment
      end
      policy.field(:diagnosis, type: :health, sensitivity: :restricted) do
        allow_for :treatment
      end
      policy.purpose(:treatment) do
        basis :contract
        requires :name, :diagnosis
      end

      assert_raises(SensitivityViolationError) do
        policy.validate_access!([:name, :diagnosis], :treatment, subject: 1)
      end
    end
  end
end
