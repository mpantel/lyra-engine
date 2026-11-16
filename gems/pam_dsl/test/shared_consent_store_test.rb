require "test_helper"

module PamDsl
  # PamDsl.consent_store: a consent store shared by every policy (Lyra
  # installs a durable one). Unset, each policy keeps its own in memory.
  class SharedConsentStoreTest < Minitest::Test
    def setup
      PamDsl.reset!
      PamDsl.consent_store = nil
      @shop = PamDsl.define_policy(:shop) do
        field :email, type: :email
        purpose :newsletter do
          basis :consent
          requires :email
        end
      end
      @club = PamDsl.define_policy(:club) do
        field :email, type: :email
        purpose :newsletter do
          basis :consent
          requires :email
        end
      end
    end

    def teardown
      PamDsl.consent_store = nil
      PamDsl.reset!
    end

    def test_without_a_shared_store_each_policy_keeps_its_own
      refute @shop.consent_policy.store.durable?
      @shop.consent_policy.grant_consent(purpose: :newsletter, subject: "Payer$7")

      assert @shop.validate_access!([:email], :newsletter, subject: "Payer$7")
      assert_raises(ConsentRequiredError) { @club.validate_access!([:email], :newsletter, subject: "Payer$7") }
    end

    def test_a_shared_store_is_every_policy_s_store_and_survives_reset
      shared = ConsentStore.new
      PamDsl.consent_store = shared
      @shop.consent_policy.grant_consent(purpose: :newsletter, subject: "Payer$7")

      assert_same shared, @club.consent_policy.store
      assert @club.validate_access!([:email], :newsletter, subject: "Payer$7")

      PamDsl.reset!
      assert_same shared, PamDsl.consent_store
      club = PamDsl.define_policy(:club) do
        field :email, type: :email
        purpose :newsletter do
          basis :consent
          requires :email
        end
      end
      assert club.validate_access!([:email], :newsletter, subject: "Payer$7")
    end

    def test_restore_rebuilds_a_recorded_record_without_checking_the_clock
      granted = ConsentRecord.restore(purpose: :newsletter, subject: "Payer$7", state: :granted,
                                      granted_at: Time.now - 7200, expires_at: Time.now - 3600)
      assert_equal :expired, granted.state, "expiry stays derived"

      withdrawn = ConsentRecord.restore(purpose: "newsletter", subject: "Payer$7", state: "withdrawn",
                                        granted_at: Time.now - 60, withdrawn_at: Time.now)
      assert_equal [:newsletter, :withdrawn], [withdrawn.purpose, withdrawn.state]
    end

    # A store that cannot answer for a subject raises ConsentRequiredError;
    # under the :consent exception of Art. 18(2) that refusal is reported
    # with the restriction, not raised past enforcement.
    def test_a_consent_store_refusal_under_the_consent_exception_is_a_violation
      PamDsl.define_policy(:survey_policy) do
        field :email, type: :email
        purpose :survey do
          basis :legitimate_interests
          lia_documented!
          allowed_when_restricted :consent
          requires :email
        end
      end
      store = ConsentStore.new
      def store.record_for(*) = raise(ConsentRequiredError, "cannot tell whose consent")
      PamDsl.consent_store = store
      PamDsl.rights.restrict!(subject: "Payer$7", ground: :accuracy_contested)

      violations = PamDsl.policy(:survey_policy).access_violations([:email], :survey, subject: "Payer$7")
      assert_equal [RestrictedProcessingError, ConsentRequiredError], violations.map(&:class)
      assert_match(/whose consent/, violations.last.message)
    end

    def test_the_consent_audit_lists_the_shared_store_s_records
      store = ConsentStore.new
      def store.consents_for(key)
        [{ purpose: :newsletter, subject_key: key, state: :granted, granted_at: Time.at(0), expires_at: nil }]
      end
      PamDsl.consent_store = store

      audit = GDPRCompliance.new(subject_id: 7, subject_type: "Payer", record_reader: ->(*) { [] }).consent_audit
      assert_equal "Payer$7", audit[:recorded_consents].sole[:subject_key]
      assert_equal true, audit[:current_consents][:newsletter][:granted]
      assert_equal :consent_store, audit[:current_consents][:newsletter][:source]
    end
  end
end
