# frozen_string_literal: true

require "test_helper"

# A thread that uses monitored models ends without holding a connection, in
# every mode, as it does with plain ActiveRecord.
#
# Since Rails 7.2 a query outside with_connection checks a connection out and
# returns it at once; only Model.connection (lease_connection) keeps one for
# the thread until the thread ends or releases it, even inside with_connection.
# Lyra called Model.connection in its write, lock and read paths, so every
# thread that wrote through it in Hijack or an event-sourcing mode ended still
# holding a connection. The pool got it back only by reaping, which resets
# each dead thread's connection: at 64 threads the benchmark's next trial
# waited for that, now and then past the 5 s checkout timeout.
class ConnectionReleaseTest < Minitest::Test
  PARENTS = "lyra_release_parents"
  CHILDREN = "lyra_release_children"
  MODES = %i[disabled monitor hijack es_sync es_async es_noproj es_lazy].freeze

  def setup
    skip "Requires Rails and PostgreSQL" unless defined?(ActiveRecord::Base) && connection.adapter_name.match?(/postgres/i)

    connection.create_table(PARENTS, force: true) { |t| t.string :label; t.timestamps }
    connection.create_table(CHILDREN, force: true) { |t| t.bigint :release_parent_id; t.string :label; t.timestamps }
    %i[ReleaseParent ReleaseChild].each { |name| Object.send(:remove_const, name) if Object.const_defined?(name) }
    Object.const_set(:ReleaseParent, Class.new(ActiveRecord::Base))
    Object.const_set(:ReleaseChild, Class.new(ActiveRecord::Base))
    ReleaseParent.class_eval do
      self.table_name = PARENTS
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
      has_many :release_children, class_name: "ReleaseChild", foreign_key: :release_parent_id
    end
    ReleaseChild.class_eval do
      self.table_name = CHILDREN
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
      belongs_to :release_parent, class_name: "ReleaseParent", optional: true
    end
    [ReleaseParent, ReleaseChild].each(&:reset_column_information)
    clean
    Lyra.config.monitor_model(ReleaseParent)
    Lyra.config.monitor_model(ReleaseChild)
    ActiveRecord::Base.connection_pool.release_connection
  end

  def teardown
    return unless defined?(ReleaseParent)

    Lyra.reset_config!
    clean
    [CHILDREN, PARENTS].each { |table| connection.drop_table(table, if_exists: true) }
  end

  MODES.each do |mode|
    define_method("test_a_thread_that_writes_and_reads_holds_no_connection_after_in_#{mode}") do
      use(mode)

      assert_equal false, in_thread { work }, "the thread ended holding a connection"
    end

    define_method("test_with_connection_returns_the_connection_in_#{mode}") do
      use(mode)

      held = in_thread { ActiveRecord::Base.connection_pool.with_connection { work } }

      assert_equal false, held, "with_connection did not return the connection Lyra leased inside it"
    end
  end

  def test_lyras_maintenance_calls_hold_no_connection_after
    use(:es_sync)
    ReleaseParent.create!(label: "kept")

    held = in_thread do
      Lyra::DualView.new(ReleaseParent, ReleaseParent.first.id).calculate_differences
      Lyra::Projections::Rebuild.rebuild(ReleaseParent)
      Lyra::ModeTransition.check(to: "event_sourcing/sync", from: "event_sourcing/sync", models: [ReleaseParent])
      Lyra::Genesis.import_all(ReleaseChild)
    end

    assert_equal false, held
  end

  # Lyra uses with_connection, never Model.connection, which leases. The one
  # exception is CachedRelation#connection, kept as ActiveRecord::Relation has it.
  def test_lib_never_leases_a_connection
    allowed = { "lib/lyra/projections/cached_relation.rb" => ["model_class.connection"] }
    root = File.expand_path("..", __dir__)
    leases = Dir[File.join(root, "lib/**/*.rb")].sort.flat_map do |file|
      path = file.delete_prefix("#{root}/")
      File.readlines(file).each_with_index.filter_map do |line, i|
        next if line.match?(/\A\s*#/)
        next unless line.match?(/(?:\w|\))\.(?:connection|lease_connection)\b(?![_?!])/)
        next if allowed.fetch(path, []).include?(line.strip)

        "#{path}:#{i + 1}: #{line.strip}"
      end
    end

    assert_empty leases, "use with_connection; Model.connection keeps the connection for the thread"
  end

  private

  def work
    parent = ReleaseParent.create!(label: "p")
    child = ReleaseChild.create!(label: "c", release_parent_id: parent.id)
    ReleaseParent.find(parent.id).update!(label: "q")
    ReleaseParent.where(label: "q").to_a
    ReleaseChild.count
    ReleaseParent.find(parent.id).release_children.to_a
    ReleaseChild.find(child.id).destroy!
    ReleaseParent.find(parent.id).destroy!
  end

  # Runs the block on a new thread; true if that thread still holds a
  # connection of the pool when the block is done.
  def in_thread(&block)
    Thread.new do
      block.call
      ActiveRecord::Base.connection_pool.active_connection? ? true : false
    end.value
  end

  def use(mode)
    case mode
    when :disabled then Lyra.config.disable!
    when :monitor then Lyra.config.enable_monitor!
    when :hijack then Lyra.config.enable_hijack!
    else
      Lyra.config.enable_event_sourcing!
      Lyra.config.projection_mode = { es_sync: :sync, es_async: :async, es_noproj: :disabled, es_lazy: :lazy }.fetch(mode)
    end
  end

  def connection = ActiveRecord::Base.connection

  def clean
    [CHILDREN, PARENTS].each { |table| connection.execute("DELETE FROM #{table}") if connection.table_exists?(table) }
    connection.execute("DELETE FROM event_store_events_in_streams")
    connection.execute("DELETE FROM event_store_events")
    Lyra::Projections::LazyProjection.reset!
    Lyra::Genesis.reset!
  end
end
