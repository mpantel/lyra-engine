# frozen_string_literal: true

require "test_helper"

# Domain events (Lyra::DomainEvents): rules name a write's event after what it
# means, add a payload, use an event class of your own, and emit additional
# events. Replay must not notice: renamed events replay as their operation,
# and additional events are not replayed at all.
class DomainEventsTest < Minitest::Test
  RULES = [
    { name: "MemberJoined", on: :create },
    { name: "MemberRenamed", on: :update,
      if: ->(_user, changes) { changes.key?("name") },
      payload: ->(_user, changes) { { from: changes["name"][0], to: changes["name"][1] } } },
    { class: "DomainEventsTest::EmailChanged", on: :update, if: ->(_user, changes) { changes.key?("email") } },
    { name: "ProfileTouched", on: :update, also: true }
  ].freeze

  class EmailChanged < Lyra::Event; end

  def setup
    skip "Requires Rails and database" unless defined?(ActiveRecord::Base) && ActiveRecord::Base.connection.table_exists?(:users)

    Object.send(:remove_const, :DomUser) if defined?(DomUser)
    rules = RULES.map { |r| r[:class].is_a?(String) ? r.merge(class: r[:class].constantize) : r }
    # Named before monitor_with_lyra, as a real model is: the default event
    # prefix is the model's name.
    Object.const_set(:DomUser, Class.new(ActiveRecord::Base) do
      self.table_name = "users"
      include Lyra::Interceptors::CrudInterceptor
    end)
    DomUser.monitor_with_lyra(domain_events: rules)
    Lyra.config.monitor_model(DomUser, domain_events: rules)
    clean
    Rails.cache.clear
  end

  def teardown
    return unless defined?(DomUser)

    Lyra.config.projection_mode = :sync
    clean
    Rails.cache.clear
  end

  %i[monitor hijack es_sync es_noproj].each do |mode|
    define_method("test_#{mode}_names_events_by_the_rules_and_replays_them") do
      use(mode)
      user = DomUser.create!(name: "Ann", email: "ann@example.com")
      user.update!(name: "Anna")
      user.update!(email: "anna@example.com")

      assert_equal %w[MemberJoined MemberRenamed ProfileTouched EmailChanged ProfileTouched], types(user)

      renamed = stream(user)[1]
      assert_equal({ from: "Ann", to: "Anna" }, (renamed.data[:payload] || renamed.data["payload"]).transform_keys(&:to_sym))
      assert_instance_of EmailChanged, stream(user)[3]

      touched = stream(user)[2]
      assert_equal false, touched.data[:replay]
      assert_equal renamed.event_id, touched.metadata[:causation_id], "an additional event points to the write's own"

      assert_equal "Anna", Lyra.state_at(DomUser, user.id, Time.current)["name"]
      assert_equal "anna@example.com", Lyra.state_at(DomUser, user.id, Time.current)["email"]
      assert_equal "Anna", DomUser.find(user.id).name
      unless mode == :es_noproj
        assert Lyra::DualView.new(DomUser, user.id).compare[:differences][:no_differences]
      end
    end
  end

  def test_a_write_no_rule_names_keeps_its_crud_event
    use(:monitor)
    user = DomUser.create!(name: "Ann", email: "ann@example.com")
    user.update!(updated_at: 1.minute.from_now)

    assert_equal %w[MemberJoined DomUserUpdated ProfileTouched], types(user)
  end

  def test_rebuild_applies_each_write_once
    use(:monitor)
    user = DomUser.create!(name: "Ann", email: "ann@example.com")
    user.update!(name: "Anna")

    Lyra::Projections::Rebuild.rebuild(DomUser)
    assert_equal "Anna", connection.select_value("SELECT name FROM users WHERE id = #{user.id}")
  end

  def test_generated_event_classes_are_registered_for_deserialization
    assert_includes Lyra::DomainEvents.generated_names(DomUser), "MemberRenamed"
    refute_includes Lyra::DomainEvents.generated_names(DomUser), "EmailChanged", "a class of your own is not generated"
  end

  def test_a_raising_rule_fails_the_write_where_events_are_the_record
    use(:hijack)
    boom = [{ name: "Boom", on: :create, if: ->(_u) { raise "rule failed" } }]
    DomUser.monitor_with_lyra(domain_events: boom)
    Lyra.config.monitor_model(DomUser, domain_events: boom)

    refute DomUser.new(name: "Ann", email: "ann@example.com").save
    assert_equal 0, connection.select_value("SELECT count(*) FROM users").to_i
  end

  def test_rules_are_validated
    rule = Lyra::DomainEvents.method(:rule)
    assert_raises(ArgumentError) { rule.call({ name: "X", when: :create }) }
    assert_raises(ArgumentError) { rule.call({ on: :create }) }
    assert_raises(ArgumentError) { rule.call({ name: "X", on: :archive }) }
    assert_raises(ArgumentError) { rule.call({ class: String }) }
    assert_equal %i[create update destroy], rule.call({ name: "X" }).operations
  end

  private

  def use(mode)
    case mode
    when :monitor then Lyra.config.enable_monitor!
    when :hijack then Lyra.config.enable_hijack!
    else
      Lyra.config.enable_event_sourcing!
      Lyra.config.projection_mode = mode == :es_noproj ? :disabled : :sync
    end
  end

  def stream(user) = Lyra.config.event_store.read.stream("DomUser$#{user.id}").to_a

  def types(user) = stream(user).map { _1.class.name.split("::").last }

  def connection = ActiveRecord::Base.connection

  def clean
    connection.execute("DELETE FROM users")
    connection.execute("DELETE FROM event_store_events_in_streams")
    connection.execute("DELETE FROM event_store_events")
  end
end
