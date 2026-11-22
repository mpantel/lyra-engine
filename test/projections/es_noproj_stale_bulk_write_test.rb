# frozen_string_literal: true

require "test_helper"

# An ES-NoProj relation (CachedRelation), and each batch in_batches yields,
# holds the records it selected when it was built. A bulk write on it
# (update_all, delete_all, touch_all, destroy_all, update_counters) wrote
# every one of them, a record destroyed since included: it got an Updated
# event after its Destroyed and read as live again, so a stale relation could
# undo a delete or an erasure. Active Record's write reaches no row of it. The
# write now reads each record's stream under the aggregate lock and leaves a
# destroyed record out of the writes, the events and the count. Each case runs
# in Monitor (Active Record on PostgreSQL) and in ES-NoProj on the same rows.
class EsNoprojStaleBulkWriteTest < Minitest::Test
  TABLE = "lyra_sbw_items"
  ROWS = [
    { code: "a1", status: "active", qty: 1, tag: "x" },
    { code: "a2", status: "active", qty: 2, tag: nil },
    { code: "a3", status: "archived", qty: 3, tag: "y" },
    { code: "a4", status: "draft", qty: 4, tag: nil },
    { code: "a5", status: "archived", qty: 5, tag: "x" },
    { code: "a6", status: "active", qty: 6, tag: "z" },
    { code: "a7", status: "draft", qty: 7, tag: "x" }
  ].freeze
  PARENTS = "lyra_sbw_parents"
  MODES = %i[monitor es_noproj].freeze

  def setup
    skip "Requires Rails and PostgreSQL" unless defined?(ActiveRecord::Base) && connection.adapter_name.match?(/postgres/i)

    connection.create_table(TABLE, force: true) do |t|
      t.string :code
      t.string :status
      t.integer :qty
      t.string :tag
      t.integer :parent_id
      t.timestamps
    end
    Object.send(:remove_const, :SbwItem) if Object.const_defined?(:SbwItem)
    Object.const_set(:SbwItem, Class.new(ActiveRecord::Base) do
      self.table_name = TABLE
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
    end)
    SbwItem.reset_column_information
    Lyra.config.monitor_model(SbwItem)
    clean
  end

  def teardown
    return unless Object.const_defined?(:SbwItem)

    Lyra.reset_config!
    clean
    connection.drop_table(TABLE, if_exists: true)
  end

  # The relation selects a3 and a5; a5 is deleted after it was built (and,
  # when +loaded+, after it was loaded). +write+ runs on the relation; the
  # result is its return value, the records left and a3's and a5's streams.
  def stale(mode, loaded:, &write)
    clean
    use(mode)
    seed
    relation = SbwItem.where(status: "archived")
    relation.to_a if loaded
    SbwItem.where(code: "a5").delete_all
    result = write.call(relation)
    [result, state, operations("a3"), operations("a5")]
  end

  # The destroyed record is not written: no event in its stream after its
  # Destroyed, and it does not read as live. The live one is written as before.
  %i[loaded unloaded].each do |load|
    define_method("test_update_all_on_a_stale_relation_skips_the_destroyed_record_#{load}") do
      runs = MODES.map { |mode| stale(mode, loaded: load == :loaded) { |r| r.update_all(tag: "u") } }
      assert_equal runs.first, runs.last

      count, rows, a3, a5 = runs.last
      assert_equal 1, count, "Active Record counts only the row it wrote"
      refute_includes rows.map(&:first), "a5"
      assert_equal "u", rows.to_h { [_1[0], _1[3]] }["a3"]
      assert_equal %i[created updated], a3
      assert_equal %i[created destroyed], a5
    end

    define_method("test_delete_all_on_a_stale_relation_skips_the_destroyed_record_#{load}") do
      runs = MODES.map { |mode| stale(mode, loaded: load == :loaded, &:delete_all) }
      assert_equal runs.first, runs.last

      count, rows, a3, a5 = runs.last
      assert_equal 1, count
      assert_equal %w[a1 a2 a4 a6 a7], rows.map(&:first)
      assert_equal %i[created destroyed], a3
      assert_equal %i[created destroyed], a5, "a second Destroyed is a stream no replay can apply"
    end

    define_method("test_touch_all_on_a_stale_relation_skips_the_destroyed_record_#{load}") do
      runs = MODES.map { |mode| stale(mode, loaded: load == :loaded, &:touch_all) }
      assert_equal runs.first, runs.last

      count, rows, a3, a5 = runs.last
      assert_equal 1, count
      refute_includes rows.map(&:first), "a5"
      assert_equal %i[created updated], a3
      assert_equal %i[created destroyed], a5
    end

    define_method("test_update_counters_on_a_stale_relation_skips_the_destroyed_record_#{load}") do
      runs = MODES.map { |mode| stale(mode, loaded: load == :loaded) { |r| r.update_counters(qty: 10) } }
      assert_equal runs.first, runs.last

      count, rows, _a3, a5 = runs.last
      assert_equal 1, count
      assert_equal 13, rows.to_h { [_1[0], _1[2]] }["a3"]
      assert_equal %i[created destroyed], a5
    end
  end

  # destroy_all returns the records it destroyed: Active Record's, loading
  # the relation afresh, leaves the deleted record out. (Active Record's
  # destroy_all of a relation loaded before the delete runs destroy on the
  # stale copy too, which deletes no row; ES-NoProj, whose relation always
  # holds its records, leaves it out loaded or not.)
  def test_destroy_all_on_a_stale_relation_skips_the_destroyed_record
    runs = MODES.map { |mode| stale(mode, loaded: false) { |r| r.destroy_all.map(&:code) } }
    assert_equal runs.first, runs.last

    destroyed, rows, a3, a5 = runs.last
    assert_equal %w[a3], destroyed
    assert_equal %w[a1 a2 a4 a6 a7], rows.map(&:first)
    assert_equal %i[created destroyed], a3
    assert_equal %i[created destroyed], a5
  end

  def test_destroy_all_on_a_loaded_stale_relation_does_not_refuse_or_write_the_destroyed_record
    destroyed, rows, a3, a5 = stale(:es_noproj, loaded: true) { |r| r.destroy_all.map(&:code) }

    assert_equal %w[a3], destroyed, "it used to raise RecordDestroyedError on a5, after destroying a3"
    assert_equal %w[a1 a2 a4 a6 a7], rows.map(&:first)
    assert_equal %i[created destroyed], a3
    assert_equal %i[created destroyed], a5
  end

  # A destroy aborted by a callback rolls back as on its own, and its record
  # is returned, as Active Record's destroy_all returns it.
  def test_destroy_all_keeps_an_aborted_destroy_out_of_the_log
    SbwItem.class_eval { before_destroy { throw :abort if code == "a3" } }
    runs = MODES.map do |mode|
      clean
      use(mode)
      seed
      destroyed = SbwItem.where(status: "archived").destroy_all.map(&:code)
      [destroyed, state, operations("a3"), operations("a5")]
    end
    assert_equal runs.first, runs.last

    destroyed, rows, a3, a5 = runs.last
    assert_equal %w[a3 a5], destroyed
    assert_equal %w[a1 a2 a3 a4 a6 a7], rows.map(&:first)
    assert_equal %i[created], a3
    assert_equal %i[created destroyed], a5
  end

  # A record deleted while in_batches runs is not written back by a later
  # batch, which still holds it. (The batches themselves are those of the
  # records when the loop began, where Active Record queries each batch as it
  # comes: a4, a6, a7 are its second batch, ES-NoProj's second and third. So
  # the totals are compared, not each batch's.)
  def test_in_batches_update_all_skips_a_record_deleted_during_the_loop
    runs = MODES.map do |mode|
      clean
      use(mode)
      seed
      counts = []
      SbwItem.in_batches(of: 3) do |batch|
        counts << batch.update_all(tag: "u")
        SbwItem.where(code: "a5").delete_all if counts.size == 1
      end
      [counts.sum, state, operations("a5")]
    end
    assert_equal runs.first, runs.last

    count, rows, a5 = runs.last
    assert_equal 6, count
    assert_equal %w[a1 a2 a3 a4 a6 a7], rows.map(&:first)
    assert(rows.all? { _1[3] == "u" })
    assert_equal %i[created destroyed], a5
  end

  def test_in_batches_delete_all_and_destroy_all_skip_a_record_deleted_during_the_loop
    %i[delete_all destroy_all].each do |write|
      runs = MODES.map do |mode|
        clean
        use(mode)
        seed
        results = []
        SbwItem.in_batches(of: 3) do |batch|
          result = batch.public_send(write)
          results << (write == :destroy_all ? result.map(&:code) : result)
          SbwItem.where(code: "a5").delete_all if results.size == 1
        end
        [write == :destroy_all ? results.flatten : results.sum, state, operations("a5")]
      end
      assert_equal runs.first, runs.last, write

      result, rows, a5 = runs.last
      assert_equal(write == :destroy_all ? %w[a1 a2 a3 a4 a6 a7] : 6, result, write)
      assert_empty rows, write
      assert_equal %i[created destroyed], a5, write
    end
  end

  # The batch enumerator's own bulk writes (in_batches without a block).
  def test_batch_enumerator_update_all_skips_a_destroyed_record
    runs = MODES.map do |mode|
      clean
      use(mode)
      seed
      batches = SbwItem.where(status: "archived").in_batches(of: 1)
      SbwItem.where(code: "a5").delete_all
      [batches.update_all(tag: "u"), state, operations("a5")]
    end
    assert_equal runs.first, runs.last

    count, rows, a5 = runs.last
    assert_equal 1, count
    refute_includes rows.map(&:first), "a5"
    assert_equal %i[created destroyed], a5
  end

  # Records that are all live are written as before: one event each.
  def test_a_relation_with_no_destroyed_record_is_written_as_before
    use(:es_noproj)
    seed
    relation = SbwItem.where(status: "active")
    before = event_count

    assert_equal 3, relation.update_all(tag: "w")
    assert_equal before + 3, event_count
    assert_equal %w[w w w], SbwItem.where(status: "active").order(:code).pluck(:tag)
    assert_equal 3, relation.delete_all
    assert_equal before + 6, event_count
    assert_equal %w[a3 a4 a5 a7], state.map(&:first)
  end

  # What the check costs. A relation built again (Rebuildable): one lock
  # statement for the records it holds, then one read of its selection, and
  # no read of each stream (a destroyed record is not in the selection). A
  # relation of given records: one lock statement, then one read of the
  # records' streams (one query for all of them where each ends in a create
  # or an update). A destroy_all checks each record before its destroy, and
  # the destroy checks again (its before_destroy callbacks run in between):
  # two of each per record.
  def test_the_check_costs
    use(:es_noproj)
    seed
    relation = SbwItem.where(status: "active")
    assert_equal [1, 0, 1], count_queries { relation.update_all(tag: "q") }

    given = Lyra::Projections::CachedRelation.new(SbwItem, SbwItem.where(status: "active").to_a)
    assert_nil given.rebuild_recipe
    assert_equal [1, 1, 0], count_queries { given.update_all(tag: "r") }

    relation = SbwItem.where(status: "draft")
    locks, reads, = count_queries { relation.destroy_all }
    assert_equal [4, 4], [locks, reads], "two locks and two reads per destroyed record"

    relation = SbwItem.where(status: "active")
    assert_equal [1, 0, 1], count_queries { relation.update_counters(qty: 1) },
                 "the groups' writes do not lock or read again"
  end

  # A before_destroy callback that deletes the record itself: its destroy's
  # own check refuses it, and the destroy_all rolls back, as a destroy on its
  # own does. A check made only before the callbacks let a second Destroyed
  # in.
  def test_destroy_all_refuses_a_record_its_own_callbacks_deleted
    SbwItem.class_eval { before_destroy { SbwItem.where(id: id).delete_all } }
    use(:es_noproj)
    seed

    assert_raises(Lyra::RecordDestroyedError) { SbwItem.where(code: "a3").destroy_all }
    assert_equal %i[created], operations("a3")
    assert_includes state.map(&:first), "a3"
  end

  # update_counters adds to the counters the event store holds when its
  # locks are taken, not to the values the relation read: an update made
  # since is kept, as Active Record's SQL (qty = qty + 1) keeps it.
  def test_update_counters_adds_to_the_current_value
    runs = MODES.map do |mode|
      clean
      use(mode)
      seed
      relation = SbwItem.where(code: %w[a3 a4]).order(:code)
      relation.to_a
      SbwItem.find(@ids["a3"]).update!(qty: 100)
      [relation.update_counters(qty: 1), state.select { %w[a3 a4].include?(_1[0]) }.map { _1[2] }]
    end
    assert_equal runs.first, runs.last
    assert_equal [2, [101, 5]], runs.last
  end

  # Two writers incrementing the same records, their relations in opposite
  # orders: the locks were taken group by group, so they deadlocked, and
  # each added to the values it had read, so increments were lost.
  def test_concurrent_update_counters_in_opposite_orders_neither_deadlock_nor_lose_increments
    use(:es_noproj)
    seed
    rounds = 15
    errors = Queue.new
    writers = %i[asc desc].map do |direction|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          rounds.times do
            SbwItem.order(qty: direction).update_counters(qty: 1)
          rescue StandardError => e
            errors << e
          end
        end
      end
    end
    writers.each(&:join)

    assert_empty(errors.size.times.map { errors.pop.class })
    expected = ROWS.sum { _1[:qty] } + (ROWS.size * rounds * 2)
    assert_equal expected, SbwItem.sum(:qty)
  end

  # More records than bulk_write_lock_limit: refused before anything is
  # locked or written. Batches of at most the limit each commit on their own.
  def test_a_bulk_write_over_the_lock_limit_is_refused_before_it_writes
    use(:es_noproj)
    seed
    Lyra.config.bulk_write_lock_limit = 2
    before = event_count

    %i[update_all delete_all touch_all update_counters].each do |write|
      error = assert_raises(Lyra::BulkWriteLockLimitError, write) do
        relation = SbwItem.where(status: "active")
        case write
        when :update_all then relation.update_all(tag: "l")
        when :update_counters then relation.update_counters(qty: 1)
        else relation.public_send(write)
        end
      end
      assert_equal [3, 2], [error.count, error.limit], write
      assert_match(/bulk_write_lock_limit \(2\).*in_batches/m, error.message)
    end
    assert_equal before, event_count
    assert_equal 0, locks_held

    assert_equal 3, SbwItem.where(status: "active").in_batches(of: 2).update_all(tag: "l")
    assert_equal %w[l l l], SbwItem.where(status: "active").pluck(:tag)
    assert_equal 2, SbwItem.where(status: "active").limit(2).update_all(tag: "m")

    Lyra.config.bulk_write_lock_limit = nil
    assert_equal 3, SbwItem.where(status: "active").update_all(tag: "n")
  end

  # destroy_all locks each record in its own transaction: the limit applies
  # only inside a transaction already open, where the locks add up.
  def test_destroy_all_over_the_lock_limit_is_refused_only_inside_a_transaction
    use(:es_noproj)
    seed
    Lyra.config.bulk_write_lock_limit = 2
    before = event_count

    assert_raises(Lyra::BulkWriteLockLimitError) do
      SbwItem.transaction { SbwItem.where(status: "active").destroy_all }
    end
    assert_equal before, event_count
    assert_equal %w[a1 a2 a6], SbwItem.where(status: "active").order(:code).pluck(:code)

    assert_equal %w[a1 a2 a6], SbwItem.where(status: "active").destroy_all.map(&:code)
  end

  # A dependent: :delete_all or :nullify over more children than the limit
  # refuses the parent's destroy before any event is written.
  def test_a_dependent_write_over_the_lock_limit_refuses_the_destroy_before_it_writes
    with_parents do
      use(:es_noproj)
      %w[SbwDeleteParent SbwNullifyParent].each do |name|
        parent = Object.const_get(name).create!(name: name)
        3.times { |i| SbwItem.create!(code: "#{name}#{i}", status: "child", qty: i, parent_id: parent.id) }
      end
      Lyra.config.bulk_write_lock_limit = 2
      before = event_count

      %w[SbwDeleteParent SbwNullifyParent].each do |name|
        parent = Object.const_get(name).find_by(name: name)
        assert_raises(Lyra::BulkWriteLockLimitError, name) { parent.destroy }
        assert Object.const_get(name).exists?(parent.id), name
        assert_equal 3, SbwItem.where(parent_id: parent.id).count, name
      end
      assert_equal before, event_count

      Lyra.config.bulk_write_lock_limit = 3
      %w[SbwDeleteParent SbwNullifyParent].each { |name| Object.const_get(name).find_by(name: name).destroy! }
      assert_equal 0, SbwItem.where(status: "child").where.not(parent_id: nil).count
    end
  end

  # A record that comes to match between the write's read of its selection
  # and the locks: the selection read again holds it, so it is locked too,
  # and the selection read once more; then it is written.
  def test_a_record_matching_after_the_selection_was_read_is_locked_and_written
    use(:es_noproj)
    seed
    relation = SbwItem.where(status: "active")
    evaluations = 0
    original = relation.method(:evaluate)
    relation.define_singleton_method(:evaluate) do |recipe|
      evaluations += 1
      SbwItem.create!(code: "a8", status: "active", qty: 8) if evaluations == 1
      original.call(recipe)
    end

    locks, = count_queries { assert_equal 4, relation.update_all(tag: "late") }
    assert_equal 2, evaluations
    assert_equal 2, locks
    assert_equal "late", SbwItem.find_by(code: "a8").tag
  end

  # A write to a record destroyed after the relation read it, but before the
  # write took its lock, waits for the destroy to commit and leaves the record
  # out.
  def test_a_concurrent_destroy_is_seen_under_the_lock
    use(:es_noproj)
    seed
    relation = SbwItem.where(status: "archived")
    a5 = SbwItem.find_by(code: "a5")
    locked = Queue.new
    release = Queue.new
    destroyer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        SbwItem.transaction do
          a5.destroy!
          locked << true
          release.pop
        end
      end
    end
    locked.pop
    writer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection { relation.update_all(tag: "c") }
    end
    sleep 0.2
    assert writer.alive?, "the bulk write waits for the destroy's lock"
    release << true
    destroyer.join
    assert_equal 1, writer.value
    assert_equal %i[created destroyed], operations("a5")
  ensure
    release&.push(true)
    destroyer&.join
    writer&.join
  end

  private

  def use(mode)
    if mode == :es_noproj
      Lyra.config.enable_event_sourcing!
      Lyra.config.projection_mode = :disabled
    else
      Lyra.config.enable_monitor!
      Lyra.config.projection_mode = :sync
    end
  end

  def seed
    @ids = ROWS.to_h { |row| [row[:code], SbwItem.create!(row).id] }
  end

  def state
    SbwItem.unscoped.order(:code).pluck(:code, :status, :qty, :tag)
  end

  def operations(code)
    stream = Lyra.stream_name(SbwItem, @ids.fetch(code))
    Lyra.config.event_store.read.stream(stream).to_a.map { |e| Lyra::Event.operation_of(e) }
  end

  # [lock statements, stream reads, reads of every stream's last event (a
  # selection of the model read from the event store)] while the block runs.
  def count_queries
    locks = 0
    reads = 0
    selections = 0
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      locks += 1 if payload[:sql].match?(/pg_(try_)?advisory_xact_lock\(/)
      reads += 1 if payload[:name] == "Lyra stream tail"
      selections += 1 if payload[:sql].include?("WHERE stream LIKE")
    end
    yield
    [locks, reads, selections]
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  def event_count
    connection.select_value("SELECT count(*) FROM event_store_events").to_i
  end

  # Advisory locks this session holds.
  def locks_held
    connection.select_value("SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND pid = pg_backend_pid()").to_i
  end

  # Two parent models of SbwItem: one dependent: :delete_all, one :nullify.
  def with_parents
    connection.create_table(PARENTS, force: true) do |t|
      t.string :name
      t.timestamps
    end
    { SbwDeleteParent: :delete_all, SbwNullifyParent: :nullify }.each do |name, dependent|
      Object.send(:remove_const, name) if Object.const_defined?(name)
      Object.const_set(name, Class.new(ActiveRecord::Base) do
        self.table_name = PARENTS
        include Lyra::Interceptors::CrudInterceptor
        monitor_with_lyra
        has_many :items, class_name: "SbwItem", foreign_key: :parent_id, dependent: dependent
      end)
      Object.const_get(name).reset_column_information
      Lyra.config.monitor_model(Object.const_get(name))
    end
    yield
  ensure
    %i[SbwDeleteParent SbwNullifyParent].each { Object.send(:remove_const, _1) if Object.const_defined?(_1) }
    connection.drop_table(PARENTS, if_exists: true)
  end

  def clean
    @ids = nil
    connection.execute("DELETE FROM #{TABLE}") if connection.table_exists?(TABLE)
    connection.execute("DELETE FROM event_store_events_in_streams")
    connection.execute("DELETE FROM event_store_events")
    Lyra::Projections::CachedProjection.invalidate_all(SbwItem) if Object.const_defined?(:SbwItem)
    Rails.cache.clear
  end

  def connection = ActiveRecord::Base.connection
end
