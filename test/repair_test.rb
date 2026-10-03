# frozen_string_literal: true

require "test_helper"

# Lyra::Repair: after Monitor lost events (log-and-continue), the event log
# is brought back in line with the table, so every stream replays to its row.
class RepairTest < Minitest::Test
  class Unavailable < StandardError; end

  MT = Lyra::ModeTransition

  def setup
    skip "Requires Rails and database" unless defined?(ActiveRecord::Base) && ActiveRecord::Base.connection.table_exists?(:users)

    Object.send(:remove_const, :RepairUser) if defined?(RepairUser)
    Object.const_set(:RepairUser, Class.new(ActiveRecord::Base) do
      self.table_name = "users"
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
    end)
    clean
    Lyra.config.monitor_model(RepairUser)
    Lyra.config.mode = :monitor
  end

  def teardown
    return unless defined?(RepairUser)

    Lyra.config.mode = :monitor
    clean
  end

  def test_a_lost_create_is_repaired_with_an_imported_event
    user = store_fails { RepairUser.create!(name: "Ann", email: "ann@example.com") }

    result = repair
    assert_equal ["row but no events"], result.repaired.map(&:problem)
    event = stream(user).sole
    assert_equal "imported", event.data[:operation].to_s
    assert_equal "lyra_repair", event.metadata[:source]
    assert_in_line user
  end

  def test_a_lost_update_is_repaired_with_the_changed_columns_only
    user = RepairUser.create!(name: "Ann", email: "ann@example.com")
    store_fails { user.update!(name: "Bea") }

    assert_equal ["row differs from its events"], repair.repaired.map(&:problem)
    event = stream(user).last
    assert_equal "updated", event.data[:operation].to_s
    assert_equal({ "name" => %w[Ann Bea] }, event.data[:changes].transform_keys(&:to_s))
    assert_equal "row differs from its events", event.metadata[:repaired]
    assert_in_line user
  end

  def test_a_lost_destroy_is_repaired_with_a_destroyed_event
    user = RepairUser.create!(name: "Ann", email: "ann@example.com")
    store_fails { user.destroy! }

    assert_equal ["events but no row"], repair.repaired.map(&:problem)
    assert_equal "destroyed", stream(user).last.data[:operation].to_s
    assert_in_line user
  end

  def test_a_dry_run_lists_without_writing
    user = store_fails { RepairUser.create!(name: "Ann", email: "ann@example.com") }

    result = Lyra::Repair.run(models: [RepairUser], dry_run: true)
    assert_equal 1, result.found.size
    assert_empty result.repaired
    assert_empty stream(user)
  end

  def test_records_already_in_line_are_left_alone
    user = RepairUser.create!(name: "Ann", email: "ann@example.com")

    result = repair
    assert_equal 1, result.checked
    assert_empty result.found
    assert_equal 1, stream(user).size
  end

  def test_a_record_that_came_back_in_line_meanwhile_is_skipped
    user = RepairUser.create!(name: "Ann", email: "ann@example.com")

    assert_nil Lyra::Repair.repair(RepairUser, user.id.to_s)
  end

  def test_refused_where_the_events_are_authoritative
    Lyra.config.mode = :hijack

    error = assert_raises(Lyra::Repair::Refused) { repair }
    assert_match(/REBUILD=1/, error.message)
  end

  private

  def repair = Lyra::Repair.run(models: [RepairUser])

  def store_fails(&block)
    Rails.logger.stub(:error, nil) do
      Lyra.config.event_store.stub(:publish, ->(*_a, **_k) { raise Unavailable, "store down" }, &block)
    end
  end

  def stream(user) = Lyra.config.event_store.read.stream("RepairUser$#{user.id}").to_a

  def assert_in_line(user)
    assert_nil MT.discrepancy(RepairUser, user.id.to_s), "the stream replays to the row"
  end

  def clean
    conn = ActiveRecord::Base.connection
    conn.execute("DELETE FROM users")
    conn.execute("DELETE FROM event_store_events_in_streams")
    conn.execute("DELETE FROM event_store_events")
  end
end
