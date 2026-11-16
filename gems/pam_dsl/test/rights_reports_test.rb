require "test_helper"
require "stringio"

module PamDsl
  # What PAM DSL gives a host for the enforcement of Arts. 18 and 21 beyond
  # validate_access! (1.0.0): Condition 6 alone for an access that names no
  # declared field (validate_rights!), the subject's requests in the
  # Art. 15 copy, and each purpose's declarations in the per-subject record
  # of processing.
  class RightsReportsTest < Minitest::Test
    ProcessingRecord = Struct.new(:event_id, :data, :metadata)

    def setup
      PamDsl.reset!
      PamDsl.logger = Logger.new(StringIO.new)
      PamDsl.define_policy(:shop) do
        field(:email, type: :email)
        field(:name, type: :name)
        purpose(:payment) { basis :contract; requires :email }
        purpose(:analytics) do
          basis :legitimate_interests
          lia_documented!
          requires :email, :name
        end
        purpose(:defence_of_claims) do
          basis :legitimate_interests
          lia_documented!
          requires :email
          allowed_when_restricted :legal_claims
        end
        purpose(:survey) { basis :consent; requires :email }
      end
    end

    def teardown
      PamDsl.reset!
      PamDsl.logger = nil
      PamDsl.access_recorder = nil
      PamDsl.rights_store = nil
    end

    def shop = PamDsl.policy(:shop)
    def rights = PamDsl.rights

    # ── validate_rights!: Condition 6 alone ──

    def test_validate_rights_checks_condition_6_only
      assert shop.validate_rights!([], :payment, subject: "Payer$7"), "nothing in force"
      assert shop.validate_rights!([], :survey, subject: "Payer$7"), "no consent step: that is Condition 4's"
      assert shop.validate_rights!([], :undeclared, subject: "Payer$7"), "no purpose check either"

      rights.restrict!(subject: "Payer$7", ground: :accuracy_contested)
      assert_raises(RestrictedProcessingError) { shop.validate_rights!([], :payment, subject: "Payer$7") }
      assert shop.validate_rights!([], :defence_of_claims, subject: "Payer$7"), "an Art. 18(2) exception"
      assert shop.validate_rights!([], :payment, subject: "Payer$8")
    end

    def test_validate_rights_with_a_field_restriction_covers_only_its_fields
      rights.restrict!(subject: "Payer$7", ground: :accuracy_contested, fields: [:name])
      assert shop.validate_rights!([], :payment, subject: "Payer$7")
      assert_raises(RestrictedProcessingError) { shop.validate_rights!([:name], :analytics, subject: "Payer$7") }
    end

    def test_validate_rights_records_a_refusal_and_audits_in_audit_mode
      recorded = []
      PamDsl.access_recorder = Struct.new(:log) { def record?(_) = true; def call(a) = log << a }.new(recorded)
      assert shop.validate_rights!([], :payment, subject: "Payer$7")
      assert_empty recorded, "an access Condition 6 allows is not recorded here: nothing was read that it covers"

      rights.restrict!(subject: "Payer$7", ground: :accuracy_contested)
      assert_raises(RestrictedProcessingError) { shop.validate_rights!([], :payment, subject: "Payer$7") }
      assert_equal [:denied], recorded.map(&:outcome)

      PamDsl.enforcement_mode = :audit
      refute shop.validate_rights!([], :payment, subject: "Payer$7")
      assert_equal %i[denied audited], recorded.map(&:outcome)
    end

    # ── The Art. 15 copy ──

    def test_the_copy_lists_the_subject_s_restrictions_and_objections
      r = rights.restrict!(subject: "Payer$7", ground: :accuracy_contested, fields: [:name], recorded_by: "desk 4")
      rights.notify_lift!(r.id)
      o = rights.object!(subject: "Payer$7", policy: :shop, purpose: :analytics, grounds: "my situation")
      rights.decide!(o.id, outcome: :overridden, grounds: :compelling_legitimate_grounds, reason: "fraud case",
                           by: "dpo", notified_at: Time.now)
      rights.restrict!(subject: "Payer$8", ground: :accuracy_contested)

      export = GDPRCompliance.new(subject_id: 7, subject_type: "Payer", record_reader: ->(*) { [] }).data_export
      restriction = export[:restrictions].sole
      assert_equal [r.id, "Payer$7", :accuracy_contested, "Art. 18(1)(a)", [:name], :lift_notified],
                   restriction.values_at(:id, :subject, :ground, :article, :fields, :state)
      assert_kind_of Time, restriction[:lift_notified_at]
      refute restriction.key?(:recorded_by)

      objection = export[:objections].sole
      assert_equal [o.id, :shop, :analytics, "Art. 21(1)", :overridden, "my situation", :compelling_legitimate_grounds,
                    "fraud case"],
                   objection.values_at(:id, :policy, :purpose, :article, :state, :grounds, :decision_grounds, :reason)
      refute objection.key?(:decided_by)
    end

    def test_a_host_names_the_keys_the_subject_s_rights_are_under
      rights.restrict!(subject: "Invoice$3", ground: :needed_for_legal_claims)
      export = GDPRCompliance.new(subject_id: 7, subject_type: "Payer", record_reader: ->(*) { [] },
                                  rights_keys: ->(_records) { ["Payer$7", "Invoice$3"] }).data_export
      assert_equal ["Invoice$3"], export[:restrictions].map { _1[:subject] }
    end

    def test_a_subject_with_no_requests_has_empty_lists
      export = GDPRCompliance.new(subject_id: 7, subject_type: "Payer", record_reader: ->(*) { [] }).data_export
      assert_equal [[], []], export.values_at(:restrictions, :objections)
    end

    # ── The per-subject record of processing ──

    def test_processing_activities_carry_each_declared_purpose_s_rights
      records = [ProcessingRecord.new("e1", { operation: :created, model_class: "Visit", model_id: 1, timestamp: Time.now,
                                              attributes: { email: "a@example.com" } }, { source: "web" })]
      compliance = GDPRCompliance.new(subject_id: 1, record_reader: ->(_id, _type) { records },
                                      policy_resolver: ->(_model) { shop })
      activity = compliance.processing_activities.sole

      assert_equal({ objectable: "Art. 21(1)", allowed_when_restricted: [:legal_claims] },
                   activity[:rights_by_purpose][:defence_of_claims])
      assert_equal({ objectable: nil, allowed_when_restricted: [] }, activity[:rights_by_purpose][:payment])
      assert_nil activity[:objectable], "several purposes: no single answer"
    end
  end
end
