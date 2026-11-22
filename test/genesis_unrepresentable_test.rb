# frozen_string_literal: true

require "test_helper"
require "rake"

# Genesis and stored values the model cannot represent (from 1.0.0). A row
# whose refund status is '2' under a string enum without that value is read
# as status nil; its Imported event would then disagree with the row, and the
# disagreement surfaced later, elsewhere (ES-Lazy's catch-up writing NULL
# into a NOT NULL column). Genesis checks every value first: by default it
# refuses the model's import, listing the rows; with :skip it leaves them out
# and reports them. Values the model does represent, in whatever form the
# database returns them, are no difference (one test per kind of column).
class GenesisUnrepresentableTest < Minitest::Test
  TABLE = "lyra_genesis_odd_items"
  TYPED = "lyra_genesis_typed_items"
  PARENTS = "lyra_genesis_odd_parents"

  def setup
    skip "Requires Rails and PostgreSQL" unless defined?(ActiveRecord::Base) && connection.adapter_name.match?(/postgres/i)

    ActiveRecord::Encryption.configure(primary_key: "p" * 32, deterministic_key: "d" * 32, key_derivation_salt: "s" * 32)
    connection.create_table(TABLE, force: true) do |t|
      t.string :status
      t.integer :stage
      t.decimal :amount, precision: 12, scale: 2
      t.timestamps
    end
    define_model(:GenesisOdd, TABLE) do
      enum :status, { requested: "requested", approved: "approved" }
      enum :stage, { draft: 0, sent: 1 }
    end
    @saved_genesis = Lyra.config.genesis_unrepresentable
    clean_events
  end

  def teardown
    return unless defined?(GenesisOdd)

    Lyra.config.genesis_unrepresentable = @saved_genesis
    Lyra.config.mode = :monitor
    Lyra.config.projection_mode = :sync
    Lyra.config.mode_transition_gate = nil
    Lyra.config.genesis = :auto
    Lyra::Genesis.reset!
    clean_events
    connection.execute("DELETE FROM #{Lyra::ModeTransition::TABLE}") if connection.table_exists?(Lyra::ModeTransition::TABLE)
    connection.drop_table(TABLE, if_exists: true)
    connection.drop_table(PARENTS, if_exists: true)
    connection.drop_table(TYPED, if_exists: true)
    Time.zone = "UTC"
  end

  # -- values outside an enum --------------------------------------------------

  def test_a_string_enum_value_outside_the_mapping_refuses_the_import_and_nothing_is_imported
    good = insert(TABLE, status: "'requested'", stage: "0")
    bad = insert(TABLE, status: "'2'", stage: "1")
    insert(TABLE, status: "'approved'", stage: "1")

    error = assert_raises(Lyra::Genesis::Refused) { Lyra::Genesis.import(GenesisOdd) }

    assert_equal "GenesisOdd", error.model
    assert_equal 1, error.rows
    assert_equal [["GenesisOdd", bad, "status", "2", nil]], error.values.map { [_1.model, _1.id, _1.attribute, _1.stored, _1.read_as] }
    assert_includes error.message, %(GenesisOdd #{bad}: status stored "2", read as nil)
    assert_includes error.message, "genesis_unrepresentable = :skip"
    assert_equal 0, events_count, "no partial import: the row imported before the bad one is rolled back"
    assert_empty stream(good)
  end

  def test_an_integer_enum_value_outside_the_mapping_refuses_the_import
    insert(TABLE, status: "'requested'", stage: "0")
    bad = insert(TABLE, status: "'approved'", stage: "5")

    error = assert_raises(Lyra::Genesis::Refused) { Lyra::Genesis.import_all(GenesisOdd) }

    assert_equal [["stage", 5, nil]], error.values.map { [_1.attribute, _1.stored, _1.read_as] }
    assert_includes error.message, %(GenesisOdd #{bad}: stage stored 5, read as nil)
    assert_equal 0, events_count
  end

  def test_with_skip_the_other_rows_are_imported_and_the_skipped_ones_reported
    good = insert(TABLE, status: "'requested'", stage: "0")
    bad = insert(TABLE, status: "'2'", stage: "7")
    later = insert(TABLE, status: "'approved'", stage: "1")

    result = Lyra::Genesis.import(GenesisOdd, unrepresentable: :skip)

    assert_equal 2, result.imported
    assert_equal 1, result.skipped
    assert_equal [[bad, "status"], [bad, "stage"]], result.unrepresentable.map { [_1.id, _1.attribute] }
    assert_match(/2 rows imported, 1 skipped/, result.summary)
    assert_equal 1, stream(good).size
    assert_equal 1, stream(later).size
    assert_empty stream(bad), "the skipped row has no stream"

    assert_equal 0, Lyra::Genesis.import_all(GenesisOdd, unrepresentable: "skip"), "a string is taken as its symbol"
  end

  def test_the_listing_is_capped_with_the_count
    (Lyra::Genesis::LISTED + 5).times { insert(TABLE, status: "'9'", stage: "0") }

    error = assert_raises(Lyra::Genesis::Refused) { Lyra::Genesis.import(GenesisOdd) }

    assert_equal Lyra::Genesis::LISTED + 5, error.rows
    assert_equal Lyra::Genesis::LISTED, error.values.size
    assert_includes error.message, "(and 5 more)"
  end

  def test_a_lossy_attribute_type_is_found_too
    define_model(:GenesisOdd, TABLE) { attribute :amount, :integer }
    insert(TABLE, amount: "10.00")
    bad = insert(TABLE, amount: "10.50")

    error = assert_raises(Lyra::Genesis::Refused) { Lyra::Genesis.import(GenesisOdd) }

    assert_equal [[bad, "amount", 10]], error.values.map { [_1.id, _1.attribute, _1.read_as] }
  end

  # Whatever the type, a stored value the model writes back as NULL is lost:
  # a blank or 'null' JSON text or an empty YAML hash in a serialized column
  # (its text is otherwise not compared: it has many encodings), a JSON null
  # in a jsonb column, an empty range. In a NOT NULL column a rebuild failed
  # on it; in a nullable one where(col: nil) would find the row afterwards.
  def test_a_value_written_back_as_null_is_found_whatever_the_type_and_column
    connection.add_column(TABLE, :prefs, :text, null: false, default: "{}")
    connection.add_column(TABLE, :options, :text, default: "---\na: 1\n")
    connection.add_column(TABLE, :data, :jsonb)
    connection.add_column(TABLE, :span, :int4range)
    define_model(:GenesisOdd, TABLE) do
      serialize :prefs, coder: JSON
      serialize :options, coder: YAML, type: Hash
    end
    insert(TABLE, prefs: "'{\"a\": 1}'", data: "'{\"a\": null}'", span: "'[1,5)'")
    blank = insert(TABLE, prefs: "''")
    null = insert(TABLE, prefs: "'null'")
    empty_hash = insert(TABLE, options: "''")
    yaml_default = insert(TABLE, options: "'--- {}\n'")
    json_null = insert(TABLE, data: "'null'")
    empty_range = insert(TABLE, span: "'empty'")

    error = assert_raises(Lyra::Genesis::Refused) { Lyra::Genesis.import(GenesisOdd) }

    assert_equal [[blank, "prefs"], [null, "prefs"], [empty_hash, "options"], [yaml_default, "options"],
                  [json_null, "data"], [empty_range, "span"]], error.values.map { [_1.id, _1.attribute] }
    assert_includes error.message, %(GenesisOdd #{blank}: prefs stored "", read as nil, which would be written back as NULL)
    assert_includes error.message, %(GenesisOdd #{empty_range}: span stored "empty", read as nil, which would be written back as NULL)
  end

  def test_a_value_out_of_the_models_range_is_said_so
    connection.add_column(TABLE, :big, :bigint)
    define_model(:GenesisOdd, TABLE) { attribute :big, :integer }
    insert(TABLE, big: "2147483647")
    bad = insert(TABLE, big: "9223372036854775807")

    error = assert_raises(Lyra::Genesis::Refused) { Lyra::Genesis.import(GenesisOdd) }

    assert_equal [bad], error.values.map(&:id)
    assert_includes error.message, %(GenesisOdd #{bad}: big stored 9223372036854775807: out of range for the model's type)
  end

  # Rails reads an inet value as the IPAddr of its network: 192.168.1.5/24
  # comes back as 192.168.1.0/24.
  def test_an_inet_value_whose_host_bits_rails_drops_is_found
    connection.add_column(TABLE, :ip, :inet)
    connection.add_column(TABLE, :ips, :inet, array: true)
    define_model(:GenesisOdd, TABLE)
    insert(TABLE, ip: "'192.168.1.0/24'", ips: "'{10.0.0.0/8,2001:db8::1}'")
    insert(TABLE, ip: "'10.1.2.3'")
    bad = insert(TABLE, ip: "'192.168.1.5/24'")
    bad_element = insert(TABLE, ips: "'{10.0.0.0/8,10.1.2.3/8}'")

    error = assert_raises(Lyra::Genesis::Refused) { Lyra::Genesis.import(GenesisOdd) }

    assert_equal [[bad, "ip"], [bad_element, "ips"]], error.values.map { [_1.id, _1.attribute] }
    assert_includes error.message, %(ip stored "192.168.1.5/24": host bits lost)
    assert_includes error.message, %(ips stored "{10.0.0.0/8,10.1.2.3/8}": host bits lost)
  end

  def test_import_one_logs_such_a_value_and_imports_the_row
    bad = insert(TABLE, status: "'2'", stage: "0")
    log = StringIO.new
    saved = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(log)

    assert Lyra::Genesis.import_one(GenesisOdd, bad), "an erasure does not fail on it"

    assert_equal 1, stream(bad).size
    assert_includes log.string, %(Lyra::Genesis imported a row of GenesisOdd holding values the model cannot represent: ) +
                                %(GenesisOdd #{bad}: status stored "2", read as nil)
  ensure
    Rails.logger = saved
  end

  def test_a_policy_declared_value_is_not_shown
    skip "Requires pam_dsl" unless Lyra.pam_dsl_available?

    PamDsl.reset!
    PamDsl.logger = Logger.new(nil)
    PamDsl.define_policy(:genesis_odd_policy) { field :status, type: :email, sensitivity: :confidential }
    define_model(:GenesisOdd, TABLE) { enum :status, { requested: "requested" } }
    GenesisOdd.monitor_with_lyra(privacy_policy: :genesis_odd_policy)
    bad = insert(TABLE, status: "'ann@example.com'")
    log = StringIO.new
    saved = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(log)

    error = assert_raises(Lyra::Genesis::Refused) { Lyra::Genesis.import(GenesisOdd) }
    result = Lyra::Genesis.import(GenesisOdd, unrepresentable: :skip)

    assert_includes error.message, "GenesisOdd #{bad}: status (a personal value, not shown)"
    assert_equal "GenesisOdd #{bad}: status (a personal value, not shown)", result.unrepresentable.sole.to_s
    [error.message, log.string].each { refute_includes _1, "ann@example.com" }
  ensure
    Rails.logger = saved if saved
    PamDsl.reset! if defined?(PamDsl)
    PamDsl.logger = nil if defined?(PamDsl)
  end

  def test_an_invalid_choice_is_rejected
    assert_raises(ArgumentError) { Lyra::Genesis.import(GenesisOdd, unrepresentable: :ignore) }
    assert_raises(ArgumentError) { Lyra.config.genesis_unrepresentable = :ignore }
    Lyra.config.genesis_unrepresentable = "skip"
    assert_equal :skip, Lyra.config.genesis_unrepresentable
  end

  # -- where Genesis runs ------------------------------------------------------

  def test_the_first_use_in_event_sourcing_refuses_until_the_row_is_fixed
    item = insert(TABLE, status: "'requested'", stage: "0")
    bad = insert(TABLE, status: "'2'", stage: "0")
    Lyra.config.enable_event_sourcing!
    Lyra.config.projection_mode = :sync

    assert_raises(Lyra::Genesis::Refused) { GenesisOdd.find(item).update!(stage: :sent) }
    assert_equal "draft", GenesisOdd.find(item).stage, "the write failed with the refusal"
    refute Lyra::Genesis.imported?(GenesisOdd)

    connection.execute("UPDATE #{TABLE} SET status = 'approved' WHERE id = #{bad}")
    error = assert_raises(Lyra::Genesis::Refused) { GenesisOdd.find(item).update!(stage: :sent) }
    assert_includes error.message, %(GenesisOdd #{bad}: status stored "2"), "the refusal is remembered, the table not scanned again"

    age_refusals(Lyra::Genesis::REFUSAL_RECHECK + 1)
    GenesisOdd.find(item).update!(stage: :sent)
    assert_equal %w[Imported Updated], stream(item).map { _1.event_type[/(Imported|Updated)\z/] }
    assert_equal "approved", stream(bad).first.data[:attributes]["status"]
  end

  # Refusing, every row is checked before anything is written; a repeated
  # first use does not scan the table again within REFUSAL_RECHECK, and an
  # explicit import (lyra:genesis) always does.
  def test_a_refused_first_use_writes_nothing_and_is_not_repeated_at_once
    insert(TABLE, status: "'requested'", stage: "0")
    bad = insert(TABLE, status: "'2'", stage: "0")
    Lyra.config.enable_event_sourcing!
    Lyra.config.projection_mode = :sync
    # Observed, not stubbed: other tests prepend modules to Lyra.append_events.
    published = 0
    unsubscribe = Lyra.config.event_store.subscribe_to_all_events(->(_event) { published += 1 })
    begin
      assert_raises(Lyra::Genesis::Refused) { Lyra::Genesis.first_use(GenesisOdd) }
    ensure
      unsubscribe.call
    end
    assert_equal 0, published, "nothing is written before the refusal (not written, then rolled back)"

    scans = 0
    counter = ->(*, payload) { scans += 1 if payload[:sql].to_s.include?("NOT EXISTS") && payload[:sql].include?(TABLE) }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
      3.times { assert_raises(Lyra::Genesis::Refused) { Lyra::Genesis.first_use(GenesisOdd) } }
    end
    assert_equal 0, scans, "the refusal is remembered"

    connection.execute("UPDATE #{TABLE} SET status = 'approved' WHERE id = #{bad}")
    assert_equal 2, Lyra::Genesis.import_all(GenesisOdd), "an explicit import scans"
    assert_equal 0, Lyra::Genesis.first_use(GenesisOdd), "and clears the refusal"
  end

  # The refusal is remembered from the scan that found it, not renewed by the
  # uses that raise it again: a process using the model every few seconds
  # scans again REFUSAL_RECHECK seconds after that scan, and picks up a row
  # fixed meanwhile.
  def test_the_remembered_refusal_is_not_renewed_by_its_uses
    item = insert(TABLE, status: "'requested'", stage: "0")
    bad = insert(TABLE, status: "'2'", stage: "0")
    Lyra.config.enable_event_sourcing!
    Lyra.config.projection_mode = :sync

    assert_raises(Lyra::Genesis::Refused) { GenesisOdd.find(item).update!(stage: :sent) }
    connection.execute("UPDATE #{TABLE} SET status = 'approved' WHERE id = #{bad}")
    age_refusals(20)
    assert_raises(Lyra::Genesis::Refused) { GenesisOdd.find(item).update!(stage: :sent) }
    age_refusals(20) # 40 s after the scan, 20 s after the last use

    GenesisOdd.find(item).update!(stage: :sent)
    assert_equal %w[Imported Updated], stream(item).map { _1.event_type[/(Imported|Updated)\z/] }
  end

  # A write that bypasses callbacks records an event per row too: it admits
  # its rows first. A row an import skipped is refused (the write with it, no
  # event, the row unchanged, still skipped); once fixed by SQL, the next
  # such write imports it before its own event.
  %i[sync async lazy].each do |projection|
    define_method(:"test_bypass_writes_to_a_skipped_row_are_refused_in_es_#{projection}") do
      assert_bypass_writes_refused(projection)
    end
  end

  # dependent: :nullify writes every child's foreign key in one statement and
  # records an event per child. In Monitor a skipped child is logged and gets
  # no event, but the other children still get theirs (the loop stopped at the
  # first refusal and left a nulled key with no event). Where events are
  # required the whole destroy is refused before anything is written.
  def test_nullify_records_every_other_child_in_monitor_and_refuses_in_event_sourcing
    connection.create_table(PARENTS, force: true) { |t| t.string :name }
    connection.add_column(TABLE, :parent_id, :bigint)
    define_model(:GenesisOdd, TABLE) { enum :status, { requested: "requested", approved: "approved" } }
    Object.send(:remove_const, :GenesisOddParent) if defined?(GenesisOddParent)
    Object.const_set(:GenesisOddParent, Class.new(ActiveRecord::Base) do
      self.table_name = PARENTS
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
      has_many :children, class_name: "GenesisOdd", foreign_key: :parent_id, dependent: :nullify
    end)
    Lyra.config.genesis_unrepresentable = :skip

    # Monitor, Genesis on: the skipped child first.
    Lyra.config.mode = :monitor
    Lyra.config.genesis = true
    parent = connection.select_value("INSERT INTO #{PARENTS} (name) VALUES ('p') RETURNING id").to_i
    bad = insert(TABLE, status: "'2'", stage: "0", parent_id: parent)
    good = insert(TABLE, status: "'requested'", stage: "0", parent_id: parent)
    Rails.logger.stub(:error, nil) { GenesisOddParent.find(parent).destroy! }

    assert_equal [nil, nil], connection.select_values("SELECT parent_id FROM #{TABLE} WHERE id IN (#{bad}, #{good}) ORDER BY id")
    assert_equal [{ "parent_id" => [parent, nil] }], stream(good).select { _1.event_type.end_with?("Updated") }.map { _1.data[:changes].transform_keys(&:to_s) }
    assert_empty stream(bad)
    assert Lyra::Genesis.skipped?(GenesisOdd, bad)

    # Event sourcing: refused as a whole.
    clean_events
    Lyra::Genesis.reset!
    Lyra.config.genesis = :auto
    parent = connection.select_value("INSERT INTO #{PARENTS} (name) VALUES ('q') RETURNING id").to_i
    connection.execute("UPDATE #{TABLE} SET parent_id = #{parent}")
    Lyra.config.enable_event_sourcing!
    Lyra.config.projection_mode = :sync
    GenesisOdd.find(good).update!(stage: :sent) # the first use skips the bad row
    count = stream(good).size

    error = assert_raises(Lyra::Genesis::Refused) { GenesisOddParent.find(parent).destroy! }
    assert_includes error.message, %(GenesisOdd #{bad}: status stored "2", read as nil)
    assert_equal [parent, parent], connection.select_values("SELECT parent_id FROM #{TABLE} ORDER BY id").map(&:to_i)
    assert_equal count, stream(good).size, "nothing written"
    assert_empty stream(bad)
  ensure
    Object.send(:remove_const, :GenesisOddParent) if defined?(GenesisOddParent)
  end

  # In ES-NoProj a skipped row has no stream, so a bulk write over the
  # records does not see it: it gets no event and stays skipped.
  def test_a_bulk_write_in_es_noproj_does_not_reach_a_skipped_row
    good = insert(TABLE, status: "'requested'", stage: "0")
    bad = insert(TABLE, status: "'2'", stage: "0")
    Lyra.config.genesis_unrepresentable = :skip
    Lyra.config.enable_event_sourcing!
    Lyra.config.projection_mode = :disabled

    GenesisOdd.where(stage: "draft").update_all(stage: 1)

    assert_equal %w[Imported Updated], stream(good).map { _1.event_type[/(Imported|Updated)\z/] }
    assert_empty stream(bad)
    assert Lyra::Genesis.skipped?(GenesisOdd, bad)
  end

  # Before a model's first use, a bulk write imports the rows that predate
  # Lyra first, as a write through callbacks does: no stream begins with the
  # bulk write's Updated event.
  def test_a_bulk_write_as_the_first_use_imports_first
    item = insert(TABLE, status: "'requested'", stage: "0")
    Lyra.config.enable_event_sourcing!
    Lyra.config.projection_mode = :sync

    GenesisOdd.where(id: item).update_all(stage: 1)

    assert_equal %w[Imported Updated], stream(item).map { _1.event_type[/(Imported|Updated)\z/] }
  end

  # Inside a caller's transaction the import is a savepoint: a refusal the
  # caller rescues leaves nothing imported when the caller commits.
  def test_a_refusal_rescued_inside_a_transaction_leaves_nothing_imported
    insert(TABLE, status: "'requested'", stage: "0")
    insert(TABLE, status: "'approved'", stage: "1")
    insert(TABLE, status: "'2'", stage: "0")

    ActiveRecord::Base.transaction do
      Lyra::Genesis.import(GenesisOdd)
    rescue Lyra::Genesis::Refused
      nil
    end

    assert_equal 0, events_count
  end

  # A row skipped with :skip has no Imported event: a write or an ES-NoProj
  # read of it is refused while it holds the value, and imports it once it
  # is fixed, so its stream never begins with an Updated event.
  def test_a_skipped_row_is_refused_on_write_and_read_and_imported_once_fixed
    good = insert(TABLE, status: "'requested'", stage: "0")
    bad = insert(TABLE, status: "'2'", stage: "0")
    Lyra.config.genesis_unrepresentable = :skip
    Lyra.config.enable_event_sourcing!
    Lyra.config.projection_mode = :sync

    GenesisOdd.find(good).update!(stage: :sent)
    assert Lyra::Genesis.skipped?(GenesisOdd, bad)
    error = assert_raises(Lyra::Genesis::Refused) { GenesisOdd.find(bad).update!(stage: :sent) }
    assert_equal bad.to_s, error.id.to_s
    assert_includes error.message, %(left GenesisOdd #{bad} without events)
    assert_includes error.message, %(GenesisOdd #{bad}: status stored "2", read as nil)
    assert_empty stream(bad)
    assert_equal 0, connection.select_value("SELECT stage FROM #{TABLE} WHERE id = #{bad}").to_i, "the write failed"

    Lyra.config.projection_mode = :disabled
    assert_raises(Lyra::Genesis::Refused) { Lyra::Projections::EventStoreReader.find(GenesisOdd, bad) }

    Lyra.config.projection_mode = :sync
    connection.execute("UPDATE #{TABLE} SET status = 'approved' WHERE id = #{bad}")
    GenesisOdd.find(bad).update!(stage: :sent)
    assert_equal %w[Imported Updated], stream(bad).map { _1.event_type[/(Imported|Updated)\z/] }
    assert_equal "approved", stream(bad).first.data[:attributes]["status"]
    refute Lyra::Genesis.skipped?(GenesisOdd, bad)
  end

  def test_the_first_use_skips_with_the_configuration
    item = insert(TABLE, status: "'requested'", stage: "0")
    bad = insert(TABLE, status: "'2'", stage: "0")
    Lyra.config.genesis_unrepresentable = :skip
    Lyra.config.enable_event_sourcing!
    Lyra.config.projection_mode = :sync

    GenesisOdd.find(item).update!(stage: :sent)

    assert_equal 2, stream(item).size
    assert_empty stream(bad)
  end

  def test_a_gated_switch_into_event_sourcing_is_refused_with_the_listing
    insert(TABLE, status: "'requested'", stage: "0")
    bad = insert(TABLE, status: "'2'", stage: "0")
    Lyra.config.instance_variable_set(:@monitored_models, [GenesisOdd])
    Lyra.config.mode_transition_gate = true
    Lyra.config.mode = :monitor
    Lyra.config.genesis_unrepresentable = :skip # a switch needs every row: it refuses all the same

    error = assert_raises(Lyra::ModeTransition::Refused) { Lyra::ModeTransition.to!(:event_sourcing, projection_mode: :sync) }

    assert_equal :monitor, Lyra.config.mode
    assert_includes error.message, %(GenesisOdd #{bad}: a value the model cannot represent (status stored "2", read as nil))
    assert_equal 1, error.report.unrepresentable
    assert_equal 1, error.report.discrepancies.size, "the model's rows are not also listed as rows without events"
    assert_match(/1 rows with values their model cannot represent/, error.report.summary)
    assert_equal 0, events_count

    connection.execute("UPDATE #{TABLE} SET status = 'approved' WHERE id = #{bad}")
    report = Lyra::ModeTransition.to!(:event_sourcing, projection_mode: :sync)
    assert report.clean?, report.discrepancies.map(&:to_s).inspect
    assert_equal 2, report.imported
  ensure
    Lyra.config.instance_variable_set(:@monitored_models, [])
  end

  def test_the_rake_task_lists_a_refused_model_and_exits_1_or_skips_with_unrepresentable_skip
    insert(TABLE, status: "'requested'", stage: "0")
    bad = insert(TABLE, status: "'2'", stage: "0")

    out, = capture_io { assert_raises(SystemExit) { run_genesis_task } }
    assert_match(/GenesisOdd\s+refused: 1 rows hold values the model cannot represent; nothing imported/, out)
    assert_includes out, %(GenesisOdd #{bad}: status stored "2", read as nil)
    assert_equal 0, events_count

    out, = capture_io { run_genesis_task("UNREPRESENTABLE" => "skip") }
    assert_match(/GenesisOdd\s+1 rows imported, 1 skipped/, out)
    assert_includes out, %(GenesisOdd #{bad}: status stored "2", read as nil)
    assert_match(/Done\./, out)
  end

  def test_a_policy_declared_or_encrypted_value_is_not_shown
    connection.add_column(TABLE, :code, :text)
    define_model(:GenesisOdd, TABLE) do
      encrypts :code
      enum :code, { alpha: "alpha" }
    end
    ciphertext = GenesisOdd.type_for_attribute("code").subtype.serialize("omega")
    bad = insert(TABLE, code: connection.quote(ciphertext))

    error = assert_raises(Lyra::Genesis::Refused) { Lyra::Genesis.import(GenesisOdd) }

    assert_equal [[bad, "code", nil]], error.values.map { [_1.id, _1.attribute, _1.read_as] }
    assert_includes error.message, "code (a personal value, not shown)"
    refute_includes error.message, "omega"
    refute_includes error.message, ciphertext
  end

  # -- Lyra::Repair ------------------------------------------------------------
  #
  # Repair writes a row as its model reads it (an Imported event for a row
  # without events, an Updated event for the changed columns): the same check,
  # the same policy.

  def test_repair_refuses_a_row_with_a_string_enum_value_outside_the_mapping_and_writes_nothing
    Lyra.config.mode = :monitor
    good = insert(TABLE, status: "'requested'", stage: "0")
    bad = insert(TABLE, status: "'2'", stage: "0")

    error = assert_raises(Lyra::Repair::Unrepresentable) { Lyra::Repair.run(models: [GenesisOdd]) }

    assert_equal 1, error.rows
    assert_includes error.message, %(GenesisOdd #{bad}: status stored "2", read as nil)
    assert_includes error.message, "UNREPRESENTABLE=skip"
    assert_equal 0, events_count, "nothing repaired, the good row neither"
    assert_kind_of Lyra::Repair::Refused, error, "lyra:repair's rescue reports it"
    assert_empty stream(good)
  end

  def test_repair_refuses_an_integer_enum_value_outside_the_mapping_in_an_update
    Lyra.config.mode = :monitor
    item = GenesisOdd.create!(status: :requested, stage: :draft)
    connection.execute("UPDATE #{TABLE} SET stage = 5 WHERE id = #{item.id}")

    error = assert_raises(Lyra::Repair::Unrepresentable) { Lyra::Repair.run(models: [GenesisOdd]) }

    assert_equal [[item.id, "stage", 5, nil]], error.values.map { [_1.id, _1.attribute, _1.stored, _1.read_as] }
    assert_equal 1, stream(item.id).size, "no Updated event with stage nil"
    assert_raises(Lyra::Repair::Unrepresentable) { Lyra::Repair.repair(GenesisOdd, item.id.to_s) }
  end

  def test_repair_with_skip_repairs_the_rest_and_reports_the_skipped_records
    Lyra.config.mode = :monitor
    good = insert(TABLE, status: "'approved'", stage: "1")
    bad = insert(TABLE, status: "'2'", stage: "0")

    dry = Lyra::Repair.run(models: [GenesisOdd], dry_run: true)
    assert_equal [[bad, "status"]], dry.unrepresentable.map { [_1.id, _1.attribute] }, "a dry run lists, never raises"
    assert_equal 0, events_count

    result = Lyra::Repair.run(models: [GenesisOdd], unrepresentable: :skip)

    assert_equal [good.to_s], result.repaired.map { _1.id.to_s }
    assert_equal [bad.to_s], result.remaining.map { _1.id.to_s }
    assert_equal 1, result.skipped
    assert_match(/1 with values their model cannot represent \(not repaired\)/, result.summary)
    assert_equal "imported", stream(good).sole.data[:operation].to_s
    assert_empty stream(bad)
  end

  # The changed columns are DualView's differences: computed once for the
  # check and the Updated event, beside the discrepancy check itself.
  def test_repair_of_an_update_compares_once_for_the_check_and_the_event
    Lyra.config.mode = :monitor
    item = GenesisOdd.create!(status: :requested, stage: :draft)
    connection.execute("UPDATE #{TABLE} SET status = 'approved' WHERE id = #{item.id}")
    calls = 0
    original = Lyra::DualView.instance_method(:compare)
    Lyra::DualView.define_method(:compare) do |*args, **kwargs|
      calls += 1
      original.bind_call(self, *args, **kwargs)
    end

    assert Lyra::Repair.repair(GenesisOdd, item.id.to_s)

    assert_equal 2, calls, "the discrepancy, then the differences once"
    assert_equal({ "status" => %w[requested approved] }, stream(item.id).last.data[:changes].transform_keys(&:to_s))
  ensure
    Lyra::DualView.define_method(:compare, original) if original
  end

  def test_repair_of_a_normal_row_is_not_refused
    Lyra.config.mode = :monitor
    row = insert(TABLE, status: "'approved'", stage: "1", amount: "10.50")
    item = GenesisOdd.create!(status: :requested, stage: :draft)
    connection.execute("UPDATE #{TABLE} SET status = 'approved', amount = 7.10 WHERE id = #{item.id}")

    result = Lyra::Repair.run(models: [GenesisOdd])

    assert_equal [row.to_s, item.id.to_s].sort, result.repaired.map { _1.id.to_s }.sort
    assert_empty result.remaining
    assert_equal 0, result.skipped
  end

  def test_lyra_repair_reports_the_values_refused_or_skipped
    Lyra.config.mode = :monitor
    insert(TABLE, status: "'requested'", stage: "0")
    bad = insert(TABLE, status: "'2'", stage: "0")

    _, err = capture_io { assert_raises(SystemExit) { run_task("lyra:repair", "lyra_mode.rake", "MODELS" => "GenesisOdd") } }
    assert_includes err, %(GenesisOdd #{bad}: status stored "2", read as nil)
    assert_equal 0, events_count

    out, = capture_io do
      assert_raises(SystemExit) { run_task("lyra:repair", "lyra_mode.rake", "MODELS" => "GenesisOdd", "UNREPRESENTABLE" => "skip") }
    end
    assert_match(/1 repaired, 1 still out of line, 1 with values their model cannot represent/, out)
    assert_includes out, "Values their model cannot represent (not repaired):"
    assert_includes out, %(GenesisOdd #{bad}: status stored "2", read as nil)
  end

  # -- no false positives ------------------------------------------------------
  #
  # Each kind of column, holding a value the model represents in a form other
  # than the one it would write: one row, imported under :refuse.

  TYPED_COLUMNS = {
    string_enum: [:string, "'approved'"],
    integer_enum: [:integer, "1"],
    timestamp: [:datetime, "'2020-01-01 23:30:00.123456'"],
    timestamp_without_precision: [:datetime, "'2020-01-01 10:00:00'", { precision: 0 }],
    timestamptz: [:timestamptz, "'2020-06-30 23:30:00.5+03'"],
    date: [:date, "'2020-02-29'"],
    time: [:time, "'23:30:00.25'"],
    decimal: [:decimal, "10.10", { precision: 12, scale: 4 }],
    decimal_unbounded: [:decimal, "'1.2300'"],
    decimal_nan: [:decimal, "'NaN'"],
    float: [:float, "1.1"],
    float_nan: [:float, "'NaN'"],
    float_infinity: [:float, "'Infinity'"],
    json: [:json, %('{"b": 1,  "a": [1, 2.0, null]}')],
    jsonb: [:jsonb, %('{"z": {"y": 1, "x": [true]}, "a": 1.50}')],
    serialized_json: [:text, %('{ "x" :  [1, "y"] }')],
    serialized_yaml: [:text, %('---\nk:   v\nlist: [1, 2]\n')],
    encrypted: [:text, nil],
    integer_array: [:integer, "'{1,2,NULL}'", { array: true }],
    string_array: [:string, %q('{a,"b c",NULL,"NULL"}'), { array: true }],
    boolean_true: [:boolean, "'t'"],
    boolean_false: [:boolean, "false"],
    uuid: [:uuid, "'A0EEBC99-9C0B-4EF8-BB6D-6BB9BD380A11'"],
    inet: [:inet, "'10.0.0.0/8'"],
    money: [:money, "12.3"],
    interval: [:interval, "'1 day 2 hours'"],
    int_range: [:int4range, "'[1,10]'"],
    bytea: [:binary, "'\\x00ff'"],
    char_padded: ["character(5)", "'ab'"],
    text_with_spaces_and_case: [:text, "'  Mixed Case  '"],
    normalized: [:string, "'  untrimmed '"],
    string_over_integer: [:integer, "7"],
    ignored: [:string, "'anything'"],
    json_over_text: [:text, %('{ "a" :  1 }')],
    inet_host: [:inet, "'192.168.1.5'"],
    inet_network: [:inet, "'192.168.1.0/24'"],
    bigint: [:bigint, "9223372036854775807"]
  }.freeze

  TYPED_COLUMNS.each_key do |name|
    define_method(:"test_no_false_positive_for_#{name}") { assert_round_trips(name) }
  end

  private

  def connection = ActiveRecord::Base.connection

  def define_model(name, table, &block)
    Object.send(:remove_const, name) if Object.const_defined?(name)
    model = Class.new(ActiveRecord::Base) do
      self.table_name = table
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
    end
    Object.const_set(name, model)
    model.class_eval(&block) if block
    model.reset_column_information
    model
  end

  # In a time zone east of UTC and one west of it (a negative offset), not
  # the database's UTC.
  def assert_round_trips(name)
    %w[Athens America/Sao_Paulo].each do |zone|
      Time.zone = zone
      clean_events
      assert_round_trips_in(name, zone)
    end
  end

  def assert_round_trips_in(name, zone)
    connection.create_table(TYPED, force: true) do |t|
      TYPED_COLUMNS.each { |column, (type, _, options)| t.column column, type, **(options || {}) }
    end
    define_model(:GenesisTyped, TYPED) do
      self.ignored_columns += ["ignored"]
      enum :string_enum, { pending: "pending", approved: "approved" }
      enum :integer_enum, { draft: 0, sent: 1 }
      serialize :serialized_json, coder: JSON
      serialize :serialized_yaml, coder: YAML
      encrypts :encrypted
      normalizes :normalized, with: ->(value) { value.strip }
      attribute :string_over_integer, :string
      attribute :json_over_text, :json
    end
    value = TYPED_COLUMNS[name][1] || connection.quote(GenesisTyped.type_for_attribute("encrypted").serialize("secret"))
    id = insert(TYPED, name => value)

    result = Lyra::Genesis.import(GenesisTyped)

    assert_equal [1, 0], [result.imported, result.skipped], "#{name} in #{zone}: #{result.unrepresentable.map(&:to_s)}"
    assert_equal 1, stream(id, "GenesisTyped").size
  end

  def insert(table, values)
    values = values.merge(created_at: "now()", updated_at: "now()") if table == TABLE
    connection.select_value(
      "INSERT INTO #{table} (#{values.keys.join(', ')}) VALUES (#{values.values.join(', ')}) RETURNING id"
    ).to_i
  end

  def run_genesis_task(env = {}) = run_task("lyra:genesis", "lyra_projections.rake", { "MODEL" => "GenesisOdd" }.merge(env))

  def run_task(name, file, env)
    saved = %w[MODEL MODELS UNREPRESENTABLE DRY_RUN].to_h { [_1, ENV[_1]] }
    saved.each_key { ENV.delete(_1) }
    ENV.update(env)
    rake = Rake::Application.new
    Rake.application = rake
    Rake::Task.define_task(:environment)
    load File.expand_path("../lib/tasks/#{file}", __dir__)
    rake[name].invoke
  ensure
    saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    Rake.application = nil
  end

  def assert_bypass_writes_refused(projection)
    good = insert(TABLE, status: "'requested'", stage: "0")
    bad = insert(TABLE, status: "'2'", stage: "0")
    Lyra.config.genesis_unrepresentable = :skip
    Lyra.config.enable_event_sourcing!
    Lyra.config.projection_mode = projection
    GenesisOdd.find(good).update!(stage: :sent) # the first use skips the bad row
    assert Lyra::Genesis.skipped?(GenesisOdd, bad)
    good_events = stream(good).size

    writes = {
      update_all: -> { GenesisOdd.where(id: bad).update_all(stage: 1) },
      touch_all: -> { GenesisOdd.where(id: bad).touch_all },
      delete_all: -> { GenesisOdd.where(id: bad).delete_all },
      update_columns: -> { GenesisOdd.find(bad).update_columns(stage: 1) },
      both_rows: -> { GenesisOdd.where(id: [good, bad]).update_all(stage: 1) }
    }
    writes.each do |name, write|
      error = assert_raises(Lyra::Genesis::Refused, "#{name} in es_#{projection}") { write.call }
      assert_equal [bad.to_s], Array(error.id).map(&:to_s), name
      assert_includes error.message, %(GenesisOdd #{bad}: status stored "2", read as nil), name
    end
    assert_empty stream(bad), "no bypass event began its stream"
    assert Lyra::Genesis.skipped?(GenesisOdd, bad), "still skipped"
    assert_equal [0], connection.select_values("SELECT stage FROM #{TABLE} WHERE id = #{bad}").map(&:to_i), "the row is unchanged"
    assert_equal good_events, stream(good).size, "the refused bulk write wrote nothing for the other row"

    connection.execute("UPDATE #{TABLE} SET status = 'approved' WHERE id = #{bad}")
    GenesisOdd.where(id: bad).update_all(stage: 1)
    assert_equal %w[Imported Updated], stream(bad).map { _1.event_type[/(Imported|Updated)\z/] }
    refute Lyra::Genesis.skipped?(GenesisOdd, bad)
  end

  # Make the remembered refusals +seconds+ older.
  def age_refusals(seconds)
    Lyra::Genesis.instance_variable_get(:@refused).transform_values! { |at, error| [at - seconds, error] }
  end

  def stream(id, model = "GenesisOdd") = Lyra.config.event_store.read.stream("#{model}$#{id}").to_a

  def events_count = connection.select_value("SELECT COUNT(*) FROM event_store_events").to_i

  def clean_events
    connection.execute("DELETE FROM event_store_events_in_streams")
    connection.execute("DELETE FROM event_store_events")
  end
end
