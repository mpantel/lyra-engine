# frozen_string_literal: true

require "test_helper"

# A monitored model whose single primary key is not "id" (a string column
# "code" here, with no id column at all). Every place Lyra reads or writes a
# record's row by its key uses the model's primary key: the dual view and the
# mode gate's compare, repair, rebuild and projection, Genesis, Hijack and
# event sourcing (which reserve the key before the event), and ES-NoProj
# reads. They used to look the row up by an "id" column the table does not
# have, so the compare raised instead of reporting.
#
# A composite primary key is not supported: enrolling such a model is
# refused with an error that says so.
class CustomPrimaryKeyTest < Minitest::Test
  TABLE = "lyra_custom_pk_items"

  def setup
    skip "Requires Rails and PostgreSQL" unless defined?(ActiveRecord::Base) && connection.adapter_name.match?(/postgres/i)

    connection.create_table(TABLE, id: :string, primary_key: "code", force: true) do |t|
      t.string :label
      t.integer :quantity
      t.timestamps
    end
    Object.send(:remove_const, :CustomPkItem) if defined?(CustomPkItem)
    klass = Class.new(ActiveRecord::Base)
    Object.const_set(:CustomPkItem, klass) # named before it is monitored: event names come from the name
    klass.table_name = TABLE
    klass.primary_key = "code"
    klass.include Lyra::Interceptors::CrudInterceptor
    klass.monitor_with_lyra
    klass.reset_column_information
    clean_events
    Lyra.config.monitor_model(klass)
  end

  def teardown
    return unless defined?(CustomPkItem)

    Lyra.config.projection_mode = :sync
    Lyra::Projections::CachedProjection.invalidate_all(CustomPkItem) rescue nil
    Lyra.reset_config!
    clean_events
    connection.drop_table(TABLE, if_exists: true)
  end

  # --- every mode: create, update, destroy; the row and its events agree -----

  def test_monitor_create_update_destroy_compare_clean
    Lyra.config.enable_monitor!
    assert_lifecycle_in_line
  end

  def test_hijack_create_update_destroy_compare_clean
    Lyra.config.enable_hijack!
    assert_lifecycle_in_line
  end

  def test_event_sourcing_create_update_destroy_compare_clean
    Lyra.config.enable_event_sourcing!
    Lyra.config.projection_mode = :sync
    assert_lifecycle_in_line
  end

  def test_es_noproj_create_update_destroy_reads_by_the_key
    es_noproj!

    item = CustomPkItem.create!(code: "A-1", label: "first", quantity: 1)
    assert_equal "A-1", item.code
    assert_equal "A-1", item.id
    assert_equal "first", CustomPkItem.find("A-1").label
    assert_equal "first", CustomPkItem.find_by(code: "A-1").label
    assert_equal ["A-1"], CustomPkItem.where(quantity: 1).map(&:code)

    CustomPkItem.find("A-1").update!(label: "second")
    assert_equal "second", CustomPkItem.find("A-1").label
    assert_equal({ "label" => "second", "quantity" => 1 }, state_of("A-1").slice("label", "quantity"))

    CustomPkItem.find("A-1").destroy!
    assert_nil CustomPkItem.find_by(code: "A-1")
    assert_raises(ActiveRecord::RecordNotFound) { CustomPkItem.find("A-1") }
    assert_equal 0, row_count, "ES-NoProj writes no row"
  end

  # The key the application gives is the key: Hijack and event sourcing
  # reserve a key only when none is given, and never put an "id" attribute
  # the table does not have into the event.
  def test_the_given_key_is_kept_in_the_event_and_the_row
    %i[hijack event_sourcing].each do |mode|
      mode == :hijack ? Lyra.config.enable_hijack! : Lyra.config.enable_event_sourcing!
      code = "K-#{mode}"
      CustomPkItem.create!(code: code, label: "x")

      assert_equal 1, CustomPkItem.where(code: code).count, "#{mode}: the row is under the given key"
      created = stream(code).find { Lyra::Event.operation_of(_1) == :created }
      assert created, "#{mode}: the created event is in the given key's stream"
      assert_equal code, created.data[:model_id]
      attributes = created.data[:attributes].stringify_keys
      assert_equal code, attributes["code"]
      refute attributes.key?("id"), "#{mode}: no id attribute in the event of a table without an id column"
    end
  end

  # --- a row changed behind Lyra's back is reported, not raised -------------

  def test_a_changed_row_is_reported_by_the_dual_view_and_the_gate
    Lyra.config.enable_monitor!
    CustomPkItem.create!(code: "B-1", label: "kept")
    connection.execute("UPDATE #{TABLE} SET label = 'tampered' WHERE code = 'B-1'")

    differences = Lyra::DualView.new(CustomPkItem, "B-1").compare[:differences]
    assert_equal ["label"], differences.keys
    assert_equal "tampered", differences["label"][:crud]
    assert_equal "kept", differences["label"][:event_sourced]

    problem = Lyra::ModeTransition.discrepancy(CustomPkItem, "B-1")
    assert_equal "row differs from its events", problem.problem
    assert_equal "B-1", problem.id

    found = Lyra::DualView.find_discrepancies(CustomPkItem)
    assert_equal ["B-1"], found.map { _1[:metadata][:model_id] }
  end

  def test_rows_and_events_out_of_step_are_reported
    Lyra.config.enable_monitor!
    CustomPkItem.create!(code: "C-1", label: "gone")
    connection.execute("DELETE FROM #{TABLE} WHERE code = 'C-1'")
    connection.execute("INSERT INTO #{TABLE} (code, label, created_at, updated_at) VALUES ('C-2', 'stray', now(), now())")

    assert_equal "events but no row", Lyra::ModeTransition.discrepancy(CustomPkItem, "C-1").problem
    assert_equal "row but no events", Lyra::ModeTransition.discrepancy(CustomPkItem, "C-2").problem
    assert_equal %w[C-1 C-2], Lyra::ModeTransition.record_ids(CustomPkItem)
  end

  def test_the_mode_check_runs_over_the_model
    Lyra.config.enable_monitor!
    CustomPkItem.create!(code: "D-1", label: "one")
    CustomPkItem.create!(code: "D-2", label: "two")
    connection.execute("UPDATE #{TABLE} SET label = 'tampered' WHERE code = 'D-2'")

    report = Lyra::ModeTransition.check(to: "event_sourcing", models: [CustomPkItem])

    assert_equal 2, report.checked
    assert_equal ["D-2"], report.discrepancies.map(&:id)
  end

  # --- repair, rebuild, genesis ---------------------------------------------

  def test_repair_brings_the_events_in_line_with_the_rows
    Lyra.config.enable_monitor!
    CustomPkItem.create!(code: "E-1", label: "before")
    CustomPkItem.create!(code: "E-2", label: "lost")
    connection.execute("UPDATE #{TABLE} SET label = 'after' WHERE code = 'E-1'")
    connection.execute("DELETE FROM #{TABLE} WHERE code = 'E-2'")
    connection.execute("INSERT INTO #{TABLE} (code, label, created_at, updated_at) VALUES ('E-3', 'new', now(), now())")

    result = Lyra::Repair.run(models: [CustomPkItem])

    assert_equal %w[E-1 E-2 E-3], result.found.map(&:id).sort
    assert_empty result.remaining
    %w[E-1 E-2 E-3].each { |code| assert_nil Lyra::ModeTransition.discrepancy(CustomPkItem, code) }
    assert_equal "after", state_of("E-1")["label"]
  end

  def test_rebuild_restores_the_rows_from_the_events
    Lyra.config.enable_event_sourcing!
    Lyra.config.projection_mode = :sync
    CustomPkItem.create!(code: "F-1", label: "one", quantity: 1)
    CustomPkItem.create!(code: "F-2", label: "two", quantity: 2)
    CustomPkItem.find("F-1").update!(label: "uno")
    CustomPkItem.find("F-2").destroy!
    before = rows

    Lyra::Projections::Rebuild.rebuild(CustomPkItem, truncate: true)

    assert_equal before, rows
    assert_equal [["F-1", "uno", 1]], rows.map { _1.values_at("code", "label", "quantity") }
    assert_nil Lyra::ModeTransition.discrepancy(CustomPkItem, "F-1")
    assert_nil Lyra::ModeTransition.discrepancy(CustomPkItem, "F-2")
  end

  def test_genesis_imports_rows_that_predate_lyra
    connection.execute(<<~SQL)
      INSERT INTO #{TABLE} (code, label, quantity, created_at, updated_at) VALUES
        ('G-1', 'a', 1, '2020-01-01 10:00:00', '2020-01-02 10:00:00'),
        ('G-2', 'b', 2, '2020-01-01 11:00:00', '2020-01-02 11:00:00')
    SQL
    es_noproj!

    assert_equal 3, CustomPkItem.sum(:quantity)
    imported = Lyra.config.event_store.read.to_a.select { Lyra::Event.operation_of(_1) == :imported }
    assert_equal %w[G-1 G-2], imported.map { _1.data[:model_id] }.sort
    assert_equal "a", CustomPkItem.find("G-1").label

    Lyra.config.enable_monitor!
    %w[G-1 G-2].each { |code| assert_nil Lyra::ModeTransition.discrepancy(CustomPkItem, code) }
  end

  # --- composite keys are refused --------------------------------------------

  def test_a_composite_primary_key_is_refused_at_enrolment
    klass = Class.new(ActiveRecord::Base) do
      def self.name = "CompositePkItem"
      self.table_name = TABLE
      self.primary_key = %i[code label]
      include Lyra::Interceptors::CrudInterceptor
    end

    error = assert_raises(ArgumentError) { klass.monitor_with_lyra }
    assert_match(/composite primary key/i, error.message)
    refute Lyra.config.monitored_models.include?(klass)
  end

  # A composite key the table declares (the model does not): config.models
  # reads it from the schema and refuses the model; :all never picks it.
  def test_a_composite_primary_key_of_the_table_is_refused_by_config_models
    connection.create_table("composite_pk_items", primary_key: %i[region number], force: true) do |t|
      t.string :region
      t.integer :number
      t.string :label
    end
    Object.send(:remove_const, :CompositePkItem) if defined?(CompositePkItem)
    Object.const_set(:CompositePkItem, Class.new(ActiveRecord::Base) do
      self.table_name = "composite_pk_items"
      include Lyra::Interceptors::CrudInterceptor
    end)

    spec = Lyra::ModelSelection.parse(%w[CompositePkItem])
    error = assert_raises(ArgumentError) { Lyra::ModelSelection.apply(spec) }
    assert_match(/CompositePkItem has a composite primary key \(region, number\)/, error.message)
    refute Lyra::ModelSelection.eligible?(CompositePkItem)
  ensure
    Object.send(:remove_const, :CompositePkItem) if defined?(CompositePkItem)
    connection.drop_table("composite_pk_items", if_exists: true)
  end

  # --- a uuid key Lyra reserves, and the past by the key -------------------

  def test_a_uuid_key_left_to_lyra_is_reserved_and_compares_clean
    connection.create_table("lyra_uuid_pk_items", id: :uuid, primary_key: "ref", default: nil, force: true) do |t|
      t.string :label
      t.timestamps
    end
    Object.send(:remove_const, :UuidPkItem) if defined?(UuidPkItem)
    klass = Class.new(ActiveRecord::Base)
    Object.const_set(:UuidPkItem, klass)
    klass.table_name = "lyra_uuid_pk_items"
    klass.include Lyra::Interceptors::CrudInterceptor
    klass.monitor_with_lyra

    %i[hijack event_sourcing].each do |mode|
      mode == :hijack ? Lyra.config.enable_hijack! : Lyra.config.enable_event_sourcing!
      item = UuidPkItem.create!(label: mode.to_s)

      assert_match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/, item.ref, "#{mode}: a reserved uuid")
      assert_equal mode.to_s, UuidPkItem.find(item.ref).label
      assert_nil Lyra::ModeTransition.discrepancy(UuidPkItem, item.ref), mode.to_s
      item.update!(label: "#{mode}2")
      assert_nil Lyra::ModeTransition.discrepancy(UuidPkItem, item.ref), mode.to_s
    end
  ensure
    Object.send(:remove_const, :UuidPkItem) if defined?(UuidPkItem)
    connection.drop_table("lyra_uuid_pk_items", if_exists: true)
  end

  def test_as_of_finds_a_record_by_its_key
    Lyra.config.enable_monitor!
    CustomPkItem.create!(code: "H-1", label: "then")
    sleep 0.01
    between = Time.current
    sleep 0.01
    CustomPkItem.find("H-1").update!(label: "now")

    assert_equal "then", CustomPkItem.as_of(between).find("H-1").label
    assert_equal "H-1", Lyra.state_at(CustomPkItem, "H-1", between)["code"]
    refute Lyra.state_at(CustomPkItem, "H-1", between).key?("id"), "no id key for a table without an id column"
  end

  private

  # Create, update and destroy one record, checking after each step that the
  # row and the events agree in every view that compares them.
  def assert_lifecycle_in_line
    item = CustomPkItem.create!(code: "Z-9", label: "first", quantity: 1)
    assert_equal "Z-9", item.id
    assert_equal 1, row_count
    assert_in_line("Z-9", "after create")
    assert_equal [{}], Lyra::DualView.compare_all(CustomPkItem).map { _1[:differences] }
    assert_empty Lyra::DualView.find_discrepancies(CustomPkItem)

    CustomPkItem.find("Z-9").update!(label: "second")
    assert_equal "second", connection.select_value("SELECT label FROM #{TABLE} WHERE code = 'Z-9'")
    assert_in_line("Z-9", "after update")

    CustomPkItem.find("Z-9").destroy!
    assert_equal 0, row_count
    assert_in_line("Z-9", "after destroy")
    assert_equal %w[Created Updated Destroyed], stream("Z-9").map { _1.event_type[/(Created|Updated|Destroyed)\z/] }
  end

  def assert_in_line(code, step)
    comparison = Lyra::DualView.new(CustomPkItem, code).compare
    assert_equal({}, comparison[:differences], "dual view #{step}")
    assert_nil Lyra::ModeTransition.discrepancy(CustomPkItem, code), "mode gate #{step}"
  end

  def es_noproj!
    Lyra.config.enable_event_sourcing!
    Lyra.config.projection_mode = :disabled
    Lyra::Projections::CachedProjection.invalidate_all(CustomPkItem)
  end

  def state_of(code) = Lyra::StateProjection.rebuild_state(CustomPkItem, code).stringify_keys

  def stream(code) = Lyra.config.event_store.read.stream("CustomPkItem$#{code}").to_a

  def rows = connection.select_all("SELECT code, label, quantity, created_at, updated_at FROM #{TABLE} ORDER BY code").to_a

  def row_count = connection.select_value("SELECT COUNT(*) FROM #{TABLE}").to_i

  def clean_events
    connection.execute("DELETE FROM event_store_events_in_streams")
    connection.execute("DELETE FROM event_store_events")
  end

  def connection = ActiveRecord::Base.connection
end
