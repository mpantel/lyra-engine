# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "stringio"

# bin/rails generate lyra:install: one migration with Lyra's own tables, which
# Lyra otherwise creates the first time it needs each one. The migration's
# definitions must stay those of the code: each table is created both ways, in
# scratch databases, and compared as PostgreSQL's catalog describes them
# (columns in order, types, nulls, defaults, indexes, constraints).
class InstallGeneratorTest < Minitest::Test
  RES_TABLE = "event_store_events_in_streams"
  RES_INDEX = "index_event_store_events_in_streams_on_stream_and_id"
  RES_EVENT_INDEX = "index_event_store_events_in_streams_on_event_id"

  def setup
    skip "Requires Rails and PostgreSQL" unless defined?(ActiveRecord::Base) && postgres?
    require "generators/lyra/install/install_generator"

    @dir = Dir.mktmpdir("lyra-install")
    @scratch = []
  end

  def teardown
    return unless @dir

    FileUtils.rm_rf(@dir)
    @scratch.each { |name| main { |c| c.drop_database(name) } }
  end

  def test_the_generator_writes_one_migration_and_an_initializer
    assert_equal Lyra::Generators::InstallGenerator, Rails::Generators.find_by_namespace("lyra:install")
    generate

    assert_equal 1, migrations.size
    assert_match(/\A\d{14}_create_lyra_tables\.rb\z/, File.basename(migrations.first))
    source = File.read(migrations.first)
    assert_includes source, "class CreateLyraTables < ActiveRecord::Migration[#{ActiveRecord::Migration.current_version}]"
    tables.each { |table| assert_includes source, "create_table :#{table}, " }
    assert_includes source, RES_INDEX
    assert_includes source, RES_EVENT_INDEX

    initializer = File.join(@dir, "config/initializers/lyra.rb")
    assert_includes File.read(initializer), "Lyra.configure do |config|"
  end

  def test_the_generator_keeps_an_existing_initializer
    initializer = File.join(@dir, "config/initializers/lyra.rb")
    FileUtils.mkdir_p(File.dirname(initializer))
    File.write(initializer, "# the application's own\n")

    generate

    assert_equal "# the application's own\n", File.read(initializer)
    assert_equal 1, migrations.size
  end

  def test_the_generator_can_skip_the_initializer
    generate("--skip-initializer")

    refute File.exist?(File.join(@dir, "config/initializers/lyra.rb"))
    assert_equal 1, migrations.size
  end

  # On an empty database the migration creates every table as the code does
  # at run time, and the index on Rails Event Store's table.
  def test_the_migration_creates_the_tables_as_run_time_creation_does
    generate
    at_run_time = scratch { create_at_run_time; catalog }
    migrated = scratch { migrate; catalog }

    assert_same_tables at_run_time, migrated
    assert_equal tables.sort, migrated[:columns].map(&:first).uniq.sort - [RES_TABLE]
    refute res_index?(at_run_time), "run time never builds the index on #{RES_TABLE}"
    refute res_index?(at_run_time, RES_EVENT_INDEX)
    assert res_index?(migrated)
    assert res_index?(migrated, RES_EVENT_INDEX)
  end

  # Where Lyra created its tables at run time (1.0.0 and earlier), the
  # migration runs without error and changes none of them; it adds the index.
  def test_the_migration_leaves_tables_created_at_run_time_as_they_are
    generate
    scratch do
      create_at_run_time
      before = catalog
      migrate
      after = catalog

      assert_same_tables before, after
      assert res_index?(after)
      assert res_index?(after, RES_EVENT_INDEX)
    end
  end

  # With the migration run, the run-time creation still runs (it is the
  # fallback) and finds nothing to do.
  def test_run_time_creation_after_the_migration_changes_nothing
    generate
    scratch do
      migrate
      before = catalog
      create_at_run_time
      assert_equal before, catalog
    end
  end

  # A mode-transitions table created by an earlier version gets the columns
  # later versions added, in the order run time adds them.
  def test_the_migration_completes_an_older_mode_transitions_table
    generate
    table = Lyra::ModeTransition::TABLE
    at_run_time = scratch { create_at_run_time; catalog }
    upgraded = scratch do
      main_connection.create_table(table) do |t|
        t.string :kind, null: false
        t.string :from_config
        t.string :to_config, null: false
        t.bigint :position, null: false, default: 0
        t.integer :checked, null: false, default: 0
        t.datetime :created_at, null: false
      end
      migrate
      catalog
    end

    assert_same_tables at_run_time, upgraded, [table]
  end

  # db/schema.rb dumped after the migration has the tables, and
  # db:schema:load recreates them as the migration did.
  def test_schema_load_recreates_the_tables
    generate
    schema = File.join(@dir, "schema.rb")
    migrated = scratch do
      migrate
      File.write(schema, ActiveRecord::SchemaDumper.dump(ActiveRecord::Base.connection_pool, StringIO.new).string)
      catalog
    end
    dumped = File.read(schema)
    tables.each { |table| assert_includes dumped, %(create_table "#{table}") }

    loaded = scratch do
      ActiveRecord::Migration.suppress_messages do
        ActiveRecord::Tasks::DatabaseTasks.load_schema(ActiveRecord::Base.connection_db_config, :ruby, schema)
      end
      catalog
    end

    assert_equal migrated, loaded
  end

  private

  def postgres?
    ActiveRecord::Base.with_connection { |c| c.adapter_name.match?(/postg/i) }
  end

  def tables
    [Lyra::ModeTransition::TABLE, Lyra::Projections::LazyProjection::TABLE,
     Lyra::Projections::AsyncCheckpoint::TABLE, Lyra::Rights::TABLE, Lyra::Rights::CONSENT_TABLE,
     Lyra::StreamHeads::TABLE]
  end

  def generate(*args)
    capture_io { Lyra::Generators::InstallGenerator.start(args, destination_root: @dir) }
  end

  def migrations = Dir[File.join(@dir, "db/migrate/*_create_lyra_tables.rb")]

  def migrate
    ActiveRecord::Migration.suppress_messages do
      ActiveRecord::MigrationContext.new([File.join(@dir, "db/migrate")]).migrate
    end
  end

  def main(&) = ActiveRecord::Base.with_connection(&)

  def main_connection = ActiveRecord::Base.lease_connection

  # Run the block with ActiveRecord::Base on a new, empty database that has
  # Rails Event Store's streams table (as the test schema has it, without the
  # index on stream and id); Lyra's memory of which tables it has seen is
  # cleared for it and restored after.
  def scratch
    name = "lyra_install_#{Process.pid}_#{@scratch.size}"
    main { |c| c.create_database(name) }
    @scratch << name
    config = ActiveRecord::Base.connection_db_config.configuration_hash.merge(database: name)
    remembered = forget_tables
    ActiveRecord::Base.establish_connection(config)
    main_connection.create_table(RES_TABLE) do |t|
      t.string :stream, null: false
      t.integer :position
      t.string :event_id, limit: 36, null: false
      t.datetime :created_at, precision: 6, null: false
    end
    yield
  ensure
    ActiveRecord::Base.establish_connection(:test)
    restore_tables(remembered) if remembered
  end

  # Each table through the code that creates it on first use.
  def create_at_run_time
    Lyra::ModeTransition.send(:table_ready?)
    main do |c|
      Lyra::Projections::LazyProjection.send(:ensure_table!, c)
      Lyra::Projections::AsyncCheckpoint.send(:ensure_table!, c)
      Lyra::StreamHeads.ensure_table!(c)
    end
    Lyra::Rights::Store.new.send(:ensure_table!)
    Lyra::Rights::ConsentStore.new.send(:ensure_table!)
  end

  READY = [Lyra::ModeTransition, Lyra::Projections::LazyProjection, Lyra::Projections::AsyncCheckpoint].freeze

  def forget_tables
    remembered = READY.to_h { |owner| [owner, owner.instance_variable_get(:@table_ready)] }
    READY.each { |owner| owner.instance_variable_set(:@table_ready, nil) }
    Lyra::StreamHeads.reset!
    remembered
  end

  def restore_tables(remembered)
    remembered.each { |owner, ready| owner.instance_variable_set(:@table_ready, ready) }
    Lyra::StreamHeads.reset!
  end

  # The tables as PostgreSQL describes them.
  def catalog
    names = (tables + [RES_TABLE]).map { main_connection.quote(_1) }.join(", ")
    {
      columns: main_connection.select_rows(<<~SQL.squish),
        SELECT table_name, ordinal_position, column_name, data_type, character_maximum_length,
               numeric_precision, datetime_precision, is_nullable, column_default
        FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name IN (#{names})
        ORDER BY table_name, ordinal_position
      SQL
      indexes: main_connection.select_rows(<<~SQL.squish),
        SELECT tablename, indexname, indexdef FROM pg_indexes
        WHERE schemaname = 'public' AND tablename IN (#{names}) ORDER BY tablename, indexname
      SQL
      constraints: main_connection.select_rows(<<~SQL.squish)
        SELECT rel.relname, con.conname, pg_get_constraintdef(con.oid)
        FROM pg_constraint con JOIN pg_class rel ON rel.oid = con.conrelid
        WHERE rel.relname IN (#{names}) ORDER BY rel.relname, con.conname
      SQL
    }
  end

  def only(catalog, *names) = catalog.transform_values { |rows| rows.select { names.include?(_1.first) } }

  # Table by table, so that a difference names its table.
  def assert_same_tables(expected, actual, names = tables)
    names.each { |name| assert_equal only(expected, name), only(actual, name), "#{name} differs" }
  end

  def res_index?(catalog, index = RES_INDEX) = catalog[:indexes].any? { |table, name, _| table == RES_TABLE && name == index }
end
