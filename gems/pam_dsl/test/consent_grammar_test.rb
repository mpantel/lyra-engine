require "test_helper"

module PamDsl
  # A purpose whose basis is consent cannot make consent optional or not
  # withdrawable: the Regulation allows neither (Arts. 4(11), 6(1)(a), 7(3)).
  # Checked when the policy is defined, whichever of the purpose and the consent
  # block comes first, and whether the policy is built by define_policy or
  # by calling Policy's methods.
  class ConsentGrammarTest < Minitest::Test
    def setup
      PamDsl.reset!
    end

    def teardown
      PamDsl.reset!
    end

    def test_optional_consent_on_a_consent_purpose_is_refused
      error = assert_raises(ConsentGrammarError) do
        PamDsl.define_policy(:optional_consent) do
          field :email, type: :email
          purpose(:marketing) do
            basis :consent
            requires :email
          end
          consent { for_purpose(:marketing) { required!(false) } }
        end
      end

      assert_match(/marketing/, error.message)
      assert_match(/Art\. 6\(1\)\(a\)/, error.message)
    end

    def test_consent_that_cannot_be_withdrawn_on_a_consent_purpose_is_refused
      error = assert_raises(ConsentGrammarError) do
        PamDsl.define_policy(:locked_consent) do
          field :email, type: :email
          purpose(:marketing) do
            basis :consent
            requires :email
          end
          consent { for_purpose(:marketing) { withdrawable!(false) } }
        end
      end

      assert_match(/Art\. 7\(3\)/, error.message)
    end

    def test_the_order_does_not_matter
      assert_raises(ConsentGrammarError) do
        PamDsl.define_policy(:consent_first) do
          field :email, type: :email
          consent { for_purpose(:marketing) { withdrawable!(false) } }
          purpose(:marketing) do
            basis :consent
            requires :email
          end
        end
      end
    end

    def test_a_consent_purpose_with_the_defaults_is_accepted
      policy = PamDsl.define_policy(:fine) do
        field :email, type: :email
        purpose(:marketing) do
          basis :consent
          requires :email
        end
        consent { for_purpose(:marketing) { withdrawable! } }
      end

      assert policy.consent_policy.required_for?(:marketing)
    end

    def test_optional_consent_on_another_basis_is_still_allowed
      policy = PamDsl.define_policy(:analytics_on_interest) do
        field :email, type: :email
        purpose(:analytics) do
          basis :legitimate_interests
          requires :email
        end
        consent { for_purpose(:analytics) { required!(false) } }
      end

      refute policy.consent_policy.required_for?(:analytics)
    end
    # A policy built with Policy.new and its methods, not define_policy, is
    # checked too, in either order.
    def test_a_policy_built_by_its_methods_is_checked_with_the_consent_block_first
      policy = Policy.new(:built)
      policy.field(:email, type: :email)
      policy.consent { for_purpose(:marketing) { withdrawable!(false) } }

      assert_raises(ConsentGrammarError) do
        policy.purpose(:marketing) do
          basis :consent
          requires :email
        end
      end
    end

    def test_a_policy_built_by_its_methods_is_checked_with_the_purpose_first
      policy = Policy.new(:built)
      policy.field(:email, type: :email)
      policy.purpose(:marketing) do
        basis :consent
        requires :email
      end

      assert_raises(ConsentGrammarError) { policy.consent { for_purpose(:marketing) { required!(false) } } }
    end

    # The basis is consent, so access needs an active consent whether or not
    # the policy declares a consent block for the purpose: without consent
    # there is no basis (Art. 6(1)(a)).
    def test_a_consent_purpose_without_a_consent_block_still_needs_consent
      policy = PamDsl.define_policy(:no_block) do
        field :email, type: :email
        purpose(:marketing) do
          basis :consent
          requires :email
        end
      end

      assert_raises(ConsentRequiredError) { policy.validate_access!([:email], :marketing, subject: 7) }

      policy.consent_policy.grant_consent(purpose: :marketing, subject: 7)
      assert policy.validate_access!([:email], :marketing, subject: 7)

      policy.consent_policy.withdraw_consent(purpose: :marketing, subject: 7)
      assert_raises(ConsentRequiredError) { policy.validate_access!([:email], :marketing, subject: 7) }
    end

    def test_another_basis_without_a_consent_block_needs_no_consent
      policy = PamDsl.define_policy(:contract_only) do
        field :email, type: :email
        purpose(:billing) do
          basis :contract
          requires :email
        end
      end

      assert policy.validate_access!([:email], :billing, subject: 7)
    end
  end
end
