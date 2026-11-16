# frozen_string_literal: true

require "test_helper"

# Restriction of processing (Art. 18) and the right to object (Art. 21) in
# Lyra's reads, erasure, retention and reports (1.0.0, part 3 of the rights
# work): the rights are read afresh per checking scope; a whole-record
# restriction refuses a load that names no declared field; model-wide
# queries leave restricted subjects out (a join or a subquery reaching one is
# refused); lyra_processable gives batch jobs the records they may process;
# erasure refuses a restricted subject unless it lifts a notified
# restriction; retention skips restricted records and reports them; the
# subject-access copy lists the subject's requests.
class RightsEnforcementTest < Minitest::Test
  Restricted = PamDsl::RestrictedProcessingError if defined?(PamDsl)

  MODES = {
    monitor: -> { Lyra.config.enable_monitor! },
    es_noproj: lambda {
      Lyra.config.enable_event_sourcing!
      Lyra.config.projection_mode = :disabled
    }
  }.freeze

  # label => query on a relation of EnfArticle. Each is run under a purpose
  # on EnfArticle.all, and with no purpose on the relation without the rows
  # expected to be left out: the two answers must be equal.
  QUERIES = {
    "count" => ->(r) { r.count },
    "count(:all)" => ->(r) { r.count(:all) },
    "count(:title)" => ->(r) { r.count(:title) },
    "where(status:).count" => ->(r) { r.where(status: "draft").count },
    "group(:status).count" => ->(r) { r.group(:status).count },
    "sum(:id)" => ->(r) { r.sum(:id) },
    "minimum(:id)" => ->(r) { r.minimum(:id) },
    "maximum(:id)" => ->(r) { r.maximum(:id) },
    "pluck(:id)" => ->(r) { r.pluck(:id).sort },
    "pluck(:title)" => ->(r) { r.pluck(:title).sort },
    "ids" => ->(r) { r.ids.sort },
    "where(title:).exists?" => ->(r) { r.where(title: "Ann's").exists? },
    "exists?" => ->(r) { r.exists? },
    "where(status:).size" => ->(r) { r.where(status: "draft").size },
    "order(:id).pick(:id)" => ->(r) { r.order(:id).pick(:id) }
  }.freeze

  def setup
    skip "Requires Rails and database" unless defined?(ActiveRecord::Base) && ActiveRecord::Base.connection.table_exists?(:users)
    skip "Requires pam_dsl" unless Lyra.pam_dsl_available?

    PamDsl.reset!
    @log = StringIO.new
    PamDsl.logger = Logger.new(@log)
    define_policy

    %i[EnfAuthor EnfArticle].each { |c| Object.send(:remove_const, c) if Object.const_defined?(c) }
    Object.const_set(:EnfAuthor, Class.new(ActiveRecord::Base) { self.table_name = "users" })
    Object.const_set(:EnfArticle, Class.new(ActiveRecord::Base) do
      self.table_name = "articles"
      belongs_to :author, class_name: "EnfAuthor", optional: true
    end)
    [EnfAuthor, EnfArticle].each do |model|
      model.include(Lyra::Interceptors::CrudInterceptor)
      model.monitor_with_lyra(privacy_policy: :enf_policy)
      Lyra.config.monitor_model(model, privacy_policy: :enf_policy)
    end
    use_mode(:monitor)
  end

  def teardown
    return unless defined?(EnfAuthor)

    PamDsl.rights_store = Lyra::Rights.store
    Lyra.config.projection_mode = :sync
    Lyra.config.enable_monitor!
    Lyra.config.retention_executor = false
    clean
    PamDsl.reset!
    PamDsl.logger = nil
  end

  def rights = PamDsl.rights

  # ── 1. The rights are read afresh per checking scope ──

  def test_a_right_recorded_elsewhere_applies_from_the_next_purpose_block
    Lyra.config.rights_refresh_interval = 60
    Lyra.with_purpose(:publishing) do
      assert EnfArticle.find(@anns.id), "nothing in force yet: the snapshot is read"
      elsewhere { rights.restrict!(subject: @ann_key, ground: :accuracy_contested) }
      assert EnfArticle.find(@anns.id), "within the scope that began before it, the snapshot stands"
    end

    assert_raises(Restricted, "the next scope reads the rights afresh, whatever the interval") do
      Lyra.with_purpose(:publishing) { EnfArticle.find(@anns.id) }
    end
  end

  # config.rights_refresh :interval: scopes still open, but nothing is read
  # afresh because one began; another process's right applies once the
  # interval has passed, even within one scope.
  def test_under_interval_refresh_a_right_recorded_elsewhere_applies_after_the_interval
    assert_equal :scope, Lyra.config.rights_refresh, "the default"
    Lyra.config.rights_refresh = "interval"
    assert_equal :interval, Lyra.config.rights_refresh
    Lyra.config.rights_refresh_interval = 0.5
    Lyra::Rights.refresh!

    assert Lyra.with_purpose(:publishing) { EnfArticle.find(@anns.id) }
    elsewhere { rights.restrict!(subject: @ann_key, ground: :accuracy_contested) }
    assert Lyra.with_purpose(:publishing) { EnfArticle.find(@anns.id) }, "the next scope still answers from the snapshot"
    assert_equal 0, rights_queries { Lyra.with_purpose(:publishing) { EnfArticle.find(@bobs.id) } }

    sleep 0.6
    assert_raises(Restricted, "after the interval") { Lyra.with_purpose(:publishing) { EnfArticle.find(@anns.id) } }
  end

  def test_rights_refresh_takes_only_scope_or_interval
    error = assert_raises(ArgumentError) { Lyra.config.rights_refresh = :never }
    assert_match(/config\.rights_refresh must be one of :scope, :interval/, error.message)
    assert_equal :scope, Lyra.config.rights_refresh
  end

  def test_each_batch_reads_the_rights_afresh
    each_mode do |mode|
      Lyra.config.rights_refresh_interval = 60
      Lyra::Rights.refresh!
      seen = []
      assert_raises(Restricted, "#{mode}: the second batch sees a right recorded after the first") do
        Lyra.with_purpose(:publishing) do
          EnfArticle.find_each(batch_size: 1) do |article|
            seen << article.id
            elsewhere { rights.restrict!(subject: @bob_key, ground: :accuracy_contested) } if seen.size == 1
          end
        end
      end
      assert_equal [@anns.id], seen, mode
    end
  end

  def test_a_web_request_and_a_job_each_begin_a_scope
    inside = nil
    app = ->(_env) { inside = Lyra::Rights.scope_started_at; [200, {}, ["ok"]] }
    assert_nil Lyra::Rights.scope_started_at
    Lyra::Rights::Middleware.new(app).call({})
    assert_kind_of Float, inside
    assert_nil Lyra::Rights.scope_started_at, "the scope ends with the request"

    job = Class.new(ActiveJob::Base) do
      def self.name = "EnfScopeJob"
      def perform(box) = box << Lyra::Rights.scope_started_at
    end
    box = []
    job.perform_now(box)
    assert_kind_of Float, box.first, "a job runs in a scope of its own"
  end

  # Unchecked reads (no purpose, reads_without_purpose :allow: every
  # benchmark) ask nothing of the rights, even with a right in force; a
  # checked scope with nothing in force reads them once.
  def test_unchecked_reads_never_query_the_rights
    rights.restrict!(subject: @ann_key, ground: :accuracy_contested)
    Lyra::Rights.store.invalidate!
    queries = rights_queries do
      EnfArticle.find(@anns.id)
      EnfArticle.where(author_id: @ann.id).to_a
      EnfArticle.count
      EnfArticle.pluck(:title)
      EnfArticle.find_each { _1 }
      EnfArticle.lyra_processable.to_a
    end
    assert_equal 0, queries
  end

  def test_a_checked_scope_with_nothing_in_force_reads_the_rights_once
    queries = rights_queries do
      Lyra.with_purpose(:publishing) do
        EnfArticle.find(@anns.id)
        EnfArticle.where(author_id: @ann.id).to_a
        EnfArticle.count
        EnfArticle.pluck(:title)
      end
    end
    assert_equal 1, queries
  end

  # ── 2. A whole-record restriction, with no declared field read ──

  def test_a_whole_record_restriction_refuses_a_load_that_names_no_declared_field
    each_mode do |mode|
      rights.restrict!(subject: @ann_key, ground: :accuracy_contested)

      assert_raises(Restricted, "#{mode}: her article") do
        Lyra.with_purpose(:publishing) { EnfArticle.select(:id, :author_id).find(@anns.id) }
      end
      assert_raises(Restricted, "#{mode}: her own record") do
        Lyra.with_purpose(:publishing) { EnfAuthor.select(:id).where(id: @ann.id).to_a }
      end
      assert Lyra.with_purpose(:defence) { EnfArticle.select(:id, :author_id).find(@anns.id) }, "#{mode}: Art. 18(2)"
      assert Lyra.with_purpose(:publishing) { EnfArticle.select(:id, :author_id).find(@bobs.id) }, "#{mode}: others"
    end
  end

  def test_a_field_restriction_does_not_refuse_a_load_that_names_none_of_its_fields
    rights.restrict!(subject: @ann_key, ground: :accuracy_contested, fields: [:body])
    assert Lyra.with_purpose(:publishing) { EnfArticle.select(:id, :author_id).find(@anns.id) }
  end

  def test_an_upheld_objection_refuses_a_load_that_names_no_declared_field
    o = rights.object!(subject: @ann_key, policy: :enf_policy, purpose: :survey)
    rights.decide!(o.id, outcome: :upheld, by: "dpo")
    assert_raises(PamDsl::ObjectedProcessingError) do
      Lyra.with_purpose(:survey) { EnfArticle.select(:id, :author_id).find(@anns.id) }
    end
    assert Lyra.with_purpose(:publishing) { EnfArticle.select(:id, :author_id).find(@anns.id) }
  end

  def test_with_no_purpose_a_load_by_undeclared_columns_is_not_checked
    rights.restrict!(subject: @ann_key, ground: :accuracy_contested)
    Lyra.config.reads_without_purpose = :deny
    assert EnfArticle.select(:id, :author_id).find(@anns.id)
  end

  # ── 3. Queries over many people ──

  def test_model_wide_queries_leave_a_restricted_person_out
    each_mode do |mode|
      rights.restrict!(subject: @ann_key, ground: :accuracy_contested)
      QUERIES.each do |label, query|
        expected = query.call(EnfArticle.where.not(id: @anns.id))
        actual = Lyra.with_purpose(:publishing) { query.call(EnfArticle.all) }
        assert_equal expected, actual, "#{mode} #{label}: Ann's article left out, the article with no author kept"
      end
    end
  end

  def test_model_wide_queries_leave_a_restricted_record_out
    each_mode do |mode|
      rights.restrict!(subject: "EnfArticle$#{@bobs.id}", ground: :needed_for_legal_claims)
      QUERIES.each do |label, query|
        expected = query.call(EnfArticle.where.not(id: @bobs.id))
        assert_equal expected, Lyra.with_purpose(:publishing) { query.call(EnfArticle.all) }, "#{mode} #{label}"
      end
    end
  end

  def test_a_field_restriction_leaves_the_person_out_only_of_queries_naming_its_fields
    each_mode do |mode|
      rights.restrict!(subject: @ann_key, ground: :accuracy_contested, fields: [:body])
      assert_equal 3, Lyra.with_purpose(:publishing) { EnfArticle.count }, mode
      assert_equal 3, Lyra.with_purpose(:publishing) { EnfArticle.pluck(:title).size }, mode
      assert_equal [nil, nil], Lyra.with_purpose(:publishing) { EnfArticle.pluck(:body) }, "#{mode}: her body left out"
    end
  end

  def test_model_wide_queries_are_unchanged_where_the_restriction_does_not_apply
    each_mode do |mode|
      rights.restrict!(subject: @ann_key, ground: :accuracy_contested)
      assert_equal 3, Lyra.with_purpose(:defence) { EnfArticle.count }, "#{mode}: an Art. 18(2) exception"
      assert_equal 3, EnfArticle.count, "#{mode}: no purpose"
      PamDsl.enforcement_mode = :audit
      assert_equal 3, Lyra.with_purpose(:publishing) { EnfArticle.count }, "#{mode}: audit mode excludes nothing"
      assert_match(/restricted/, @log.string, "#{mode}: and says so")
      PamDsl.enforcement_mode = :strict
    end
  end

  def test_without_rights_in_force_the_sql_is_unchanged
    plain = articles_statements { EnfArticle.where(status: "draft").count }
    checked = articles_statements { Lyra.with_purpose(:publishing) { EnfArticle.where(status: "draft").count } }
    assert_equal plain, checked

    rights.restrict!(subject: "EnfAuthor$#{@bob.id}", ground: :accuracy_contested)
    other = articles_statements { Lyra.with_purpose(:defence) { EnfArticle.where(status: "draft").count } }
    assert_equal plain, other, "a purpose the restriction does not cover runs the same query"
  end

  def test_an_objection_leaves_the_person_out_of_the_objected_purpose_only
    each_mode do |mode|
      rights.object!(subject: @ann_key, policy: :enf_policy, purpose: :survey)
      assert_equal 2, Lyra.with_purpose(:survey) { EnfArticle.count }, "#{mode}: pending, Art. 18(1)(d)"
      assert_equal 3, Lyra.with_purpose(:publishing) { EnfArticle.count }, mode
    end
  end

  def test_a_join_or_a_subquery_reaching_a_restricted_model_is_refused
    rights.restrict!(subject: @ann_key, ground: :accuracy_contested)

    assert_raises(Restricted) do
      Lyra.with_purpose(:publishing) { EnfArticle.joins(:author).where(users: { name: "Bob" }).count }
    end
    assert_raises(Restricted) do
      Lyra.with_purpose(:publishing) { EnfArticle.where(author_id: EnfAuthor.where(name: "Bob").select(:id)).count }
    end
    assert_equal 1, Lyra.with_purpose(:defence) { EnfArticle.joins(:author).where(users: { name: "Bob" }).count }
  end

  def test_a_load_that_returns_a_restricted_record_raises_and_lyra_processable_leaves_it_out
    each_mode do |mode|
      rights.restrict!(subject: @ann_key, ground: :accuracy_contested)

      assert_raises(Restricted, "#{mode}") { Lyra.with_purpose(:publishing) { EnfArticle.order(:id).to_a } }
      kept = Lyra.with_purpose(:publishing) { EnfArticle.lyra_processable.to_a.map(&:id).sort }
      assert_equal [@bobs.id, @orphan.id].sort, kept, mode
      batched = []
      Lyra.with_purpose(:publishing) { EnfArticle.lyra_processable.find_each(batch_size: 1) { batched << _1.id } }
      assert_equal [@bobs.id, @orphan.id].sort, batched.sort, mode
      chained = Lyra.with_purpose(:publishing) { EnfArticle.where(status: "draft").lyra_processable.count }
      assert_equal 2, chained, mode
      assert_equal 3, EnfArticle.lyra_processable.to_a.size, "#{mode}: no purpose, nothing to leave out"
      assert_equal 3, Lyra.with_purpose(:defence) { EnfArticle.lyra_processable.to_a.size }, mode
    end
  end

  # ── 4. Erasure and retention ──

  def test_erasure_refuses_a_restricted_subject_unless_it_lifts_a_notified_restriction
    r = rights.restrict!(subject: @ann_key, ground: :unlawful_erasure_opposed)

    error = assert_raises(Restricted) { Lyra::Erasure.erase!(EnfAuthor, @ann.id, reason: "Art. 17 request") }
    assert_includes error.message, r.id
    assert_raises(Restricted, "a record naming her") { Lyra::Erasure.erase!(EnfArticle, @anns.id, reason: "x") }
    assert Lyra::Erasure.erase!(EnfArticle, @bobs.id, reason: "x"), "others are erased"

    assert_raises(PamDsl::RightsTransitionError, "lifting needs the Art. 18(3) notice first") do
      Lyra::Erasure.erase!(EnfAuthor, @ann.id, reason: "x", lifting: r.id)
    end
    assert_equal "Ann", raw("SELECT name FROM users WHERE id = #{@ann.id}")
    assert_equal :active, rights.find(r.id).state

    rights.notify_lift!(r.id)
    Lyra::Erasure.erase!(EnfAuthor, @ann.id, reason: "x", lifting: r.id, erased_by: "dpo")
    assert_equal :lifted, rights.find(r.id).state
    assert_equal "dpo", rights.find(r.id).lifted_by
    refute_equal "Ann", raw("SELECT name FROM users WHERE id = #{@ann.id}")
  end

  # A dry run is refused as the erasure would be; with lifting: it lifts
  # nothing, writes nothing, and reports what it would lift.
  def test_a_dry_run_of_a_restricted_subject_is_refused_or_reports_the_lift_and_writes_nothing
    r = rights.restrict!(subject: @ann_key, ground: :unlawful_erasure_opposed)
    assert_raises(Restricted) { Lyra::Erasure.erase!(EnfAuthor, @ann.id, reason: "x", dry_run: true) }
    assert_raises(PamDsl::RightsTransitionError) do
      Lyra::Erasure.erase!(EnfAuthor, @ann.id, reason: "x", dry_run: true, lifting: r.id)
    end

    rights.notify_lift!(r.id)
    events_before = Lyra::Rights.store.events_for(@ann_key).size
    result = Lyra::Erasure.erase!(EnfAuthor, @ann.id, reason: "x", dry_run: true, lifting: r.id)
    assert result.dry_run
    assert_equal [r.id], result.lifting, "what it would lift"
    assert_includes result.fields, "name"
    assert_equal :lift_notified, rights.find(r.id).state, "nothing lifted"
    assert_equal events_before, Lyra::Rights.store.events_for(@ann_key).size
    assert_equal "Ann", raw("SELECT name FROM users WHERE id = #{@ann.id}"), "nothing erased"
    assert Lyra::Rights.store.any_active?

    assert_equal [], Lyra::Erasure.erase!(EnfArticle, @bobs.id, reason: "x", dry_run: true).lifting
  end

  # The erasure's lift is recorded in the subject's rights stream, which
  # erasure never rewrites (Erasure.kept_stream?), everywhere included.
  def test_an_erasure_that_lifts_keeps_the_rights_stream
    r = rights.restrict!(subject: @ann_key, ground: :unlawful_erasure_opposed)
    rights.notify_lift!(r.id)
    result = Lyra::Erasure.erase!(EnfAuthor, @ann.id, reason: "x", lifting: r.id, everywhere: true)

    assert_equal [r.id], result.lifting
    assert Lyra::Erasure.kept_stream?(Lyra::Rights.stream_for(@ann_key))
    assert Lyra::Erasure.kept_stream?(Lyra::Rights.consent_stream_for(@ann_key))
    assert_equal %w[ProcessingRestricted RestrictionLiftNotified RestrictionLifted],
                 Lyra::Rights.store.events_for(@ann_key).map(&:type)
  end

  def test_a_failed_erasure_leaves_the_restriction_in_force
    r = rights.restrict!(subject: @ann_key, ground: :unlawful_erasure_opposed)
    rights.notify_lift!(r.id)
    assert_raises(Lyra::Erasure::Unsupported) do
      Lyra::Erasure.erase!(EnfAuthor, @ann.id, reason: "x", fields: ["nope"], lifting: r.id)
    end
    assert_equal :lift_notified, rights.find(r.id).state
  end

  def test_lifting_names_a_restriction_of_this_subject
    mine = rights.restrict!(subject: @ann_key, ground: :unlawful_erasure_opposed)
    other = rights.restrict!(subject: @bob_key, ground: :unlawful_erasure_opposed)
    rights.notify_lift!(other.id)
    assert_raises(Restricted) { Lyra::Erasure.erase!(EnfAuthor, @ann.id, reason: "x", lifting: other.id) }
    assert_equal :active, rights.find(mine.id).state
    assert_equal :lift_notified, rights.find(other.id).state
  end

  def test_a_field_restriction_refuses_erasure_of_its_fields_only
    rights.restrict!(subject: @ann_key, ground: :needed_for_legal_claims, fields: [:body])
    assert_raises(Restricted) { Lyra::Erasure.erase!(EnfArticle, @anns.id, reason: "x") }
    assert_raises(Restricted) { Lyra::Erasure.erase!(EnfArticle, @anns.id, reason: "x", fields: ["body"]) }
    assert Lyra::Erasure.erase!(EnfArticle, @anns.id, reason: "x", fields: ["title"])
  end

  def test_a_pending_objection_does_not_refuse_erasure
    rights.object!(subject: @ann_key, policy: :enf_policy, purpose: :survey)
    assert Lyra::Erasure.erase!(EnfAuthor, @ann.id, reason: "Art. 17(1)(c)")
  end

  def test_retention_skips_restricted_records_and_reports_them
    Lyra.config.retention_executor = true
    r = rights.restrict!(subject: @ann_key, ground: :needed_for_legal_claims)

    dry = Lyra::Retention.apply!(models: [EnfArticle], dry_run: true, now: Time.current + 2.years)
    assert_equal({ @anns.id => :restricted, @bobs.id => :would_erase, @orphan.id => :would_erase },
                 dry.actions.to_h { [_1.id, _1.outcome] })

    result = Lyra::Retention.apply!(models: [EnfArticle], now: Time.current + 2.years)
    actions = result.actions.to_h { [_1.id, _1] }
    assert_equal :restricted, actions[@anns.id].outcome
    assert_includes actions[@anns.id].detail, r.id
    assert_equal :erased, actions[@bobs.id].outcome
    assert_match(/1 restricted/, result.summary)
    assert_equal [actions[@anns.id]], result.restricted
    assert_equal "Ann's", raw("SELECT title FROM articles WHERE id = #{@anns.id}"), "kept, as the subject asked"
  end

  # (articles have no deleted_at column, so :soft_delete is skipped for that
  # reason before any restriction is looked at.)
  def test_retention_skips_a_restricted_record_under_hard_delete
    Lyra.config.retention_executor = true
    rights.restrict!(subject: @ann_key, ground: :unlawful_erasure_opposed)
    define_policy(:hard_delete)
    dry = Lyra::Retention.apply!(models: [EnfArticle], dry_run: true, now: Time.current + 2.years)
    assert_equal :restricted, dry.actions.find { _1.id == @anns.id }.outcome

    Lyra::Retention.apply!(models: [EnfArticle], now: Time.current + 2.years)
    assert_equal ["Ann's"], EnfArticle.pluck(:title), "hers kept, the others deleted"
  end

  # ── Review findings ──

  # 1. Under ES-NoProj the table is empty: the record's people come from its
  # events, so a restricted person's article is not erased (dry run either).
  def test_erasure_of_a_restricted_person_s_record_is_refused_in_every_mode
    each_mode do |mode|
      rights.restrict!(subject: @ann_key, ground: :unlawful_erasure_opposed)
      assert_raises(Restricted, "#{mode}") { Lyra::Erasure.erase!(EnfArticle, @anns.id, reason: "x") }
      assert_raises(Restricted, "#{mode} dry run") { Lyra::Erasure.erase!(EnfArticle, @anns.id, reason: "x", dry_run: true) }
    end
  end

  def test_the_copy_lists_a_record_restriction_in_every_mode
    each_mode do |mode|
      record = rights.restrict!(subject: "EnfArticle$#{@anns.id}", ground: :needed_for_legal_claims)
      export = Lyra::Privacy::GDPRCompliance.new(subject_id: @ann.id, subject_type: "EnfAuthor").data_export(record: false)
      assert_equal [record.id], export[:restrictions].map { _1[:id] }, mode
    end
  end

  # 2. SQL written as strings: a joined table's alias, and a subquery's
  # words, belong to the table they name.
  def test_string_joins_and_string_subqueries_reaching_a_restricted_record_are_refused
    rights.restrict!(subject: "EnfArticle$#{@anns.id}", ground: :accuracy_contested)
    pub = ->(&block) { Lyra.with_purpose(:publishing, &block) }

    assert_raises(Restricted) { pub.call { EnfAuthor.where("id IN (SELECT author_id FROM articles WHERE body = 'text')").count } }
    assert_raises(Restricted) do
      pub.call { EnfAuthor.joins("INNER JOIN articles a ON a.author_id = users.id").where("a.body = 'text'").count }
    end
    assert_raises(Restricted) do
      pub.call { EnfAuthor.joins("INNER JOIN articles a ON a.author_id = users.id").pluck(Arel.sql("a.title")) }
    end
    assert_raises(Restricted) { pub.call { EnfAuthor.joins("INNER JOIN articles ON articles.author_id = users.id").count } }
    assert_equal 2, pub.call { EnfAuthor.where("name IN ('Ann', 'Bob')").count }, "a fragment naming no other table runs"
  end

  # A FROM whose table cannot be read: refused while a right is in force.
  def test_an_sql_fragment_reading_from_something_unnamed_fails_closed
    opaque = -> { EnfAuthor.where("id IN (SELECT x FROM (VALUES (#{@ann.id})) AS t(x))").count }
    assert_equal 1, Lyra.with_purpose(:publishing) { opaque.call }, "nothing in force: it runs"
    rights.restrict!(subject: "EnfArticle$#{@anns.id}", ground: :accuracy_contested)
    assert_raises(Restricted) { Lyra.with_purpose(:publishing) { opaque.call } }
  end

  def test_a_string_subquery_s_words_are_checked_against_the_table_they_name
    PamDsl.define_policy(:enf_author_only) do
      field :name, type: :name
      purpose(:greeting) { basis :contract; requires :name }
    end
    EnfAuthor.lyra_config.privacy_policy = :enf_author_only
    error = assert_raises(PamDsl::UndeclaredPurposeError) do
      Lyra.with_purpose(:greeting) { EnfAuthor.where("id IN (SELECT author_id FROM articles WHERE body = 'text')").count }
    end
    assert_match(/greeting/, error.message, "author_id and body are the articles', checked under their policy")
  ensure
    EnfAuthor.lyra_config.privacy_policy = :enf_policy
  end

  # 3. STI: the type column holds the subclass's name.
  def test_a_polymorphic_link_to_an_sti_subclass_is_left_out
    with_rv_models do |cat, dan, cats, dans|
      rights.restrict!(subject: "RvPerson$#{cat.id}", ground: :accuracy_contested)
      pub = ->(&block) { Lyra.with_purpose(:rv_publishing, &block) }
      assert_equal "RvCustomer", raw("SELECT owner_type FROM rv_notes WHERE id = #{cats.id}")
      assert_raises(Restricted) { pub.call { RvNote.find(cats.id) } }
      assert_equal ["dan's note"], pub.call { RvNote.pluck(:body) }
      assert_equal 1, pub.call { RvNote.count }
      assert_equal [dans.id], pub.call { RvNote.lyra_processable.map(&:id) }
    end
  end

  # 4. Keys are resolved only when a request in force could cover the access;
  # rows with no key (aggregates) are not subjects; ES-NoProj resolves them
  # from the whole record before it narrows it.
  def test_partial_and_aggregate_reads_with_an_unrelated_right_in_force
    each_mode do |mode|
      rights.restrict!(subject: "EnfAuthor$999999", ground: :accuracy_contested)
      Lyra::Rights.refresh!
      assert_equal "Bob's", Lyra.with_purpose(:defence) { EnfArticle.select(:id, :title).find(@bobs.id).title }, mode
      assert_equal "Bob's", Lyra.with_purpose(:publishing) { EnfArticle.select(:id, :title).find(@bobs.id).title }, mode
      assert_equal ["Bob's"], Lyra.with_purpose(:defence) { EnfArticle.where(author_id: @bob.id).select(:title).map(&:title) }, "#{mode}: no id to read the author from; the purpose is excepted, so no key is needed"
      next unless mode == :monitor

      grouped = Lyra.with_purpose(:publishing) { EnfArticle.select("status, count(*) AS n").group(:status).map { [_1.status, _1.n] } }
      assert_equal [["draft", 3]], grouped
      by_sql = Lyra.with_purpose(:publishing) do
        EnfArticle.find_by_sql("SELECT status, count(*) AS n FROM articles GROUP BY status").map { [_1.status, _1.n] }
      end
      assert_equal [["draft", 3]], by_sql
    end
  end

  def test_a_partial_read_of_a_restricted_person_s_record_is_still_refused
    each_mode do |mode|
      rights.restrict!(subject: @ann_key, ground: :accuracy_contested)
      assert_raises(Restricted, Lyra::Rights::UnresolvedSubjectError, "#{mode}: refused, or unresolved (fail closed)") do
        Lyra.with_purpose(:publishing) { EnfArticle.where(author_id: @ann.id).select(:title).to_a }
      end
    end
  end

  # 6. everywhere: another person's restricted record keeps its copy.
  def test_everywhere_leaves_a_restricted_holder_and_reports_it
    raw_exec("UPDATE articles SET body = 'ann@example.com' WHERE id IN (#{@anns.id}, #{@bobs.id})")
    rights.restrict!(subject: "EnfArticle$#{@bobs.id}", ground: :needed_for_legal_claims)

    result = Lyra::Erasure.erase!(EnfAuthor, @ann.id, reason: "x", everywhere: true)
    assert_equal "ann@example.com", raw("SELECT body FROM articles WHERE id = #{@bobs.id}"), "kept"
    assert_equal [{ record: "EnfArticle #{@bobs.id}", columns: ["body"] }], result.restricted_copies
    refute_includes result.restricted_copies.to_s, "ann@example.com"
    refute_equal "ann@example.com", raw("SELECT body FROM articles WHERE id = #{@anns.id}"), "her own article is erased"
  end

  # 8. Lifting through erase! lifts only what is being erased.
  def test_erasing_one_record_cannot_lift_the_person_s_restriction
    r = rights.restrict!(subject: @ann_key, ground: :unlawful_erasure_opposed)
    rights.notify_lift!(r.id)
    error = assert_raises(Restricted) { Lyra::Erasure.erase!(EnfArticle, @anns.id, reason: "x", lifting: r.id) }
    assert_match(/PamDsl\.rights\.lift!/, error.message)
    assert_equal :lift_notified, rights.find(r.id).state

    record = rights.restrict!(subject: "EnfArticle$#{@anns.id}", ground: :unlawful_erasure_opposed)
    rights.notify_lift!(record.id)
    rights.lift!(r.id, reason: :verified_accurate)
    assert_equal [record.id], Lyra::Erasure.erase!(EnfArticle, @anns.id, reason: "x", lifting: record.id).lifting
  end

  # 9a. ES-NoProj's class-level exists?(id) answers as Monitor's.
  def test_exists_by_id_leaves_a_restricted_record_out_in_every_mode
    each_mode do |mode|
      rights.restrict!(subject: @ann_key, ground: :accuracy_contested)
      refute Lyra.with_purpose(:publishing) { EnfArticle.exists?(@anns.id) }, mode
      assert Lyra.with_purpose(:publishing) { EnfArticle.exists?(@bobs.id) }, mode
    end
  end

  # 9b. An undeclared purpose has no Art. 18(2) exception.
  def test_an_undeclared_purpose_is_not_an_exception
    rights.restrict!(subject: @ann_key, ground: :accuracy_contested)
    assert_raises(Restricted) { Lyra.with_purpose(:undeclared) { EnfArticle.select(:id, :author_id).find(@anns.id) } }
    assert_equal 2, Lyra.with_purpose(:undeclared) { EnfArticle.count }
  end

  # 7. The set of subjects a query leaves out is computed once per snapshot.
  def test_the_excluded_subjects_are_remembered_until_the_rights_change
    40.times { |i| rights.restrict!(subject: "EnfAuthor$#{500_000 + i}", ground: :accuracy_contested) }
    rights.restrict!(subject: @ann_key, ground: :accuracy_contested)
    Lyra::Rights.refresh!
    calls = 0
    policy = PamDsl.policy(:enf_policy)
    original = policy.method(:rights_violations)
    policy.define_singleton_method(:rights_violations) { |*a, **k| calls += 1; original.call(*a, **k) }
    Lyra.with_purpose(:publishing) { 5.times { EnfArticle.count } }
    first = calls
    Lyra.with_purpose(:publishing) { 5.times { EnfArticle.count } }
    assert_operator first, :<=, 41, "once for the keys in force"
    assert_equal first, calls, "not again while the rights are unchanged"

    rights.restrict!(subject: @bob_key, ground: :accuracy_contested)
    assert_equal 1, Lyra.with_purpose(:publishing) { EnfArticle.count }, "a change is seen"
  end

  # ── 5. Reports ──

  def test_the_subject_access_copy_lists_the_subject_s_own_requests
    r = rights.restrict!(subject: @ann_key, ground: :accuracy_contested, fields: [:name], recorded_by: "desk 4")
    record = rights.restrict!(subject: "EnfArticle$#{@anns.id}", ground: :needed_for_legal_claims)
    o = rights.object!(subject: @ann_key, policy: :enf_policy, purpose: :survey, grounds: "my situation")
    rights.restrict!(subject: @bob_key, ground: :accuracy_contested)

    export = Lyra.with_purpose(:publishing) do
      Lyra::Privacy::GDPRCompliance.new(subject_id: @ann.id, subject_type: "EnfAuthor").data_export(record: false)
    end

    restrictions = export[:restrictions].sort_by { _1[:id] == r.id ? 0 : 1 }
    assert_equal [r.id, record.id], restrictions.map { _1[:id] }, "hers and her record's, not Bob's"
    assert_equal [:accuracy_contested, "Art. 18(1)(a)", [:name], :active],
                 restrictions.first.values_at(:ground, :article, :fields, :state)
    assert_kind_of Time, restrictions.first[:requested_at]
    refute restrictions.first.key?(:recorded_by), "who recorded it is the controller's staff"
    assert_equal "EnfArticle$#{@anns.id}", restrictions.last[:subject]

    objection = export[:objections].sole
    assert_equal [o.id, :enf_policy, :survey, "Art. 21(1)", :pending, "my situation"],
                 objection.values_at(:id, :policy, :purpose, :article, :state, :grounds)
  end

  # Lyra's per-subject register reads each record's policy (policy_resolver),
  # not one policy: the declarations come from the purposes it finds there.
  def test_the_subject_s_processing_activities_show_each_purpose_s_rights
    activities = Lyra::Privacy::GDPRCompliance.new(subject_id: @ann.id, subject_type: "EnfAuthor").processing_activities
    rights = activities.map { _1[:rights_by_purpose] }.compact.reduce({}, :merge)
    assert_equal({ objectable: "Art. 21(1)", allowed_when_restricted: [:legal_claims] }, rights[:defence])
    assert_equal({ objectable: nil, allowed_when_restricted: [] }, rights[:publishing])
  end

  private

  def define_policy(strategy = :anonymize)
    PamDsl.define_policy(:enf_policy) do
      field :name, type: :name
      field :email, type: :email
      field :title, type: :custom
      field :body, type: :custom
      purpose :publishing do
        basis :contract
        requires :title, :body, :name, :email
      end
      purpose :defence do
        basis :legitimate_interests
        lia_documented!
        allowed_when_restricted :legal_claims
        requires :title, :body, :name, :email
      end
      purpose :survey do
        basis :legitimate_interests
        lia_documented!
        requires :title, :body, :name, :email
      end
      retention do
        for_model("EnfArticle") do
          keep_for 1.year
          on_expiry strategy
        end
      end
    end
  end

  def each_mode
    MODES.each_key do |mode|
      use_mode(mode)
      yield mode
    end
  end

  # Ann's article, Bob's, and one with no author, afresh in +mode+.
  def use_mode(mode)
    clean
    MODES.fetch(mode).call
    @ann = EnfAuthor.create!(name: "Ann", email: "ann@example.com")
    @bob = EnfAuthor.create!(name: "Bob", email: "bob@example.com")
    @anns = EnfArticle.create!(title: "Ann's", body: "text", author_id: @ann.id)
    @bobs = EnfArticle.create!(title: "Bob's", body: nil, author_id: @bob.id)
    @orphan = EnfArticle.create!(title: "Nobody's", body: nil, author_id: nil)
    @ann_key = "EnfAuthor$#{@ann.id}"
    @bob_key = "EnfAuthor$#{@bob.id}"
  end

  # Record through another process's store.
  def elsewhere
    here = PamDsl.rights_store
    PamDsl.rights_store = Lyra::Rights::Store.new
    yield
  ensure
    PamDsl.rights_store = here
  end

  def rights_queries(&block) = statements(/lyra_rights/, &block).size

  def articles_statements(&block) = statements(/FROM "articles"/, &block)

  def statements(pattern)
    found = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      found << payload[:sql] if payload[:sql].match?(pattern)
    end
    yield
    found
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  def raw(sql) = ActiveRecord::Base.connection.select_value(sql)

  def raw_exec(sql) = ActiveRecord::Base.connection.execute(sql)

  # Scratch tables for an STI person (RvPerson, RvCustomer) and a note that
  # names its owner polymorphically, with the subclass's name in owner_type.
  def ensure_rv_tables
    connection = ActiveRecord::Base.connection
    connection.create_table(:rv_people, if_not_exists: true) do |t|
      t.string :type
      t.string :name
      t.string :email
      t.timestamps
    end
    connection.create_table(:rv_notes, if_not_exists: true) do |t|
      t.text :body
      t.string :owner_type
      t.integer :owner_id
      t.timestamps
    end
    connection.execute("DELETE FROM rv_notes")
    connection.execute("DELETE FROM rv_people")
  end

  def with_rv_models
    ensure_rv_tables
    %i[RvNote RvCustomer RvPerson].each { |k| Object.send(:remove_const, k) if Object.const_defined?(k) }
    Object.const_set(:RvPerson, Class.new(ActiveRecord::Base) { self.table_name = "rv_people" })
    Object.const_set(:RvCustomer, Class.new(RvPerson))
    Object.const_set(:RvNote, Class.new(ActiveRecord::Base) do
      self.table_name = "rv_notes"
      belongs_to :owner, polymorphic: true, optional: true
    end)
    PamDsl.define_policy(:rv_policy) do
      field :name, type: :name
      field :email, type: :email
      field :body, type: :custom
      purpose(:rv_publishing) { basis :contract; requires :name, :email, :body }
    end
    [RvPerson, RvNote].each do |model|
      model.include(Lyra::Interceptors::CrudInterceptor)
      model.monitor_with_lyra(privacy_policy: :rv_policy)
      Lyra.config.monitor_model(model, privacy_policy: :rv_policy)
    end
    Lyra::Rights::SubjectKeys.reset!
    cat = RvCustomer.create!(name: "Cat", email: "cat@example.com")
    dan = RvCustomer.create!(name: "Dan", email: "dan@example.com")
    cats = RvNote.create!(owner: cat, body: "cat's note")
    dans = RvNote.create!(owner: dan, body: "dan's note")
    raw_exec("UPDATE rv_notes SET owner_type = 'RvCustomer' WHERE id = #{cats.id}")
    yield cat, dan, cats, dans
  ensure
    ensure_rv_tables
  end

  def clean
    connection = ActiveRecord::Base.connection
    connection.execute("DELETE FROM articles")
    connection.execute("DELETE FROM users")
    connection.execute("DELETE FROM event_store_events_in_streams")
    connection.execute("DELETE FROM event_store_events")
    LyraRightsIsolation.purge!
  end
end
