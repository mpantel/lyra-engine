# frozen_string_literal: true

require "test_helper"

# Database foreign keys under ES-NoProj (event sourcing, projections
# disabled). The table of a monitored model stays empty there: its records
# live in the event log. A foreign key from a table no monitored model writes
# into such a table therefore refuses every insert that references a record
# (PG::ForeignKeyViolation). The switch into ES-NoProj refuses it up front,
# naming the tables, the column and the constraint.
#
# Foreign keys that never fire in ES-NoProj pass: between two monitored
# tables, and from a monitored table into an unmonitored one (the monitored
# table gets no rows).
class EsNoprojForeignKeysTest < Minitest::Test
  MODELS = %i[FkParent FkMonitoredChild].freeze
  TABLES = %i[lyra_fk_children lyra_fk_monitored_children lyra_fk_parents lyra_fk_lookups].freeze

  def setup
    skip "Requires Rails and database" unless defined?(ActiveRecord::Base) && ActiveRecord::Base.connection.table_exists?(:users)

    create_tables
    MODELS.each { |c| Object.send(:remove_const, c) if Object.const_defined?(c) }
    define_models
    Lyra.config.stubs(:monitored_models).returns([FkParent, FkMonitoredChild])
    Lyra.config.mode = :monitor
    Lyra.config.projection_mode = :sync
  end

  def teardown
    return unless defined?(FkParent)

    Lyra.config.mode = :monitor
    Lyra.config.projection_mode = :sync
    Lyra.config.instance_variable_get(:@monitored_models).reject! { |m| %w[FkParent FkMonitoredChild].include?(m.name) }
    connection = ActiveRecord::Base.connection
    TABLES.each { connection.drop_table(_1, if_exists: true, force: :cascade) }
  end

  def test_a_foreign_key_from_an_unmonitored_table_into_a_monitored_one_refuses_the_switch
    connection.add_foreign_key :lyra_fk_children, :lyra_fk_parents, column: :parent_id, name: "fk_child_parent"

    error = assert_raises(Lyra::ModeTransition::Refused) do
      Lyra::ModeTransition.to!(:event_sourcing, projection_mode: :disabled)
    end

    assert_match(/lyra_fk_children\.parent_id/, error.message)
    assert_match(/lyra_fk_parents/, error.message)
    assert_match(/fk_child_parent/, error.message)
    assert_match(/remove_foreign_key :lyra_fk_children, name: "fk_child_parent"/, error.message)
    assert_match(/monitor the referencing model/, error.message)
    assert_equal "monitor", Lyra::ModeTransition.current
  end

  def test_the_refusal_lists_what_blocks
    connection.add_foreign_key :lyra_fk_children, :lyra_fk_parents, column: :parent_id, name: "fk_child_parent"

    blocking = Lyra::Projections::ForeignKeys.blocking([FkParent, FkMonitoredChild])

    assert_equal 1, blocking.size
    assert_equal ["lyra_fk_children", "parent_id", "lyra_fk_parents", "fk_child_parent"],
                 blocking.first.to_h.values_at(:from_table, :column, :to_table, :name)
  end

  def test_force_switches_anyway
    connection.add_foreign_key :lyra_fk_children, :lyra_fk_parents, column: :parent_id

    Lyra::ModeTransition.to!(:event_sourcing, projection_mode: :disabled, force: true)

    assert_equal "event_sourcing/disabled", Lyra::ModeTransition.current
  end

  def test_without_the_foreign_key_the_switch_is_allowed
    Lyra::ModeTransition.to!(:event_sourcing, projection_mode: :disabled)

    assert_equal "event_sourcing/disabled", Lyra::ModeTransition.current
  end

  def test_a_foreign_key_between_monitored_tables_is_allowed
    connection.add_foreign_key :lyra_fk_monitored_children, :lyra_fk_parents, column: :parent_id

    Lyra::ModeTransition.to!(:event_sourcing, projection_mode: :disabled)

    assert_equal "event_sourcing/disabled", Lyra::ModeTransition.current
  end

  def test_a_foreign_key_from_a_monitored_table_into_an_unmonitored_one_is_allowed
    connection.add_foreign_key :lyra_fk_monitored_children, :lyra_fk_lookups, column: :lookup_id

    Lyra::ModeTransition.to!(:event_sourcing, projection_mode: :disabled)

    assert_equal "event_sourcing/disabled", Lyra::ModeTransition.current
  end

  # Only the switch into ES-NoProj checks: ES-Sync writes the tables.
  def test_other_event_sourcing_modes_are_not_refused
    connection.add_foreign_key :lyra_fk_children, :lyra_fk_parents, column: :parent_id

    Lyra::ModeTransition.to!(:event_sourcing, projection_mode: :sync)

    assert_equal "event_sourcing/sync", Lyra::ModeTransition.current
  end

  # ES-NoProj set at boot (config.projection_mode = :disabled in an
  # initializer) passes no switch: the boot warns instead.
  def test_booting_in_es_noproj_warns
    connection.add_foreign_key :lyra_fk_children, :lyra_fk_parents, column: :parent_id, name: "fk_child_parent"
    Lyra.config.mode = :event_sourcing
    Lyra.config.projection_mode = :disabled

    messages = []
    Kernel.stubs(:warn).with { |message| messages << message }
    Rails.stubs(:logger).returns(nil)
    warned = Lyra::ModeTransition.check_es_noproj!

    assert_equal 1, warned.size
    assert_equal 1, messages.size
    assert_match(/lyra_fk_children\.parent_id -> lyra_fk_parents \(constraint fk_child_parent\)/, messages.first)
  end

  def test_booting_in_another_mode_does_not_warn
    connection.add_foreign_key :lyra_fk_children, :lyra_fk_parents, column: :parent_id

    assert_empty Lyra::ModeTransition.check_es_noproj!
  end

  private

  def connection = ActiveRecord::Base.connection

  def create_tables
    TABLES.each { connection.drop_table(_1, if_exists: true, force: :cascade) }
    connection.create_table(:lyra_fk_parents) { |t| t.string :name }
    connection.create_table(:lyra_fk_lookups) { |t| t.string :name }
    connection.create_table(:lyra_fk_children) { |t| t.bigint :parent_id }
    connection.create_table(:lyra_fk_monitored_children) do |t|
      t.bigint :parent_id
      t.bigint :lookup_id
    end
  end

  def define_models
    monitored = lambda do |table|
      Class.new(ActiveRecord::Base) do
        self.table_name = table
        include Lyra::Interceptors::CrudInterceptor
        monitor_with_lyra
      end
    end
    Object.const_set(:FkParent, monitored.call("lyra_fk_parents"))
    Object.const_set(:FkMonitoredChild, monitored.call("lyra_fk_monitored_children"))
  end
end
