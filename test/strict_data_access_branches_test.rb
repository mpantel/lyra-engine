# frozen_string_literal: true

require "test_helper"

if defined?(ActiveRecord::Base)
  class SdaArticle < ActiveRecord::Base
    self.table_name = "articles"
    include Lyra::Interceptors::CrudInterceptor
    monitor_with_lyra
  end

  # Not monitored: the parent whose destroy nullifies the monitored children.
  class SdaAuthor < ActiveRecord::Base
    self.table_name = "users"
    has_many :articles, class_name: "SdaArticle", foreign_key: :author_id, dependent: :nullify
  end
end

module Lyra
  # Lyra::StrictDataAccess and StrictDataAccessRelation: what the bypass
  # events tests leave out. The instance writes under strict mode (refused,
  # nothing written, no event; allowed inside without_strict_access, with
  # the event), update_columns with touch:, insert_all! and the RETURNING
  # forms it is given, a delete when Lyra is off, and a dependent: :nullify
  # with no children to clear.
  class StrictDataAccessBranchesTest < Minitest::Test
    def self.runnable_methods
      return [] unless defined?(ActiveRecord::Base) && defined?(Rails)

      super
    end

    def setup
      Lyra.reset_config!
      Lyra.configure do |config|
        config.mode = :monitor
        config.event_store = RailsEventStore::Client.new(
          repository: RubyEventStore::ActiveRecord::EventRepository.new(serializer: RubyEventStore::Serializers::YAML)
        )
      end
      wipe
    end

    def teardown
      wipe
      Lyra.reset_config!
    end

    # ── Strict mode on the instance writes ──

    def test_strict_mode_refuses_update_columns_update_column_and_delete
      article = SdaArticle.create!(title: "One", status: "draft")
      clear_event_store
      Lyra.config.strict_data_access = true

      { update_columns: -> { article.update_columns(status: "x") }, update_column: -> { article.update_column(:status, "x") },
        delete: -> { article.delete } }.each do |name, write|
        error = assert_raises(Lyra::StrictDataAccessViolation) { write.call }
        assert_equal name, error.method_name
        assert_equal SdaArticle, error.model_class
        assert_includes error.message, "Use #{Lyra::StrictDataAccessViolation::ALTERNATIVES[name]} instead"
      end

      assert_equal "draft", SdaArticle.find(article.id).status, "nothing written"
      assert_empty events_for(article)
    end

    # touch skips callbacks too, but Rails itself calls it (belongs_to ...
    # touch: true): it is not a violation, and it is recorded.
    def test_strict_mode_allows_touch_and_records_it
      article = SdaArticle.create!(title: "One", status: "draft", updated_at: 1.day.ago)
      clear_event_store
      Lyra.config.strict_data_access = true

      article.touch(:published_at)

      event = only_event(article)
      assert_equal "touch", event.metadata[:bypass_source]
      assert_equal %w[published_at updated_at], value(event.data, :changes).keys.sort
    end

    def test_without_strict_access_the_write_runs_and_is_recorded
      article = SdaArticle.create!(title: "One", status: "draft")
      clear_event_store
      Lyra.config.strict_data_access = true

      Lyra.without_strict_access do
        Lyra.without_strict_access { article.update_columns(status: "inner") }
        article.update_column(:status, "outer")
      end

      assert_equal "outer", SdaArticle.find(article.id).status
      assert_equal [{ "status" => %w[draft inner] }, { "status" => %w[inner outer] }],
                   events_for(article).map { value(_1.data, :changes) }
      assert_raises(Lyra::StrictDataAccessViolation) { article.update_columns(status: "after") }
    end

    def test_a_violation_without_a_known_alternative_says_how_to_allow_it
      message = Lyra::StrictDataAccessViolation.new(:upsert, SdaArticle).message

      refute_includes message, " Use "
      assert_includes message, "Disable strict_data_access mode if this is intentional."
    end

    # ── update_columns with touch: ──

    # The timestamps touch: sets are recorded with the columns written.
    def test_update_columns_with_touch_records_the_timestamps
      article = SdaArticle.create!(title: "One", status: "draft", updated_at: 1.day.ago)
      clear_event_store

      article.update_columns(status: "a", touch: true)
      first = value(events_for(article).last.data, :changes)
      article.update_columns(title: "Two", touch: :published_at)
      second = value(events_for(article).last.data, :changes)

      assert_equal %w[status updated_at], first.keys.sort
      assert_equal %w[published_at title updated_at], second.keys.sort
      assert_equal article.reload.published_at.to_i, second["published_at"].last.to_i
    end

    # ── insert_all! ──

    def test_insert_all_bang_publishes_a_created_event_per_row
      now = Time.current
      result = SdaArticle.insert_all!([{ title: "A", status: "draft", created_at: now, updated_at: now },
                                       { title: "B", status: "draft", created_at: now, updated_at: now }])

      ids = SdaArticle.order(:title).pluck(:id)
      assert_equal 2, result.length
      ids.each do |id|
        event = Lyra.config.event_store.read.stream("SdaArticle$#{id}").to_a.sole
        assert_equal "insert_all!", event.metadata[:bypass_source]
      end
    end

    # The caller gets the RETURNING it asked for; Lyra reads the primary key
    # with it to publish the events.
    def test_insert_all_bang_keeps_the_callers_returning
      now = Time.current
      row = ->(title) { { title: title, status: "draft", created_at: now, updated_at: now } }

      titles = SdaArticle.insert_all!([row.call("A")], returning: :title)
      nothing = SdaArticle.insert_all!([row.call("B")], returning: false)
      literal = SdaArticle.insert_all!([row.call("C")], returning: Arel.sql("id, upper(title) AS shout"))

      assert_equal [["title"], [["A"]]], [titles.columns, titles.rows]
      assert_empty nothing.rows
      assert_equal ["C"], literal.rows.map(&:last)
      assert_equal 3, SdaArticle.count
      SdaArticle.pluck(:id).each do |id|
        assert_equal 1, Lyra.config.event_store.read.stream("SdaArticle$#{id}").to_a.size
      end
    end

    def test_strict_mode_refuses_insert_all_bang
      Lyra.config.strict_data_access = true
      now = Time.current

      assert_raises(Lyra::StrictDataAccessViolation) do
        SdaArticle.insert_all!([{ title: "A", status: "draft", created_at: now, updated_at: now }])
      end
      assert_equal 0, SdaArticle.count
    end

    # ── Lyra off ──

    def test_with_lyra_disabled_a_delete_publishes_nothing
      article = SdaArticle.create!(title: "One", status: "draft")
      clear_event_store
      Lyra.config.mode = :disabled

      article.delete

      refute SdaArticle.exists?(article.id)
      assert_empty events_for(article)
    end

    # ── dependent: :nullify ──

    # A parent with no children: nothing to clear, nothing published, and
    # the parent is destroyed. With one, its key is cleared and recorded.
    def test_dependent_nullify_with_and_without_children
      lonely = SdaAuthor.create!(name: "Lone", email: "sda-lone@example.com")
      parent = SdaAuthor.create!(name: "Parent", email: "sda-parent@example.com")
      child = SdaArticle.create!(title: "Child", status: "draft", author_id: parent.id)
      clear_event_store

      lonely.destroy!
      assert_equal 0, Lyra.config.event_store.read.to_a.size
      refute SdaAuthor.exists?(lonely.id)

      parent.destroy!
      event = only_event(child)
      assert_equal({ "author_id" => [parent.id, nil] }, value(event.data, :changes))
      assert_nil child.reload.author_id
    end

    private

    def wipe
      Lyra.projection_write(lyra_internal) do
        SdaArticle.delete_all
        SdaAuthor.where("email LIKE 'sda-%'").delete_all
      end
      clear_event_store
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
