# frozen_string_literal: true

require "test_helper"

# A rebuild that clears a table (truncate: true, the default) deletes every
# row before the replay, and the database applies each foreign key's ON
# DELETE action to the rows that reference them. Up to 1.0.0 it did so
# without a word: the rows of an unmonitored table on an ON DELETE CASCADE
# key into the rebuilt one were deleted for good, SET NULL and SET DEFAULT
# references rewritten, and rows of the table with no stream deleted and not
# restored. A ModeTransition check with rebuild: true rebuilt (and committed)
# before it compared, so a check that failed had already changed the tables.
# From 1.0.1 the rebuild refuses, naming what would be lost, unless asked to
# clear anyway (force: true, FORCE=1), and a check that is not clean rolls
# its rebuild back.
class RebuildDataLossTest < Minitest::Test
  MT = Lyra::ModeTransition
  PARENTS = "lyra_rebuild_loss_parents"
  CHILDREN = "lyra_rebuild_loss_children" # no model: the application's own table
  ITEMS = "lyra_rebuild_loss_items"       # monitored

  def setup
    skip "Requires Rails and PostgreSQL" unless defined?(ActiveRecord::Base) && connection.adapter_name.match?(/postgres/i)

    [CHILDREN, ITEMS, PARENTS].each { connection.drop_table(_1, if_exists: true) }
    connection.create_table(PARENTS) do |t|
      t.string :name
      t.bigint :parent_id # a reference to the table itself
      t.timestamps
    end
    connection.create_table(CHILDREN) do |t|
      t.bigint :parent_id
      t.string :label
    end
    connection.create_table(ITEMS) do |t|
      t.bigint :parent_id
      t.string :label
      t.timestamps
    end
    clean
    define_model(:LossItem, ITEMS)
    define_model(:LossParent, PARENTS)
    Lyra.config.instance_variable_set(:@monitored_models, [LossParent])
    Lyra.config.enable_event_sourcing!
    Lyra.config.projection_mode = :sync
  end

  def teardown
    return unless defined?(LossParent)

    Lyra.reset_config!
    clean
    [CHILDREN, ITEMS, PARENTS].each { connection.drop_table(_1, if_exists: true) }
  end

  # --- foreign keys into the table -------------------------------------------

  def test_an_unmonitored_cascade_child_refuses_the_rebuild_and_survives
    parent = LossParent.create!(name: "Ann")
    child(parent.id, "kept")
    foreign_key(:cascade)

    error = assert_raises(Lyra::Projections::Rebuild::Refused) { Lyra::Projections::Rebuild.rebuild(LossParent) }

    assert_match(/refuses to clear #{PARENTS}/, error.message)
    assert_match(/1 row of #{CHILDREN} \(unmonitored; #{CHILDREN}.parent_id ON DELETE CASCADE, constraint loss_fk\)/,
                 error.message)
    assert_match(/truncate: false/, error.message)
    assert_match(/force: true/, error.message)
    assert_equal [[parent.id, "kept"]], children, "the child is still there"
    assert_equal ["Ann"], names, "and the parent row untouched"
  end

  def test_force_clears_the_table_anyway
    parent = LossParent.create!(name: "Ann")
    child(parent.id, "lost")
    foreign_key(:cascade)

    Lyra::Projections::Rebuild.rebuild(LossParent, force: true)

    assert_equal ["Ann"], names, "the parent is rebuilt from its events"
    assert_empty children, "what force: true asks for: the cascade deleted the child"
  end

  def test_truncate_false_rebuilds_in_place_and_keeps_the_child
    parent = LossParent.create!(name: "Ann")
    parent.update!(name: "Ann B")
    child(parent.id, "kept")
    foreign_key(:cascade)
    raw("UPDATE #{PARENTS} SET name = 'stale' WHERE id = #{parent.id}")

    Lyra::Projections::Rebuild.rebuild(LossParent, truncate: false)

    assert_equal ["Ann B"], names
    assert_equal [[parent.id, "kept"]], children
  end

  def test_set_null_and_set_default_references_refuse_the_rebuild
    { nullify: "SET NULL", default: "SET DEFAULT" }.each do |action, sql|
      raw("DELETE FROM #{CHILDREN}")
      raw("ALTER TABLE #{CHILDREN} DROP CONSTRAINT IF EXISTS loss_fk")
      parent = LossParent.create!(name: "Ann #{action}")
      child(parent.id, "kept")
      foreign_key(action)

      error = assert_raises(Lyra::Projections::Rebuild::Refused) { Lyra::Projections::Rebuild.rebuild(LossParent) }

      assert_match(/ON DELETE #{sql}, constraint loss_fk/, error.message)
      assert_includes children, [parent.id, "kept"], "the reference is not rewritten (#{sql})"
    end
  end

  def test_a_key_whose_table_has_no_referencing_row_does_not_refuse
    LossParent.create!(name: "Ann")
    raw("INSERT INTO #{CHILDREN} (parent_id, label) VALUES (NULL, 'references nothing')")
    foreign_key(:cascade)

    stats = Lyra::Projections::Rebuild.rebuild(LossParent)

    assert_equal 1, stats[:records]
    assert_equal [[nil, "references nothing"]], children
  end

  def test_a_reference_from_the_table_into_itself_does_not_refuse
    root = LossParent.create!(name: "root")
    LossParent.create!(name: "leaf", parent_id: root.id)
    raw("ALTER TABLE #{PARENTS} ADD CONSTRAINT loss_self_fk FOREIGN KEY (parent_id) REFERENCES #{PARENTS} (id) " \
        "ON DELETE CASCADE")

    Lyra::Projections::Rebuild.rebuild(LossParent)

    assert_equal %w[leaf root], names, "every row has a stream, and is replayed"
  end

  # A monitored child is restored only by its own rebuild, after the
  # parent's: a single rebuild does not do it, so it refuses too.
  def test_a_monitored_cascade_child_refuses_the_rebuild
    Lyra.config.monitor_model(LossItem)
    parent = LossParent.create!(name: "Ann")
    LossItem.create!(parent_id: parent.id, label: "item")
    raw("ALTER TABLE #{ITEMS} ADD CONSTRAINT loss_item_fk FOREIGN KEY (parent_id) REFERENCES #{PARENTS} (id) " \
        "ON DELETE CASCADE")

    error = assert_raises(Lyra::Projections::Rebuild::Refused) { Lyra::Projections::Rebuild.rebuild_all }

    assert_match(/1 row of #{ITEMS} \(monitored by LossItem, restored only by its own rebuild/, error.message)
    assert_equal 1, raw_value("SELECT count(*) FROM #{ITEMS}").to_i
  end

  # --- rows with no stream ---------------------------------------------------

  def test_a_row_with_no_stream_refuses_the_rebuild_and_survives
    LossParent.create!(name: "Ann")
    raw("INSERT INTO #{PARENTS} (id, name, created_at, updated_at) VALUES (900, 'never imported', now(), now())")

    error = assert_raises(Lyra::Projections::Rebuild::Refused) { Lyra::Projections::Rebuild.rebuild(LossParent) }

    assert_match(/1 row of #{PARENTS} with no event stream \(id 900; Lyra::Genesis imports them/, error.message)
    assert_equal ["Ann", "never imported"], names

    Lyra::Genesis.import_all(LossParent)
    Lyra::Projections::Rebuild.rebuild(LossParent)
    assert_equal ["Ann", "never imported"], names, "once imported it has a stream and is rebuilt"
  end

  def test_a_row_whose_record_the_log_destroys_is_not_a_hazard
    gone = LossParent.create!(name: "gone")
    gone.destroy!
    raw("INSERT INTO #{PARENTS} (id, name, created_at, updated_at) VALUES (#{gone.id}, 'gone', now(), now())")

    stats = Lyra::Projections::Rebuild.rebuild(LossParent)

    assert_equal 1, stats[:destroyed]
    assert_empty names, "deleted, as the log says"
  end

  def test_clear_hazards_lists_both
    parent = LossParent.create!(name: "Ann")
    child(parent.id, "kept")
    foreign_key(:cascade)
    raw("INSERT INTO #{PARENTS} (id, name, created_at, updated_at) VALUES (900, 'x', now(), now())")

    hazards = Lyra::Projections::Rebuild.clear_hazards(LossParent)

    assert_equal [[CHILDREN, "parent_id", "CASCADE", "loss_fk", 1]],
                 hazards[:references].map { _1.to_h.values_at(:from_table, :columns, :action, :name, :rows) }
    assert_equal 1, hazards[:streamless]
    assert_equal [900], hazards[:streamless_ids]
  end

  # --- the rake task ---------------------------------------------------------

  def test_rake_rebuild_by_default_refuses_and_keeps_the_child
    parent = LossParent.create!(name: "Ann")
    child(parent.id, "kept")
    foreign_key(:cascade)
    ENV["MODEL"] = "LossParent"

    _, err = capture_io do
      error = assert_raises(SystemExit) { rake("lyra:projections:rebuild") }
      refute error.success?
    end

    assert_match(/Lyra refuses to clear #{PARENTS}/, err)
    assert_equal [[parent.id, "kept"]], children

    ENV["TRUNCATE"] = "false"
    capture_io { rake("lyra:projections:rebuild") }
    assert_equal [[parent.id, "kept"]], children, "TRUNCATE=false keeps it"

    ENV.delete("TRUNCATE")
    ENV["FORCE"] = "1"
    capture_io { rake("lyra:projections:rebuild") }
    assert_empty children, "FORCE=1 clears the table anyway"
    assert_equal ["Ann"], names
  ensure
    %w[MODEL TRUNCATE FORCE].each { ENV.delete(_1) }
  end

  # --- ModeTransition.check(rebuild: true) -----------------------------------

  def test_a_check_that_fails_leaves_the_tables_as_they_were
    parent = lagging_parent

    # A discrepancy the rebuild does not repair (any check that is not clean).
    differs = ->(model, id) { MT::Discrepancy.new(model: model.name, id: id, problem: "row differs from its events") }
    report = MT.stub(:compare, differs) { MT.check(to: "monitor", from: "event_sourcing/disabled", rebuild: true) }

    refute report.clean?
    assert_equal 0, report.rebuilt, "nothing it rebuilt was kept"
    assert_equal ["Ann"], names, "the row still lags, as before the check"
    assert_nil raw_value("SELECT id FROM #{MT::TABLE} WHERE kind = 'certificate'"), "and nothing is certified"

    Lyra.config.mode_transition_gate = true
    MT.stub(:compare, differs) { assert_raises(MT::Refused) { MT.to!(:monitor, rebuild: true) } }
    assert_equal ["Ann"], names, "a refused switch leaves it too"
    assert_equal :event_sourcing, Lyra.config.mode

    report = MT.check(to: "monitor", from: "event_sourcing/disabled", rebuild: true)
    assert report.clean?, report.discrepancies.map(&:to_s).inspect
    assert_equal 1, report.rebuilt
    assert_equal ["Ann B"], names, "a clean check keeps its rebuild"
    assert_equal parent.id, raw_value("SELECT id FROM #{PARENTS}").to_i
  end

  def test_a_check_whose_rebuild_is_refused_changes_no_table
    parent = lagging_parent
    child(parent.id, "kept")
    foreign_key(:cascade)
    Lyra.config.mode_transition_gate = true

    error = assert_raises(MT::Refused) { MT.to!(:monitor, rebuild: true) }

    assert_match(/refuses to check event_sourcing\/disabled -> monitor with rebuild: true; no table was changed/,
                 error.message)
    assert_match(/#{CHILDREN}.parent_id ON DELETE CASCADE/, error.message)
    assert_equal ["Ann"], names
    assert_equal [[parent.id, "kept"]], children
    assert_equal :disabled, Lyra.config.projection_mode
  end

  private

  # A parent whose row lags its events, as in ES-NoProj: created in ES-Sync,
  # then renamed with projections off.
  def lagging_parent
    parent = LossParent.create!(name: "Ann")
    Lyra.config.projection_mode = :disabled
    LossParent.find(parent.id).update!(name: "Ann B")
    assert_equal ["Ann"], names, "precondition: the row lags"
    parent
  end

  def define_model(name, table)
    Object.send(:remove_const, name) if Object.const_defined?(name)
    klass = Class.new(ActiveRecord::Base)
    Object.const_set(name, klass)
    klass.table_name = table
    klass.include Lyra::Interceptors::CrudInterceptor
    klass.monitor_with_lyra
    klass.reset_column_information
    Lyra.config.monitor_model(klass)
  end

  def foreign_key(action)
    on_delete = { cascade: "CASCADE", nullify: "SET NULL", default: "SET DEFAULT" }.fetch(action)
    raw("ALTER TABLE #{CHILDREN} ADD CONSTRAINT loss_fk FOREIGN KEY (parent_id) REFERENCES #{PARENTS} (id) " \
        "ON DELETE #{on_delete}")
  end

  def child(parent_id, label)
    raw("INSERT INTO #{CHILDREN} (parent_id, label) VALUES (#{Integer(parent_id)}, #{connection.quote(label)})")
  end

  def children = connection.select_rows("SELECT parent_id, label FROM #{CHILDREN} ORDER BY id")

  def names = connection.select_values("SELECT name FROM #{PARENTS} ORDER BY name")

  def rake(task)
    require "rake"
    Rake.application = Rake::Application.new
    Rake::Task.define_task(:environment)
    load File.expand_path("../../lib/tasks/lyra_projections.rake", __dir__)
    Rake::Task[task].invoke
  end

  def raw(sql) = connection.execute(sql)

  def raw_value(sql) = connection.select_value(sql)

  def clean
    raw("DELETE FROM event_store_events_in_streams")
    raw("DELETE FROM event_store_events")
    raw("DELETE FROM #{MT::TABLE}") if connection.table_exists?(MT::TABLE)
  end

  def connection = ActiveRecord::Base.connection
end
