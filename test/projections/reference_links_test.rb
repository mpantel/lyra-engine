# frozen_string_literal: true

require "test_helper"

# ES-NoProj answers a lookup by foreign key from reference links in the event
# store (Lyra::Projections::ReferenceLinks) instead of building every record
# of the model. These tests check that the answer stays exact (moved and
# destroyed children, events from other modes) and that the full load is
# skipped.
class ReferenceLinksTest < Minitest::Test
  ReferenceLinks = Lyra::Projections::ReferenceLinks

  def setup
    skip "Requires Rails and database" unless defined?(ActiveRecord::Base) && ActiveRecord::Base.connection.table_exists?(:articles)

    %i[RlArticle RlAuthor].each { |c| Object.send(:remove_const, c) if Object.const_defined?(c) }
    Object.const_set(:RlAuthor, Class.new(ActiveRecord::Base) do
      self.table_name = "users"
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
      has_many :rl_articles, foreign_key: :author_id, class_name: "RlArticle", dependent: :nullify
    end)
    Object.const_set(:RlArticle, Class.new(ActiveRecord::Base) do
      self.table_name = "articles"
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
      belongs_to :author, class_name: "RlAuthor", optional: true
    end)

    clean
    Rails.cache.clear
    ReferenceLinks.reset!
    @reference_links = Lyra.config.reference_links
    Lyra.config.monitor_model(RlAuthor)
    Lyra.config.monitor_model(RlArticle)
    no_proj!
    @ann = RlAuthor.create!(name: "Ann", email: "ann@example.com")
    @bob = RlAuthor.create!(name: "Bob", email: "bob@example.com")
    @a1 = RlArticle.create!(title: "A1", body: "x", author_id: @ann.id)
    @a2 = RlArticle.create!(title: "A2", body: "x", author_id: @ann.id)
    @b1 = RlArticle.create!(title: "B1", body: "x", author_id: @bob.id)
  end

  def teardown
    return unless defined?(RlArticle)

    Lyra.config.reference_links = @reference_links
    Lyra.config.projection_mode = :sync
    ReferenceLinks.reset!
    clean
    Rails.cache.clear
  end

  def test_creates_are_linked_under_their_parent
    assert_equal [@a1.id, @a2.id].sort, linked_ids(@ann.id).sort
    assert_equal [@b1.id], linked_ids(@bob.id)
  end

  def test_a_foreign_key_lookup_does_not_build_every_record
    loads = count_full_loads { assert_equal %w[A1 A2], titles(RlAuthor.find(@ann.id).rl_articles) }
    assert_equal 0, loads
    assert_equal 2, RlAuthor.find(@ann.id).rl_articles.count
  end

  def test_a_moved_child_is_found_under_its_new_parent_only
    RlArticle.find(@a2.id).update!(author_id: @bob.id)

    assert_includes linked_ids(@ann.id), @a2.id, "links are append-only"
    assert_equal %w[A1], titles(RlAuthor.find(@ann.id).rl_articles)
    assert_equal %w[A2 B1], titles(RlAuthor.find(@bob.id).rl_articles)
  end

  def test_a_destroyed_child_is_not_found
    RlArticle.find(@a1.id).destroy!

    assert_equal %w[A2], titles(RlAuthor.find(@ann.id).rl_articles)
  end

  def test_a_dependent_nullify_finds_the_children_through_the_links
    loads = count_full_loads { RlAuthor.find(@ann.id).destroy! }

    assert_equal 0, loads
    assert_nil RlArticle.find(@a1.id).author_id
    assert_nil RlArticle.find(@a2.id).author_id
    assert_equal @bob.id, RlArticle.find(@b1.id).author_id
  end

  # Under :auto only ES-NoProj links. Events stored in another mode are
  # linked before the model's first lookup, and a checkpoint is stored.
  def test_events_from_another_mode_are_linked_on_first_use
    Lyra.config.projection_mode = :sync
    a3 = RlArticle.create!(title: "A3", body: "x", author_id: @ann.id)
    refute_includes linked_ids(@ann.id), a3.id

    no_proj!
    ReferenceLinks.reset!
    assert_equal %w[A1 A2 A3], titles(RlAuthor.find(@ann.id).rl_articles)
    assert_includes linked_ids(@ann.id), a3.id
    refute_empty Lyra.config.event_store.read.stream("#{ReferenceLinks::CHECKPOINT_PREFIX}RlArticle").to_a
  end

  # The switch into ES-NoProj links what earlier modes stored, so the
  # index is complete before the first lookup.
  def test_the_switch_into_es_noproj_links_earlier_events
    Lyra.config.projection_mode = :sync
    a3 = RlArticle.create!(title: "A3", body: "x", author_id: @ann.id)
    ReferenceLinks.reset!

    Lyra::ModeTransition.to!(:event_sourcing, projection_mode: :disabled)

    assert_includes linked_ids(@ann.id), a3.id
    assert_equal 0, ReferenceLinks.catch_up(RlArticle), "the model is taken for linked in this process"
  end

  # A model already linked in this process falls behind when an event is
  # stored while linking is off; the next lookup catches it up.
  def test_an_append_with_linking_off_is_caught_up_before_the_next_lookup
    titles(RlAuthor.find(@ann.id).rl_articles)
    Lyra.config.reference_links = false
    a3 = RlArticle.create!(title: "A3", body: "x", author_id: @ann.id)
    Lyra.config.reference_links = :auto

    assert_equal %w[A1 A2 A3], titles(RlAuthor.find(@ann.id).rl_articles)
    assert_includes linked_ids(@ann.id), a3.id
  end

  def test_with_links_off_lookups_load_every_record_and_still_answer
    Lyra.config.reference_links = false

    loads = count_full_loads { assert_equal %w[A1 A2], titles(RlAuthor.find(@ann.id).rl_articles) }
    assert_operator loads, :>, 0
  end

  def test_monitor_mode_writes_no_links
    clean
    ReferenceLinks.reset!
    Lyra.config.disable_event_sourcing! if Lyra.config.respond_to?(:disable_event_sourcing!)
    Lyra.configure { |c| c.mode = :monitor }
    author = RlAuthor.create!(name: "Cy", email: "cy@example.com")
    RlArticle.create!(title: "C1", body: "x", author_id: author.id)

    assert_empty linked_ids(author.id)
  end

  private

  def no_proj!
    Lyra.configure do |c|
      c.mode = :event_sourcing
      c.projection_mode = :disabled
    end
  end

  def linked_ids(author_id)
    stream = ReferenceLinks.stream_name(RlArticle, "author_id", author_id)
    Lyra.config.event_store.read.stream(stream).to_a.map { |e| (e.data[:model_id] || e.data["model_id"]).to_i }
  end

  def titles(relation)
    relation.to_a.map(&:title).sort
  end

  def count_full_loads
    calls = 0
    singleton = Lyra::Projections::CachedProjection.singleton_class
    original = singleton.instance_method(:all)
    singleton.define_method(:all) do |model_class|
      calls += 1 if model_class == RlArticle
      original.bind_call(self, model_class)
    end
    yield
    calls
  ensure
    singleton.define_method(:all, original)
  end

  def clean
    conn = ActiveRecord::Base.connection
    conn.execute("DELETE FROM articles")
    conn.execute("DELETE FROM users")
    conn.execute("DELETE FROM event_store_events_in_streams")
    conn.execute("DELETE FROM event_store_events")
  end
end
