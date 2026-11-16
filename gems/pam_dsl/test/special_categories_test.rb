require "test_helper"
require "stringio"

module PamDsl
  # Every GDPR Art. 9(1) special category has a field type, and so does
  # Art. 10 data (criminal convictions and offences). An Art. 9 type needs an
  # Art. 9(2) basis on the purpose that reads it (Def. 1, Condition 5); an
  # Art. 10 type needs official authority or an authorisation by Union or
  # Member State law, declared with art10_authorisation. Neither satisfies the
  # other.
  class SpecialCategoriesTest < Minitest::Test
    NEW_ART9_TYPES = %i[
      genetic racial_ethnic_origin political_opinion religious_belief
      trade_union_membership sex_life_orientation
    ].freeze

    AUTHORISATION = "Staff Vetting Act, s. 4 (staff working with children)".freeze

    def setup
      PamDsl.reset!
      PIIDetector.reset!
    end

    # PIIDetector.partial_match is process-wide and two tests below switch it;
    # put back the default so later tests see partial matching.
    def teardown
      PamDsl.reset!
      PamDsl.logger = nil
      PIIDetector.reset!
    end

    # ── Art. 9(1): the six categories PAM had no type for ──

    def test_every_art9_category_has_a_special_category_type
      NEW_ART9_TYPES.each do |type|
        field = Field.new(:data, type: type)
        assert field.special_category?, type
        refute field.criminal_data?, type
      end
      assert_equal %i[health biometric] + NEW_ART9_TYPES, Field::SPECIAL_CATEGORY_TYPES
    end

    def test_each_new_art9_type_without_an_art9_basis_raises
      NEW_ART9_TYPES.each do |type|
        policy = policy_with(type, basis_block: proc { basis :contract })

        error = assert_raises(SpecialCategoryViolationError, type) do
          policy.validate_access!([:data], :processing, subject: 1)
        end
        assert_match(/special-category \(Article 9\)/, error.message)
      end
    end

    def test_each_new_art9_type_with_an_art9_basis_passes
      NEW_ART9_TYPES.each do |type|
        policy = policy_with(type, basis_block: proc { basis :contract; art9_basis :employment_law })

        assert policy.validate_access!([:data], :processing, subject: 1), type
      end
    end

    def test_an_art10_authorisation_does_not_satisfy_art9
      policy = policy_with(:trade_union_membership, basis_block: proc { basis :legal_obligation; art10_authorisation AUTHORISATION })

      assert_raises(SpecialCategoryViolationError) { policy.validate_access!([:data], :processing, subject: 1) }
    end

    # ── Art. 10: criminal convictions and offences ──

    def test_criminal_offence_is_art10_data_not_a_special_category
      field = Field.new(:conviction, type: :criminal_offence)

      assert field.criminal_data?
      refute field.special_category?
      assert_equal [:criminal_offence], Field::CRIMINAL_DATA_TYPES
      assert_operator CriminalDataViolationError, :<, PamDsl::Error
    end

    def test_criminal_offence_field_without_authorisation_raises
      policy = policy_with(:criminal_offence, basis_block: proc { basis :legal_obligation })

      error = assert_raises(CriminalDataViolationError) do
        policy.validate_access!([:data], :processing, subject: 1)
      end
      assert_match(/Article 10/, error.message)
    end

    def test_criminal_offence_field_with_authorisation_passes
      policy = policy_with(:criminal_offence, basis_block: proc { basis :legal_obligation; art10_authorisation AUTHORISATION })

      assert policy.validate_access!([:data], :processing, subject: 1)
      assert_equal [AUTHORISATION], policy.get_purpose(:processing).art10_authorisations
    end

    def test_an_art9_basis_does_not_satisfy_art10
      policy = policy_with(:criminal_offence, basis_block: proc { basis :legal_obligation; art9_basis :substantial_public_interest })

      assert_raises(CriminalDataViolationError) { policy.validate_access!([:data], :processing, subject: 1) }
    end

    def test_the_subjectless_field_check_reports_it_too
      policy = policy_with(:criminal_offence, basis_block: proc { basis :legal_obligation })

      assert_equal [CriminalDataViolationError], policy.field_violations([:data], :processing).map(&:class)
      assert_raises(CriminalDataViolationError) { policy.validate_fields!([:data], :processing) }
    end

    def test_both_conditions_are_reported_after_the_field_checks
      policy = Policy.new(:vetting)
      policy.field(:religion, type: :religious_belief)
      policy.field(:convictions, type: :criminal_offence)
      policy.purpose(:vetting) do
        basis :legal_obligation
        requires :religion, :convictions
      end

      assert_equal [SpecialCategoryViolationError, CriminalDataViolationError],
                   policy.access_violations(%i[religion convictions], :vetting, subject: 1).map(&:class)
    end

    def test_audit_mode_records_an_art10_violation_and_lets_the_access_through
      PamDsl.logger = Logger.new(StringIO.new)
      recorded = []
      PamDsl.on_violation { |v| recorded << v.error_class }
      policy = policy_with(:criminal_offence, basis_block: proc { basis :legal_obligation })
      policy.enforcement(:audit)

      assert_equal false, policy.validate_access!([:data], :processing, subject: 1)
      assert_equal [CriminalDataViolationError], recorded
    end

    def test_art10_authorisation_accumulates_and_refuses_a_blank
      purpose = Purpose.new(:vetting)
      refute purpose.art10_authorised?
      purpose.art10_authorisation AUTHORISATION
      purpose.art10_authorisation "official authority: the Ministry of Justice", AUTHORISATION

      assert purpose.art10_authorised?
      assert_equal [AUTHORISATION, "official authority: the Ministry of Justice"], purpose.art10_authorisations
      assert_raises(PamDsl::Error) { purpose.art10_authorisation "  " }
      assert_raises(PamDsl::Error) { purpose.art10_authorisation :public_task }
    end

    # ── The detector, and so the generator, proposes the new types ──

    PROPOSED = {
      genetic_test_result: :genetic, dna_sample: :genetic, genotype: :genetic, genome: :genetic,
      ethnicity: :racial_ethnic_origin, ethnic_origin: :racial_ethnic_origin, race: :racial_ethnic_origin,
      political_opinion: :political_opinion, political_affiliation: :political_opinion,
      political_party: :political_opinion, party_affiliation: :political_opinion,
      religion: :religious_belief, religious_affiliation: :religious_belief,
      philosophical_beliefs: :religious_belief,
      trade_union: :trade_union_membership, trade_union_member: :trade_union_membership,
      union_membership: :trade_union_membership, labour_union: :trade_union_membership,
      sexual_orientation: :sex_life_orientation, sex_life: :sex_life_orientation,
      sexual_preference: :sex_life_orientation,
      criminal_record: :criminal_offence, criminal_convictions: :criminal_offence,
      conviction: :criminal_offence, criminal_offence: :criminal_offence, criminal_offense: :criminal_offence,
      criminal_background_check: :criminal_offence
    }.freeze

    # Vague names propose nothing: a party is often a counterparty, a union a
    # set operation, an orientation a page's, a denomination a banknote's.
    VAGUE = %i[party union orientation denomination faith belief opinion origin offence record gene
               race_status ethnicity_code criminal_record_status].freeze

    def test_the_detector_proposes_the_new_types_for_typical_column_names
      [true, false].each do |partial|
        PIIDetector.partial_match = partial
        PROPOSED.each do |column, type|
          assert_equal type, PIIDetector.pii_type(column), "#{column} (partial_match #{partial})"
          assert_equal :restricted, PIIDetector.sensitivity(column), column
          assert PIIDetector.sensitive?(type), type
        end
      end
      # A prefixed name only when matching partially (the default)
      PIIDetector.partial_match = true
      assert_equal :racial_ethnic_origin, PIIDetector.pii_type(:applicant_race)
      assert_equal :trade_union_membership, PIIDetector.pii_type(:employee_trade_union)
    end

    def test_vague_names_propose_nothing
      [true, false].each do |partial|
        PIIDetector.partial_match = partial
        VAGUE.each { |column| assert_nil PIIDetector.pii_type(column), "#{column} (partial_match #{partial})" }
      end
    end

    def test_the_generator_writes_the_proposed_types_into_the_draft
      generator = PolicyGenerator.new(:test, output_path: File::NULL)
      member = Struct.new(:name, :table_name, :primary_key, :columns, :ignored_columns) do
        def connection
          cols = columns
          Struct.new(:cols) { def columns(_table) = cols.map { |c| Struct.new(:name).new(c) } }.new(cols)
        end
      end.new("Member", "members", "id", %w[id trade_union_member criminal_record title], [])

      found = generator.send(:scan_model, member)
      assert_equal :trade_union_membership, found["trade_union_member"][:type]
      assert_equal :criminal_offence, found["criminal_record"][:type]

      detected = found.transform_keys(&:to_sym).transform_values { |c| c.merge(models: ["Member"], ignored_in: []) }
      code = generator.send(:generate_fields_code, detected)
      assert_includes code, "field :trade_union_member, type: :trade_union_membership, sensitivity: :restricted"
      assert_includes code, "field :criminal_record, type: :criminal_offence, sensitivity: :restricted"
      assert_includes code, "art9_basis"
      assert_includes code, "art10_authorisation"
    end

    # ── The record of processing ──

    def test_the_register_shows_the_art9_bases_and_the_art10_authorisation
      define_vetting_policy(authorised: true)
      output = StringIO.new
      Reporter.new(:vetting, output: output).article_30_report

      assert_includes output.string, "Art. 9(2) Basis:  employment_law (Art. 9(2)(b))"
      assert_includes output.string, "Art. 10:          #{AUTHORISATION}"
      assert_includes output.string, "Every Article 30(1) item is declared."
      assert_empty PamDsl.policy(:vetting).article_30_gaps

      activity = Reporter.new(:vetting).to_h[:article_30][:processing_activities].first
      assert_equal ["employment_law"], activity[:art9_bases]
      assert_equal [AUTHORISATION], activity[:art10_authorisations]
    end

    def test_the_register_lists_a_missing_authorisation_and_a_missing_art9_basis
      define_vetting_policy(authorised: false)
      output = StringIO.new
      Reporter.new(:vetting, output: output).article_30_report

      assert_includes output.string, "Art. 9(2) Basis:  NOT DECLARED (Art. 9(2))"
      assert_includes output.string, "Art. 10:          NOT DECLARED (Art. 10)"
      gaps = PamDsl.policy(:vetting).article_30_gaps
      assert_includes gaps, [:vetting, "Art. 9(2) basis for special-category data"]
      assert_includes gaps, [:vetting, "Art. 10 authorisation for criminal-offence data"]
    end

    # A purpose that reads neither kind of data prints neither line.
    def test_the_register_omits_both_lines_for_ordinary_data
      PamDsl.define_policy(:plain) do
        field :email, type: :email
        purpose(:contact) { basis :contract; requires :email }
      end
      output = StringIO.new
      Reporter.new(:plain, output: output).article_30_report

      refute_includes output.string, "Art. 9(2) Basis"
      refute_includes output.string, "Art. 10:"
    end

    private

    def policy_with(type, basis_block:)
      policy = Policy.new(:special)
      policy.field(:data, type: type, sensitivity: :restricted)
      policy.purpose(:processing) do
        instance_eval(&basis_block)
        requires :data
      end
      policy
    end

    def define_vetting_policy(authorised:)
      authorisation = AUTHORISATION
      PamDsl.define_policy(:vetting) do
        field :union_member, type: :trade_union_membership
        field :convictions, type: :criminal_offence
        security_measures "role-based access"
        purpose :vetting do
          basis :legal_obligation
          if authorised
            art9_basis :employment_law
            art10_authorisation authorisation
          end
          requires :union_member, :convictions
          data_subjects "applicants"
          recipients "HR"
          no_transfers!
        end
      end
    end
  end
end
