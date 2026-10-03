# frozen_string_literal: true

require "test_helper"

# Lyra.state_at and Model.as_of: a record as it was at a given time, rebuilt
# from its event stream.
class TemporalTest < Minitest::Test
  NotRecorded = Lyra::Temporal::HistoryNotRecorded

  def setup
    skip "Requires Rails and database" unless defined?(ActiveRecord::Base) && ActiveRecord::Base.connection.table_exists?(:users)

    Object.send(:remove_const, :TimeUser) if defined?(TimeUser)
    Object.const_set(:TimeUser, Class.new(ActiveRecord::Base) do
      self.table_name = "users"
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
    end)
    clean
    Lyra.config.enable_monitor!
    Lyra.config.monitor_model(TimeUser)
  end

  def teardown
    clean if defined?(TimeUser)
  end

  def test_a_record_through_its_life
    before_create = moment
    user = TimeUser.create!(name: "Ann", email: "ann@example.com")
    after_create = moment
    user.update!(name: "Anna")
    after_update = moment
    user.destroy!
    after_destroy = moment

    assert_nil Lyra.state_at(TimeUser, user.id, before_create), "did not exist yet"
    assert_equal "Ann", Lyra.state_at(TimeUser, user.id, after_create)["name"]
    assert_equal "Anna", Lyra.state_at(TimeUser, user.id, after_update)["name"]
    assert_equal user.id, Lyra.state_at(TimeUser, user.id, after_update)["id"]
    assert_nil Lyra.state_at(TimeUser, user.id, after_destroy), "destroyed by then"
  end

  def test_as_of_finds_read_only_records_as_they_were
    user = TimeUser.create!(name: "Ann", email: "ann@example.com")
    then_ = moment
    user.update!(name: "Anna")

    past = TimeUser.as_of(then_).find(user.id)
    assert_equal "Ann", past.name
    assert past.readonly?, "the past is read-only"
    assert_raises(ActiveRecord::RecordNotFound) { TimeUser.as_of(1.day.ago).find(user.id) }
    assert_nil TimeUser.as_of(1.day.ago).find_by_id(user.id)
  end

  def test_as_of_all_lists_the_records_that_existed_then
    ann = TimeUser.create!(name: "Ann", email: "ann@example.com")
    bob = TimeUser.create!(name: "Bob", email: "bob@example.com")
    both = moment
    bob.destroy!
    TimeUser.create!(name: "Cy", email: "cy@example.com")

    assert_equal [[ann.id, "Ann"], [bob.id, "Bob"]], TimeUser.as_of(both).all.map { [_1.id, _1.name] }
  end

  def test_an_imported_record_has_no_history_before_its_import
    connection.execute(<<~SQL)
      INSERT INTO users (name, email, created_at, updated_at)
      VALUES ('Old', 'old@example.com', '2020-01-01 10:00:00', '2020-06-01 10:00:00')
    SQL
    id = connection.select_value("SELECT id FROM users").to_i
    Lyra::Genesis.import_all(TimeUser)
    after_import = moment

    assert_equal "Old", Lyra.state_at(TimeUser, id, after_import)["name"]
    assert_raises(NotRecorded) { Lyra.state_at(TimeUser, id, Time.utc(2021, 1, 1)) }
    assert_nil Lyra.state_at(TimeUser, id, Time.utc(2019, 1, 1)), "before its own created_at it did not exist"
    assert_raises(NotRecorded) { TimeUser.as_of(Time.utc(2021, 1, 1)).all }
  end

  def test_a_record_with_no_events_did_not_exist
    assert_nil Lyra.state_at(TimeUser, 999_999, Time.current)
  end

  private

  # A time strictly between two writes: event times are microsecond-precise.
  def moment
    sleep 0.002
    t = Time.current
    sleep 0.002
    t
  end

  def connection = ActiveRecord::Base.connection

  def clean
    connection.execute("DELETE FROM users")
    connection.execute("DELETE FROM event_store_events_in_streams")
    connection.execute("DELETE FROM event_store_events")
  end
end
