# frozen_string_literal: true

require "test_helper"
require "timeout"

# A table's unique indexes in ES-Sync, ES-Async and ES-Lazy, where the event
# is appended before the projection writes the row. A duplicate's event was
# appended and its projection then met the index: logged (strict_projections
# off), so the log held a record the table could not, and in ES-Lazy the next
# read's catch-up failed on it, for every model. The writes are now checked
# before the event, as ES-NoProj's are (Lyra::Projections::UniqueIndexes):
# ES-Sync against its table, under the value's lock; ES-Async and ES-Lazy
# against the event store's value streams, since their tables lag it. Monitor,
# whose table is authoritative, is the oracle: each scenario ends as there,
# and the projection then holds what the log says (DualView).
#
# ES-Async runs with its projection jobs held (the table lags until they
# run); ES-Lazy reads nothing between the writes. test/projections
# /es_noproj_unique_writes_test.rb runs the shared scenarios (duplicate
# create, update, update_columns, update_all, multi-column, NULL, destroyed
# holder, own value, citext, enum, encrypted) in every mode with the jobs run
# inline.
class EsModesUniqueWritesTest < Minitest::Test
  TABLE = "lyra_um_people"
  MODES = %i[monitor es_sync es_async es_lazy].freeze
  STAMP = Time.utc(2026, 1, 1)

  def setup
    skip "Requires Rails and PostgreSQL" unless defined?(ActiveRecord::Base) && connection.adapter_name.match?(/postgres/i)

    connection.create_table(TABLE, force: true) do |t|
      t.string :email
      t.string :name
      t.integer :shop_id
      t.string :code
      t.timestamps
      t.index :email, unique: true, name: "index_lyra_um_people_on_email"
      t.index %i[shop_id code], unique: true
    end
    connection.create_table(:lyra_um_notes, force: true) { |t| t.string :body }
    define_model(:UmPerson, TABLE)
    define_model(:UmNote, "lyra_um_notes")
    clean
  end

  def teardown
    return unless Object.const_defined?(:UmPerson)

    UmPerson.before_create_hook = nil
    ActiveJob::Base.queue_adapter = @previous_adapter if @previous_adapter
    Lyra.reset_config!
    clean
    connection.drop_table(TABLE, if_exists: true)
    connection.drop_table(:lyra_um_notes, if_exists: true)
    %i[UmPerson UmNote].each { Object.send(:remove_const, _1) if Object.const_defined?(_1) }
  end

  # A holder whose create waits for its job (ES-Async) or for the next read
  # (ES-Lazy): every write of its value is refused before anything is
  # appended or enqueued, as Monitor's INSERT or UPDATE refuses it.
  def test_a_holder_not_yet_projected
    writes = {
      create: -> { UmPerson.create!(email: "a@x", name: "dup") },
      update: -> { UmPerson.find(@other).update!(email: "a@x") },
      update_columns: -> { UmPerson.find(@other).update_columns(email: "a@x") },
      update_all: -> { UmPerson.where(id: @other).update_all(email: "a@x") },
      pair: -> { UmPerson.create!(shop_id: 1, code: "c") },
      insert_all: -> { UmPerson.insert_all([{ email: "a@x", name: "ins", created_at: STAMP, updated_at: STAMP }]).length },
      insert_all!: -> { UmPerson.insert_all!([{ email: "a@x", name: "ins", created_at: STAMP, updated_at: STAMP }]).length },
      upsert_all: -> { UmPerson.upsert_all([{ id: @other, email: "a@x", created_at: STAMP, updated_at: STAMP }]).length }
    }
    writes.each do |name, write|
      outcomes = each_mode do
        @other = UmPerson.create!(email: "b@x").id
        settle
        UmPerson.create!(email: "a@x", shop_id: 1, code: "c")
        events = event_count
        jobs = held_jobs
        [attempt(&write), event_count - events, held_jobs - jobs]
      end
      expected = name == :insert_all ? 0 : ActiveRecord::RecordNotUnique
      assert_equal [expected, 0, 0], outcomes[:monitor][:result], name
      assert_same_as_monitor(outcomes, name)
    end
  end

  # A holder destroyed, or moved to another value, whose row is still in the
  # table (ES-Async: the job waits; ES-Lazy: no read since): the value is
  # free, as in Monitor, whose row is gone. Each write saves it; ES-Async
  # brings the old holder's row up to date first, so neither the write's
  # table write nor its projection job meets the value there.
  def test_a_holder_gone_from_the_log_not_yet_from_the_table
    writes = {
      create: -> { UmPerson.create!(email: "a@x", name: "new") },
      update: -> { UmPerson.find(@other).update!(email: "a@x") },
      update_columns: -> { UmPerson.find(@other).update_columns(email: "a@x") },
      update_all: -> { UmPerson.where(id: @other).update_all(email: "a@x") },
      insert_all: -> { UmPerson.insert_all([{ email: "a@x", name: "ins", created_at: STAMP, updated_at: STAMP }]).length },
      insert_all!: -> { UmPerson.insert_all!([{ email: "a@x", name: "ins", created_at: STAMP, updated_at: STAMP }]).length },
      upsert_all: -> { UmPerson.upsert_all([{ id: @other, email: "a@x", created_at: STAMP, updated_at: STAMP }]).length }
    }
    %i[destroyed moved].each do |gone|
      writes.each do |name, write|
        outcomes = each_mode do
          holder = UmPerson.create!(email: "a@x")
          @other = UmPerson.create!(email: "b@x").id
          settle
          gone == :destroyed ? UmPerson.find(holder.id).destroy! : UmPerson.find(holder.id).update!(email: "z@x")
          events = event_count
          [attempt(&write), event_count - events]
        end
        expected = %i[insert_all insert_all! upsert_all update_all].include?(name) ? 1 : :saved
        assert_equal [expected, 1], outcomes[:monitor][:result], [gone, name]
        assert_same_as_monitor(outcomes, [gone, name])
      end
    end
  end

  # upsert_all by the unique column: the holder, its create waiting for its
  # job in ES-Async, is updated (its row brought up to date first), as
  # Monitor's ON CONFLICT updates it; a conflict on another index raises.
  def test_upsert_all_by_the_unique_column
    outcomes = each_mode do
      holder = UmPerson.create!(email: "a@x", name: "old", shop_id: 1, code: "c")
      UmPerson.create!(email: "q@x", shop_id: 2, code: "c")
      [attempt { UmPerson.upsert_all([{ email: "a@x", name: "up", created_at: STAMP, updated_at: STAMP }], unique_by: :email).length },
       attempt { UmPerson.upsert_all([{ email: "a@x", shop_id: 2, code: "c", created_at: STAMP, updated_at: STAMP }], unique_by: :email) },
       operations(holder.id)]
    end
    assert_equal [1, ActiveRecord::RecordNotUnique, %i[created updated]], outcomes[:monitor][:result]
    assert_same_as_monitor(outcomes)
  end

  # The same, racing the holder's job: the job has written the holder's row
  # and not committed when the upsert runs. The row is taken, so the upsert
  # cannot bring it up to date, and it raises RecordNotUnique before anything
  # is written, rather than insert a second record with the value (a second
  # Created; the leftover listed after 1.0.0's unique-index work). Monitor's
  # INSERT would wait for the commit and update the row; ES-Async refuses.
  def test_upsert_all_by_the_unique_column_racing_the_holders_job
    use(:es_async)
    holder = UmPerson.create!(email: "a@x", name: "old").id
    projected = Queue.new
    go = Queue.new
    job = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        ActiveRecord::Base.transaction do
          Lyra::Projections::AsyncProjectionJob.project_pending(UmPerson, [holder]) # as the job does
          projected << true
          go.pop
        end
      end
    end
    projected.pop
    events = event_count
    begin
      result = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          attempt { UmPerson.upsert_all([{ email: "a@x", name: "up", created_at: STAMP, updated_at: STAMP }], unique_by: :email).length }
        end
      end.tap { _1.report_on_exception = false }
      outcome = Timeout.timeout(10) { result.value }
    ensure
      go << true # the job ends whatever the upsert did
      job.join(10)
    end
    settle

    assert_equal ActiveRecord::RecordNotUnique, outcome
    assert_equal events, event_count, "nothing appended"
    assert_equal %i[created], operations(holder)
    assert_equal 1, created_events, "no second record in the log"
    assert_equal [["a@x", "old"]], UmPerson.pluck(:email, :name)
    assert_projection_clean
  end

  # insert_all: a row with a value taken is left out (ON CONFLICT DO
  # NOTHING), the others inserted; with unique_by another index, raised.
  def test_insert_all_skips_or_raises_as_monitor
    outcomes = each_mode do
      UmPerson.create!(email: "a@x", shop_id: 1, code: "c")
      [attempt { UmPerson.insert_all([{ email: "a@x", created_at: STAMP, updated_at: STAMP },
                                      { email: "n@x", created_at: STAMP, updated_at: STAMP }]).length },
       attempt { UmPerson.insert_all([{ email: "a@x", shop_id: 9, code: "c", created_at: STAMP, updated_at: STAMP }],
                                     unique_by: %i[shop_id code]) }]
    end
    assert_equal [1, ActiveRecord::RecordNotUnique], outcomes[:monitor][:result]
    assert_same_as_monitor(outcomes)
  end

  # Two writers of one value, each past its before_create callbacks before
  # either appends: exactly one wins, as in Monitor. ES-Sync's value lock
  # makes the second check of the table wait for the first's commit;
  # ES-Async's and ES-Lazy's the second read of the value's stream.
  def test_two_concurrent_creates_of_one_value
    MODES.each do |mode|
      use(mode)
      results = race { UmPerson.create!(email: "r@x") }
      settle

      assert_equal 1, results.count(:saved), "#{mode}: #{results.inspect}"
      assert_equal 1, results.count { _1.is_a?(ActiveRecord::RecordNotUnique) }, "#{mode}: #{results.inspect}"
      assert_equal 1, UmPerson.where(email: "r@x").count, mode
      assert_equal 1, created_events, mode
    end
  end

  # A write through callbacks and an update_columns of one value race: one
  # wins (the bypass write takes the value's lock too).
  def test_a_save_and_an_update_columns_of_one_value
    MODES.each do |mode|
      use(mode)
      other = UmPerson.create!(email: "o@x")
      settle
      results = race(1) do |i|
        i.zero? ? UmPerson.create!(email: "r@x") : UmPerson.find(other.id).update_columns(email: "r@x")
      end
      settle

      assert_equal 1, results.count { [:saved, true].include?(_1) }, "#{mode}: #{results.inspect}"
      assert_equal 1, UmPerson.where(email: "r@x").count, mode
    end
  end

  # ES-Lazy: a refused duplicate leaves nothing for the catch-up to meet,
  # so reads of every model go on working.
  def test_es_lazy_reads_after_a_refused_duplicate
    use(:es_lazy)
    UmPerson.create!(email: "a@x")
    UmNote.create!(body: "n")
    assert_raises(ActiveRecord::RecordNotUnique) { UmPerson.create!(email: "a@x") }
    assert_raises(ActiveRecord::RecordNotUnique) { UmPerson.create!(email: "b@x").update!(email: "a@x") }

    assert_equal 1, UmNote.count
    assert_equal %w[a@x b@x], UmPerson.order(:email).pluck(:email)
    assert_projection_clean
  end

  # A refused write leaves the projection untouched in every mode: no row, no
  # event, no job, nothing logged as a failed projection.
  def test_a_refused_write_leaves_the_projection_untouched
    failures = []
    MODES.each do |mode|
      use(mode)
      Lyra.config.projection_error_handler = ->(error, *) { failures << [mode, error.class] }
      UmPerson.create!(email: "a@x")
      settle
      rows = connection.select_value("SELECT count(*) FROM #{TABLE}").to_i
      events = event_count
      jobs = held_jobs
      assert_raises(ActiveRecord::RecordNotUnique, mode) { UmPerson.create!(email: "a@x") }
      assert_equal [rows, events, jobs], [connection.select_value("SELECT count(*) FROM #{TABLE}").to_i, event_count, held_jobs], mode
      settle
      assert_projection_clean
    end
    assert_empty failures
  end

  # The cost: a model without a unique index, and a write that sets none of
  # the indexed columns, take no value lock and read no value stream; a
  # write that sets one takes one lock, and (ES-Async, ES-Lazy) reads the
  # value's stream and links it, (ES-Sync) reads the table.
  def test_the_check_costs_nothing_where_no_indexed_column_is_written
    %i[es_sync es_async es_lazy].each do |mode|
      use(mode)
      note = UmNote.create!(body: "a")
      person = UmPerson.create!(email: "p@x")
      settle
      plain = statements do
        UmNote.create!(body: "b")
        UmNote.find(note.id).update!(body: "c")
        UmPerson.find(person.id).update!(name: "n")
        UmPerson.find(person.id).update_columns(name: "m")
        UmPerson.where(id: person.id).update_all(name: "k")
        UmNote.find(note.id).destroy!
      end
      refute(plain.any? { _1.include?("lyra_unique/") || _1.include?("!email$") || _1.include?("Lyra unique") }, "#{mode}:\n#{plain.join("\n")}")

      set = statements { UmPerson.create!(email: "fresh@x") }
      assert_equal 1, set.count { _1.include?("pg_advisory_xact_lock(hashtext('lyra_unique/") }, mode
      if mode == :es_sync
        assert(set.any? { _1.include?(%(FROM "#{TABLE}" WHERE "#{TABLE}"."email")) }, set.join("\n"))
        refute(set.any? { _1.include?("UmPerson!") }, set.join("\n"))
      else
        assert(set.any? { _1.include?("WHERE stream = 'UmPerson!email$") }, set.join("\n"))
        assert(set.any? { _1.include?("Lyra value links") || _1.include?("INSERT INTO event_store_events_in_streams") }, set.join("\n"))
      end
    end
  end

  # ES-Async: the destroyed holder's row is held by another transaction
  # when the new record claims its value, so it is left to its job; the new
  # record's job runs first. Its create met the holder's row and inserted
  # nothing (ON CONFLICT DO NOTHING), and the job completed: the record was
  # in the log and never in the table. The job now fails and is retried, and
  # converges once the holder's job has run.
  def test_a_create_job_that_meets_a_holder_s_row_is_retried
    use(:es_async)
    holder = UmPerson.create!(email: "a@x")
    settle
    other = ActiveRecord::Base.connection_pool.checkout
    other.begin_db_transaction
    other.select_value("SELECT 1 FROM #{TABLE} WHERE id = #{holder.id} FOR UPDATE")
    begin
      Thread.new { ActiveRecord::Base.connection_pool.with_connection { UmPerson.find(holder.id).destroy! } }.join
      created = UmPerson.create!(email: "a@x")
      jobs = @adapter.enqueued_jobs.dup
      @adapter.enqueued_jobs.clear
      job = jobs.last # the new record's, first; more often than the general retry's five attempts
      waits = 7.times.map do
        ActiveJob::Base.execute(job.stringify_keys)
        job = @adapter.enqueued_jobs.pop

        refute_nil job, "retried, not done"
        assert_equal 0, @adapter.enqueued_jobs.size
        (job[:at] - Time.now.to_f).round
      end
      assert_operator waits.max, :<=, 300
      assert_nil connection.select_value("SELECT 1 FROM #{TABLE} WHERE id = #{created.id}")
    ensure
      other.commit_db_transaction
      ActiveRecord::Base.connection_pool.checkin(other)
    end
    jobs[0..-2].each { ActiveJob::Base.execute(_1.stringify_keys) }
    ActiveJob::Base.execute(job.stringify_keys) # the retry, after the holder's job
    settle

    assert_equal [[created.id, "a@x"]], connection.select_rows("SELECT id, email FROM #{TABLE}")
    assert_projection_clean
  end

  # ES-Async: the holder's own job is lost (failed for good). The new
  # record's job brings the holder's row up to date with its stream itself
  # (nothing holds it) and inserts, at the first attempt. With a live record
  # holding (1, NULL) in a two-column index, which conflicts with nothing,
  # the destroyed holder is still the one that lags.
  def test_a_create_job_brings_a_lagging_holder_up_to_date_itself
    use(:es_async)
    holder = UmPerson.create!(email: "a@x", shop_id: 1, code: nil)
    UmPerson.create!(email: "l@x", shop_id: 1, code: nil)
    settle
    other = ActiveRecord::Base.connection_pool.checkout
    other.begin_db_transaction
    other.select_value("SELECT 1 FROM #{TABLE} WHERE id = #{holder.id} FOR UPDATE")
    begin
      Thread.new { ActiveRecord::Base.connection_pool.with_connection { UmPerson.find(holder.id).destroy! } }.join
      created = UmPerson.create!(email: "a@x", shop_id: 1, code: nil)
    ensure
      other.commit_db_transaction
      ActiveRecord::Base.connection_pool.checkin(other)
    end
    job = @adapter.enqueued_jobs.pop # the new record's; the holder's is lost
    @adapter.enqueued_jobs.clear
    ActiveJob::Base.execute(job.stringify_keys)

    assert_empty @adapter.enqueued_jobs, "done at the first attempt"
    assert_equal %w[a@x l@x], connection.select_values("SELECT email FROM #{TABLE} ORDER BY email")
    assert_equal created.id, connection.select_value("SELECT id FROM #{TABLE} WHERE email = 'a@x'")
    assert_projection_clean
  end

  # A duplicate on an expression index (which Lyra does not check, nor read):
  # no holder is found, so it is a duplicate, not a lagging row; the job is
  # discarded and the duplicate reported once, not retried for ever.
  def test_a_create_job_that_meets_an_expression_index_is_discarded
    connection.execute("CREATE UNIQUE INDEX lyra_um_people_lower_name ON #{TABLE} (lower(name))")
    UmPerson.reset_column_information
    errors = []
    use(:es_async)
    Lyra.config.projection_error_handler = ->(error, *) { errors << error.class }
    UmPerson.create!(email: "a@x", name: "Ann")
    settle
    UmPerson.create!(email: "b@x", name: "ann")
    job = @adapter.enqueued_jobs.pop
    ActiveJob::Base.execute(job.stringify_keys)

    assert_empty @adapter.enqueued_jobs
    assert_equal [Lyra::Projections::DuplicateInLog], errors
  end

  # A create projected again (a replay) inserts nothing and raises nothing;
  # one that meets a live record's value (two records of the log holding it)
  # raises DuplicateInLog, which a job discards, except in ES-Lazy's
  # catch-up, where it is logged and the catch-up goes on. Reported once
  # per record and process, however often it is projected.
  def test_a_create_projected_over_another_record_s_value
    errors = []
    %i[es_sync es_lazy es_async].each do |mode|
      use(mode)
      Lyra.config.projection_error_handler = ->(error, *) { errors << [mode, error.class] }
      person = UmPerson.create!(email: "a@x")
      settle
      Lyra::Projections::Rebuild.replay_record(UmPerson, person.id)
      foreign = Struct.new(:events, :attributes, :success?, keyword_init: true)
                      .new(events: [], success?: true, attributes: { "id" => person.id + 1000, "email" => "a@x", "created_at" => STAMP, "updated_at" => STAMP })
      project = -> { Lyra::Projections::ModelProjection.project(UmPerson, :create, foreign, lyra_internal) }
      2.times do
        if mode == :es_lazy
          project.call
        else
          assert_raises(Lyra::Projections::DuplicateInLog) { UmPerson.transaction(requires_new: true) { project.call } }
        end
      end
      assert_equal 1, connection.select_value("SELECT count(*) FROM #{TABLE}").to_i, mode
    end
    assert_equal %i[es_sync es_lazy es_async].map { [_1, Lyra::Projections::DuplicateInLog] }, errors
    assert_includes Lyra::Projections::AsyncProjectionJob.rescue_handlers.map(&:first), "Lyra::Projections::DuplicateInLog"
  end

  # A record of an STI subclass whose type changed since: its create,
  # projected again (a job without checkpoints, a redelivered job, a
  # rebuild), finds its row under the table's class, not the subclass's,
  # and inserts nothing, raising nothing.
  def test_a_replayed_create_of_a_record_whose_type_changed
    connection.create_table(:lyra_um_kinds, force: true) do |t|
      t.string :type
      t.string :email
      t.index :email, unique: true
    end
    define_model(:UmKind, "lyra_um_kinds")
    Object.const_set(:UmKindA, Class.new(UmKind))
    Object.const_set(:UmKindB, Class.new(UmKind))
    %i[es_sync es_async es_lazy].each do |mode|
      use(mode)
      connection.execute("DELETE FROM lyra_um_kinds")
      record = UmKindA.create!(email: "k@x")
      settle
      UmKind.find(record.id).update!(type: "UmKindB")
      settle
      UmKind.count

      assert_equal 2, Lyra::Projections::Rebuild.replay_record(UmKindA, record.id), mode
      assert_equal [%w[UmKindB k@x]], connection.select_rows("SELECT type, email FROM lyra_um_kinds"), mode
    end
  ensure
    %i[UmKindA UmKindB UmKind].each { Object.send(:remove_const, _1) if Object.const_defined?(_1) }
    connection.drop_table(:lyra_um_kinds, if_exists: true)
  end

  # ES-Sync inside ReadYourWrites.with_guaranteed_read: the row is written at
  # once, as outside the block, so the block's reads see it and a second
  # create of its value is refused (the row was deferred to the block's end,
  # and the second create saved, its row dropped).
  def test_es_sync_inside_a_read_your_writes_block
    use(:es_sync)
    result = attempt do
      Lyra::Consistency::ReadYourWrites.with_guaranteed_read do
        UmPerson.create!(email: "g@x")
        assert_equal 1, UmPerson.where(email: "g@x").count
        UmPerson.create!(email: "g@x")
      end
    end

    assert_equal ActiveRecord::RecordNotUnique, result
    assert_equal 1, created_events
    assert_projection_clean
  end

  # ES-Sync under REPEATABLE READ: the check's SELECT reads the transaction's
  # snapshot, which misses a value committed after it began, and the
  # projection's INSERT then met the index. That error was logged inside the
  # aborted transaction, the save reported success and its COMMIT rolled the
  # event back. The write now fails, as Monitor's INSERT does.
  def test_es_sync_under_repeatable_read_fails_the_write
    use(:es_sync)
    started = Queue.new
    go = Queue.new
    first = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        UmPerson.transaction(isolation: :repeatable_read) do
          UmPerson.connection.select_value("SELECT count(*) FROM #{TABLE}")
          started << true
          go.pop(timeout: 5)
          UmPerson.create!(email: "rr@x")
        end
        :saved
      rescue ActiveRecord::RecordNotUnique, ActiveRecord::SerializationFailure => e
        e.class
      end
    end
    started.pop(timeout: 5)
    UmPerson.create!(email: "rr@x")
    go << true

    refute_equal :saved, first.value
    assert_equal 1, created_events
    assert_projection_clean
  end

  private

  def define_model(name, table)
    Object.send(:remove_const, name) if Object.const_defined?(name)
    Object.const_set(name, Class.new(ActiveRecord::Base) do
      self.table_name = table
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra

      cattr_accessor :before_create_hook
      before_create { before_create_hook&.call }
    end)
    Object.const_get(name).reset_column_information
    Lyra.config.monitor_model(Object.const_get(name))
  end

  def attempt
    result = yield
    result.is_a?(ActiveRecord::Base) || result == true ? :saved : result
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
    e.class
  end

  # The block's result in each mode; then the jobs run (ES-Async) or a read
  # catches up (ES-Lazy), and the records as the mode reads them, which the
  # table must hold too.
  def each_mode(&block)
    MODES.to_h do |mode|
      use(mode)
      result = block.call
      settle
      people = UmPerson.order(:email).map { [_1.email, _1.name, _1.shop_id, _1.code] }
      assert_projection_clean
      [mode, { result: result, people: people }]
    end
  end

  def assert_same_as_monitor(outcomes, label = nil)
    outcomes.each { |mode, outcome| assert_equal outcomes[:monitor], outcome, [mode, label].compact.join(" ") }
  end

  # The table as the log has it: DualView finds no difference for any
  # record the log or the table holds.
  def assert_projection_clean
    return if @mode == :monitor

    ids = connection.select_values("SELECT id FROM #{TABLE}").map(&:to_s)
    ids |= connection.select_values("SELECT DISTINCT stream FROM event_store_events_in_streams WHERE stream LIKE 'UmPerson$%'")
                     .map { _1.delete_prefix("UmPerson$") }
    ids.each { |id| assert_equal({}, Lyra::DualView.new(UmPerson, id).calculate_differences, "#{@mode} #{id}") }
  end

  def use(mode)
    clean
    @mode = mode
    case mode
    when :monitor then Lyra.config.enable_monitor!
    when :es_async
      @previous_adapter ||= ActiveJob::Base.queue_adapter
      @adapter = ActiveJob::QueueAdapters::TestAdapter.new
      @adapter.perform_enqueued_jobs = false
      ActiveJob::Base.queue_adapter = @adapter
      Lyra.config.enable_event_sourcing!
      Lyra.config.projection_mode = :async
      Lyra.config.async_projections_inline = false
    else
      Lyra.config.enable_event_sourcing!
      Lyra.config.projection_mode = { es_sync: :sync, es_lazy: :lazy }.fetch(mode)
    end
  end

  # ES-Async: run the jobs held, in the order enqueued; ES-Lazy: a read.
  def settle
    case @mode
    when :es_async
      until (jobs = @adapter.enqueued_jobs.dup).empty?
        @adapter.enqueued_jobs.clear
        jobs.each { |job| ActiveJob::Base.execute(job.stringify_keys) }
      end
    when :es_lazy then UmNote.count
    end
  end

  def held_jobs = @mode == :es_async ? @adapter.enqueued_jobs.size : 0

  # Runs +block+ in two threads, each in its own transaction on its own
  # connection; the thread +hooked+ (both when nil) waits in before_create
  # until the other is there too, so that without a lock both check before
  # either appends. :saved, the block's result, or the exception, per thread.
  def race(hooked = nil, timeout: 3, &block)
    arrived = Queue.new
    go = [Queue.new, Queue.new]
    waiting = hooked.nil? ? [0, 1] : [1 - hooked]
    UmPerson.before_create_hook = lambda do
      index = Thread.current[:um_race_index]
      next unless index

      arrived << index
      go[index].pop(timeout: timeout)
    end
    coordinator = Thread.new do
      waiting.size.times { arrived.pop(timeout: timeout * 2) }
      sleep 0.2 if hooked
      go.each { _1 << :go }
    end
    threads = 2.times.map do |i|
      Thread.new do
        Thread.current[:um_race_index] = i
        sleep 0.1 if hooked == i
        ActiveRecord::Base.connection_pool.with_connection do
          result = nil
          ActiveRecord::Base.transaction { result = block.call(i) }
          result.is_a?(ActiveRecord::Base) ? :saved : result
        rescue StandardError => e
          e
        end
      end
    end
    results = threads.map(&:value)
    coordinator.kill
    results
  ensure
    UmPerson.before_create_hook = nil
  end

  def statements(&block)
    sql = []
    callback = ->(*, payload) { sql << payload[:sql] }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record", &block)
    sql
  end

  def operations(id)
    Lyra.config.event_store.read.stream(Lyra.stream_name(UmPerson, id)).to_a.map { |e| Lyra::Event.operation_of(e) }
  end

  # How many records of UmPerson the log holds.
  def created_events
    connection.select_value("SELECT count(DISTINCT stream) FROM event_store_events_in_streams WHERE stream LIKE 'UmPerson$%'").to_i
  end

  def event_count = connection.select_value("SELECT count(*) FROM event_store_events").to_i

  def clean
    connection.execute("DELETE FROM #{TABLE}") if connection.table_exists?(TABLE)
    connection.execute("DELETE FROM lyra_um_notes") if connection.table_exists?(:lyra_um_notes)
    connection.execute("DELETE FROM event_store_events_in_streams")
    connection.execute("DELETE FROM event_store_events")
    Lyra::Projections::AsyncCheckpoint.reset!(connection)
    Lyra::Projections::LazyProjection.reset!(connection)
    Lyra::Projections::ReferenceLinks.reset!
    Lyra::Projections::Uniqueness::Snapshot.reset!
    %i[UmPerson UmNote].each do |name|
      Lyra::Projections::CachedProjection.invalidate_all(Object.const_get(name)) if Object.const_defined?(name)
    end
    Rails.cache.clear
  end

  def connection = ActiveRecord::Base.connection
end
