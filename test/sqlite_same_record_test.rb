# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# The lock on the aggregate (assumption L of Theorem 5) on a second database:
# SQLite. It has neither PostgreSQL's row lock strengths nor its advisory
# locks, and Lyra takes no lock there: SQLite lets one transaction write at a
# time, from its first write to its commit, and a Hijack or ES-Sync write's
# first write is the append. So the second writer of a record waits for the
# first, and row and log agree, without a lock of Lyra's. This runs the
# interleaving of test/concurrent_same_record_test.rb against a model and an
# event store that both live in a SQLite file.
class SqliteSameRecordTest < Minitest::Test
  # The pause point of the first writer: after its event is appended, before
  # its row is written.
  module Pause
    def self.at(point)
      gate = Thread.current[:sqlite_race_gate]
      return unless gate && gate[:point] == point

      Thread.current[:sqlite_race_gate] = nil
      gate[:reached] << true
      gate[:resume].pop
    end

    module Handler
      def handle(command)
        result = super
        Pause.at(:after_command)
        result
      end
    end

    module Projection
      def project(*args)
        Pause.at(:before_projection)
        super
      end
    end
  end

  Lyra::CommandHandler.singleton_class.prepend(Pause::Handler)
  Lyra::Projections::ModelProjection.singleton_class.prepend(Pause::Projection)

  def setup
    skip "Requires Rails" unless defined?(ActiveRecord::Base)
    begin
      require "sqlite3"
    rescue LoadError
      skip "Requires the sqlite3 gem"
    end

    @dir = Dir.mktmpdir("lyra-sqlite")
    Object.send(:remove_const, :SqliteRecord) if defined?(SqliteRecord)
    Object.const_set(:SqliteRecord, Class.new(ActiveRecord::Base) { self.abstract_class = true })
    SqliteRecord.establish_connection(adapter: "sqlite3", database: File.join(@dir, "lyra.sqlite3"),
                                      pool: 5, timeout: 10_000)
    create_schema(SqliteRecord.connection)

    Object.send(:remove_const, :LiteItem) if defined?(LiteItem)
    Object.const_set(:LiteItem, Class.new(SqliteRecord) do
      self.table_name = "lite_items"
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
    end)
    Lyra.config.event_store = RailsEventStore::Client.new(
      repository: RubyEventStore::ActiveRecord::EventRepository.new(
        model_factory: RubyEventStore::ActiveRecord::WithAbstractBaseClass.new(SqliteRecord),
        serializer: RubyEventStore::Serializers::YAML
      )
    )
    Lyra.config.monitor_model(LiteItem)
  end

  def teardown
    return unless defined?(SqliteRecord) && @dir

    SqliteRecord.connection_pool.disconnect!
    FileUtils.remove_entry(@dir)
  end

  def test_hijack_orders_the_row_and_the_log_the_same_way_without_a_lock_of_lyras
    Lyra.config.enable_hijack!
    assert_orders_agree(pause_at: :after_command)
  end

  def test_es_sync_orders_the_row_and_the_log_the_same_way_without_a_lock_of_lyras
    Lyra.config.enable_event_sourcing!
    Lyra.config.projection_mode = :sync
    assert_orders_agree(pause_at: :before_projection)
  end

  def test_no_lock_statement_and_no_warning_on_sqlite
    Lyra.config.enable_hijack!
    Lyra::AdvisoryLock.reset_warnings!
    item = LiteItem.create!(label: "a")

    sql = []
    sub = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| sql << payload[:sql].to_s }
    _out, err = capture_io { item.update!(label: "b") }
    ActiveSupport::Notifications.unsubscribe(sub)

    refute sql.any? { |s| s.match?(/FOR (NO KEY )?UPDATE|pg_advisory/) }, sql.join("\n")
    assert_empty err
    assert_equal "b", row_label(item.id)
  end

  private

  # The first writer appends and pauses before its row write; the second
  # must wait (SQLite's write lock), not finish; then both finish, in order.
  def assert_orders_agree(pause_at:)
    id = LiteItem.create!(label: "initial").id
    gate = { point: pause_at, reached: Queue.new, resume: Queue.new }
    first = Thread.new do
      Thread.current[:sqlite_race_gate] = gate
      SqliteRecord.connection_pool.with_connection { LiteItem.find(id).update!(label: "from-t1") }
    end
    gate[:reached].pop

    second = Thread.new { SqliteRecord.connection_pool.with_connection { LiteItem.find(id).update!(label: "from-t2") } }
    refute second.join(0.5), "the second writer ran past the first writer's write transaction"

    gate[:resume] << true
    first.value
    second.value

    assert_equal "from-t2", row_label(id)
    assert_equal row_label(id), replayed_label(id), "row and log agree on the last writer"
  end

  def row_label(id)
    SqliteRecord.connection.select_value("SELECT label FROM lite_items WHERE id = #{Integer(id)}")
  end

  def replayed_label(id)
    label = nil
    Lyra.config.event_store.read.stream("LiteItem$#{id}").each do |event|
      data = event.data
      attrs = (data[:changes].presence || data["changes"].presence ||
               data[:attributes] || data["attributes"] || {}).with_indifferent_access
      next unless attrs.key?(:label)

      value = attrs[:label]
      label = value.is_a?(Array) ? value.last : value
    end
    label
  end

  def create_schema(connection)
    connection.create_table(:lite_items) do |t|
      t.string :label
      t.timestamps
    end
    connection.create_table(:event_store_events) do |t|
      t.string :event_id, limit: 36, null: false
      t.string :event_type, null: false
      t.binary :metadata
      t.binary :data, null: false
      t.datetime :created_at, null: false, precision: 6
      t.datetime :valid_at, precision: 6
      t.index :event_id, unique: true
    end
    connection.create_table(:event_store_events_in_streams) do |t|
      t.string :stream, null: false
      t.integer :position
      t.string :event_id, limit: 36, null: false
      t.datetime :created_at, null: false, precision: 6
      t.index %i[stream position], unique: true
      t.index %i[stream event_id], unique: true
    end
  end
end
