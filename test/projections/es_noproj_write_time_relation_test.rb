# frozen_string_literal: true

require "test_helper"

# An ES-NoProj bulk write writes what its relation selects when the write is
# called, as Active Record's runs its query then: a record changed, inserted
# or destroyed since the relation was built, and a window (order, offset,
# limit), are taken as they are now. It wrote the records the relation held
# when it was built. Also the class-level counters (increment_counter,
# decrement_counter, update_counters, a record's increment!), which wrote
# nothing. Each case runs in Monitor (Active Record on PostgreSQL) and in
# ES-NoProj on the same rows, and the answers must be equal.
class EsNoprojWriteTimeRelationTest < Minitest::Test
  ITEMS = "lyra_wtr_items"
  PARENTS = "lyra_wtr_parents"
  GROUPS = "lyra_wtr_groups"
  ROWS = [
    { code: "a1", status: "active", qty: 1, tag: "x" },
    { code: "a2", status: "active", qty: 2, tag: nil },
    { code: "a3", status: "archived", qty: 3, tag: "y" },
    { code: "a4", status: "draft", qty: 4, tag: nil },
    { code: "a5", status: "archived", qty: 5, tag: "x" },
    { code: "a6", status: "active", qty: 6, tag: "z" },
    { code: "a7", status: "draft", qty: 7, tag: "x" }
  ].freeze
  MODES = %i[monitor es_noproj].freeze

  def setup
    skip "Requires Rails and PostgreSQL" unless defined?(ActiveRecord::Base) && connection.adapter_name.match?(/postgres/i)

    connection.create_table(ITEMS, force: true) do |t|
      t.string :code
      t.string :status
      t.integer :qty
      t.string :tag
      t.integer :parent_id
      t.timestamps
    end
    connection.create_table(PARENTS, force: true) do |t|
      t.string :name
      t.integer :group_id
      t.integer :hits, default: 0, null: false
      t.integer :lock_version, default: 0, null: false
      t.timestamps
    end
    connection.create_table(GROUPS, force: true) do |t|
      t.string :name
      t.timestamps
    end
    model(:WtrItem, ITEMS) do
      belongs_to :parent, class_name: "WtrParent", optional: true
      singleton_class.attr_accessor :wanted
      scope :created_until_now, -> { where(created_at: ..Time.current) }
      scope :active, -> { where(status: "active") }
      scope :tagged, ->(tag) { where(tag: tag) }
      scope :drafts_instead, -> { rewhere(status: "draft") }
      scope :wanted_status, -> { where(status: WtrItem.wanted) }
      def self.active_ids_now = where(id: where(status: "active").pluck(:id))
    end
    model(:WtrParent, PARENTS) do
      has_many :items, class_name: "WtrItem", foreign_key: :parent_id
      belongs_to :group, class_name: "WtrGroup", optional: true
    end
    model(:WtrGroup, GROUPS) do
      has_many :parents, class_name: "WtrParent", foreign_key: :group_id
      has_many :items, through: :parents
    end
    clean
  end

  def teardown
    return unless Object.const_defined?(:WtrItem)

    Lyra.reset_config!
    clean
    [ITEMS, PARENTS, GROUPS].each { connection.drop_table(_1, if_exists: true) }
  end

  # The same scenario in each mode: +build+ gives the relation (+loaded+:
  # and loads it), +change+ alters the rows after, +write+ writes on the
  # relation. Returns [write's result, rows, how many events] per mode, and
  # asserts they are equal.
  def parity(build:, change:, write:, loaded: true)
    runs = MODES.map do |mode|
      clean
      use(mode)
      seed
      relation = build.call
      relation.to_a if loaded
      change.call
      before = event_count
      result = write.call(relation)
      result = result.map(&:code).sort if result.is_a?(Array)
      [result, state, event_count - before]
    end
    assert_equal runs.first, runs.last
    runs.last
  end

  def test_a_window_is_taken_again
    result, rows, events = parity(
      build: -> { WtrItem.order(:code).offset(1).limit(3) },
      change: -> { WtrItem.where(code: "a3").delete_all },
      write: ->(r) { r.update_all(tag: "w") }
    )
    assert_equal 3, result
    assert_equal %w[a2 a4 a5], rows.select { _1[3] == "w" }.map(&:first)
    assert_equal 3, events
  end

  def test_records_changed_since_are_taken_as_they_are_now
    result, rows, = parity(
      build: -> { WtrItem.where(status: "active") },
      change: lambda {
        WtrItem.find(@ids["a6"]).update!(status: "draft")
        WtrItem.find(@ids["a4"]).update!(status: "active")
      },
      write: ->(r) { r.update_all(tag: "w") }
    )
    assert_equal 3, result
    assert_equal %w[a1 a2 a4], rows.select { _1[3] == "w" }.map(&:first)
  end

  def test_a_record_inserted_since_is_written
    result, rows, = parity(
      build: -> { WtrItem.where(status: "active") },
      change: -> { WtrItem.create!(code: "a8", status: "active", qty: 8) },
      write: :delete_all.to_proc
    )
    assert_equal 4, result
    assert_equal %w[a3 a4 a5 a7], codes(rows)
  end

  def test_touch_all_and_update_counters_take_the_selection_now
    result, = parity(
      build: -> { WtrItem.where(status: "draft") },
      change: -> { WtrItem.find(@ids["a3"]).update!(status: "draft") },
      write: :touch_all.to_proc
    )
    assert_equal 3, result

    result, rows, = parity(
      build: -> { WtrItem.where(status: "draft") },
      change: lambda {
        WtrItem.find(@ids["a3"]).update!(status: "draft", qty: 30)
        WtrItem.where(code: "a7").delete_all
      },
      write: ->(r) { r.update_counters(qty: 1) }
    )
    assert_equal 2, result
    assert_equal({ "a3" => 31, "a4" => 5 }, rows.select { _1[1] == "draft" }.to_h { [_1[0], _1[2]] })
  end

  # destroy_all and update load the records, as Active Record's do: those
  # the relation selects now, unless the application loaded them already.
  def test_destroy_all_and_update_take_the_selection_now_unless_loaded
    change = lambda {
      WtrItem.where(code: "a5").delete_all
      WtrItem.find(@ids["a7"]).update!(status: "archived")
    }
    result, rows, = parity(build: -> { WtrItem.where(status: "archived") }, change: change,
                           write: :destroy_all.to_proc, loaded: false)
    assert_equal %w[a3 a7], result
    assert_equal %w[a1 a2 a4 a6], codes(rows)

    result, rows, = parity(build: -> { WtrItem.where(status: "archived") }, change: change,
                           write: ->(r) { r.update(tag: "u") }, loaded: false)
    assert_equal %w[a3 a7], result, "the stale record raised RecordDestroyedError"
    assert_equal({ "a3" => "u", "a7" => "u" }, rows.select { _1[1] == "archived" }.to_h { [_1[0], _1[3]] })

    # Loaded: the records loaded. a5, destroyed since, takes the attributes
    # in memory and is not written, as Active Record's update of a row gone.
    result, rows, = parity(build: -> { WtrItem.where(status: "archived") }, change: change,
                           write: ->(r) { r.update(tag: "u") })
    assert_equal %w[a3 a5], result
    assert_equal({ "a3" => "u", "a7" => "x" }, rows.select { _1[1] == "archived" }.to_h { [_1[0], _1[3]] })
  end

  # Loaded, destroy_all destroys the records loaded: Active Record also
  # runs destroy on a5, destroyed since (its DELETE reaches no row) and
  # returns it; ES-NoProj leaves it out.
  def test_destroy_all_of_a_loaded_relation_destroys_the_records_loaded
    results = MODES.map do |mode|
      clean
      use(mode)
      seed
      relation = WtrItem.where(status: "archived").tap(&:to_a)
      WtrItem.where(code: "a5").delete_all
      WtrItem.find(@ids["a7"]).update!(status: "archived")
      [relation.destroy_all.map(&:code), codes(state)]
    end
    assert_equal [%w[a3 a5], %w[a1 a2 a4 a6 a7]], results.first
    assert_equal [%w[a3], %w[a1 a2 a4 a6 a7]], results.last
  end

  # A batch is the relation narrowed to the batch's keys: a record of a
  # later batch that no longer matches is not written.
  def test_a_batch_takes_its_records_as_they_are_now
    _, rows, = parity(
      build: -> { WtrItem.where(status: "active") },
      change: -> {},
      write: lambda { |r|
        r.in_batches(of: 1) do |batch|
          WtrItem.find(@ids["a6"]).update!(status: "draft") if batch.pluck(:code) == ["a1"]
          batch.update_all(tag: "s")
        end
        nil
      }
    )
    assert_equal({ "a1" => "s", "a2" => "s", "a6" => "z" }, rows.select { %w[a1 a2 a6].include?(_1[0]) }.to_h { [_1[0], _1[3]] })
  end

  def test_an_association_takes_its_records_as_they_are_now
    _, rows, = parity(
      build: -> { WtrParent.find_by(name: "p1").items.where(status: "child") },
      change: lambda {
        WtrItem.where(code: "c1").delete_all
        WtrItem.find_by(code: "c3").update!(parent_id: WtrParent.find_by(name: "p1").id)
      },
      write: ->(r) { r.update_all(tag: "p") }
    )
    assert_equal %w[c2 c3], rows.select { _1[3] == "p" }.map(&:first)

    # The collection itself (its update_all goes to the association's scope).
    result, rows, = parity(
      build: -> { WtrParent.find_by(name: "p1").items },
      change: -> { WtrItem.where(code: "c2").delete_all },
      write: ->(r) { r.update_all(tag: "q") }
    )
    assert_equal 1, result
    assert_equal %w[c1], rows.select { _1[3] == "q" }.map(&:first)
  end

  def test_a_through_association_takes_its_records_as_they_are_now
    result, rows, = parity(
      build: -> { WtrGroup.find_by(name: "g1").items },
      change: lambda {
        WtrItem.where(code: "c1").delete_all
        WtrItem.find_by(code: "c3").update!(parent_id: WtrParent.find_by(name: "p1").id)
      },
      write: ->(r) { r.update_all(tag: "t") }
    )
    assert_equal 3, result
    assert_equal %w[c2 c3 c4], rows.select { _1[3] == "t" }.map(&:first)
  end

  # Batches read when the loop reaches each, as Active Record queries each:
  # what the loop's own writes (or another's) change is seen by the batches
  # after. +run+ is called with the seeded ids and returns what the loop saw.
  def loop_parity(&run)
    answers = MODES.map do |mode|
      clean
      use(mode)
      seed
      run.call
    end
    assert_equal answers.first, answers.last
    answers.last
  end

  def test_batches_see_records_inserted_deleted_and_changed_during_the_loop
    seen = loop_parity do
      out = []
      WtrItem.where(status: %w[active draft archived]).in_batches(of: 3) do |batch|
        out << batch.pluck(:code)
        next unless out.size == 1

        WtrItem.where(code: "a5").delete_all
        WtrItem.find(@ids["a6"]).update!(status: "gone")
        WtrItem.create!(code: "a9", status: "draft", qty: 9)
      end
      out
    end
    assert_equal [%w[a1 a2 a3], %w[a4 a7 a9]], seen

    seen = loop_parity do
      out = []
      WtrItem.where(status: "active").find_each(batch_size: 1) do |record|
        out << record.code
        WtrItem.find(@ids["a6"]).update!(status: "draft") if record.code == "a1"
      end
      out
    end
    assert_equal %w[a1 a2], seen

    seen = loop_parity do
      out = []
      WtrItem.where(status: %w[active draft]).find_in_batches(batch_size: 2) do |records|
        out << records.map(&:code)
        WtrItem.where(code: "a4").delete_all if out.size == 1
      end
      out
    end
    assert_equal [%w[a1 a2], %w[a6 a7]], seen
  end

  def test_batch_options_are_kept_when_each_batch_is_read_in_turn
    seen = loop_parity do
      runs = []
      relation = WtrItem.where(status: %w[active draft archived])
      runs << relation.in_batches(of: 3, order: :desc).map { _1.pluck(:code) }
      runs << relation.in_batches(of: 2, start: @ids["a2"], finish: @ids["a6"]).map { _1.pluck(:code) }
      runs << relation.in_batches(of: 3, load: true).map { |batch| batch.map(&:code) }
      runs << WtrItem.in_batches(of: 4, use_ranges: true).map { _1.pluck(:code) }
      runs << relation.in_batches(of: 3).each_record.map(&:code)
      runs << relation.find_each(batch_size: 2, order: :desc).map(&:code)
      runs << relation.in_batches(of: 2).map { |batch| batch.update_all(tag: "b") }
      runs
    end
    assert_equal [%w[a5 a6 a7], %w[a2 a3 a4], %w[a1]], seen[0]
    assert_equal [%w[a2 a3], %w[a4 a5], %w[a6]], seen[1]
    assert_equal [2, 2, 2, 1], seen[6]
  end

  # Model.increment_counter, decrement_counter and update_counters(id, ...),
  # with and without touch:, and a record's increment! and decrement!.
  def test_class_level_counters_write_the_record
    MODES.each do |mode|
      clean
      use(mode)
      seed
      id = @ids["a3"]
      before = event_count
      results = [
        WtrItem.increment_counter(:qty, id),
        WtrItem.decrement_counter(:qty, id, by: 2),
        WtrItem.update_counters(id, qty: 5),
        WtrItem.update_counters([id, @ids["a4"]], qty: 1, touch: true),
        WtrItem.increment_counter(:qty, 0)
      ]
      WtrItem.find(id).increment!(:qty, 10)
      WtrItem.find(id).decrement!(:qty)
      assert_equal [1, 1, 1, 2, 0], results, mode
      assert_equal 17, WtrItem.find(id).qty, mode
      assert_equal 5, WtrItem.find(@ids["a4"]).qty, mode
      assert_equal 7, event_count - before, mode
    end
  end

  # What the write selects is what the relation was built with: arguments
  # the caller changes afterwards do not reach it, as they do not reach
  # Active Record's query.
  def test_arguments_changed_after_the_relation_was_built_do_not_reach_the_write
    codes = nil
    result, rows, = parity(build: -> { WtrItem.where(code: codes = %w[a1]) },
                           change: -> { codes << "a2" << "a3" }, write: :delete_all.to_proc)
    assert_equal 1, result
    assert_equal %w[a2 a3 a4 a5 a6 a7], codes(rows)

    conditions = nil
    result, rows, = parity(build: -> { WtrItem.where(conditions = { status: "active" }).where(tag: "x") },
                           change: -> { conditions[:status] = "draft" }, write: :delete_all.to_proc)
    assert_equal 1, result
    assert_equal %w[a2 a3 a4 a5 a6 a7], codes(rows)

    code = nil
    parity(build: -> { WtrItem.where(code: code = +"a1") }, change: -> { code.replace("a2") },
           write: ->(r) { r.update_all(tag: "s") })
  end

  # A scope or class method called on a relation runs once, when the
  # relation is built, as in Active Record: Time.current, the ids it
  # plucked, a value it read are those of then.
  def test_scopes_and_class_methods_are_not_run_again_at_write_time
    result, rows, = parity(build: -> { WtrItem.created_until_now },
                           change: -> { WtrItem.create!(code: "a8", status: "new", qty: 8) },
                           write: ->(r) { r.update_all(tag: "n") })
    assert_equal 11, result
    assert_nil rows.to_h { [_1[0], _1[3]] }["a8"]

    result, = parity(build: -> { WtrItem.all.active_ids_now },
                     change: -> { WtrItem.find(@ids["a4"]).update!(status: "active") },
                     write: ->(r) { r.update_all(tag: "i") })
    assert_equal 3, result

    result, = parity(build: -> { (WtrItem.wanted = "active") && WtrItem.wanted_status },
                     change: -> { WtrItem.wanted = "draft" },
                     write: ->(r) { r.update_all(tag: "w") })
    assert_equal 3, result
  end

  # A scope called on a relation, and a chain of them, keeps the recipe:
  # the query calls the body made are recorded (it is not run again), so a
  # write selects as Active Record's does when a record starts or stops
  # matching after the relation was built.
  def test_scope_chains_select_at_write_time
    result, rows, = parity(build: -> { WtrItem.active.tagged("x") },
                           change: -> { WtrItem.find(@ids["a4"]).update!(status: "active", tag: "x") },
                           write: ->(r) { r.update_all(qty: 0) })
    assert_equal 2, result
    assert_equal({ "a1" => 0, "a4" => 0 }, rows.select { %w[a1 a4].include?(_1[0]) }.to_h { [_1[0], _1[2]] })

    result, = parity(build: -> { WtrItem.where(tag: "x").active },
                     change: -> { WtrItem.find(@ids["a1"]).update!(status: "draft") },
                     write: ->(r) { r.update_all(qty: 0) })
    assert_equal 0, result

    result, rows, = parity(build: -> { WtrItem.active.tagged("x") },
                           change: -> { WtrItem.find(@ids["a1"]).update!(status: "draft") },
                           write: :destroy_all.to_proc, loaded: false)
    assert_equal [], result
    assert_includes codes(rows), "a1"

    result, = parity(build: -> { WtrItem.where(status: %w[active draft]).extending { def marker = :m }.tagged("x") },
                     change: -> { WtrItem.find(@ids["a4"]).update!(tag: "x") },
                     write: ->(r) { r.update_all(qty: 0) })
    assert_equal 3, result
  end

  # unscope, rewhere and except rebuild the relation from its plan: a write
  # reads that again from the event store too. It wrote the records the plan
  # held when the relation was built, with their old values.
  def test_unscope_rewhere_and_except_select_at_write_time
    rewhered = -> { WtrItem.where(status: "active").rewhere(status: "draft") }
    unscoped = -> { WtrItem.where(status: "active").unscope(where: :status).where(tag: "x") }
    tagged = ->(rows) { rows.select { _1[3] == "w" }.map(&:first) }
    write = ->(r) { r.update_all(tag: "w") }

    result, rows, = parity(build: rewhered, change: -> { WtrItem.find(@ids["a4"]).update!(status: "active") }, write: write)
    assert_equal [1, %w[a7]], [result, tagged.call(rows)]
    result, rows, = parity(build: rewhered, change: -> { WtrItem.create!(code: "a8", status: "draft", qty: 8) }, write: write)
    assert_equal [3, %w[a4 a7 a8]], [result, tagged.call(rows)]
    result, rows, = parity(build: unscoped, change: -> { WtrItem.find(@ids["a1"]).update!(tag: "q") }, write: write)
    assert_equal [2, %w[a5 a7]], [result, tagged.call(rows)]
    result, rows, = parity(build: unscoped, change: -> { WtrItem.find(@ids["a2"]).update!(tag: "x") }, write: write)
    assert_equal [4, %w[a1 a2 a5 a7]], [result, tagged.call(rows)]
    result, = parity(build: unscoped, change: -> { WtrItem.find(@ids["a1"]).update!(tag: "q") }, write: :delete_all.to_proc)
    assert_equal 2, result
    result, = parity(build: rewhered, change: -> { WtrItem.find(@ids["a4"]).update!(status: "active") },
                     write: :destroy_all.to_proc, loaded: false)
    assert_equal %w[a7], result
    result, = parity(build: -> { WtrItem.where(status: "active").except(:where).where(tag: "x") },
                     change: -> { WtrItem.find(@ids["a1"]).update!(tag: "q") }, write: write)
    assert_equal 2, result
    result, = parity(build: -> { WtrItem.where(status: "active").drafts_instead },
                     change: -> { WtrItem.find(@ids["a4"]).update!(status: "active") }, write: write)
    assert_equal 1, result
  end

  # With optimistic locking, the class-level counters and increment! move
  # the lock version, as Active Record's do: a copy read before raises
  # StaleObjectError on save.
  def test_class_level_counters_move_the_lock_version
    MODES.each do |mode|
      clean
      use(mode)
      seed
      id = WtrParent.find_by(name: "p1").id
      stale = WtrParent.find(id)
      assert_equal 1, WtrParent.increment_counter(:hits, id), mode
      assert_equal 1, WtrParent.update_counters(id, hits: 2), mode
      fresh = WtrParent.find(id)
      assert_equal [3, 2], [fresh.hits, fresh.lock_version], mode
      fresh.increment!(:hits)
      assert_equal [4, 3], [fresh.hits, fresh.lock_version], mode
      assert_equal [4, 3], WtrParent.where(id: id).pluck(:hits, :lock_version).first, mode
      stale.name = "late"
      assert_raises(ActiveRecord::StaleObjectError, mode) { stale.save! }
    end
  end

  # increment! in a callback, however the record is created, counts once.
  def test_an_increment_in_a_callback_counts_once
    WtrItem.class_eval { after_create { WtrParent.find(parent_id).increment!(:hits) if code&.start_with?("h") } }
    counts = MODES.map do |mode|
      clean
      use(mode)
      seed
      parent = WtrParent.find_by(name: "p1")
      WtrItem.create!(code: "h1", parent_id: parent.id)
      parent.items.create!(code: "h2")
      parent.items << WtrItem.new(code: "h3")
      WtrParent.find(parent.id).items.build(code: "h4").save!
      WtrParent.find(parent.id).hits
    end
    assert_equal [4, 4], counts
  end

  # A write keyed by primary key reads those records, not every record of
  # the model (Rebuildable.keyed, EventStoreReader.keyed).
  def test_a_keyed_write_reads_only_its_records
    use(:es_noproj)
    seed
    relation = WtrItem.where(id: @ids["a3"])
    count = nil
    assert_equal 0, selections { count = relation.update_all(tag: "l") }
    assert_equal 1, count
    assert_equal 0, selections { WtrItem.increment_counter(:qty, @ids["a3"]) }
    assert_equal 0, selections { WtrItem.update_counters([@ids["a3"], @ids["a4"]], qty: 1) }
    assert_equal [5, "l"], WtrItem.where(code: "a3").pluck(:qty, :tag).first
  end

  private

  # How many reads of every stream of a model the block makes.
  def selections
    count = 0
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      count += 1 if payload[:sql].include?("WHERE stream LIKE")
    end
    yield
    count
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  def model(name, table, &block)
    Object.send(:remove_const, name) if Object.const_defined?(name)
    klass = Class.new(ActiveRecord::Base)
    Object.const_set(name, klass)
    klass.table_name = table
    klass.class_eval(&block) if block
    klass.include Lyra::Interceptors::CrudInterceptor
    klass.monitor_with_lyra
    klass.reset_column_information
    Lyra.config.monitor_model(klass)
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

  def seed
    @ids = ROWS.to_h { |row| [row[:code], WtrItem.create!(row).id] }
    group = WtrGroup.create!(name: "g1")
    p1 = WtrParent.create!(name: "p1", group_id: group.id)
    p2 = WtrParent.create!(name: "p2", group_id: group.id)
    p3 = WtrParent.create!(name: "p3")
    { "c1" => p1, "c2" => p1, "c4" => p2, "c3" => p3 }.each do |code, parent|
      WtrItem.create!(code: code, status: "child", qty: 0, parent_id: parent.id)
    end
    # c4 is reached through p2; c3 (under p3) is not, until it moves to p1.
    @ids.merge!(WtrItem.where(status: "child").to_h { [_1.code, _1.id] })
  end

  def state
    WtrItem.unscoped.order(:code).pluck(:code, :status, :qty, :tag)
  end

  # The codes of the a* rows (the c* rows are the parents' items).
  def codes(rows) = rows.map(&:first).grep(/\Aa/)

  def event_count
    connection.select_value("SELECT count(*) FROM event_store_events").to_i
  end

  def clean
    @ids = nil
    [ITEMS, PARENTS, GROUPS].each { connection.execute("DELETE FROM #{_1}") if connection.table_exists?(_1) }
    connection.execute("DELETE FROM event_store_events_in_streams")
    connection.execute("DELETE FROM event_store_events")
    %i[WtrItem WtrParent WtrGroup].each do |name|
      Lyra::Projections::CachedProjection.invalidate_all(Object.const_get(name)) if Object.const_defined?(name)
    end
    Rails.cache.clear
  end

  def connection = ActiveRecord::Base.connection
end
