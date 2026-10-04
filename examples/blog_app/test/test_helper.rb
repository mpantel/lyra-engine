ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

module ActiveSupport
  class TestCase
    # Each test runs in a transaction that is rolled back, events included:
    # the event store writes through the same ActiveRecord connection.

    def stream(record)
      Lyra.config.event_store.read.stream("#{record.class.name}$#{record.id}").to_a
    end

    def author
      @author ||= User.create!(name: "Alice", email: "alice-#{SecureRandom.hex(4)}@example.com")
    end
  end
end
