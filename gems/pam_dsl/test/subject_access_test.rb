require "test_helper"

# The Art. 15 copy (GDPRCompliance#data_export's records, accesses,
# processing_context, notice and gaps), the field options it reads
# (withheld_from_access:, about:, collected_from) and the policy's
# access_notice. The store-specific parts (which records, their history, the
# access log) come from the records_reader and access_reader callables; these
# tests give them plain data.
module PamDsl
  class SubjectAccessTest < Minitest::Test
    Event = Struct.new(:event_id, :data, :metadata, keyword_init: true) do
      def timestamp = data[:timestamp]
      def operation = data[:operation]
      def model_class = data[:model_class]
      def model_id = data[:model_id]
      def attributes = data[:attributes] || {}
      def changes = data[:changes] || {}
    end

    T0 = Time.utc(2026, 1, 1)

    def setup
      PamDsl.reset!
      @policy = PamDsl.define_policy(:access_copy) do
        field :email, type: :email, collected_from: :data_subject
        field :vat_number, type: :identifier, collected_from: "the tax registry"
        field :payer_name, type: :name, about: :payer
        field :password_digest, type: :credential, withheld_from_access: "Art. 15(4): the controller's assessment, checked with the DPO"
        field :firstname, type: :name
        field :programme, type: :custom, collected_from: :data_subject

        purpose :invoicing do
          basis :legal_obligation
          requires :vat_number, :email
          recipients "tax authority"
          no_transfers!
        end

        purpose :fees do
          basis :contract
          requires :email, :firstname, :programme
        end

        retention do
          default 7.years
          for_model "Registration" do
            keep_for 10.years
            field :vat_number, duration: 5.years
          end
        end

        access_notice controller: "University of Example, Registry", rights: "Arts. 16-21: rectification, erasure, ...",
                      complaint: "the national supervisory authority"
      end
    end

    def teardown
      PamDsl.reset!
    end

    # ── The DSL ──────────────────────────────────────────────────────────────

    def test_field_options_are_declared_as_keywords_or_in_the_block
      digest = @policy.fields[:password_digest]
      assert digest.withheld_from_access?
      assert_match(/Art. 15\(4\)/, digest.withheld_from_access)
      assert_equal :payer, @policy.fields[:payer_name].about
      assert @policy.fields[:payer_name].about_another_person?
      assert_equal "the tax registry", @policy.fields[:vat_number].collected_from
      assert_equal :data_subject, @policy.fields[:email].collected_from

      policy = PamDsl.define_policy(:block_form) do
        field :card_token, type: :payment_token do
          withheld_from_access "Law X, art. Y (to be checked with the DPO)"
          collected_from "the card processor"
        end
        field :guardian_name, type: :name do
          about :guardian
        end
      end
      assert_equal "Law X, art. Y (to be checked with the DPO)", policy.fields[:card_token].withheld_from_access
      assert_equal "the card processor", policy.fields[:card_token].collected_from
      assert_equal :guardian, policy.fields[:guardian_name].about
    end

    def test_a_withholding_must_state_its_basis
      assert_raises(InvalidFieldError) { Field.new(:password_digest, type: :credential, withheld_from_access: true) }
      assert_raises(InvalidFieldError) { Field.new(:password_digest, type: :credential, withheld_from_access: " ") }
    end

    def test_a_field_about_the_data_subject_is_not_another_persons
      refute Field.new(:email, type: :email, about: :data_subject).about_another_person?
      refute Field.new(:email, type: :email).about_another_person?
    end

    def test_the_access_notice_is_a_policy_declaration
      assert_equal "the national supervisory authority", @policy.access_notice[:complaint]
      assert_raises(ArgumentError) { @policy.access_notice(website: "x") }
      assert_equal "University of Example, Registry", @policy.to_h[:access_notice][:controller]
      assert_equal "the tax registry", @policy.to_h[:fields][:vat_number][:collected_from]
    end

    # ── The copy ─────────────────────────────────────────────────────────────

    def test_existing_keys_are_unchanged_and_the_new_ones_are_added
      export = compliance.data_export

      %i[subject generated_at events pii_inventory data_lineage].each { |key| assert export.key?(key), key }
      %i[records accesses processing_context notice gaps].each { |key| assert export.key?(key), key }
      assert_equal 3, export[:events].size
    end

    # From 1.0.0 the copy's purposes are the policy's (processing_context): the
    # per-event processing_activities, a purpose guessed from the source's
    # keywords, is gone.
    def test_the_copy_has_no_guessed_processing_activities_only_the_policy_s_context
      export = compliance.data_export

      refute export.key?(:processing_activities)
      refute_empty export[:processing_context]
      assert(export[:processing_context].all? { |context| context.key?(:purpose) })
    end

    def test_every_attribute_is_in_the_copy_not_only_the_detected_ones
      record = registration(compliance.data_export)

      assert_equal 500, record[:attributes]["amount"]
      assert_equal "paid", record[:attributes]["status"]
      assert_equal "alice@example.com", record[:attributes]["email"]
    end

    def test_a_withheld_field_is_named_with_its_basis_and_its_values_are_left_out
      record = registration(compliance.data_export)

      refute record[:attributes].key?("password_digest")
      assert_equal [{ field: "password_digest", basis: @policy.fields[:password_digest].withheld_from_access }], record[:withheld]
      refute record[:history].any? { |entry| entry[:field] == "password_digest" }
    end

    def test_a_field_with_no_withholding_is_exported
      PamDsl.reset!
      PamDsl.define_policy(:access_copy) { field :password_digest, type: :credential }
      record = registration(compliance.data_export)

      assert_equal "x$2a", record[:attributes]["password_digest"]
      assert_empty record[:withheld]
    end

    def test_another_persons_field_goes_to_review_with_its_history
      record = registration(compliance.data_export)

      refute record[:attributes].key?("payer_name")
      review = record[:review].find { |entry| entry[:field] == "payer_name" }
      assert_equal :payer, review[:about]
      assert_equal "Bob Payer", review[:value]
      assert_equal ["Bob Payer"], review[:history].map { |entry| entry[:to] }
      refute record[:history].any? { |entry| entry[:field] == "payer_name" }
    end

    def test_history_is_included_by_default_with_from_and_to
      record = registration(compliance.data_export)
      change = record[:history].find { |entry| entry[:operation] == :updated && entry[:field] == "status" }

      assert_equal "pending", change[:from]
      assert_equal "paid", change[:to]
      assert_equal T0, record[:history_from]
    end

    def test_a_narrowed_request_leaves_out_history_and_accesses_and_says_so
      export = compliance(access_reader: ->(*) { [] }).data_export(history: false, accesses: false)

      assert_nil registration(export)[:history]
      assert_nil export[:accesses]
      assert_includes export[:gaps].map(&:last), "history not included (request narrowed)"
      assert_includes export[:gaps].map(&:last), "access log not included (request narrowed)"
    end

    def test_actors_are_role_labels_unless_disclosed
      history = registration(compliance.data_export)[:history]

      assert_equal %w[you staff system], history.map { |e| e[:by] }.uniq
      refute history.any? { |e| e.key?(:actor) }

      disclosed = registration(compliance.data_export(disclose_actors: true))[:history]
      staff = disclosed.find { |e| e[:by] == "staff" }
      assert_equal({ user_id: 99, ip_address: "10.0.0.1" }, staff[:actor])
    end

    # Without the actor's class an id that matches the subject's may be
    # another class's: the label says it cannot tell.
    def test_an_actor_without_a_type_is_never_taken_for_the_subject
      label = SubjectAccess::DEFAULT_ACTOR_LABEL
      subject = { id: 7, type: "Person" }

      assert_equal "you", label.call({ user_id: 7, user_type: "Person" }, subject)
      assert_equal "staff", label.call({ user_id: 7, user_type: "User" }, subject)
      assert_equal "staff or you", label.call({ user_id: 7 }, subject)
      assert_equal "staff", label.call({ user_id: 8 }, subject)
      assert_equal "system", label.call({}, subject)
    end

    # ── Review findings: the DSL ─────────────────────────────────────────────

    def test_empty_or_nil_declarations_are_refused
      assert_raises(InvalidFieldError) { PamDsl.define_policy(:a) { field(:x, type: :name) { about nil } } }
      assert_raises(InvalidFieldError) { PamDsl.define_policy(:b) { field(:x, type: :name, about: "") } }
      assert_raises(InvalidFieldError) { PamDsl.define_policy(:c) { field(:x, type: :name) { collected_from nil } } }
      assert_raises(InvalidFieldError) { PamDsl.define_policy(:d) { field(:x, type: :name, collected_from: "") } }
      assert_raises(PamDsl::Error) { PamDsl.define_policy(:e) { access_notice automated_decisions: nil } }
      assert_raises(PamDsl::Error) { PamDsl.define_policy(:f) { access_notice controller: " " } }
    end

    def test_the_comparator_compares_the_new_field_options
      first = PamDsl.define_policy(:cmp1) { field :x, type: :name, about: :payer }
      second = PamDsl.define_policy(:cmp2) { field :x, type: :name, collected_from: "registry", withheld_from_access: "basis" }
      hash = PolicyComparator.new(:cmp1, :cmp2).send(:field_to_hash, second.fields[:x])

      assert_equal "registry", hash[:collected_from]
      assert_equal "basis", hash[:withheld_from_access]
      assert_equal :payer, PolicyComparator.new(:cmp1, :cmp2).send(:field_to_hash, first.fields[:x])[:about]
    end

    # ── Review findings: the copy ────────────────────────────────────────────

    def test_the_old_keys_leave_out_withheld_fields_and_other_people_s_data
      old = compliance.data_export.slice(:events, :pii_inventory, :data_lineage).inspect

      refute_includes old, "x$2a", "withheld"
      refute_includes old, "Bob Payer", "another person's"
      assert_includes old, "alice@example.com"
    end

    def test_retention_is_what_the_policy_declares
      PamDsl.reset!
      PamDsl.define_policy(:access_copy) do
        field :email, type: :email, collected_from: :data_subject
        purpose(:fees) { basis :contract; requires :email; recipients "bank"; no_transfers! }
      end
      export = compliance.data_export
      fees = export[:processing_context].find { |c| c[:purpose] == :fees }

      assert_nil fees[:retention]["Registration"][:period]
      assert_includes export[:gaps], [nil, "Art. 15(1)(d) retention not declared: Registration"]

      PamDsl.reset!
      PamDsl.define_policy(:access_copy) do
        field :email, type: :email, collected_from: :data_subject
        purpose(:fees) { basis :contract; requires :email; recipients "bank"; no_transfers! }
        retention { default 3.years }
      end
      export = compliance.data_export
      assert_equal period(3.years), export[:processing_context].first[:retention]["Registration"][:period]
      refute_includes export[:gaps], [nil, "Art. 15(1)(d) retention not declared: Registration"]

      PamDsl.reset!
      PamDsl.define_policy(:access_copy) do
        field :email, type: :email, collected_from: :data_subject
        purpose(:fees) { basis :contract; requires :email; recipients "bank"; no_transfers! }
        retention { default nil }
      end
      export = compliance.data_export
      assert_nil export[:processing_context].first[:retention]["Registration"][:period]
      assert_includes export[:gaps], [nil, "Art. 15(1)(d) retention not declared: Registration"]
    end

    def test_columns_the_policy_does_not_declare_are_a_gap
      gaps = compliance.data_export[:gaps]

      assert_includes gaps, [nil, "not declared in the policy (no purpose, basis or retention stated): " \
                                  "Registration.amount, Registration.status, Registration.user_id"]
    end

    def test_an_access_reader_may_give_a_partial_log_with_its_gap
      partial = { entries: [{ at: T0, record: "User$7", outcome: "exported", actor: {} }], gap: "access log not enabled (accesses lists earlier exports only)" }
      export = compliance(access_reader: ->(*) { partial }).data_export

      assert_equal ["exported"], export[:accesses].map { |e| e[:outcome] }
      assert_includes export[:gaps], [nil, "access log not enabled (accesses lists earlier exports only)"]
    end

    def test_values_set_in_another_person_s_period_are_withheld_by_name
      reader = lambda do |*args, **opts|
        raw_records(*args, **opts).map { |r| r.merge(set_outside_periods: ["amount"]) }
      end
      record = registration(compliance(records_reader: reader).data_export)

      refute record[:attributes].key?("amount")
      assert_includes record[:withheld], { field: "amount", basis: "set while the record was another person's" }
    end

    def test_a_labelling_callable_maps_an_actor_to_a_label
      labeller = ->(actor, _subject) { actor[:user_id] == 99 ? "finance office" : "other" }
      history = registration(compliance(actor_label: labeller).data_export)[:history]

      assert_includes history.map { |e| e[:by] }, "finance office"
    end

    def test_the_access_log_lists_entries_with_role_labels
      entries = [{ at: T0, record: "Registration$42", policy: "access_copy", purpose: "invoicing",
                   legal_basis: "legal_obligation", fields: %w[vat_number], outcome: "granted",
                   actor: { user_id: 99, ip_address: "10.0.0.1" } }]
      export = compliance(access_reader: ->(*) { entries }).data_export

      assert_equal [{ at: T0, record: "Registration$42", purpose: "invoicing", legal_basis: "legal_obligation",
                      fields: %w[vat_number], outcome: "granted", by: "staff" }], export[:accesses]
    end

    def test_with_the_access_log_off_accesses_is_nil_and_a_gap
      export = compliance(access_reader: ->(*) { nil }).data_export

      assert_nil export[:accesses]
      assert_includes export[:gaps].map(&:last), "access log not enabled"
    end

    def test_the_processing_context_comes_from_the_policy
      export = compliance.data_export
      invoicing = export[:processing_context].find { |c| c[:purpose] == :invoicing }

      assert_equal :legal_obligation, invoicing[:legal_basis]
      assert_equal ["tax authority"], invoicing[:recipients]
      assert_equal [], invoicing[:transfers]
      assert_equal({ "Registration" => %w[email vat_number] }, invoicing[:fields])
      assert_equal period(10.years), invoicing[:retention]["Registration"][:period]
      assert_equal({ "vat_number" => period(5.years) }, invoicing[:retention]["Registration"][:fields])
      assert_equal "the tax registry", invoicing[:sources]["Registration.vat_number"]
      assert_equal "the data subject", invoicing[:sources]["Registration.email"]
      assert_includes invoicing[:data_categories], "identifier"
    end

    def test_what_the_policy_does_not_declare_is_a_gap_not_an_empty_value
      export = compliance.data_export
      fees = export[:processing_context].find { |c| c[:purpose] == :fees }

      assert_nil fees[:recipients]
      assert_nil fees[:transfers]
      gaps = export[:gaps]
      assert_includes gaps, [:fees, "Art. 15(1)(c) recipients"]
      assert_includes gaps, [:fees, "Art. 15(2) transfers to third countries"]
      refute_includes gaps, [:invoicing, "Art. 15(1)(c) recipients"]
      assert_includes gaps, [nil, "Art. 15(1)(g) source not declared: Registration.firstname"]
      assert_includes gaps, [nil, "Art. 15(1)(h) automated decision-making"]
    end

    def test_two_models_take_their_context_from_their_own_policies
      PamDsl.define_policy(:orders) do
        field :email, type: :email
        purpose(:shipping) { basis :contract; requires :email }
        retention { for_model("Order") { keep_for 2.years; field :email, duration: 1.year } }
      end
      resolver = ->(model) { PamDsl.policy(model == "Order" ? :orders : :access_copy) }
      order = { model: "Order", id: 5, state: :current, as_of: T0, attributes: { "id" => 5, "user_id" => 7, "email" => "a@x" },
                history_from: nil, periods: nil, history: [] }
      reader = ->(*args, **opts) { raw_records(*args, **opts) + [order] }
      export = compliance(policy_resolver: resolver, policy_name: nil, records_reader: reader).data_export
      shipping = export[:processing_context].find { |c| c[:purpose] == :shipping }

      assert_equal({ "Order" => %w[email] }, shipping[:fields])
      assert_equal({ period: period(2.years), fields: { "email" => period(1.year) } }, shipping[:retention]["Order"])
      refute export[:processing_context].any? { |c| c[:purpose] == :invoicing && c[:fields].key?("Order") }
    end

    def test_the_notice_comes_from_the_policy_and_its_missing_items_are_gaps
      export = compliance.data_export

      assert_equal "the national supervisory authority", export[:notice][:complaint]
      assert_equal "University of Example, Registry", export[:notice][:controller]
      refute_includes export[:gaps], [nil, "Art. 15(1)(f) right to lodge a complaint (notice)"]

      PamDsl.reset!
      PamDsl.define_policy(:access_copy) { field :email, type: :email }
      gaps = compliance.data_export[:gaps]
      assert_includes gaps, [nil, "Art. 15(1)(e) rights of the data subject (notice)"]
      assert_includes gaps, [nil, "Art. 15(1)(f) right to lodge a complaint (notice)"]
      assert_includes gaps, [nil, "identity and contact details of the controller (notice)"]
    end

    def test_a_declared_automated_decisions_statement_closes_that_gap
      @policy.access_notice(automated_decisions: "No decision is based solely on automated processing.")
      export = compliance.data_export

      assert_equal "No decision is based solely on automated processing.", export[:notice][:automated_decisions]
      refute_includes export[:gaps], [nil, "Art. 15(1)(h) automated decision-making"]
    end

    def test_each_export_is_recorded_without_values
      recorded = []
      compliance(export_recorder: ->(entry) { recorded << entry }, access_reader: ->(*) { [] })
        .data_export(verified_by: "registry desk")

      assert_equal 1, recorded.size
      entry = recorded.first
      assert_equal %i[records history accesses processing_context notice], entry[:sections]
      assert_equal 1, entry[:records]
      assert_equal "registry desk", entry[:verified_by]
      refute_match(/alice@example.com/, entry.inspect)
    end

    def test_only_an_explicit_export_is_recorded
      recorded = []
      subject = compliance(export_recorder: ->(entry) { recorded << entry })

      subject.full_report
      subject.data_export(record: false)
      assert_empty recorded, "a report or a view is not an answered request"

      subject.data_export
      assert_equal 1, recorded.size
    end

    def test_a_subject_with_no_records_gets_an_empty_copy_not_an_error
      export = GDPRCompliance.new(subject_id: 1, subject_type: "User", record_reader: ->(*) { [] },
                                  policy_name: :access_copy).data_export

      assert_equal [], export[:records]
      assert_equal [], export[:processing_context]
      assert_includes export[:gaps], [nil, "no records: nothing is held about the subject"]
    end

    def test_records_come_from_the_events_when_no_records_reader_is_given
      record = registration(compliance(records_reader: nil).data_export)

      assert_equal :replayed, record[:state]
      assert_equal 500, record[:attributes]["amount"]
      assert_equal "paid", record[:attributes]["status"]
    end

    # ── The declared policy in the other reports ─────────────────────────────

    def test_processing_activities_take_purpose_and_basis_from_the_policy
      activity = compliance.processing_activities.find { |a| a[:source] == "lyra_command_handler" }

      assert_equal "Legal obligation (Art. 6(1)(c)); Contract (Art. 6(1)(b))", activity[:legal_basis]
      assert_equal "invoicing, fees", activity[:purpose]
      assert_equal 10.years, activity[:retention_period]
    end

    def test_rectification_history_lists_corrections_of_declared_fields
      corrections = compliance.rectification_history

      assert_equal 1, corrections.size, "status is not personal; programme is declared, though no detector names it"
      assert_equal %w[programme], corrections.first[:corrected_fields].keys.map(&:to_s)
    end

    private

    # "10 years" with ActiveSupport; the polyfill's durations are seconds.
    def period(duration) = SubjectAccess.format_duration(duration)

    def compliance(records_reader: :default, access_reader: nil, export_recorder: nil, actor_label: nil,
                   policy_resolver: nil, policy_name: :access_copy)
      reader = records_reader == :default ? method(:raw_records) : records_reader
      GDPRCompliance.new(
        subject_id: 7, subject_type: "User", record_reader: ->(*) { events },
        policy_name: policy_name, policy_resolver: policy_resolver, records_reader: reader,
        access_reader: access_reader, export_recorder: export_recorder, actor_label: actor_label
      )
    end

    def registration(export)
      export[:records].find { |r| r[:model] == "Registration" }
    end

    def events
      [
        Event.new(event_id: "e1", metadata: { user_id: 7, user_type: "User", source: "lyra_command_handler" },
                  data: { operation: :created, model_class: "Registration", model_id: 42, timestamp: T0,
                          attributes: { "user_id" => 7, "email" => "alice@example.com", "amount" => 500,
                                        "status" => "pending", "payer_name" => "Bob Payer",
                                        "password_digest" => "x$2a", "vat_number" => "GR1" } }),
        Event.new(event_id: "e2", metadata: { user_id: 99, ip_address: "10.0.0.1", source: "lyra_command_handler" },
                  data: { operation: :updated, model_class: "Registration", model_id: 42, timestamp: T0 + 60,
                          changes: { "status" => %w[pending paid] } }),
        Event.new(event_id: "e3", metadata: { source: "lyra_command_handler" },
                  data: { operation: :updated, model_class: "Registration", model_id: 42, timestamp: T0 + 120,
                          changes: { "programme" => %w[MSc PhD] } })
      ]
    end

    # What a store's records_reader gives: the record with its history, actors unlabelled.
    def raw_records(_subject_id, _subject_type, events, history: true)
      [{
        model: "Registration", id: 42, state: :current, as_of: T0 + 300,
        attributes: { "id" => 42, "user_id" => 7, "email" => "alice@example.com", "amount" => 500, "status" => "paid",
                      "payer_name" => "Bob Payer", "password_digest" => "x$2a", "vat_number" => "GR1",
                      "firstname" => "Alice", "programme" => "PhD" },
        history_from: T0, periods: nil,
        history: history ? events.flat_map { |e| history_entries(e) } : nil
      }]
    end

    def history_entries(event)
      actor = { user_id: event.metadata[:user_id], ip_address: event.metadata[:ip_address], user_type: event.metadata[:user_type] }.compact
      values = event.operation == :created ? event.attributes.transform_values { |v| [nil, v] } : event.changes
      values.map do |field, (from, to)|
        { at: event.timestamp, operation: event.operation, field: field, from: from, to: to, actor: actor }
      end
    end
  end
end
