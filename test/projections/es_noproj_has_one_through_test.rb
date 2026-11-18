# frozen_string_literal: true

require "test_helper"

# A has_one :through under ES-NoProj. Its foreign key is on the intermediate
# record, as in Solidus's InventoryUnit has_one :order, through: :shipment
# (shipments.order_id), which Carton has_many :orders, through:
# :inventory_units reads for the shipped email. It was looked for on the
# target, as Spree::Order.find_by(order_id: <the unit's id>): 0.9.x answered
# nil, so no shipped email was sent.
#
# The same shape on the dummy tables: an EnHotNote (articles) belongs_to
# its parent EnHotArticle through author_id, the article belongs_to its
# EnHotAuthor (users), and the note has_one :author through the article.
# A polymorphic source with source_type: uses an EnHotLink (articles) whose
# author_id and status name the linked record and its class; an author's
# links are those whose title is the author's name.
class EsNoprojHasOneThroughTest < Minitest::Test
  CLASSES = %i[EnHotAuthor EnHotArticle EnHotPlainArticle EnHotNote EnHotLink].freeze

  def setup
    skip "Requires Rails and database" unless defined?(ActiveRecord::Base) && ActiveRecord::Base.connection.table_exists?(:articles)

    CLASSES.each { |c| Object.send(:remove_const, c) if Object.const_defined?(c) }
    Object.const_set(:EnHotAuthor, Class.new(ActiveRecord::Base) do
      self.table_name = "users"
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
      has_many :links, class_name: "EnHotLink", foreign_key: :title, primary_key: :name
      has_many :linked_authors, through: :links, source: :thing, source_type: "EnHotAuthor"
      has_one :first_link, class_name: "EnHotLink", foreign_key: :title, primary_key: :name
      has_one :linked_author, through: :first_link, source: :thing, source_type: "EnHotAuthor"
    end)
    Object.const_set(:EnHotArticle, Class.new(ActiveRecord::Base) do
      self.table_name = "articles"
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
      belongs_to :author, class_name: "EnHotAuthor", optional: true
      has_many :notes, class_name: "EnHotNote", foreign_key: :author_id, inverse_of: :article
      # Carton has_many :orders, through: :inventory_units: the source is itself
      # a has_one :through.
      has_many :note_authors, -> { distinct }, through: :notes, source: :author
    end)
    # Not monitored: its rows are in the table, read with SQL.
    Object.const_set(:EnHotPlainArticle, Class.new(ActiveRecord::Base) do
      self.table_name = "articles"
      belongs_to :author, class_name: "EnHotAuthor", optional: true
    end)
    Object.const_set(:EnHotNote, Class.new(ActiveRecord::Base) do
      self.table_name = "articles"
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
      belongs_to :article, class_name: "EnHotArticle", foreign_key: :author_id, optional: true, inverse_of: :notes
      belongs_to :plain_article, class_name: "EnHotPlainArticle", foreign_key: :author_id, optional: true
      has_one :author, through: :article
      has_one :published_author, -> { where.not(name: "Bob") }, through: :article, source: :author
      has_one :namesake_author, ->(note) { where(name: note.title) }, through: :article, source: :author
      has_one :sql_author, -> { where("EXISTS (SELECT 1 FROM articles WHERE articles.author_id = users.id)") },
              through: :article, source: :author
      has_one :plain_author, through: :plain_article, source: :author
    end)
    Object.const_set(:EnHotLink, Class.new(ActiveRecord::Base) do
      self.table_name = "articles"
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
      belongs_to :thing, polymorphic: true, foreign_key: :author_id, foreign_type: :status, optional: true
    end)

    clean
    Rails.cache.clear
    [EnHotAuthor, EnHotArticle, EnHotNote, EnHotLink].each { Lyra.config.monitor_model(_1) }
    Lyra.config.enable_event_sourcing!
    Lyra.config.projection_mode = :disabled
    @ann = EnHotAuthor.create!(name: "Ann", email: "ann@example.com")
    @bob = EnHotAuthor.create!(name: "Bob", email: "bob@example.com")
    @cat = EnHotAuthor.create!(name: "Cat", email: "cat@example.com")
    @ann_article = EnHotArticle.create!(title: "A1", body: "x", author_id: @ann.id)
    @bob_article = EnHotArticle.create!(title: "B1", body: "x", author_id: @bob.id)
    @orphan_article = EnHotArticle.create!(title: "O1", body: "x")
    @ann_notes = Array.new(2) { |i| EnHotNote.create!(title: "N#{i}", body: "x", author_id: @ann_article.id) }
    @bob_note = EnHotNote.create!(title: "NB", body: "x", author_id: @bob_article.id)
    @orphan_note = EnHotNote.create!(title: "NO", body: "x", author_id: @orphan_article.id)
  end

  def teardown
    return unless defined?(EnHotNote)

    Lyra.config.projection_mode = :sync
    clean
    Rails.cache.clear
  end

  def test_a_has_one_through_reads_through_the_intermediate_record
    assert_equal @ann.id, EnHotNote.find(@ann_notes.first.id).author.id
    assert_equal @bob.id, EnHotNote.find(@bob_note.id).author.id
  end

  def test_a_has_one_through_with_no_target_is_nil
    assert_nil EnHotNote.find(@orphan_note.id).author
    assert_nil EnHotNote.new(title: "NX", body: "x").author
  end

  def test_a_has_one_through_applies_its_scope
    assert_equal @ann.id, EnHotNote.find(@ann_notes.first.id).published_author.id
    assert_nil EnHotNote.find(@bob_note.id).published_author
  end

  def test_a_scope_taking_the_owner_is_given_the_owner
    namesake = EnHotNote.create!(title: "Ann", body: "x", author_id: @ann_article.id)

    assert_equal @ann.id, EnHotNote.find(namesake.id).namesake_author.id
    assert_nil EnHotNote.find(@ann_notes.first.id).namesake_author
  end

  # An SQL fragment (here naming another table) cannot be evaluated on the
  # records rebuilt from events: refused, not answered without it.
  def test_a_scope_the_event_store_cannot_evaluate_is_refused
    assert_raises(Lyra::Projections::UnsupportedQuery) { EnHotNote.find(@ann_notes.first.id).sql_author }
  end

  def test_an_unmonitored_intermediate_record_is_read_from_its_table
    plain = EnHotPlainArticle.create!(title: "P1", body: "x", author_id: @bob.id)
    note = EnHotNote.create!(title: "NP", body: "x", author_id: plain.id)

    assert_equal @bob.id, EnHotNote.find(note.id).plain_author.id
  end

  # source_type: only an intermediate record whose type column names that
  # class leads to the target, as Active Record's join selects; the source
  # reader alone returned the record of whatever class the column named.
  def test_a_has_one_through_follows_only_the_source_type
    EnHotLink.create!(title: "Cat", body: "x", author_id: @ann.id, status: "EnHotAuthor")
    EnHotLink.create!(title: "Bob", body: "x", author_id: @bob_article.id, status: "EnHotArticle")

    assert_equal @ann.id, EnHotAuthor.find(@cat.id).linked_author.id
    assert_nil EnHotAuthor.find(@bob.id).linked_author
  end

  def test_a_has_many_through_follows_only_the_source_type
    EnHotLink.create!(title: "Ann", body: "x", author_id: @bob.id, status: "EnHotAuthor")
    EnHotLink.create!(title: "Ann", body: "x", author_id: @ann_article.id, status: "EnHotArticle")
    EnHotLink.create!(title: "Bob", body: "x", author_id: @bob_article.id, status: "EnHotArticle")

    assert_equal [@bob.id], EnHotAuthor.find(@ann.id).linked_authors.map(&:id)
    assert_empty EnHotAuthor.find(@bob.id).linked_authors.to_a
  end

  # carton.orders: a has_many :through whose source is a has_one :through.
  def test_a_has_many_through_a_has_one_through
    assert_equal [@ann.id], EnHotArticle.find(@ann_article.id).note_authors.map(&:id)
    assert_empty EnHotArticle.find(@orphan_article.id).note_authors.to_a
  end

  private

  def clean
    conn = ActiveRecord::Base.connection
    conn.execute("DELETE FROM articles")
    conn.execute("DELETE FROM users")
    conn.execute("DELETE FROM event_store_events_in_streams")
    conn.execute("DELETE FROM event_store_events")
  end
end
