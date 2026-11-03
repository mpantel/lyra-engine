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

  class BypassTestCurrent < ActiveSupport::CurrentAttributes
    attribute :user, :request_id
  end

  # Parent side of dependent: :nullify. Not monitored: the point is what
  # happens to the monitored children when Rails nullifies them.
  class BypassTestAuthor < ActiveRecord::Base
    self.table_name = "users"
    has_many :articles, class_name: "BypassTestArticle", foreign_key: :author_id, dependent: :nullify
  end

  # Parent side of dependent: :delete_all, which deletes the children with
  # one DELETE and no callbacks.
  class BypassTestDeletingAuthor < ActiveRecord::Base
    self.table_name = "users"
    has_many :articles, class_name: "BypassTestArticle", foreign_key: :author_id, dependent: :delete_all
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

    # The other callback-skipping writes ActiveRecord offers all reach the
    # relation's update_all, delete_all or upsert_all, so the bypass events
    # cover them without overrides of their own. One test each pins that
    # routing: a Rails upgrade that changed it would fail here.
    def test_update_counters_and_increment_counter_publish_updates
      a = create_article("Counted", author_id: 5)
      clear_event_store

      BypassTestArticle.update_counters(a.id, author_id: 2)
      BypassTestArticle.increment_counter(:author_id, a.id)

      events = events_for(a)
      assert_equal 2, events.size
      assert_equal [{ "author_id" => [5, 7] }, { "author_id" => [7, 8] }], events.map { value(_1.data, :changes) }
      assert(events.all? { _1.metadata[:bypass_source] == "update_all" })
    end

    def test_increment_bang_publishes_an_update
      a = create_article("Counted", author_id: 1)
      clear_event_store

      a.increment!(:author_id)

      assert_equal({ "author_id" => [1, 2] }, value(only_event(a).data, :changes))
      assert_equal 2, a.reload.author_id
    end

    # Events never carry created_at/updated_at, so a bare touch_all changes
    # nothing an event records; a named column is recorded like any other.
    def test_touch_all_publishes_an_update_per_row_for_a_named_column
      a = create_article("One")
      b = create_article("Two")
      clear_event_store

      BypassTestArticle.where(id: [a.id, b.id]).touch_all(time: 1.day.from_now)
      assert_empty events_for(a) + events_for(b)

      BypassTestArticle.where(id: [a.id, b.id]).touch_all(:published_at)

      [a, b].each do |article|
        event = only_event(article)
        assert_equal "update_all", event.metadata[:bypass_source]
        assert_equal ["published_at"], value(event.data, :changes).keys
        assert_nil value(event.data, :changes)["published_at"].first
      end
    end

    def test_delete_by_publishes_a_destroyed_event
      a = create_article("One")
      clear_event_store

      BypassTestArticle.delete_by(id: a.id)

      event = only_event(a)
      assert_equal "delete_all", event.metadata[:bypass_source]
      assert_equal "destroyed", value(event.data, :operation).to_s
    end

    def test_singular_upsert_publishes_created_then_updated
      now = Time.current
      BypassTestUser.upsert({ email: "bypass-upsert@example.com", name: "First", created_at: now, updated_at: now },
                            unique_by: :email)
      user = BypassTestUser.find_by!(email: "bypass-upsert@example.com")
      BypassTestUser.upsert({ email: "bypass-upsert@example.com", name: "Second", created_at: now, updated_at: now },
                            unique_by: :email)

      events = events_for(user)
      assert_equal %w[created updated], events.map { value(_1.data, :operation).to_s }
      assert_equal %w[First Second], value(events.last.data, :changes)["name"]
    end

    def test_dependent_delete_all_publishes_a_destroyed_event_per_child
      author = BypassTestDeletingAuthor.create!(name: "Author", email: "bypass-deleting@example.com")
      a = create_article("Child one", author_id: author.id)
      b = create_article("Child two", author_id: author.id)
      clear_event_store

      author.destroy

      assert_empty BypassTestArticle.where(id: [a.id, b.id])
      [a, b].each { assert_equal "destroyed", value(only_event(_1).data, :operation).to_s }
    end

    def test_strict_mode_rejects_the_routed_writes
      Lyra.config.strict_data_access = true
      a = create_article("One", author_id: 1)
      now = Time.current
      writes = {
        update_counters: -> { BypassTestArticle.update_counters(a.id, author_id: 1) },
        increment!: -> { a.increment!(:author_id) },
        touch_all: -> { BypassTestArticle.where(id: a.id).touch_all },
        delete_by: -> { BypassTestArticle.delete_by(id: a.id) },
        upsert: lambda {
          BypassTestUser.upsert({ email: "bypass-strict@example.com", name: "S", created_at: now, updated_at: now },
                                unique_by: :email)
        }
      }
      clear_event_store

      writes.each do |name, write|
        assert_raises(Lyra::StrictDataAccessViolation, "#{name} was not rejected") { write.call }
      end
      assert_empty events_for(a)
      assert_equal [1, "One"], a.reload.then { [_1.author_id, _1.title] }
      assert_nil BypassTestUser.find_by(email: "bypass-strict@example.com")
    end

    # Unlike dependent: :nullify, dependent: :delete_all is not exempt: it
    # deletes rows outright, so strict mode refuses it and the parent's
    # destroy rolls back with it.
    def test_strict_mode_rejects_dependent_delete_all
      Lyra.config.strict_data_access = true
      author = BypassTestDeletingAuthor.create!(name: "Author", email: "bypass-strict-deleting@example.com")
      child = create_article("Child", author_id: author.id)
      clear_event_store

      assert_raises(Lyra::StrictDataAccessViolation) do
        BypassTestDeletingAuthor.transaction { author.destroy }
      end
      assert BypassTestDeletingAuthor.exists?(author.id)
      assert BypassTestArticle.exists?(child.id)
      assert_empty events_for(child)
    end

    # Who made the change is known whichever way the write went: a write that
    # skips callbacks still happens inside the request that made it.
    def test_writes_that_skip_callbacks_carry_the_user_and_the_request
      article = create_article("One")
      kept = create_article("Two")
      author = BypassTestAuthor.create!(email: "bypass-actor@example.com", name: "Author")
      owned = create_article("Three", author_id: author.id)
      clear_event_store

      with_current_user do
        article.update_column(:status, "a")
        article.update_columns(status: "b")
        article.touch
        BypassTestArticle.where(id: article.id).update_all(status: "c")
        BypassTestArticle.insert_all([{ title: "Inserted", status: "draft", created_at: Time.current, updated_at: Time.current }])
        BypassTestArticle.upsert_all([{ id: article.id, title: "One", status: "d", created_at: Time.current, updated_at: Time.current }], unique_by: :id)
        author.destroy
        kept.delete
        BypassTestArticle.where(id: article.id).delete_all
      end

      events = Lyra.config.event_store.read.to_a.select do |event|
        event.metadata[:bypass_source] || event.metadata[:nullify_source]
      end
      sources = events.map { _1.metadata[:bypass_source] || _1.metadata[:nullify_source] }
      assert_equal %w[delete delete_all dependent_association insert_all touch update_all update_columns upsert_all],
                   sources.uniq.sort
      assert_equal [7], events.map { _1.metadata[:user_id] }.uniq
      assert_equal ["req-1"], events.map { _1.metadata[:request_id] }.uniq
      assert_equal 7, events_for(owned).first.metadata[:user_id]
    end

    # A console, a job or a guest: nobody to name, and nothing made up.
    def test_a_write_with_nobody_signed_in_names_nobody
      article = create_article("One")
      clear_event_store

      with_current_user(user: nil, request_id: nil) { article.update_column(:status, "a") }

      event = only_event(article)
      assert_nil event.metadata[:user_id]
      assert_nil event.metadata[:request_id]
    end

    def test_a_write_in_an_application_without_current_names_nobody
      skip "the application defines Current" if Object.const_defined?(:Current, false)
      article = create_article("One")
      clear_event_store

      article.update_column(:status, "a")

      assert_nil only_event(article).metadata[:user_id]
    end

    private

    # The application's Current, for the block only.
    def with_current_user(user: Struct.new(:id).new(7), request_id: "req-1")
      original = Object.send(:remove_const, :Current) if Object.const_defined?(:Current, false)
      Object.const_set(:Current, BypassTestCurrent)
      BypassTestCurrent.user = user
      BypassTestCurrent.request_id = request_id
      yield
    ensure
      BypassTestCurrent.reset
      Object.send(:remove_const, :Current) if Object.const_defined?(:Current, false)
      Object.const_set(:Current, original) if original
    end

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
