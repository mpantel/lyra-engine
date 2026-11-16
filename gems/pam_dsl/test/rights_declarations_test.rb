require "test_helper"
require "stringio"
require "json"

module PamDsl
  # What a policy declares about Arts. 18 and 21: which purposes may continue
  # while a subject's processing is restricted (Art. 18(2)), and which purposes
  # a subject can object to (Art. 21), derived from the basis and two markers.
  class RightsDeclarationsTest < Minitest::Test
    def setup
      PamDsl.reset!
    end

    def teardown
      PamDsl.reset!
    end

    # ── allowed_when_restricted (Art. 18(2)) ──

    def test_allowed_when_restricted_accepts_the_art18_2_exceptions
      purpose = Purpose.new(:claims)
      purpose.allowed_when_restricted :consent, :legal_claims
      purpose.allowed_when_restricted :protection_of_rights
      purpose.allowed_when_restricted :important_public_interest, reference: "Tax Code, Art. 38"

      assert_equal %i[consent legal_claims protection_of_rights important_public_interest],
                   purpose.restriction_exceptions
      assert_equal "Tax Code, Art. 38", purpose.important_public_interest_reference
      assert purpose.continues_under_restriction?(:legal_claims)
      refute Purpose.new(:other).continues_under_restriction?(:legal_claims)
    end

    def test_allowed_when_restricted_rejects_an_unknown_exception
      error = assert_raises(Error) { Purpose.new(:p).allowed_when_restricted :legal_obligation }
      assert_match(/Art\. 18\(2\)/, error.message)
      assert_raises(Error) { Purpose.new(:p).allowed_when_restricted }
    end

    def test_important_public_interest_needs_a_reference
      error = assert_raises(Error) { Purpose.new(:p).allowed_when_restricted :important_public_interest }
      assert_match(/reference/, error.message)
      assert_raises(Error) { Purpose.new(:p).allowed_when_restricted :important_public_interest, reference: "  " }
    end

    def test_a_reference_without_important_public_interest_is_refused
      assert_raises(Error) { Purpose.new(:p).allowed_when_restricted :legal_claims, reference: "Some Act" }
    end

    # ── objectable (Art. 21) ──

    def test_objectable_follows_the_table_of_the_design_note
      assert_equal "Art. 21(1)", purpose_with { basis :legitimate_interests }.objectable
      assert_equal "Art. 21(1)", purpose_with { basis :public_task }.objectable
      %i[consent contract legal_obligation vital_interests].each do |basis_name|
        assert_nil purpose_with { basis basis_name }.objectable, basis_name
      end
      assert_nil Purpose.new(:draft).objectable # undetermined basis

      %i[consent contract legitimate_interests].each do |basis_name|
        assert_equal "Art. 21(2)", purpose_with { basis basis_name; direct_marketing! }.objectable, basis_name
      end

      assert_equal "Art. 21(6)",
                   purpose_with { basis :contract; research_or_statistics! public_interest_task: false }.objectable
      assert_nil purpose_with { basis :legal_obligation; research_or_statistics! public_interest_task: true }.objectable
      # Art. 21(1) covers every processing on Art. 6(1)(e) or (f), research or not: 21(6) adds a right for the
      # other bases, it does not take 21(1) away.
      assert_equal "Art. 21(1)", purpose_with { basis :public_task; research_or_statistics! public_interest_task: true }.objectable
      assert_equal "Art. 21(1)",
                   purpose_with { basis :legitimate_interests; research_or_statistics! public_interest_task: false }.objectable
    end

    def test_research_or_statistics_needs_an_explicit_public_interest_task_answer
      assert_raises(ArgumentError) { Purpose.new(:p).research_or_statistics! }
      assert_raises(Error) { Purpose.new(:p).research_or_statistics! public_interest_task: "yes" }
    end

    def test_a_purpose_is_not_both_direct_marketing_and_research
      assert_raises(Error) { purpose_with { direct_marketing!; research_or_statistics! public_interest_task: false } }
      assert_raises(Error) { purpose_with { research_or_statistics! public_interest_task: false; direct_marketing! } }
    end

    def test_the_markers_are_readable
      marketing = purpose_with { basis :consent; direct_marketing! }
      research = purpose_with { basis :public_task; research_or_statistics! public_interest_task: true }

      assert marketing.direct_marketing?
      refute marketing.research_or_statistics?
      assert research.research_or_statistics?
      assert research.public_interest_task?
      refute Purpose.new(:p).direct_marketing?
    end

    # ── to_h, the comparator, the register and its export ──

    def test_policy_to_h_includes_the_declarations
      purposes = rights_policy.to_h[:purposes]

      assert_equal "Art. 21(1)", purposes[:analytics][:objectable]
      assert_equal "Art. 21(2)", purposes[:newsletter][:objectable]
      assert purposes[:newsletter][:direct_marketing]
      assert_equal({ public_interest_task: false }, purposes[:usage_statistics][:research_or_statistics])
      assert_nil purposes[:analytics][:research_or_statistics]
      assert_equal %i[legal_claims important_public_interest], purposes[:defence_of_claims][:allowed_when_restricted]
      assert_equal "Tax Code, Art. 38", purposes[:defence_of_claims][:important_public_interest_reference]
      assert_nil purposes[:payment][:objectable]
      assert_equal [], purposes[:payment][:allowed_when_restricted]
    end

    def test_the_comparator_sees_the_declarations
      rights_policy
      PamDsl.define_policy(:plain) { purpose(:analytics) { basis :legitimate_interests } }

      first = PolicyComparator.new(:shop, :plain).purpose_comparison[:first].find { |p| p[:name] == :defence_of_claims }
      assert_equal %i[legal_claims important_public_interest], first[:allowed_when_restricted]
      assert_equal "Art. 21(1)", first[:objectable]
    end

    def test_the_article_30_register_prints_the_right_to_object_and_the_exceptions
      rights_policy
      out = StringIO.new
      Reporter.new(:shop, output: out).article_30_report
      text = out.string

      assert_match(/Right to Object:\s+Art\. 21\(1\)/, text)
      assert_match(/Right to Object:\s+Art\. 21\(2\) \(direct marketing/, text)
      assert_match(/Right to Object:\s+Art\. 21\(6\)/, text)
      assert_match(/Right to Object:\s+none \(Art\. 6\(1\)\(b\)/, text)
      assert_match(/Under Restriction:\s+legal claims, important public interest \(Tax Code, Art\. 38\)/, text)
      assert_match(/Under Restriction:\s+stops/, text)
      refute_match(/Right to Object.*NOT DECLARED/, text) # not an Art. 30(1) item: no gap
    end

    def test_the_register_lists_a_research_purpose_on_a_public_interest_task_as_not_objectable
      PamDsl.define_policy(:stats) do
        purpose(:census) { basis :legal_obligation; research_or_statistics! public_interest_task: true }
      end
      out = StringIO.new
      Reporter.new(:stats, output: out).article_30_report

      assert_match(/Right to Object:\s+none \(Art\. 21\(6\)/, out.string)
    end

    def test_the_article_30_export_carries_the_declarations
      rights_policy
      data = Reporter.new(:shop, output: StringIO.new).to_h[:article_30]
      by_name = data[:processing_activities].to_h { |a| [a[:name], a] }

      assert_equal "Art. 21(1)", by_name["analytics"][:objectable]
      assert_nil by_name["payment"][:objectable]
      refute by_name.key?("right_to_object")
      assert by_name["newsletter"][:direct_marketing]
      refute by_name["analytics"][:direct_marketing]
      assert_equal({ public_interest_task: false }, by_name["usage_statistics"][:research_or_statistics])
      assert_nil by_name["analytics"][:research_or_statistics]
      assert_equal %w[legal_claims important_public_interest], by_name["defence_of_claims"][:allowed_when_restricted]
      assert_equal "Tax Code, Art. 38", by_name["defence_of_claims"][:important_public_interest_reference]
      assert_equal [], data[:not_declared].select { |gap| gap[:item].include?("Art. 21") || gap[:item].include?("Art. 18") }
    end

    ProcessingRecord = Struct.new(:event_id, :data, :metadata)

    def test_gdpr_processing_activities_carry_the_declarations
      rights_policy
      records = [ProcessingRecord.new("e1", { operation: :created, model_class: "Visit", model_id: 1, timestamp: Time.now,
                                              attributes: { email: "a@example.com" } }, { source: "analytics" })]
      compliance = GDPRCompliance.new(subject_id: 1, record_reader: ->(_id, _type) { records }, policy_name: :shop)
      activity = compliance.processing_activities.find { |a| a[:source] == "analytics" }

      assert_equal "Art. 21(1)", activity[:objectable]
      assert_equal [], activity[:allowed_when_restricted]
    end

    private

    def purpose_with(&block)
      purpose = Purpose.new(:p)
      purpose.instance_eval(&block)
      purpose
    end

    def rights_policy
      PamDsl.define_policy(:shop) do
        field(:email, type: :email)
        purpose(:analytics) { basis :legitimate_interests; lia_documented!; requires :email }
        purpose(:newsletter) { basis :consent; direct_marketing!; requires :email }
        purpose(:usage_statistics) { basis :contract; research_or_statistics! public_interest_task: false }
        purpose(:defence_of_claims) do
          basis :legitimate_interests
          allowed_when_restricted :legal_claims
          allowed_when_restricted :important_public_interest, reference: "Tax Code, Art. 38"
        end
        purpose(:payment) { basis :contract; requires :email }
      end
    end
  end
end
