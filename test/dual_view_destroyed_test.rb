# frozen_string_literal: true

require "test_helper"
require "rails_event_store"

# DualView on a destroyed record: the events say it no longer exists, so a
# missing row agrees with them and a surviving row does not (as
# Lyra::ModeTransition.compare reads it).
class DualViewDestroyedTest < Minitest::Test
  def setup
    skip "Requires Rails and database" unless defined?(ActiveRecord::Base) && ActiveRecord::Base.connection.table_exists?(:users)

    Lyra.configure do |config|
      config.event_store = RailsEventStore::Client.new
      config.mode = :monitor
    end
    ::User.delete_all
  end

  def teardown
    ::User.delete_all if defined?(ActiveRecord::Base)
  end

  def test_a_destroyed_record_whose_row_is_gone_compares_clean
    user = ::User.create!(name: "Gone", email: "gone@example.com")
    user.destroy!

    comparison = Lyra::DualView.new(::User, user.id).compare

    assert_equal false, comparison[:crud_view][:exists]
    assert_equal false, comparison[:event_sourced_view][:exists]
    assert comparison[:event_sourced_view][:destroyed]
    assert_equal 2, comparison[:event_sourced_view][:events_count]
    assert_equal({ no_differences: true }, comparison[:differences])
  end

  def test_a_destroyed_record_whose_row_survives_is_a_mismatch
    user = ::User.create!(name: "Back", email: "back@example.com")
    user.destroy!
    ActiveRecord::Base.connection.execute(
      "INSERT INTO users (id, name, email, created_at, updated_at) " \
      "VALUES (#{user.id}, 'Back', 'back@example.com', now(), now())"
    )

    comparison = Lyra::DualView.new(::User, user.id).compare

    assert_equal true, comparison[:crud_view][:exists]
    assert_equal false, comparison[:event_sourced_view][:exists]
    assert_equal({ exists_mismatch: true }, comparison[:differences])
  end

  def test_a_live_record_still_exists_in_both_views
    user = ::User.create!(name: "Here", email: "here@example.com")

    comparison = Lyra::DualView.new(::User, user.id).compare

    assert_equal true, comparison[:event_sourced_view][:exists]
    assert_equal false, comparison[:event_sourced_view][:destroyed]
    assert_equal({ no_differences: true }, comparison[:differences])
  end

  # Only replay: false events (domain events emitted alongside a write) say
  # nothing about the record's existence, as ModeTransition.compare reads it.
  def test_a_stream_of_only_unreplayed_events_describes_no_record
    id = 987_654
    Lyra.config.event_store.publish(
      RubyEventStore::Event.new(data: { replay: false, payload: { note: "domain only" } }),
      stream_name: "User$#{id}"
    )

    comparison = Lyra::DualView.new(::User, id).compare

    assert_equal false, comparison[:event_sourced_view][:exists]
    assert_equal false, comparison[:event_sourced_view][:destroyed]
    assert_equal({ no_differences: true }, comparison[:differences])
  ensure
    Lyra.config.event_store.delete_stream("User$#{id}") rescue nil
  end
end
