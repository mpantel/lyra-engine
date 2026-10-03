# frozen_string_literal: true

require "test_helper"

# A write recorded under another name than ...Created/...Updated/...Destroyed
# (event_mapping, or a domain event) must replay as the operation it was.
# Replay used to look at the name's suffix, so a renamed event was skipped:
# Rebuild left the row out, and ES-NoProj could not find the record.
class RenamedEventsReplayTest < Minitest::Test
  def setup
    skip "Requires Rails and database" unless defined?(ActiveRecord::Base) && ActiveRecord::Base.connection.table_exists?(:users)

    Object.send(:remove_const, :RenamedUser) if defined?(RenamedUser)
    Object.const_set(:RenamedUser, Class.new(ActiveRecord::Base) do
      self.table_name = "users"
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra event_mapping: { created: "MemberJoined", updated: "MemberChanged" }
    end)
    clean
    Rails.cache.clear
    Lyra.config.enable_monitor!
    Lyra.config.monitor_model(RenamedUser, event_mapping: { created: "MemberJoined", updated: "MemberChanged" })
    @user = RenamedUser.create!(name: "Ann", email: "ann@example.com")
    @user.update!(name: "Anna")
  end

  def teardown
    return unless defined?(RenamedUser)

    Lyra.config.projection_mode = :sync
    clean
    Rails.cache.clear
  end

  def test_the_events_carry_the_new_names
    types = connection.select_values("SELECT event_type FROM event_store_events ORDER BY id")
    assert_equal %w[Lyra::Events::MemberJoined Lyra::Events::MemberChanged], types
  end

  def test_rebuild_replays_renamed_events
    stats = Lyra::Projections::Rebuild.rebuild(RenamedUser)
    assert_equal 1, stats[:records]
    assert_equal "Anna", connection.select_value("SELECT name FROM users WHERE id = #{@user.id}")
  end

  def test_es_noproj_reads_renamed_events
    Lyra.config.enable_event_sourcing!
    Lyra.config.projection_mode = :disabled
    assert_equal "Anna", RenamedUser.find(@user.id).name
  end

  def test_state_at_and_the_aggregate_read_renamed_events
    assert_equal "Anna", Lyra.state_at(RenamedUser, @user.id, Time.current)["name"]
    aggregate = Lyra::GenericAggregate.new(@user.id, RenamedUser)
    Lyra.config.event_store.read.stream("RenamedUser$#{@user.id}").each { aggregate.apply(_1, persisted: true) }
    assert_equal 2, aggregate.version, "both renamed events applied"
    state = aggregate.send(:state)
    assert_equal "Anna", state[:name] || state["name"]
  end

  private

  def connection = ActiveRecord::Base.connection

  def clean
    connection.execute("DELETE FROM users")
    connection.execute("DELETE FROM event_store_events_in_streams")
    connection.execute("DELETE FROM event_store_events")
  end
end
