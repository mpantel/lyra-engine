# frozen_string_literal: true

require "test_helper"

if defined?(ActiveRecord::Base)
  class BypassTestArticle < ActiveRecord::Base
    self.table_name = "articles"
    include Lyra::Interceptors::CrudInterceptor
    monitor_with_lyra
  end

  # users.email has a unique index, so upsert_all can conflict on it.
  class BypassTestUser < ActiveRecord::Base
    self.table_name = "users"
    include Lyra::Interceptors::CrudInterceptor
    monitor_with_lyra
  end

  # Parent side of dependent: :nullify. Not monitored: the point is what
  # happens to the monitored children when Rails nullifies them.
  class BypassTestAuthor < ActiveRecord::Base
    self.table_name = "users"
    has_many :articles, class_name: "BypassTestArticle", foreign_key: :author_id, dependent: :nullify
  end
end

module Lyra
  # Every callback-bypassing write on a monitored model must leave an event,
  # whatever the strict_data_access setting, unless it is Lyra's own
  # projection write. The case study runs in Monitor mode with strict mode
  # off, so that is the default configuration here.
  class BypassEventsTest < Minitest::Test
    def self.runnable_methods
      return [] unless defined?(ActiveRecord::Base) && defined?(Rails)

      super
    end

    def setup
      Lyra.reset_config!
      Lyra.configure do |config|
        config.mode = :monitor
        config.event_store = RailsEventStore::Client.new(
          repository: RubyEventStore::ActiveRecord::EventRepository.new(
            serializer: RubyEventStore::Serializers::YAML
          )
        )
      end
      Lyra.projection_write do
        BypassTestArticle.delete_all
        BypassTestAuthor.where("email LIKE 'bypass-%'").delete_all
      end
      clear_event_store
    end

    def teardown
      Lyra.projection_write do
        BypassTestArticle.delete_all
        BypassTestAuthor.where("email LIKE 'bypass-%'").delete_all
      end
      clear_event_store
      Lyra.reset_config!
    end

    def test_update_all_publishes_an_updated_event_per_changed_row
      a = create_article("One")
      b = create_article("Two")
      untouched = create_article("Three")
      clear_event_store

      BypassTestArticle.where(id: [a.id, b.id]).update_all(status: "published")

      [a, b].each do |article|
        event = only_event(article)
        assert_equal "update_all", event.metadata[:bypass_source]
        assert_equal({ "status" => %w[draft published] }, value(event.data, :changes))
      end
      assert_empty events_for(untouched)
    end

    def test_update_all_with_sql_fragment_records_the_resulting_values
      a = create_article("One")
      clear_event_store

      BypassTestArticle.where(id: a.id).update_all("title = title || ' (edited)'")

      assert_equal({ "title" => ["One", "One (edited)"] }, value(only_event(a).data, :changes))
    end

    def test_update_all_that_changes_nothing_publishes_nothing
      a = create_article("One")
      clear_event_store

      BypassTestArticle.where(id: a.id).update_all(status: "draft")

      assert_empty events_for(a)
    end

    def test_delete_all_publishes_a_destroyed_event_per_row
      a = create_article("One")
      b = create_article("Two")
      clear_event_store

      BypassTestArticle.where(id: [a.id, b.id]).delete_all

      [a, b].each do |article|
        event = only_event(article)
        assert_equal "delete_all", event.metadata[:bypass_source]
        assert_equal "destroyed", value(event.data, :operation).to_s
      end
    end

    def test_insert_all_publishes_a_created_event_per_row
      now = Time.current
      BypassTestArticle.insert_all([
        { title: "Bulk one", status: "draft", created_at: now, updated_at: now },
        { title: "Bulk two", status: "draft", created_at: now, updated_at: now }
      ])

      BypassTestArticle.where(title: ["Bulk one", "Bulk two"]).each do |article|
        event = only_event(article)
        assert_equal "insert_all", event.metadata[:bypass_source]
        assert_equal article.title, value(value(event.data, :attributes), :title)
      end
    end

    def test_dependent_nullify_publishes_events_with_strict_mode_off
      refute Lyra.config.strict_data_access, "precondition: the case study's configuration"
      author = BypassTestAuthor.create!(name: "Author", email: "bypass-author@example.com")
      child = create_article("Child", author_id: author.id)
      clear_event_store

      author.destroy

      assert_nil child.reload.author_id
      event = only_event(child)
      assert_equal "dependent_association", event.metadata[:nullify_source]
      assert_equal({ "author_id" => [author.id, nil] }, value(event.data, :changes))
    end

    def test_strict_mode_raises_and_publishes_nothing
      Lyra.config.strict_data_access = true
      a = create_article("One")
      clear_event_store

      assert_raises(Lyra::StrictDataAccessViolation) do
        BypassTestArticle.where(id: a.id).update_all(status: "published")
      end
      assert_empty events_for(a)
      assert_equal "draft", a.reload.status
    end

    def test_without_strict_access_allows_bulk_writes_and_still_publishes
      Lyra.config.strict_data_access = true
      a = create_article("One")
      clear_event_store

      Lyra.without_strict_access do
        BypassTestArticle.where(id: a.id).delete_all
      end

      assert_equal "delete_all", only_event(a).metadata[:bypass_source]
    end

    def test_projection_writes_publish_nothing
      a = create_article("One")
      clear_event_store

      Lyra.projection_write do
        BypassTestArticle.where(id: a.id).update_all(status: "published")
        BypassTestArticle.where(id: a.id).delete_all
      end

      assert_empty events_for(a)
    end

    def test_disabled_mode_publishes_nothing
      a = create_article("One")
      clear_event_store
      Lyra.config.mode = :disabled

      BypassTestArticle.where(id: a.id).update_all(status: "published")

      assert_empty events_for(a)
    end

    # Event sourcing without projections: the stream is the only store, so a
    # bulk write through the read path must be recorded as events, or the
    # records reappear on the next read.
    def test_event_sourced_bulk_writes_without_projections_are_events
      a = create_article("One")
      b = create_article("Two")
      clear_event_store
      Lyra.config.mode = :event_sourcing
      Lyra.config.projection_mode = :disabled

      Lyra::Projections::CachedRelation.new(BypassTestArticle, [a]).update_all(status: "published")
      Lyra::Projections::CachedRelation.new(BypassTestArticle, [b]).delete_all

      assert_equal({ "status" => %w[draft published] }, value(only_event(a).data, :changes))
      assert_equal "destroyed", value(only_event(b).data, :operation).to_s
      refute BypassTestArticle.unscoped.exists?(b.id), "stale table row left behind"
    end

    # In the events-only store there is no row: the UPDATE matched nothing,
    # update_columns returned false, and no event was published, so the
    # change was lost. The event is the write.
    def test_update_columns_in_the_events_only_store_is_recorded
      Lyra.config.mode = :event_sourcing
      Lyra.config.projection_mode = :disabled
      article = create_article("One")

      assert article.update_columns(title: "Renamed")
      assert_equal({ "title" => %w[One Renamed] }, value(events_for(article).last.data, :changes))
      assert_equal "Renamed", BypassTestArticle.find(article.id).title
    end

    def test_event_sourced_update_all_without_projections_rejects_sql_fragments
      a = create_article("One")
      Lyra.config.mode = :event_sourcing
      Lyra.config.projection_mode = :disabled

      assert_raises(ArgumentError) do
        Lyra::Projections::CachedRelation.new(BypassTestArticle, [a]).update_all("title = 'x'")
      end
    end

    # upsert_all: existing rows (found by the conflict key) get "updated"
    # events with their changes, new rows get "created" events.
    def test_upsert_all_publishes_updated_and_created_events
      existing = create_user("bypass-old@example.com", "Old Name")
      clear_event_store

      BypassTestUser.upsert_all(
        [{ email: "bypass-old@example.com", name: "New Name" }, { email: "bypass-new@example.com", name: "Fresh" }],
        unique_by: :email
      )

      updated = only_event(existing)
      assert_equal "upsert_all", updated.metadata[:bypass_source]
      assert_equal "updated", value(updated.data, :operation).to_s
      assert_equal({ "name" => ["Old Name", "New Name"] }, value(updated.data, :changes))

      created = only_event(BypassTestUser.find_by!(email: "bypass-new@example.com"))
      assert_equal "created", value(created.data, :operation).to_s
    end

    def test_upsert_all_that_changes_nothing_publishes_nothing
      existing = create_user("bypass-same@example.com", "Same")
      clear_event_store

      BypassTestUser.upsert_all([{ email: "bypass-same@example.com", name: "Same" }], unique_by: :email)

      assert_empty events_for(existing)
    end

    def test_upsert_all_accepts_an_index_name_for_unique_by
      existing = create_user("bypass-idx@example.com", "Before")
      clear_event_store

      BypassTestUser.upsert_all([{ email: "bypass-idx@example.com", name: "After" }], unique_by: :index_users_on_email)

      assert_equal({ "name" => %w[Before After] }, value(only_event(existing).data, :changes))
    end

    # Lyra needs the primary keys back to find the rows; the caller still
    # gets the result they asked for.
    def test_upsert_all_keeps_the_callers_returning_contract
      result = BypassTestUser.upsert_all([{ email: "bypass-ret@example.com", name: "Ret" }],
                                         unique_by: :email, returning: false)
      assert_empty result.rows

      result = BypassTestUser.upsert_all([{ email: "bypass-ret2@example.com", name: "Ret2" }],
                                         unique_by: :email, returning: [:name])
      assert_equal ["name"], result.columns
      assert_equal [["Ret2"]], result.rows

      %w[bypass-ret@example.com bypass-ret2@example.com].each do |email|
        assert_equal "created", value(only_event(BypassTestUser.find_by!(email: email)).data, :operation).to_s
      end
    end

    def test_upsert_all_is_rejected_in_the_events_only_store
      Lyra.config.mode = :event_sourcing
      Lyra.config.projection_mode = :disabled

      error = assert_raises(Lyra::Projections::UnsupportedQuery) do
        BypassTestUser.upsert_all([{ email: "bypass-es@example.com", name: "ES" }], unique_by: :email)
      end
      assert_match(/upsert_all/, error.message)
      assert_match(/ON CONFLICT/, error.message)
    end

    # In the events-only store Model.insert_all goes through CachedRelation,
    # which used to run it as a "scope" and hand back the relation.
    def test_insert_all_in_the_events_only_store_returns_the_result_and_publishes
      Lyra.config.mode = :event_sourcing
      Lyra.config.projection_mode = :disabled
      now = Time.current

      result = BypassTestArticle.insert_all([{ title: "ES insert", status: "draft", created_at: now, updated_at: now }])

      assert_kind_of ActiveRecord::Result, result
      Lyra.config.mode = :monitor
      Lyra.config.projection_mode = :sync
      event = only_event(BypassTestArticle.unscoped.find_by!(title: "ES insert"))
      assert_equal "created", value(event.data, :operation).to_s
    end

    # The class-level hook used to miss these: ActiveRecord routes both
    # through the relation.
    def test_singular_insert_and_association_insert_all_publish
      now = Time.current
      BypassTestArticle.insert({ title: "Single", status: "draft", created_at: now, updated_at: now })
      author = BypassTestAuthor.create!(name: "Author", email: "bypass-assoc@example.com")
      author.articles.insert_all([{ title: "Via association", status: "draft", created_at: now, updated_at: now }])

      ["Single", "Via association"].each do |title|
        event = only_event(BypassTestArticle.find_by!(title: title))
        assert_equal "created", value(event.data, :operation).to_s
      end
      assert_equal author.id, BypassTestArticle.find_by!(title: "Via association").author_id
    end

    private

    def create_user(email, name)
      BypassTestUser.create!(email: email, name: name)
    end

    def create_article(title, **attrs)
      BypassTestArticle.create!(title: title, status: "draft", **attrs)
    end

    def events_for(record)
      Lyra.config.event_store.read.stream("#{record.class.name}$#{record.id}").to_a
    end

    def only_event(record)
      events = events_for(record)
      assert_equal 1, events.size, "expected exactly one event for #{record.class.name}$#{record.id}"
      events.first
    end

    def value(hash, key)
      hash[key] || hash[key.to_s]
    end

    def clear_event_store
      ActiveRecord::Base.connection.execute("DELETE FROM event_store_events_in_streams")
      ActiveRecord::Base.connection.execute("DELETE FROM event_store_events")
    end
  end
end
