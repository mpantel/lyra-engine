# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# A process that only reads: the Lyra::Events::<Model><Operation> classes are
# created when a monitored model first writes, so a fresh process reading a
# stream got plain RubyEventStore::Event objects (RES falls back to them when
# Object.const_get(event_type) raises NameError), without operation,
# attributes, changes. Lyra::Events.const_missing now creates Lyra's own event
# classes on demand, loading the model the name stands for if need be.
class FreshProcessEventClassesTest < Minitest::Test
  EVENT_NAMES = %w[FreshReadUserCreated FreshReadUserUpdated FreshReadUserDestroyed FreshReadUserImported].freeze

  MODEL_SOURCE = <<~RUBY
    class FreshReadUser < ActiveRecord::Base
      self.table_name = "users"
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
    end
  RUBY

  def setup
    skip "Requires Rails and database" unless defined?(ActiveRecord::Base) && ActiveRecord::Base.connection.table_exists?(:users)

    @previous_mode = Lyra.config.mode
    Lyra.config.mode = :monitor
    clean
    define_model
  end

  def teardown
    return unless defined?(ActiveRecord::Base)

    clean
    forget_model
    Lyra.config.mode = @previous_mode if @previous_mode
  end

  def test_reading_a_stream_in_a_fresh_process_yields_lyra_events
    user = FreshReadUser.create!(name: "Fay", email: "fay@example.com")
    user.update!(name: "Fay2")
    remove_event_classes

    events = Lyra.event_store.read.stream("FreshReadUser$#{user.id}").to_a

    assert_equal 2, events.size
    events.each { |event| assert_kind_of Lyra::Event, event }
    assert_equal %i[created updated], events.map(&:operation)
    assert_equal "Fay", (events.first.attributes["name"] || events.first.attributes[:name])
    assert_equal "Lyra::Events::FreshReadUserCreated", events.first.class.name
  end

  # The model has not been loaded yet (lazy loading): the name's stem loads
  # it, its monitor_with_lyra declares the event names, and the class is
  # created.
  def test_the_model_is_loaded_by_the_event_name_when_not_yet_loaded
    user = FreshReadUser.create!(name: "Gil", email: "gil@example.com")
    remove_event_classes
    forget_model

    Dir.mktmpdir do |dir|
      path = File.join(dir, "fresh_read_user.rb")
      File.write(path, MODEL_SOURCE)
      Object.autoload(:FreshReadUser, path)

      events = Lyra.event_store.read.stream("FreshReadUser$#{user.id}").to_a

      assert_kind_of Lyra::Event, events.first
      assert_equal :created, events.first.operation
      assert(Lyra.config.monitored_models.any? { |m| m.name == "FreshReadUser" }, "the model was loaded")
    end
  end

  def test_names_that_are_not_lyra_events_still_raise
    assert_raises(NameError) { Lyra::Events::FreshReadUsrCreated }
    assert_raises(NameError) { Lyra::Events::NoSuchModelAnywhereCreated }
    assert_raises(NameError) { Lyra::Events::FreshReadUserTypo }
    refute Lyra::Events.const_defined?(:NoSuchModelAnywhereCreated, false)
  end

  private

  # A named class (monitor_with_lyra takes the event prefix from the name).
  def define_model
    Object.class_eval(MODEL_SOURCE)
  end

  def forget_model
    Object.send(:remove_const, :FreshReadUser) if Object.const_defined?(:FreshReadUser, false)
    Lyra.config.monitored_models.reject! { |m| (m.name rescue nil) == "FreshReadUser" }
    remove_event_classes
  end

  def remove_event_classes
    EVENT_NAMES.each { |n| Lyra::Events.send(:remove_const, n) if Lyra::Events.const_defined?(n, false) }
  end

  def clean
    conn = ActiveRecord::Base.connection
    conn.execute("DELETE FROM users")
    conn.execute("DELETE FROM event_store_events_in_streams")
    conn.execute("DELETE FROM event_store_events")
  end
end
