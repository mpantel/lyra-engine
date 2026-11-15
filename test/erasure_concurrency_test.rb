# frozen_string_literal: true

require "test_helper"

# Erasure against a concurrent write. Before 1.0.0 erasure read the
# stream before its transaction and take the row lock after it had rewritten the
# events, so a Monitor update that committed in that window left the value in an
# event the erasure never saw. It now takes the row lock, then the aggregate's
# advisory lock, and only then reads the stream.
class ErasureConcurrencyTest < Minitest::Test
  def setup
    skip "Requires Rails and PostgreSQL" unless defined?(ActiveRecord::Base) && ActiveRecord::Base.connection.table_exists?(:users) &&
                                                ActiveRecord::Base.connection.adapter_name.match?(/postgres/i)
    skip "Requires pam_dsl" unless Lyra.pam_dsl_available?

    PamDsl.reset!
    PamDsl.define_policy(:race_policy) do
      field :email, type: :email, sensitivity: :confidential
      field :name, type: :name
      purpose :contact do
        basis :contract
        requires :email
      end
    end
    Object.send(:remove_const, :RaceUser) if defined?(RaceUser)
    Object.const_set(:RaceUser, Class.new(ActiveRecord::Base) { self.table_name = "users" })
    RaceUser.include(Lyra::Interceptors::CrudInterceptor)
    RaceUser.monitor_with_lyra(privacy_policy: :race_policy)
    Lyra.config.monitor_model(RaceUser, privacy_policy: :race_policy)
    clean
    Lyra.config.enable_monitor!
  end

  def teardown
    return unless defined?(RaceUser)

    Lyra.config.enable_monitor!
    clean
    PamDsl.reset!
  end

  def test_an_update_committed_while_the_erasure_waits_is_erased_too
    user = RaceUser.create!(name: "Ann", email: "ann@example.com")
    writer_holds_the_row = Queue.new
    release_the_writer = Queue.new

    writer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        RaceUser.transaction do
          # The UPDATE locks the row and Monitor appends its event in this transaction.
          RaceUser.find(user.id).update!(email: "ann@new.example")
          writer_holds_the_row << true
          release_the_writer.pop
        end
      end
    end
    writer_holds_the_row.pop

    eraser = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Lyra::Erasure.erase!(RaceUser, user.id, reason: "Art. 17 request")
      end
    end
    wait_until_blocked(eraser)
    release_the_writer << true
    writer.join(10)
    result = eraser.value

    refute_includes log_text, "ann@example.com", "the first address is gone from every event, the writer's too"
    refute_includes log_text, "ann@new.example", "the address the writer committed is erased as well"
    assert_includes result.fields, "email"
  end

  def test_an_erasure_with_no_concurrent_write_is_unchanged
    user = RaceUser.create!(name: "Ann", email: "ann@example.com")
    user.update!(email: "ann@new.example")

    result = Lyra::Erasure.erase!(RaceUser, user.id, reason: "r")

    assert_equal %w[email name], result.fields.sort
    refute_includes log_text, "ann@example.com"
    refute_includes log_text, "ann@new.example"
  end

  private

  # The eraser is blocked on the writer's row lock when its thread sleeps on the database.
  def wait_until_blocked(thread, timeout: 5)
    deadline = Time.now + timeout
    sleep 0.05 until thread.status == "sleep" || Time.now > deadline
    sleep 0.3 # past any other sleep before it reached the lock
    flunk "the eraser never blocked" unless thread.status == "sleep"
  end

  def log_text = ActiveRecord::Base.connection.select_value("SELECT string_agg(convert_from(data, 'UTF8'), ' ') FROM event_store_events").to_s

  def clean
    conn = ActiveRecord::Base.connection
    conn.execute("DELETE FROM users")
    conn.execute("DELETE FROM event_store_events_in_streams")
    conn.execute("DELETE FROM event_store_events")
  end
end
