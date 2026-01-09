require "test_helper"

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
  end
end
