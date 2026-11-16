# frozen_string_literal: true

require "test_helper"
require "stringio"

# Purpose binding of queries (Lyra::PurposeBoundReads, from 1.0.0): a query
# uses every declared field it names (select, where, having, order, group,
# the aggregated column, the conditions of find_by and exists?, the filter
# of a bulk write), whatever it returns. Aggregates, exists?, ids, pluck and
# filtered writes read everyone at once (subject Model$*); record loads have
# their fields checked before the query, without the consent step, and each
# record returned checked as before, consent included.
#
# The expectations are one table, run in Monitor and in ES-NoProj.
class PurposeBoundQueriesTest < Minitest::Test
  # label => [kind, query]. The query takes the field and its values: Ann's
  # (consent given), Bo's (none) and one no record has.
  #   :unchecked  names no declared field
  #   :aggregate  subject Model$*, consent included (refused under a consent purpose)
  #   :load       fields checked before the query, then every record returned
  #   :load_none  a load that finds nothing
  #   :load_other a load of Bo, who gave no consent
  # Each can run twice on the same rows with the same answer (the bulk writes
  # set a fixed value or match nothing), so a run with no purpose gives the
  # answer expected under one.
  QUERIES = {
    "count" => [:unchecked, ->(_f, _v) { ReadUser.count }],
    "count(:all)" => [:unchecked, ->(_f, _v) { ReadUser.count(:all) }],
    "count(:f)" => [:aggregate, ->(f, _v) { ReadUser.count(f) }],
    "group(:f).count" => [:aggregate, ->(f, _v) { ReadUser.group(f).count }],
    "where(f:).sum(:id)" => [:aggregate, ->(f, v) { ReadUser.where(f => v[:ann]).sum(:id) }],
    "where(f:).average(:id)" => [:aggregate, ->(f, v) { ReadUser.where(f => v[:ann]).average(:id) }],
    "minimum(:f)" => [:aggregate, ->(f, _v) { ReadUser.minimum(f) }],
    "maximum(:f)" => [:aggregate, ->(f, _v) { ReadUser.maximum(f) }],
    "where(f:).count" => [:aggregate, ->(f, v) { ReadUser.where(f => v[:ann]).count }],
    "where(f:).size" => [:aggregate, ->(f, v) { ReadUser.where(f => v[:ann]).size }],
    "where(f:).exists?" => [:aggregate, ->(f, v) { ReadUser.where(f => v[:ann]).exists? }],
    "where(f:).any?" => [:aggregate, ->(f, v) { ReadUser.where(f => v[:ann]).any? }],
    "exists?(f:)" => [:aggregate, ->(f, v) { ReadUser.exists?(f => v[:ann]) }],
    "exists?(f: none)" => [:aggregate, ->(f, v) { ReadUser.exists?(f => v[:none]) }],
    "where(f:).ids" => [:aggregate, ->(f, v) { ReadUser.where(f => v[:ann]).ids }],
    "where(f:).pluck(:id)" => [:aggregate, ->(f, v) { ReadUser.where(f => v[:ann]).pluck(:id) }],
    "order(:f).pluck(:id)" => [:aggregate, ->(f, _v) { ReadUser.order(f).pluck(:id) }],
    "where.not(f:).count" => [:aggregate, ->(f, v) { ReadUser.where.not(f => v[:ann]).count }],
    "where(f:).update_all" => [:aggregate, ->(f, v) { ReadUser.where(f => v[:ann]).update_all(updated_at: Time.utc(2026, 1, 1)) }],
    "where(f: none).delete_all" => [:aggregate, ->(f, v) { ReadUser.where(f => v[:none]).delete_all }],
    "delete_by(f: none)" => [:aggregate, ->(f, v) { ReadUser.delete_by(f => v[:none]) }],
    "select(:id).where(f:).first" => [:load, ->(f, v) { ReadUser.select(:id).where(f => v[:ann]).first&.id }],
    "select(:id).order(:f).first" => [:load, ->(f, _v) { ReadUser.select(:id).order(f).first&.id }],
    "select(:id).where(f:).to_a" => [:load, ->(f, v) { ReadUser.select(:id).where(f => v[:ann]).to_a.map(&:id) }],
    "select(:id).find_by(f:)" => [:load, ->(f, v) { ReadUser.select(:id).find_by(f => v[:ann])&.id }],
    "select(:id).where(f: none).to_a" => [:load_none, ->(f, v) { ReadUser.select(:id).where(f => v[:none]).to_a }],
    "select(:id).where(f: bo).first" => [:load_other, ->(f, v) { ReadUser.select(:id).where(f => v[:bo]).first&.id }]
  }.freeze

  MODES = {
    monitor: -> { Lyra.config.enable_monitor! },
    es_noproj: lambda {
      Lyra.config.enable_event_sourcing!
      Lyra.config.projection_mode = :disabled
    }
  }.freeze

  def setup
    skip "Requires Rails and database" unless defined?(ActiveRecord::Base) && ActiveRecord::Base.connection.table_exists?(:users)
    skip "Requires pam_dsl" unless Lyra.pam_dsl_available?

    PamDsl.reset!
    @log = StringIO.new
    PamDsl.logger = Logger.new(@log)
    PamDsl.define_policy(:query_policy) do
      field :email, type: :email, sensitivity: :confidential
      field :name, type: :name
      purpose :contact do
        basis :contract
        requires :email
      end
      purpose :directory do
        basis :legitimate_interests
        requires :name, :email
      end
      purpose :newsletter do
        basis :consent
        requires :email
      end
      purpose :greeting do
        basis :contract
        requires :name
      end
      consent do
        for_purpose(:newsletter) { required! }
      end
    end
    # The articles' author is a declared field of theirs (a dependent's key).
    PamDsl.define_policy(:article_policy) do
      field :author_id, type: :identifier
      field :title, type: :name
      purpose :contact do
        basis :contract
        requires :title
      end
    end
    %i[ReadArticle ReadUser].each { |name| Object.send(:remove_const, name) if Object.const_defined?(name) }
    Object.const_set(:ReadUser, Class.new(ActiveRecord::Base) do
      self.table_name = "users"
      has_many :articles, class_name: "ReadArticle", foreign_key: :author_id
    end)
    Object.const_set(:ReadArticle, Class.new(ActiveRecord::Base) do
      self.table_name = "articles"
      belongs_to :author, class_name: "ReadUser", optional: true
      # The users whose email is this article's title: an association whose
      # key is a declared field.
      has_many :addressees, class_name: "ReadUser", primary_key: :title, foreign_key: :email
      # The article's author again, as a has_one.
      has_one :reader, class_name: "ReadUser", primary_key: :author_id, foreign_key: :id
    end)
    ReadUser.include(Lyra::Interceptors::CrudInterceptor)
    ReadUser.monitor_with_lyra(privacy_policy: :query_policy)
    Lyra.config.monitor_model(ReadUser, privacy_policy: :query_policy)
    ReadArticle.include(Lyra::Interceptors::CrudInterceptor)
    ReadArticle.monitor_with_lyra
    Lyra.config.monitor_model(ReadArticle)
    clean
    Lyra.config.enable_monitor!
  end

  def teardown
    return unless defined?(ReadUser)

    Lyra.config.reads_without_purpose = :allow
    Lyra.config.record_access_events = false
    Lyra.config.projection_mode = :sync
    Lyra.config.enable_monitor!
    clean
    PamDsl.reset!
    PamDsl.logger = nil
  end

  # ---------------------------------------------------------------------------
  # The table
  # ---------------------------------------------------------------------------

  # A purpose that allows the field: the query runs and gives the answer it
  # gives with no purpose; what it read is recorded.
  def test_under_a_purpose_that_allows_the_field_every_query_runs_and_is_recorded
    each_mode do |mode|
      QUERIES.each do |label, (kind, query)|
        reset_users
        expected = query.call(:name, values(:name))
        Lyra.config.record_access_events = true
        result = Lyra.with_purpose(:directory) { query.call(:name, values(:name)) }
        Lyra.config.record_access_events = false

        assert_equal expected, result, "#{mode} #{label}"
        model_wide = Lyra::AccessLog.for("ReadUser$*")
        case kind
        when :unchecked, :load_none
          assert_empty model_wide, "#{mode} #{label}"
        when :aggregate
          assert_equal 1, model_wide.size, "#{mode} #{label}: one entry for the query"
          assert_equal ["directory", "granted"], model_wide.first.data.values_at(:purpose, :outcome)
          assert_includes model_wide.first.data[:fields], "name", "#{mode} #{label}"
        when :load, :load_other
          assert_empty model_wide, "#{mode} #{label}: a load is recorded per record"
          person = kind == :load ? @ann : @bo
          entries = Lyra::AccessLog.for(person)
          assert_equal 1, entries.size, "#{mode} #{label}"
          assert_includes entries.first.data[:fields], "name", "#{mode} #{label}: the field it filtered or sorted on"
        end
      end
    end
  end

  # A purpose that does not allow the field: refused before the query runs,
  # and the refusal recorded.
  def test_under_a_purpose_that_does_not_allow_the_field_every_query_naming_it_is_refused
    each_mode do |mode|
      QUERIES.each do |label, (kind, query)|
        reset_users
        Lyra.config.record_access_events = true
        statements = users_statements do
          if kind == :unchecked
            Lyra.with_purpose(:contact) { query.call(:name, values(:name)) }
          else
            assert_raises(PamDsl::PurposeFieldMismatchError, "#{mode} #{label}") do
              Lyra.with_purpose(:contact) { query.call(:name, values(:name)) }
            end
          end
        end
        Lyra.config.record_access_events = false
        next if kind == :unchecked

        assert_empty statements, "#{mode} #{label}: refused before the query ran" if mode == :monitor
        denied = Lyra::AccessLog.for("ReadUser$*")
        assert_equal [Lyra::Events::DataAccessDenied], denied.map(&:class), "#{mode} #{label}"
      end
    end
  end

  # A purpose resting on consent: a load is checked per record returned, so
  # it serves the people who consented; a query over everyone cannot check
  # anyone's consent and is refused.
  def test_under_a_consent_purpose_loads_are_checked_per_record_and_the_rest_refused
    each_mode do |mode|
      QUERIES.each do |label, (kind, query)|
        reset_users
        expected = query.call(:email, values(:email))
        run = -> { Lyra.with_purpose(:newsletter) { query.call(:email, values(:email)) } }
        case kind
        when :unchecked, :load, :load_none
          assert_equal expected, run.call, "#{mode} #{label}"
        when :aggregate
          assert_raises(PamDsl::ConsentRequiredError, "#{mode} #{label}") { run.call }
        when :load_other
          assert_raises(PamDsl::ConsentRequiredError, "#{mode} #{label}: Bo gave no consent") { run.call }
        end
      end
    end
  end

  # With no purpose, a query naming a declared field follows
  # reads_without_purpose, as pluck does.
  def test_with_no_purpose_queries_follow_reads_without_purpose
    each_mode do |mode|
      QUERIES.each do |label, (kind, query)|
        reset_users
        expected = query.call(:name, values(:name))

        Lyra.config.reads_without_purpose = :deny
        if kind == :unchecked
          assert_equal expected, query.call(:name, values(:name)), "#{mode} #{label}"
        else
          assert_raises(Lyra::PurposeBoundReads::PurposeRequiredError, "#{mode} #{label}") { query.call(:name, values(:name)) }
        end

        Lyra.config.reads_without_purpose = :audit
        Lyra.config.record_access_events = true
        result = Rails.logger.stub(:warn, nil) { query.call(:name, values(:name)) }
        Lyra.config.record_access_events = false
        assert_equal expected, result, "#{mode} #{label}"
        audited = Lyra::AccessLog.for("ReadUser$*").map { _1.data[:outcome] }
        assert_equal(kind == :unchecked ? [] : ["audited"], audited, "#{mode} #{label}")
      ensure
        Lyra.config.reads_without_purpose = :allow
      end
    end
  end

  # ---------------------------------------------------------------------------
  # The probe of the design note, section 1
  # ---------------------------------------------------------------------------

  # Under :contact (email only) every one of these named name and ran, or
  # answered by raising for Ann and returning nil for Zed.
  def test_the_probe_every_query_on_a_field_the_purpose_may_not_use_is_refused
    each_mode do |mode|
      reset_users
      probes = {
        "group(:name).count" => -> { ReadUser.group(:name).count },
        "maximum(:name)" => -> { ReadUser.maximum(:name) },
        "count(:name)" => -> { ReadUser.count(:name) },
        "where(name:).count" => -> { ReadUser.where(name: "Ann").count },
        "where(name:).exists?" => -> { ReadUser.where(name: "Ann").exists? },
        "exists?(name: Ann)" => -> { ReadUser.exists?(name: "Ann") },
        "exists?(name: Zed)" => -> { ReadUser.exists?(name: "Zed") },
        "where(name:).ids" => -> { ReadUser.where(name: "Ann").ids },
        "where(name:).pluck(:id)" => -> { ReadUser.where(name: "Ann").pluck(:id) },
        "select(:id).where(name:).first" => -> { ReadUser.select(:id).where(name: "Ann").first },
        "find_by(name: Ann)" => -> { ReadUser.find_by(name: "Ann") },
        "find_by(name: Zed)" => -> { ReadUser.find_by(name: "Zed") },
        "find_by!(name: Zed)" => -> { ReadUser.find_by!(name: "Zed") }
      }
      Lyra.with_purpose(:contact) do
        probes.each do |label, probe|
          assert_raises(PamDsl::PurposeFieldMismatchError, "#{mode} #{label}") { probe.call }
        end
        assert_equal 2, ReadUser.count, "#{mode}: a count of all rows names no one's data"
        assert_equal "ann@example.com", ReadUser.select(:id, :email).find_by(email: "ann@example.com").email, mode
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Forms beyond the table
  # ---------------------------------------------------------------------------

  # A joined model's declared fields are checked against its own policy,
  # with subject Other$*.
  def test_a_condition_on_a_joined_model_is_checked_against_its_policy
    each_mode do |mode|
      reset_users
      ReadArticle.create!(title: "On Ann", author_id: @ann.id)
      Lyra.config.record_access_events = true
      Lyra.with_purpose(:contact) do
        assert_raises(PamDsl::PurposeFieldMismatchError, mode.to_s) do
          ReadArticle.joins(:author).where(users: { name: "Ann" }).count
        end
        assert_equal 1, ReadArticle.joins(:author).where(users: { email: "ann@example.com" }).count, mode
        assert_equal 1, ReadArticle.joins(:author).count, "#{mode}: the join itself names no declared field"
      end
      assert_equal 1, Lyra.with_purpose(:directory) { ReadArticle.joins(:author).where(users: { name: "Ann" }).count }, mode
      Lyra.config.record_access_events = false
      outcomes = Lyra::AccessLog.for("ReadUser$*").map { [_1.data[:purpose], _1.data[:outcome], _1.data[:fields]] }
      assert_equal [["contact", "denied", ["name"]], ["contact", "granted", ["email"]], ["directory", "granted", ["name"]]],
                   outcomes, mode
    end
  end

  # An association's records are records returned: each is checked, consent
  # included, in both modes, also when its key is a declared field (which its
  # query now names). It held before; it guards the new query-time check.
  def test_an_association_s_records_are_checked_in_every_mode
    each_mode do |mode|
      reset_users
      article = ReadArticle.create!(title: "bo@example.com")
      seen = []
      assert_raises(PamDsl::ConsentRequiredError, "#{mode}: Bo gave no consent") do
        Lyra.with_purpose(:newsletter) { ReadArticle.find(article.id).addressees.each { seen << _1 } }
      end
      assert_empty seen, mode
      assert_equal ["Bo"], Lyra.with_purpose(:directory) { ReadArticle.find(article.id).addressees.map(&:name) }, mode
    end
  end

  # Rails' dependent: :delete_all and :nullify, and the lookup of the
  # children dependent: :destroy destroys, are part of destroying the parent,
  # as a uniqueness check is part of saving: a write, not a read for a
  # purpose. The application's own delete by the same key is checked.
  def test_a_parent_s_dependents_are_part_of_its_destroy
    parents = {
      delete_all: Class.new(ActiveRecord::Base) { self.table_name = "users" },
      nullify: Class.new(ActiveRecord::Base) { self.table_name = "users" },
      destroy: Class.new(ActiveRecord::Base) { self.table_name = "users" }
    }
    parents.each do |dependent, parent|
      Object.const_set(:"#{dependent.to_s.camelize}Parent", parent)
      parent.has_many :articles, class_name: "ReadArticle", foreign_key: :author_id, dependent: dependent
      parent.include(Lyra::Interceptors::CrudInterceptor)
      parent.monitor_with_lyra
      Lyra.config.monitor_model(parent)
    end
    ReadArticle.monitor_with_lyra(privacy_policy: :article_policy)
    Lyra.config.monitor_model(ReadArticle, privacy_policy: :article_policy)

    each_mode do |mode|
      parents.each do |dependent, parent|
        clean
        owner = parent.create!(name: "Ann", email: "ann@example.com")
        ReadArticle.create!(title: "On Ann", author_id: owner.id)
        owner = parent.find(owner.id)

        assert Lyra.with_purpose(:contact) { owner.destroy }, "#{mode} #{dependent}"
        # ES-NoProj does not apply dependent: :delete_all to the event log, with
        # or without a purpose (a defect of its own): only the refusal is
        # tested there.
        next if mode == :es_noproj && dependent == :delete_all

        left = Lyra::PurposeBoundReads.internal(lyra_internal) { ReadArticle.pluck(:author_id) }
        assert_equal(dependent == :nullify ? [nil] : [], left, "#{mode} #{dependent}")
      end

      ReadArticle.create!(title: "On Bo", author_id: 7)
      assert_raises(PamDsl::PurposeFieldMismatchError, mode.to_s) do
        Lyra.with_purpose(:contact) { ReadArticle.where(author_id: 7).delete_all }
      end
      assert_raises(PamDsl::PurposeFieldMismatchError, mode.to_s) do
        Lyra.with_purpose(:contact) { ReadArticle.where(author_id: 7).update_all(author_id: nil) }
      end
    end
  ensure
    %i[DeleteAllParent NullifyParent DestroyParent].each { Object.send(:remove_const, _1) if Object.const_defined?(_1) }
  end

  # A block given to select (and find, many?) runs on records the relation
  # loads, as in Active Record: each is checked before the block sees it.
  # Enumerable's own methods (map, filter, reject, group_by, ...) go through
  # each, which delivers the same way.
  def test_a_block_over_the_records_sees_only_checked_records
    blocks = {
      "select { }" => -> { ReadUser.all.select { _1.email.present? } },
      "find { }" => -> { ReadUser.all.find { _1.email == "ann@example.com" } },
      "many? { }" => -> { ReadUser.all.many? { _1.email.present? } },
      "count { }" => -> { ReadUser.all.count { _1.email.present? } },
      "filter { }" => -> { ReadUser.all.filter { _1.email.present? } },
      "reject { }" => -> { ReadUser.all.reject { _1.email.present? } },
      "map" => -> { ReadUser.all.map(&:email) },
      "group_by { }" => -> { ReadUser.all.group_by(&:email) },
      "partition { }" => -> { ReadUser.all.partition { _1.email.present? } },
      "sort_by { }" => -> { ReadUser.all.sort_by(&:email) }
    }
    each_mode do |mode|
      reset_users
      expected = blocks.transform_values(&:call)

      Lyra.with_purpose(:greeting) do
        blocks.each do |label, block|
          assert_raises(PamDsl::PurposeFieldMismatchError, "#{mode} #{label}") { block.call }
        end
        # Narrowed to what the purpose may use, the records have no email to test.
        assert_raises(ActiveModel::MissingAttributeError, mode.to_s) do
          ReadUser.select(:id, :name).select { _1.email.present? }.count
        end
        assert_equal ["Ann"], ReadUser.select(:id, :name).select { _1.name == "Ann" }.map(&:name), mode
      end

      Lyra.config.record_access_events = true
      assert_equal expected["select { }"].map(&:id), Lyra.with_purpose(:directory) { ReadUser.all.select { _1.email.present? } }.map(&:id), mode
      assert_equal expected["find { }"].id, Lyra.with_purpose(:directory) { ReadUser.all.find { _1.email == "ann@example.com" } }.id, mode
      Lyra.config.record_access_events = false
      [@ann, @bo].each do |person|
        assert_equal 2, Lyra::AccessLog.for(person).size, "#{mode}: one entry per load the record was in"
      end
    end
  end

  def test_a_subquery_is_part_of_the_query
    each_mode do |mode|
      reset_users
      ReadArticle.create!(title: "On Ann", author_id: @ann.id)
      Lyra.with_purpose(:contact) do
        assert_raises(PamDsl::PurposeFieldMismatchError, mode.to_s) do
          ReadArticle.where(author_id: ReadUser.where(name: "Ann").select(:id)).count
        end
        assert_equal 1, ReadArticle.where(author_id: ReadUser.where(email: "ann@example.com").select(:id)).count, mode
      end
    end
  end

  # A fragment is matched by declared name, as a word; a value bound into it
  # is not a name.
  def test_an_sql_fragment_is_matched_by_declared_name
    each_mode do |mode|
      reset_users
      Lyra.with_purpose(:contact) do
        assert_raises(PamDsl::PurposeFieldMismatchError, mode.to_s) { ReadUser.where("name = ?", "Ann").count }
        assert_raises(PamDsl::PurposeFieldMismatchError, mode.to_s) { ReadUser.exists?(["name = ?", "Zed"]) }
        assert_raises(PamDsl::PurposeFieldMismatchError, mode.to_s) { ReadUser.where("email LIKE ? OR name LIKE ?", "a%", "a%").exists? }
        assert_equal 1, ReadUser.where("email = ?", "ann@example.com").count, mode
        assert_equal 2, ReadUser.where("email <> ?", "name").count, "#{mode}: a bound value is not a field"
      end
    end

    use_mode(:monitor)
    reset_users
    Lyra.with_purpose(:contact) do
      assert_raises(PamDsl::PurposeFieldMismatchError) { ReadUser.order(Arel.sql("LOWER(users.name)")).pluck(:id) }
      assert_raises(PamDsl::PurposeFieldMismatchError) { ReadUser.group(:email).having("COUNT(name) > 0").count }
      assert_raises(PamDsl::PurposeFieldMismatchError) { ReadUser.from(ReadUser.where(name: "Ann"), :users).count }
      assert_equal 2, ReadUser.where("email <> 'name'").count, "a quoted literal is not a field"
      assert_equal 1, ReadUser.where(ReadUser.arel_table[:email].eq("ann@example.com")).count
      assert_raises(PamDsl::PurposeFieldMismatchError) { ReadUser.where(ReadUser.arel_table[:name].eq("Ann")).count }
    end
  end

  # The async forms build their query in the caller's thread, where the
  # purpose is. ES-NoProj cannot run them at all.
  def test_async_count_is_checked_in_the_callers_thread
    use_mode(:monitor)
    reset_users
    Lyra.with_purpose(:contact) do
      assert_raises(PamDsl::PurposeFieldMismatchError) { ReadUser.async_count(:name) }
      assert_raises(PamDsl::PurposeFieldMismatchError) { ReadUser.where(name: "Ann").async_count }
    end
    assert_equal 1, Lyra.with_purpose(:directory) { ReadUser.where(name: "Ann").async_count.value }

    use_mode(:es_noproj)
    reset_users
    Lyra.with_purpose(:directory) do
      assert_raises(Lyra::Projections::UnsupportedQuery) { ReadUser.async_count(:name) }
    end
  end

  # A batch query is checked, and recorded, once: not once per batch.
  def test_batches_are_checked_and_recorded_once
    each_mode do |mode|
      reset_users
      ReadUser.create!(name: "Ann", email: "ann2@example.com")
      ReadUser.create!(name: "Ann", email: "ann3@example.com")
      Lyra.config.record_access_events = true

      batches = 0
      Lyra.with_purpose(:directory) { ReadUser.where(name: "Ann").in_batches(of: 1) { batches += 1 } }
      assert_equal 3, batches, mode
      assert_equal 1, Lyra::AccessLog.for("ReadUser$*").size, "#{mode}: in_batches, one entry"

      PamDsl.enforcement_mode = :audit
      seen = []
      Lyra.with_purpose(:contact) { ReadUser.select(:id).where(name: "Ann").find_each(batch_size: 1) { seen << _1.id } }
      assert_equal 3, seen.size, mode
      audited = Lyra::AccessLog.for("ReadUser$*").select { _1.data[:purpose] == "contact" }
      assert_equal ["audited"], audited.map { _1.data[:outcome] }, "#{mode}: find_each, one entry for the query"
    ensure
      PamDsl.enforcement_mode = :strict
      Lyra.config.record_access_events = false
    end
  end

  # Under audit enforcement a violation is logged and the query runs.
  def test_in_audit_mode_a_violation_is_logged_and_the_query_runs
    each_mode do |mode|
      reset_users
      PamDsl.enforcement_mode = :audit
      @log.truncate(0)
      assert_equal({ "Ann" => 1, "Bo" => 1 }, Lyra.with_purpose(:contact) { ReadUser.group(:name).count }, mode)
      assert_equal [@ann.id], Lyra.with_purpose(:contact) { ReadUser.where(name: "Ann").pluck(:id) }, mode
      assert_match(/PurposeFieldMismatchError.*name/, @log.string, mode)
    ensure
      PamDsl.enforcement_mode = :strict
    end
  end

  # Rails' uniqueness check is part of writing the record; the
  # application's own find_or_create_by is a lookup and stays checked.
  def test_a_uniqueness_check_is_part_of_the_write
    ReadUser.validates :name, uniqueness: true
    each_mode do |mode|
      reset_users
      Lyra.with_purpose(:contact) do
        assert ReadUser.create!(name: "Uma", email: "uma@example.com"), mode
        assert_raises(PamDsl::PurposeFieldMismatchError, mode.to_s) { ReadUser.find_or_create_by(name: "Vi") { _1.email = "vi@example.com" } }
      end
    end
  end

  # Lyra's own reads are not processing for a purpose: a join's partners in
  # ES-NoProj are read by Lyra to evaluate the join, as SQL reads them.
  def test_lyra_s_own_reads_are_not_checked
    each_mode do |mode|
      reset_users
      ReadArticle.create!(title: "On Ann", author_id: @ann.id)
      Lyra.config.reads_without_purpose = :deny
      assert_raises(Lyra::PurposeBoundReads::PurposeRequiredError, mode.to_s) { ReadUser.where(name: "Ann").count }
      assert_equal 1, Lyra::PurposeBoundReads.internal(lyra_internal) { ReadUser.where(name: "Ann").count }, mode
      Lyra.config.reads_without_purpose = :allow

      assert_equal 1, Lyra.with_purpose(:contact) { ReadArticle.joins(:author).count }, mode
    ensure
      Lyra.config.reads_without_purpose = :allow
    end
  end

  # With no purpose in scope and reads_without_purpose :allow (the default,
  # and every benchmark), the hooks return before looking at the query.
  def test_nothing_is_inspected_when_nothing_is_checked
    each_mode do |mode|
      reset_users
      Lyra::PurposeBoundReads.expects(:named_fields_of).never
      Lyra::PurposeBoundReads.expects(:check_query).never
      Lyra::PurposeBoundReads.expects(:once).never
      QUERIES.each_value { |_kind, query| query.call(:name, values(:name)) }
      ReadUser.find_by(name: "Ann")
      ReadUser.where(name: "Ann").find_each { nil }
      ReadUser.where(name: "Ann").in_batches(of: 1) { nil }
      Lyra::PurposeBoundReads.unstub(:named_fields_of, :check_query, :once)
      assert true, mode
    end
  end

  # The fields a relation names, by model: the Arel walk.
  def test_named_fields_of_walks_the_relation
    named = ->(relation) { Lyra::PurposeBoundReads.named_fields_of(relation).transform_values(&:sort) }
    assert_equal({ ReadUser => ["name"] }, named.call(ReadUser.where(name: "Ann")))
    assert_equal({ ReadUser => %w[email name] }, named.call(ReadUser.where(name: "Ann").or(ReadUser.where(email: "x"))))
    assert_equal({ ReadUser => %w[id name] }, named.call(ReadUser.select(:id).order(:name)))
    assert_equal({ ReadUser => ["name"] }, named.call(ReadUser.group("users.name")))
    assert_includes named.call(ReadUser.having("MAX(name) > 'a'"))[ReadUser], "name"
    refute_includes named.call(ReadUser.where("email = 'name'"))[ReadUser], "name"
    subquery = Lyra::PurposeBoundReads.query_names(ReadArticle.where(author_id: ReadUser.where(name: "Ann").select(:id)))
    assert_equal({ ReadArticle => ["author_id"] }, subquery.result, "the query's own")
    assert_equal ["id", "name"], subquery.whole[ReadUser].sort, "the subquery's, checked whole"
    assert_equal ["name"], named.call(ReadArticle.joins(:author).group(:name))[ReadUser], "a joined model's column"
    assert_includes Lyra::PurposeBoundReads.named_in_conditions(ReadArticle, author: ReadUser.new(id: 1)).result[ReadArticle], "author_id"
    assert_equal ["name"], named.call(ReadArticle.joins(:author).where(users: { name: "Ann" }))[ReadUser]
    assert_equal({}, named.call(ReadUser.all))
  end

  # ---------------------------------------------------------------------------
  # Found by review
  # ---------------------------------------------------------------------------

  # An association's reader returns a record: it is checked as a load is,
  # consent included, in ES-NoProj as Monitor's after_find checks it.
  def test_an_association_reader_returns_a_checked_record
    each_mode do |mode|
      reset_users
      on_ann = ReadArticle.create!(title: "On Ann", author_id: @ann.id)
      on_bo = ReadArticle.create!(title: "On Bo", author_id: @bo.id)
      Lyra.with_purpose(:contact) do
        assert_raises(PamDsl::PurposeFieldMismatchError, "#{mode} belongs_to") { ReadArticle.find(on_ann.id).author }
        assert_raises(PamDsl::PurposeFieldMismatchError, "#{mode} has_one") { ReadArticle.find(on_ann.id).reader }
        assert_raises(PamDsl::PurposeFieldMismatchError, "#{mode} preload") { ReadArticle.preload(:author).to_a.map(&:author) }
      end
      Lyra.with_purpose(:newsletter) do
        assert_raises(PamDsl::ConsentRequiredError, "#{mode}: Bo gave no consent") { ReadArticle.find(on_bo.id).author }
      end
      assert_equal "Ann", Lyra.with_purpose(:directory) { ReadArticle.find(on_ann.id).author.name }, mode
    end
  end

  # What a relation hands out is checked however it is asked for: records,
  # an enumerator, inspect.
  def test_every_way_out_of_a_relation_is_checked
    each_mode do |mode|
      reset_users
      Lyra.with_purpose(:contact) do
        {
          "records" => -> { ReadUser.all.records },
          "where(name:).records" => -> { ReadUser.where(name: "Ann").records },
          "each.map" => -> { ReadUser.all.each.map(&:name) },
          "find_each.map" => -> { ReadUser.all.find_each.map(&:name) },
          "inspect" => -> { ReadUser.where(name: "Ann").inspect }
        }.each do |label, way_out|
          assert_raises(PamDsl::PurposeFieldMismatchError, "#{mode} #{label}") { way_out.call }
        end
        shown = ReadUser.select(:id, :email).inspect
        assert_includes shown, "ann@example.com", mode
        refute_includes shown, "Ann\"", mode
        # Lyra's own code still reads the records as they are.
        raw = Lyra::PurposeBoundReads.internal(lyra_internal) { ReadUser.all.records.to_a }
        assert_equal %w[Ann Bo], raw.map(&:name).sort, mode
      end
    end
  end

  # A refused check stays refused: rescuing it and asking again inside a
  # batch loop does not get the answer. And a query the application makes
  # inside the loop is checked and recorded each time it is made.
  def test_a_refused_check_is_not_remembered_and_the_application_s_block_is_not_batched
    each_mode do |mode|
      reset_users
      retried = lambda do |query|
        Lyra.with_purpose(:contact) do
          ReadUser.where(email: "ann@example.com").find_each do
            query.call
          rescue PamDsl::PurposeFieldMismatchError
            query.call
          end
        end
      end
      assert_raises(PamDsl::PurposeFieldMismatchError, "#{mode} find_each") { retried.call(-> { ReadUser.where(name: "Ann").count }) }
      assert_raises(PamDsl::PurposeFieldMismatchError, "#{mode} in_batches") do
        Lyra.with_purpose(:contact) do
          ReadUser.where(email: "ann@example.com").in_batches do
            ReadUser.group(:name).count
          rescue PamDsl::PurposeFieldMismatchError
            ReadUser.group(:name).count
          end
        end
      end

      Lyra.config.record_access_events = true
      Lyra.with_purpose(:directory) do
        ReadUser.where(email: "ann@example.com").find_each { 2.times { ReadUser.where(name: "Ann").count } }
      end
      Lyra.config.record_access_events = false
      counts = Lyra::AccessLog.for("ReadUser$*").count { _1.data[:fields] == ["name"] }
      assert_equal 2, counts, "#{mode}: each count in the block is recorded"
    end
  end

  # A column named without its table, on a joined model, is that model's
  # (as SQL resolves it), and is checked against its policy.
  def test_an_unqualified_column_of_a_joined_model_is_that_model_s
    reset_users
    ReadArticle.create!(title: "On Ann", author_id: @ann.id)
    Lyra.with_purpose(:contact) do
      assert_raises(PamDsl::PurposeFieldMismatchError) { ReadArticle.joins(:author).pluck(:name) }
      assert_raises(PamDsl::PurposeFieldMismatchError) { ReadArticle.joins(:author).group(:name).count }
      assert_raises(PamDsl::PurposeFieldMismatchError) { ReadArticle.joins(:author).maximum(:name) }
      assert_equal ["ann@example.com"], ReadArticle.joins(:author).pluck(:email)
    end

    use_mode(:es_noproj)
    reset_users
    ReadArticle.create!(title: "On Ann", author_id: @ann.id)
    Lyra.with_purpose(:contact) do
      assert_raises(PamDsl::PurposeFieldMismatchError) { ReadArticle.joins(:author).group(:name).count }
    end
  end

  # A bulk write that copies a column reads it; a write that returns columns
  # reads them.
  def test_a_bulk_write_s_set_expressions_and_returning_columns_are_reads
    reset_users
    stamp = Time.utc(2026, 1, 1)
    Lyra.with_purpose(:contact) do
      assert_raises(PamDsl::PurposeFieldMismatchError) { ReadUser.where(id: @ann.id).update_all("email = name") }
      assert_raises(PamDsl::PurposeFieldMismatchError) { ReadUser.where(id: @bo.id).update_all(email: ReadUser.arel_table[:name]) }
      assert_raises(PamDsl::PurposeFieldMismatchError) do
        ReadUser.upsert_all([{ id: @ann.id, name: "Zed", email: "ann@example.com", created_at: stamp, updated_at: stamp }],
                            update_only: [:email], returning: [:name], record_timestamps: false)
      end
      assert_raises(PamDsl::PurposeFieldMismatchError) do
        ReadUser.insert_all([{ name: "Cy", email: "cy@example.com", created_at: stamp, updated_at: stamp }], returning: %w[id name])
      end
      assert_equal 1, ReadUser.where(id: @ann.id).update_all("email = LOWER(email)")
      assert_equal [["ann@example.com"]],
                   ReadUser.upsert_all([{ id: @ann.id, name: "Ann", email: "ann@example.com", created_at: stamp, updated_at: stamp }],
                                       update_only: [:email], returning: [:email], record_timestamps: false).rows
    end
    assert_equal %w[Ann Bo], ReadUser.order(:id).pluck(:name), "the refused writes wrote nothing"

    use_mode(:es_noproj)
    reset_users
    Lyra.with_purpose(:contact) do
      assert_raises(PamDsl::PurposeFieldMismatchError) { ReadUser.where(id: @bo.id).update_all(email: ReadUser.arel_table[:name]) }
    end
  end

  # A relation's cache version is a count and a maximum over its rows.
  def test_a_cache_version_is_an_aggregate
    reset_users
    Lyra.with_purpose(:contact) do
      assert_raises(PamDsl::PurposeFieldMismatchError) { ReadUser.where(name: "Zed").cache_version }
      assert_raises(PamDsl::PurposeFieldMismatchError) { ReadUser.where(name: "Ann").cache_key_with_version }
      assert_match(/\A1-/, ReadUser.where(email: "ann@example.com").cache_version)
    end
  end

  # A condition on an association is a condition on its foreign key.
  def test_a_condition_on_an_association_names_its_foreign_key
    ReadArticle.monitor_with_lyra(privacy_policy: :article_policy)
    Lyra.config.monitor_model(ReadArticle, privacy_policy: :article_policy)
    each_mode do |mode|
      reset_users
      ReadArticle.create!(title: "On Ann", author_id: @ann.id)
      Lyra.with_purpose(:contact) do
        assert_raises(PamDsl::PurposeFieldMismatchError, mode.to_s) { ReadArticle.where(author: @ann).count }
        assert_raises(PamDsl::PurposeFieldMismatchError, mode.to_s) { ReadArticle.exists?(author: @bo) }
        assert_equal 1, ReadArticle.where(title: "On Ann").count, mode
      end
    end
  end

  # The purpose follows the code into the fibers an Enumerator runs in, and
  # stays in its thread.
  def test_the_purpose_follows_enumerators_and_stays_in_its_thread
    each_mode do |mode|
      reset_users
      Lyra.with_purpose(:contact) do
        assert_raises(PamDsl::PurposeFieldMismatchError, "#{mode} to_enum.next") { ReadUser.all.to_enum.next }
        assert_raises(PamDsl::PurposeFieldMismatchError, "#{mode} find_each.next") { ReadUser.where(name: "Ann").find_each.next }
      end
      Lyra.config.reads_without_purpose = :deny
      assert_equal "ann@example.com",
                   Lyra.with_purpose(:contact) { ReadUser.select(:id, :email).order(:id).to_enum.next.email }, mode
    ensure
      Lyra.config.reads_without_purpose = :allow
    end

    Lyra.with_purpose(:contact) do
      assert_nil Thread.new { Lyra::PurposeBoundReads.current }.value, "a thread started under a purpose has none"
      assert_equal :contact, Fiber.new { Lyra::PurposeBoundReads.current }.resume
      Lyra::PurposeBoundReads.internal(lyra_internal) do
        refute Lyra::PurposeBoundReads.checking?
        assert Thread.new { Lyra.with_purpose(:contact) { Lyra::PurposeBoundReads.checking? } }.value, "nor Lyra's internal flag"
      end
    end
  end

  # A subquery reads other people, whatever its model: its fields are checked
  # whole (subject Model$*), as an aggregate's, consent included.
  def test_a_subquery_is_checked_whole_even_on_the_same_model
    each_mode do |mode|
      reset_users
      assert_raises(PamDsl::ConsentRequiredError, mode.to_s) do
        Lyra.with_purpose(:newsletter) do
          ReadUser.select(:id).where(id: @ann.id).where(id: ReadUser.where(email: "bo@example.com").select(:id)).to_a
        end
      end
      assert_equal [@ann.id], Lyra.with_purpose(:newsletter) { ReadUser.select(:id).where(email: "ann@example.com").map(&:id) }, mode
    end
  end

  # table.column inside an SQL fragment belongs to that table's model; a CTE
  # is a subquery.
  def test_a_qualified_column_in_a_fragment_and_a_cte_are_read
    reset_users
    ReadArticle.create!(title: "On Ann", author_id: @ann.id)
    Lyra.with_purpose(:contact) do
      assert_raises(PamDsl::PurposeFieldMismatchError) { ReadArticle.joins(:author).where("users.name = ?", "Ann").count }
      assert_raises(PamDsl::PurposeFieldMismatchError) { ReadArticle.joins(:author).pluck(Arel.sql("UPPER(users.name)")) }
      assert_raises(PamDsl::PurposeFieldMismatchError) { ReadUser.with(n: ReadUser.where(name: "Ann")).from("n AS users").count }
      assert_equal 1, ReadArticle.joins(:author).where("users.email = ?", "ann@example.com").count
    end
  end

  private

  def each_mode
    MODES.each_key do |mode|
      use_mode(mode)
      yield mode
    end
  end

  def use_mode(mode)
    clean
    MODES.fetch(mode).call
  end

  # Ann (consent to :newsletter) and Bo (none), afresh, with no access log.
  def reset_users
    Lyra.config.record_access_events = false
    clean
    @ann = ReadUser.create!(name: "Ann", email: "ann@example.com")
    @bo = ReadUser.create!(name: "Bo", email: "bo@example.com")
    PamDsl.policy(:query_policy).consent_policy.grant_consent(purpose: :newsletter, subject: @ann)
  end

  def values(field)
    field == :name ? { ann: "Ann", bo: "Bo", none: "Zed" } : { ann: "ann@example.com", bo: "bo@example.com", none: "zed@example.com" }
  end

  # The SQL statements on the users table run inside the block.
  def users_statements
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      statements << payload[:sql] if payload[:sql].match?(/\b(FROM|UPDATE|INTO)\s+"users"/i)
    end
    yield
    statements
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  def clean
    conn = ActiveRecord::Base.connection
    conn.execute("DELETE FROM articles")
    conn.execute("DELETE FROM users")
    conn.execute("DELETE FROM event_store_events_in_streams")
    conn.execute("DELETE FROM event_store_events")
  end
end
