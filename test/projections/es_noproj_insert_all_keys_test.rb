# frozen_string_literal: true

require "test_helper"

# insert_all and insert_all! with explicit primary keys, in ES-NoProj and in
# Monitor, where the table is the store. Monitor inserts a row for the key of
# a record destroyed before, and its log goes on with a Created after the
# Destroyed; it skips (insert_all) or refuses (insert_all!) the key of a
# record that exists. ES-NoProj must do the same, with the event store saying
# which records exist: its table answered before, so a record created through
# callbacks (no row there) was inserted again, a second Created on a live
# stream, and a record inserted with insert_all and then destroyed kept its
# row, which made the next insert of its key skip, with no event.
#
# A stream [created, destroyed, created] reads as the record created last:
# by find, by a query, by StreamTail, and to the writes that follow.
class EsNoprojInsertAllKeysTest < Minitest::Test
  MODES = %i[monitor es_noproj].freeze

  def setup
    skip "Requires Rails and database" unless defined?(ActiveRecord::Base) && connection.table_exists?(:articles)

    Object.send(:remove_const, :IkArticle) if Object.const_defined?(:IkArticle)
    Object.const_set(:IkArticle, Class.new(ActiveRecord::Base) do
      self.table_name = "articles"
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
    end)
    Lyra.config.monitor_model(IkArticle)
    Object.send(:remove_const, :IkUser) if Object.const_defined?(:IkUser)
    Object.const_set(:IkUser, Class.new(ActiveRecord::Base) do
      self.table_name = "users"
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
    end)
    Lyra.config.monitor_model(IkUser)
    clean
  end

  def teardown
    return unless defined?(IkArticle)

    Lyra.config.enable_monitor!
    Lyra.config.projection_mode = :sync
    clean
  end

  def test_a_destroyed_record_inserted_again_reads_as_created_last
    states = MODES.map do |mode|
      scenario(mode) do
        article = IkArticle.create!(title: "Old", body: "old body", status: "draft")
        id = article.id
        IkArticle.find(id)
        IkArticle.where(status: "draft").to_a # read (and cached) before
        article.destroy!
        assert_nil IkArticle.find_by(id: id)

        result = IkArticle.insert_all([row(id, "New", "published")])

        assert_equal [id], result.rows.flatten
        assert_equal %w[created destroyed created], operations(id)
        refute Lyra::StreamTail.destroyed?(Lyra.stream_name(IkArticle, id))
        record = IkArticle.find(id)
        assert_equal ["New", nil, "published"], [record.title, record.body, record.status], "nothing of the first record"
        assert_equal [id], IkArticle.where(status: "published").pluck(:id)
        assert_equal 0, IkArticle.where(status: "draft").count
        assert_equal 1, IkArticle.count

        # The writes that follow find the record live.
        record.update!(title: "Newer")
        IkArticle.find(id).update_columns(status: "archived")
        assert_equal %w[Newer archived], IkArticle.find(id).then { [_1.title, _1.status] }
        IkArticle.find(id).destroy!
        assert_nil IkArticle.find_by(id: id)
        operations(id)
      end
    end
    assert_equal %w[created destroyed created updated updated destroyed], states.first
    assert_equal states.first, states.last
  end

  def test_a_key_inserted_destroyed_and_inserted_again_is_created_again
    states = MODES.map do |mode|
      scenario(mode) do
        IkArticle.insert_all([row(900, "A", "draft")])
        IkArticle.find(900).destroy!

        result = IkArticle.insert_all([row(900, "B", "draft")])

        assert_equal [900], result.rows.flatten
        assert_equal "B", IkArticle.find(900).title
        IkArticle.where(id: 900).delete_all
        IkArticle.insert_all!([row(900, "C", "draft")])
        [IkArticle.find(900).title, operations(900)]
      end
    end
    assert_equal ["C", %w[created destroyed created destroyed created]], states.first
    assert_equal states.first, states.last
  end

  def test_the_key_of_a_live_record_is_skipped_or_refused
    states = MODES.map do |mode|
      scenario(mode) do
        article = IkArticle.create!(title: "Live", status: "draft")
        events = event_count

        result = IkArticle.insert_all([row(article.id, "Dup", "published"), row(901, "Other", "draft")])

        assert_equal [901], result.rows.flatten, "the live record's row skipped, the other inserted"
        assert_raises(ActiveRecord::RecordNotUnique) { IkArticle.insert_all!([row(902, "X", "draft"), row(article.id, "Dup", "draft")]) }
        assert_nil IkArticle.find_by(id: 902), "insert_all! wrote nothing"
        assert_equal events + 1, event_count, "one Created, for 901"
        [IkArticle.find(article.id).title, operations(article.id), IkArticle.order(:id).pluck(:title)]
      end
    end
    assert_equal ["Live", %w[created], %w[Live Other]], states.first.then { [_1[0], _1[1], _1[2].sort] }
    assert_equal states.first, states.last
  end

  # With unique_by another index (users' email), ON CONFLICT does not cover
  # the primary key: Monitor's insert of a live record's key raises
  # RecordNotUnique, and so does ES-NoProj's, before writing anything.
  def test_a_live_key_outside_the_conflict_target_is_refused
    states = MODES.map do |mode|
      scenario(mode) do
        user = IkUser.create!(name: "Ann", email: "ann-ik@example.com")
        fresh = user.id + 1_000_000 # a key no record has (a fixed one can meet the sequence)
        events = event_count

        assert_raises(ActiveRecord::RecordNotUnique) do
          IkUser.insert_all([{ id: fresh, name: "New", email: "new-ik@example.com" },
                             { id: user.id, name: "Dup", email: "dup-ik@example.com" }], unique_by: :index_users_on_email)
        end
        assert_equal events, event_count, "nothing recorded"
        assert_nil IkUser.find_by(id: fresh)
        IkUser.find(user.id).then { [_1.name, _1.email] }
      end
    end
    assert_equal ["Ann", "ann-ik@example.com"], states.first
    assert_equal states.first, states.last
  end

  private

  def scenario(mode)
    clean
    use(mode)
    yield
  ensure
    Lyra.config.enable_monitor!
    Lyra.config.projection_mode = :sync
  end

  def row(id, title, status)
    now = Time.current
    { id: id, title: title, status: status, created_at: now, updated_at: now }
  end

  def use(mode)
    if mode == :es_noproj
      Lyra.config.enable_event_sourcing!
      Lyra.config.projection_mode = :disabled
    else
      Lyra.config.enable_monitor!
      Lyra.config.projection_mode = :sync
    end
  end

  def operations(id)
    Lyra.config.event_store.read.stream(Lyra.stream_name(IkArticle, id)).to_a.map { (_1.data[:operation] || _1.data["operation"]).to_s }
  end

  def event_count = connection.select_value("SELECT COUNT(*) FROM event_store_events").to_i

  def connection = ActiveRecord::Base.connection

  def clean
    connection.execute("DELETE FROM articles")
    connection.execute("DELETE FROM users")
    connection.execute("DELETE FROM event_store_events_in_streams")
    connection.execute("DELETE FROM event_store_events")
    Lyra::Projections::CachedProjection.invalidate_all(IkArticle) if defined?(IkArticle)
    Rails.cache.clear
  end
end
