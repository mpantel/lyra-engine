# frozen_string_literal: true

require "test_helper"

# A model's default scope under ES-NoProj (event sourcing, projections
# disabled), where reads are rebuilt from the event log. Active Record applies
# the default scope to every read of a table: Model.all, where, find, the
# association readers. ES-NoProj reads used to leave it out, so soft-deleted
# records (default_scope { where(deleted_at: nil) }, as paranoia, discard and
# Solidus use) came back. Model.unscoped read the table, which ES-NoProj
# leaves empty.
#
# One table of expectations, run in Monitor (the table is the store, Active
# Record answers) and in ES-NoProj: the two must agree.
class EsNoprojDefaultScopeTest < Minitest::Test
  MODELS = %i[DsBook DsOrderedBook DsPlainBook DsSqlBook DsGuardedBook DsAuthor DsReview].freeze

  BOOK_TABLES = %i[lyra_ds_books lyra_ds_ordered_books lyra_ds_plain_books lyra_ds_sql_books lyra_ds_guarded_books].freeze

  Seed = Struct.new(:author, :gone, :live, :later, :plain, :review_of_gone, :review_of_live, keyword_init: true)

  def not_found
    yield
    :found
  rescue ActiveRecord::RecordNotFound
    :not_found
  end

  # [what is read, what Active Record answers]; ids and titles, so that both
  # modes compare the same values.
  EXPECTATIONS = {
    all: [->(_) { DsBook.all.map(&:id).sort }, ->(s) { [s.live, s.later].sort }],
    where_on_a_foreign_key: [->(s) { DsBook.where(ds_author_id: s.author).map(&:id).sort }, ->(s) { [s.live, s.later].sort }],
    where_on_a_column: [->(_) { DsBook.where(title: %w[Gone Live]).map(&:id) }, ->(s) { [s.live] }],
    count: [->(_) { DsBook.count }, ->(_) { 2 }],
    where_count: [->(s) { DsBook.where(ds_author_id: s.author).count }, ->(_) { 2 }],
    pluck: [->(_) { DsBook.pluck(:title).sort }, ->(_) { %w[Later Live] }],
    exists_soft_deleted_id: [->(s) { DsBook.exists?(s.gone) }, ->(_) { false }],
    exists_live_id: [->(s) { DsBook.exists?(s.live) }, ->(_) { true }],
    exists_conditions: [->(_) { DsBook.exists?(title: "Gone") }, ->(_) { false }],
    first: [->(_) { DsBook.first.id }, ->(s) { [s.live, s.later].min }],
    last: [->(_) { DsBook.last.id }, ->(s) { [s.live, s.later].max }],
    find_soft_deleted: [->(s) { not_found { DsBook.find(s.gone) } }, ->(_) { :not_found }],
    find_live: [->(s) { DsBook.find(s.live).id }, ->(s) { s.live }],
    find_by_id_soft_deleted: [->(s) { DsBook.find_by(id: s.gone) }, ->(_) { nil }],
    find_by_column_soft_deleted: [->(_) { DsBook.find_by(title: "Gone") }, ->(_) { nil }],
    find_by_bang_soft_deleted: [->(_) { not_found { DsBook.find_by!(title: "Gone") } }, ->(_) { :not_found }],
    find_by_live: [->(_) { DsBook.find_by(title: "Live")&.id }, ->(s) { s.live }],
    named_scope: [->(_) { DsBook.titled("Gone").map(&:id) }, ->(_) { [] }],
    named_scope_on_a_relation: [->(s) { DsBook.where(ds_author_id: s.author).titled("Gone").map(&:id) }, ->(_) { [] }],
    scope_that_unscopes: [->(_) { DsBook.with_deleted.map(&:id).sort }, ->(s) { [s.gone, s.live, s.later].sort }],
    scope_that_unscopes_then_where: [->(_) { DsBook.with_deleted.where(title: "Gone").map(&:id) }, ->(s) { [s.gone] }],
    scope_that_unscopes_then_find: [->(s) { DsBook.with_deleted.find(s.gone).id }, ->(s) { s.gone }],
    where_then_scope_that_unscopes: [->(_) { DsBook.where(title: "Gone").with_deleted.map(&:id) }, ->(s) { [s.gone] }],
    foreign_key_where_then_scope_that_unscopes: [->(s) { DsBook.where(ds_author_id: s.author).with_deleted.count }, ->(_) { 3 }],
    unscope_after_a_where: [->(_) { DsBook.where(title: "Gone").unscope(where: :deleted_at).count }, ->(_) { 1 }],
    has_many_then_scope_that_unscopes: [->(s) { DsAuthor.find(s.author).ds_books.with_deleted.count }, ->(_) { 3 }],
    unscoped: [->(_) { DsBook.unscoped.map(&:id).sort }, ->(s) { [s.gone, s.live, s.later].sort }],
    unscoped_where: [->(_) { DsBook.unscoped.where(title: "Gone").count }, ->(_) { 1 }],
    unscoped_find_by: [->(_) { DsBook.unscoped.find_by(title: "Gone")&.id }, ->(s) { s.gone }],
    unscoped_find: [->(s) { DsBook.unscoped.find(s.gone).id }, ->(s) { s.gone }],
    unscoped_block_where: [->(_) { DsBook.unscoped { DsBook.where(title: "Gone").map(&:id) } }, ->(s) { [s.gone] }],
    unscoped_block_count: [->(_) { DsBook.unscoped { DsBook.count } }, ->(_) { 3 }],
    unscoped_block_find: [->(s) { DsBook.unscoped { DsBook.find(s.gone).id } }, ->(s) { s.gone }],
    unscoped_block_find_by: [->(_) { DsBook.unscoped { DsBook.find_by(title: "Gone")&.id } }, ->(s) { s.gone }],
    unscoped_block_exists: [->(s) { DsBook.unscoped { DsBook.exists?(s.gone) } }, ->(_) { true }],
    default_scope_back_after_the_block: [->(_) { DsBook.unscoped { DsBook.count } && DsBook.count }, ->(_) { 2 }],
    reload_of_a_soft_deleted_record: [->(s) { DsBook.unscoped.find(s.gone).reload.title }, ->(_) { "Gone" }],
    belongs_to_soft_deleted: [->(s) { DsReview.find(s.review_of_gone).ds_book }, ->(_) { nil }],
    belongs_to_live: [->(s) { DsReview.find(s.review_of_live).ds_book&.id }, ->(s) { s.live }],
    belongs_to_that_unscopes: [->(s) { DsReview.find(s.review_of_gone).any_ds_book&.id }, ->(s) { s.gone }],
    has_one: [->(s) { DsAuthor.find(s.author).ds_book&.id }, ->(s) { s.live }],
    has_many: [->(s) { DsAuthor.find(s.author).ds_books.map(&:id).sort }, ->(s) { [s.live, s.later].sort }],
    has_many_count: [->(s) { DsAuthor.find(s.author).ds_books.count }, ->(_) { 2 }],
    has_many_size: [->(s) { DsAuthor.find(s.author).ds_books.size }, ->(_) { 2 }],
    has_many_pluck: [->(s) { DsAuthor.find(s.author).ds_books.pluck(:title).sort }, ->(_) { %w[Later Live] }],
    has_many_where_exists: [->(s) { DsAuthor.find(s.author).ds_books.where(title: "Gone").exists? }, ->(_) { false }],
    has_many_that_unscopes: [->(s) { DsAuthor.find(s.author).every_ds_book.map(&:id).sort }, ->(s) { [s.gone, s.live, s.later].sort }],
    has_many_that_unscopes_count: [->(s) { DsAuthor.find(s.author).every_ds_book.count }, ->(_) { 3 }],
    ordered_all: [->(_) { DsOrderedBook.all.map(&:title) }, ->(_) { %w[Live Later] }],
    ordered_first: [->(_) { DsOrderedBook.first.title }, ->(_) { "Live" }],
    ordered_last: [->(_) { DsOrderedBook.last.title }, ->(_) { "Later" }],
    ordered_last_two: [->(_) { DsOrderedBook.last(2).map(&:title) }, ->(_) { %w[Live Later] }],
    ordered_then_order: [->(_) { DsOrderedBook.order(:title).map(&:title) }, ->(_) { %w[Live Later] }],
    ordered_then_reorder: [->(_) { DsOrderedBook.reorder(:title).map(&:title) }, ->(_) { %w[Later Live] }],
    ordered_where: [->(s) { DsOrderedBook.where(ds_author_id: s.author).map(&:title) }, ->(_) { %w[Live Later] }],
    ordered_has_many: [->(s) { DsAuthor.find(s.author).ds_ordered_books.map(&:title) }, ->(_) { %w[Live Later] }],
    no_default_scope_all: [->(_) { DsPlainBook.count }, ->(_) { 3 }],
    no_default_scope_find: [->(s) { DsPlainBook.find(s.plain[:gone]).id }, ->(s) { s.plain[:gone] }],
    no_default_scope_find_by: [->(_) { DsPlainBook.find_by(title: "Gone")&.title }, ->(_) { "Gone" }],
    no_default_scope_where: [->(s) { DsPlainBook.where(ds_author_id: s.author).count }, ->(_) { 3 }],
    no_default_scope_first: [->(_) { DsPlainBook.first.title }, ->(_) { "Gone" }],
    # Conditions and orders keep what unscope and rewhere need.
    order_then_scope_that_unscopes: [->(_) { DsBook.order(:title).with_deleted.map(&:title) }, ->(_) { %w[Gone Later Live] }],
    two_wheres_then_scope_that_unscopes: [->(s) { DsBook.where(title: "Gone").where(ds_author_id: s.author).with_deleted.count }, ->(_) { 1 }],
    has_many_where_then_scope_that_unscopes: [->(s) { DsAuthor.find(s.author).ds_books.where(title: "Gone").with_deleted.count }, ->(_) { 1 }],
    rewhere_the_default_scope: [->(s) { DsBook.rewhere(deleted_at: DsBook.unscoped.find(s.gone).deleted_at).pluck(:title) }, ->(_) { ["Gone"] }],
    rewhere_a_condition: [->(_) { DsBook.where(title: "Live").rewhere(title: "Later").pluck(:title) }, ->(_) { ["Later"] }],
    unscope_where_entirely: [->(_) { DsBook.where(title: "Live").unscope(:where).count }, ->(_) { 3 }],
    # merge evaluates the other relation instead of ignoring it.
    merge: [->(_) { DsBook.all.merge(DsBook.where(title: "Live")).pluck(:title) }, ->(_) { ["Live"] }],
    merge_then_delete_all: [->(_) { [DsBook.unscoped.merge(DsBook.unscoped.where(title: "Gone")).delete_all, book_state] },
                            ->(_) { [1, [%w[Later live 1], %w[Live live 3]]] }],
    merge_bang_then_update_all: [->(_) { r = DsBook.unscoped; r.merge!(DsBook.where(title: "Live")); [r.update_all(position: 9), book_state] },
                                 ->(_) { [1, [%w[Gone gone 2], %w[Later live 1], %w[Live live 9]]] }],
    where_bang: [->(_) { r = DsBook.unscoped; r.where!(title: "Gone"); r.count }, ->(_) { 1 }],
    # Writes and creates through a relation act on its records and take its conditions.
    where_update: [->(_) { [DsBook.where(title: "Live").update(position: 7).size, book_state] },
                   ->(_) { [1, [%w[Gone gone 2], %w[Later live 1], %w[Live live 7]]] }],
    unscoped_where_update: [->(_) { [DsBook.unscoped.where(title: "Gone").update(position: 7).size, book_state] },
                            ->(_) { [1, [%w[Gone gone 7], %w[Later live 1], %w[Live live 3]]] }],
    unscoped_where_update_counters: [->(_) { [DsBook.unscoped.where(title: "Gone").update_counters(position: 10), book_state] },
                                     ->(_) { [1, [%w[Gone gone 12], %w[Later live 1], %w[Live live 3]]] }],
    where_update_counters: [->(_) { [DsBook.where(title: %w[Gone Live]).update_counters(position: -1), book_state] },
                            ->(_) { [1, [%w[Gone gone 2], %w[Later live 1], %w[Live live 2]]] }],
    class_method_on_a_relation: [->(_) { DsBook.where(title: "Live").move_to(50); book_state },
                                 ->(_) { [%w[Gone gone 2], %w[Later live 1], %w[Live live 50]] }],
    create_or_find_by_creates_with_the_conditions: [->(_) { [DsBook.unscoped.where(position: 4).create_or_find_by!(title: "New").position, book_state.size] },
                                                    ->(_) { [4, 4] }],
    create_or_find_by_without_a_unique_index_creates: [->(s) { [DsBook.unscoped.create_or_find_by!(title: "Gone").id == s.gone, book_state.size] },
                                                       ->(_) { [false, 4] }],
    first_or_create_finds: [->(_) { [DsBook.unscoped.where(title: "Gone").first_or_create!.title, book_state.size] }, ->(_) { ["Gone", 3] }],
    first_or_create_creates_with_the_conditions: [->(_) { DsBook.where(title: "New").first_or_create!.title }, ->(_) { "New" }],
    first_or_initialize: [->(_) { DsBook.unscoped.where(title: "Gone").first_or_initialize.new_record? }, ->(_) { false }],
    create_with: [->(_) { DsBook.unscoped.create_with(position: 5).find_or_create_by!(title: "New").position }, ->(_) { 5 }],
    lock_find: [->(s) { DsBook.unscoped.lock.find(s.gone).title }, ->(_) { "Gone" }],
    sole: [->(_) { DsBook.where(title: "Live").sole.title }, ->(_) { "Live" }],
    sole_of_a_soft_deleted_record: [->(_) { not_found { DsBook.where(title: "Gone").sole } }, ->(_) { :not_found }],
    find_sole_by: [->(_) { DsBook.find_sole_by(title: "Live").title }, ->(_) { "Live" }],
    exists_with_an_sql_condition: [->(_) { DsBook.exists?(["title = ?", "Gone"]) }, ->(_) { false }],
    # An association scope that decides at run time is evaluated on each read.
    has_many_with_a_run_time_scope: [->(s) { [false, true, false].map { |admin| as_admin(admin) { DsAuthor.find(s.author).ds_books_for_admins.count } } },
                                     ->(_) { [2, 3, 2] }],
    belongs_to_with_a_run_time_scope: [->(s) { [false, true, false].map { |admin| as_admin(admin) { DsReview.find(s.review_of_gone).ds_book_for_admins&.title } } },
                                       ->(_) { [nil, "Gone", nil] }],
    # A model that overrides unscoped (def self.unscoped = super) still
    # validates uniqueness through ActiveRecord's own relation.
    unscoped_override_find: [->(s) { DsGuardedBook.unscoped.find_by(title: "Gone")&.title }, ->(_) { "Gone" }],
    unscoped_override_where: [->(_) { DsGuardedBook.where(title: %w[Gone Live]).pluck(:title) }, ->(_) { ["Live"] }]
  }.freeze

  def setup
    skip "Requires Rails and database" unless defined?(ActiveRecord::Base) && ActiveRecord::Base.connection.table_exists?(:users)

    create_tables
    MODELS.each { |c| Object.send(:remove_const, c) if Object.const_defined?(c) }
    define_models
    clean
    Rails.cache.clear
    MODELS.each { |name| Lyra.config.monitor_model(Object.const_get(name)) }
  end

  def teardown
    return unless defined?(DsBook)

    Lyra.config.enable_monitor!
    Lyra.config.projection_mode = :sync
    clean
    Rails.cache.clear
    # A model ES-NoProj refuses stays out of the registry the mode gate reads.
    Lyra.config.monitored_models.reject! { |model| (model.name rescue nil) == "DsSqlBook" }
    drop_tables
  end

  %i[monitor es_noproj].each do |mode|
    EXPECTATIONS.each do |name, (read, expected)|
      define_method(:"test_#{name}_in_#{mode}") do
        s = seed(mode)
        want = expected.call(s)
        got = instance_exec(s, &read)
        want.nil? ? assert_nil(got) : assert_equal(want, got)
      end
    end
  end

  # The records come from the event store, not the table, in ES-NoProj: the
  # table has no row, and unscoped still finds every record.
  def test_unscoped_reads_the_event_store_in_es_noproj
    s = seed(:es_noproj)

    assert_equal 0, Lyra::ModeTransition.send(:bypass) { DsBook.unscoped.count }
    assert_equal [s.gone, s.live, s.later].sort, DsBook.unscoped.map(&:id).sort
    assert_kind_of Lyra::Projections::CachedRelation, DsBook.unscoped
  end

  # An unscope after a limit is taken off the relation the limit was taken
  # from, as Active Record applies the limit after the conditions: the
  # records the default scope took out come back (it was refused).
  def test_unscope_of_the_default_scope_after_a_limit_in_es_noproj
    seed(:es_noproj)

    assert_equal 3, DsBook.with_deleted.limit(5).count
    assert_equal 3, DsBook.limit(5).with_deleted.to_a.size
    assert_equal 2, DsBook.limit(2).with_deleted.count
  end

  # A where.not continues the plan: the default scope is taken off after
  # it as Active Record takes it off (it was refused).
  def test_unscope_of_the_default_scope_after_a_where_not_in_es_noproj
    seed(:es_noproj)

    assert_equal 3, DsBook.where.not(title: "x").with_deleted.to_a.size
    assert_equal 2, DsBook.where.not(title: "Live").with_deleted.count
  end

  # After an SQL fragment the relation has no plan to replay: an unscope
  # that would bring back what the default scope took out is refused rather
  # than answered short.
  def test_unscope_of_the_default_scope_after_an_sql_fragment_is_refused_in_es_noproj
    seed(:es_noproj)

    error = assert_raises(Lyra::Projections::UnsupportedQuery) { DsBook.where("title = ?", "Live").with_deleted.to_a }
    assert_match(/unscope/, error.message)
  end

  # What a relation read from the event store cannot do exactly is refused
  # before anything runs: there is no SQL, and Active Record's other
  # relation methods are not evaluated here.
  def test_what_a_relation_cannot_do_is_refused_before_it_runs_in_es_noproj
    seed(:es_noproj)
    before = book_state

    [-> { DsBook.unscoped.where(title: "Gone").to_sql }, -> { DsBook.where(title: "Live").regroup(:title) },
     -> { DsBook.where(title: "Live").invert_where }, -> { DsBook.unscoped.where!("title = 'Gone'") },
     -> { DsBook.all.merge(DsAuthor.where(name: "Ann")) }].each do |call|
      assert_raises(Lyra::Projections::UnsupportedQuery) { call.call }
    end
    assert_equal before, book_state
    # A limited relation merges as Active Record merges it: its limit.
    assert_equal DsBook.order(:id).limit(1).to_a, DsBook.order(:id).merge(DsBook.unscoped.limit(1)).to_a
  end

  # A find by primary key reads one record, whatever the default scope's
  # order (an ordered default scope used to build every record).
  def test_find_by_primary_key_with_an_ordered_default_scope_builds_one_record_in_es_noproj
    seed(:es_noproj)
    10.times { |i| DsOrderedBook.create!(title: "x#{i}", position: i) }
    id = DsOrderedBook.find_by(title: "Live").id
    gone = DsOrderedBook.unscoped.find_by(title: "Gone").id
    reader = Lyra::Projections::EventStoreReader
    original = reader.method(:build_instance)
    built = 0
    reader.define_singleton_method(:build_instance) do |*args, **kwargs|
      built += 1
      original.call(*args, **kwargs)
    end

    assert_equal "Live", DsOrderedBook.find_by(id: id).title
    assert_nil DsOrderedBook.find_by(id: gone)
    assert_operator built, :<=, 2
  ensure
    if original
      reader.singleton_class.send(:define_method, :build_instance, original.unbind)
      reader.singleton_class.send(:private, :build_instance)
    end
  end

  # A default scope ES-NoProj cannot evaluate (an SQL string) refuses every
  # read of the model rather than answer with the records it leaves out.
  def test_a_default_scope_es_noproj_cannot_evaluate_refuses_reads
    seed(:es_noproj)
    DsSqlBook.unscoped.find_by(title: "Gone") # unscoped needs no default scope

    [-> { DsSqlBook.count }, -> { DsSqlBook.where(title: "Live").to_a }, -> { DsSqlBook.find_by(title: "Live") },
     -> { DsAuthor.find(DsAuthor.first.id).ds_sql_books.to_a }].each do |read|
      error = assert_raises(Lyra::Projections::UnsupportedQuery) { read.call }
      assert_match(/default scope of DsSqlBook/, error.message)
    end
  end

  def test_a_default_scope_es_noproj_cannot_evaluate_reads_in_monitor
    seed(:monitor)

    assert_equal 2, DsSqlBook.count
  end

  # The switch into ES-NoProj names such a model up front.
  def test_the_switch_to_es_noproj_refuses_a_default_scope_it_cannot_evaluate
    Lyra.config.stubs(:monitored_models).returns([DsBook, DsSqlBook])
    Lyra.config.enable_monitor!

    error = assert_raises(Lyra::ModeTransition::Refused) do
      Lyra::ModeTransition.to!(:event_sourcing, projection_mode: :disabled)
    end
    assert_match(/DsSqlBook/, error.message)
    refute_match(/DsBook\b/, error.message)
    assert_equal "monitor", Lyra::ModeTransition.current
    assert_empty Lyra::Projections::DefaultScopes.unevaluable([DsBook, DsOrderedBook, DsPlainBook])
  end

  private

  def seed(mode)
    use(mode)
    author = DsAuthor.create!(name: "Ann")
    books = [DsBook, DsOrderedBook, DsPlainBook, DsSqlBook, DsGuardedBook].to_h { |klass| [klass, triple(klass, author)] }
    gone, live, later = books[DsBook].values_at(:gone, :live, :later)
    Seed.new(
      plain: books[DsPlainBook].transform_values(&:id),
      author: author.id, gone: gone.id, live: live.id, later: later.id,
      review_of_gone: DsReview.create!(body: "x", ds_book_id: gone.id).id,
      review_of_live: DsReview.create!(body: "y", ds_book_id: live.id).id
    )
  end

# Gone (soft-deleted), Live and Later of one author, with positions such
# that the default order (position desc) and the order by title differ.
def triple(klass, author)
  created = { gone: ["Gone", 2], live: ["Live", 3], later: ["Later", 1] }.transform_values do |(title, position)|
    klass.create!(title: title, ds_author_id: author.id, position: position)
  end
  created[:gone].update!(deleted_at: Time.current)
  created
end

  def use(mode)
    if mode == :es_noproj
      Lyra.config.enable_event_sourcing!
      Lyra.config.projection_mode = :disabled
    else
      Lyra.config.enable_monitor!
    end
  end

  def create_tables
    connection = ActiveRecord::Base.connection
    connection.create_table(:lyra_ds_authors, force: true) do |t|
      t.string :name
      t.timestamps
    end
    BOOK_TABLES.each do |table|
      connection.create_table(table, force: true) do |t|
        t.string :title
        t.integer :ds_author_id
        t.integer :position
        t.datetime :deleted_at
        t.timestamps
      end
    end
    connection.create_table(:lyra_ds_reviews, force: true) do |t|
      t.string :body
      t.integer :ds_book_id
      t.timestamps
    end
  end

  def drop_tables
    (%i[lyra_ds_reviews lyra_ds_authors] + BOOK_TABLES).each { ActiveRecord::Base.connection.drop_table(_1, if_exists: true) }
  end

  def define_models
    # One table each: ES-NoProj keeps a stream per model, so models sharing a
    # table would not share records there.
    book = lambda do |table, &body|
      Class.new(ActiveRecord::Base) do
        self.table_name = table.to_s
        include Lyra::Interceptors::CrudInterceptor
        monitor_with_lyra
        class_eval(&body) if body
      end
    end
    # Soft deletion, as paranoia and discard (Solidus's Spree::SoftDeletable) do it.
    Object.const_set(:DsBook, book.call(:lyra_ds_books) do
      default_scope { where(deleted_at: nil) }
      scope :titled, ->(title) { where(title: title) }
      scope :with_deleted, -> { unscope(where: :deleted_at) }
      def self.move_to(position) = update_all(position: position)
    end)
    Object.const_set(:DsOrderedBook, book.call(:lyra_ds_ordered_books) do
      default_scope { where(deleted_at: nil) }
      default_scope { order(position: :desc) }
    end)
    Object.const_set(:DsPlainBook, book.call(:lyra_ds_plain_books))
    # Overrides unscoped, as some gems and applications do.
    Object.const_set(:DsGuardedBook, book.call(:lyra_ds_guarded_books) do
      default_scope { where(deleted_at: nil) }
      validates :title, uniqueness: true
      def self.unscoped(&block) = super
    end)
    Object.const_set(:DsSqlBook, book.call(:lyra_ds_sql_books) { default_scope { where("deleted_at IS NULL") } })
    Object.const_set(:DsAuthor, Class.new(ActiveRecord::Base) do
      self.table_name = "lyra_ds_authors"
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
      has_many :ds_books
      has_many :every_ds_book, -> { unscope(where: :deleted_at) }, class_name: "DsBook"
      has_many :ds_ordered_books, foreign_key: :ds_author_id
      has_many :ds_sql_books, foreign_key: :ds_author_id
      has_one :ds_book
      has_many :ds_books_for_admins, -> { Thread.current[:ds_admin] ? unscope(where: :deleted_at) : all }, class_name: "DsBook"
    end)
    Object.const_set(:DsReview, Class.new(ActiveRecord::Base) do
      self.table_name = "lyra_ds_reviews"
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
      belongs_to :ds_book, optional: true
      belongs_to :any_ds_book, -> { with_deleted }, class_name: "DsBook", foreign_key: :ds_book_id, optional: true
      belongs_to :ds_book_for_admins, -> { Thread.current[:ds_admin] ? unscope(where: :deleted_at) : all },
                 class_name: "DsBook", foreign_key: :ds_book_id, optional: true
    end)
  end

  # Every DsBook as [title, live or gone, position], from the store the mode reads.
  def book_state
    DsBook.unscoped.map { |b| [b.title, b.deleted_at.nil? ? "live" : "gone", b.position.to_s] }.sort
  end

  def as_admin(admin)
    previous = Thread.current[:ds_admin]
    Thread.current[:ds_admin] = admin
    yield
  ensure
    Thread.current[:ds_admin] = previous
  end

  def clean
    conn = ActiveRecord::Base.connection
    (%w[lyra_ds_reviews lyra_ds_authors] + BOOK_TABLES.map(&:to_s)).each { conn.execute("DELETE FROM #{_1}") if conn.table_exists?(_1) }
    conn.execute("DELETE FROM event_store_events_in_streams")
    conn.execute("DELETE FROM event_store_events")
  end
end
