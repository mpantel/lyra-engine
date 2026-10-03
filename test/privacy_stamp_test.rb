# frozen_string_literal: true

require "test_helper"

# Privacy Policy Coverage, step 1 (Lyra::Privacy.stamp): with
# config.annotate_privacy on, every event that carries a declared attribute
# is stamped, when it is built, with the policy's name and each such
# attribute's type, sensitivity and purposes, never a value.
class PrivacyStampTest < Minitest::Test
  def setup
    skip "Requires Rails and database" unless defined?(ActiveRecord::Base) && ActiveRecord::Base.connection.table_exists?(:users)
    skip "Requires pam_dsl" unless Lyra.pam_dsl_available?

    PamDsl.reset!
    define_policy(email_sensitivity: :confidential)
    Object.send(:remove_const, :StampUser) if defined?(StampUser)
    Object.const_set(:StampUser, Class.new(ActiveRecord::Base) { self.table_name = "users" })
    StampUser.include(Lyra::Interceptors::CrudInterceptor)
    StampUser.monitor_with_lyra(privacy_policy: :stamp_policy)
    Lyra.config.monitor_model(StampUser, privacy_policy: :stamp_policy)
    clean
    Lyra.config.annotate_privacy = true
    Lyra.config.enable_monitor!
  end

  def teardown
    return unless defined?(StampUser)

    Lyra.config.projection_mode = :sync
    clean
    PamDsl.reset!
  end

  %i[monitor hijack es_sync].each do |mode|
    define_method("test_#{mode}_a_create_is_stamped_with_every_declared_attribute_it_carries") do
      use(mode)
      user = StampUser.create!(name: "Ann", email: "ann@example.com")

      privacy = privacy_of(stream(user).first)
      assert_equal "stamp_policy", privacy["policy"]
      assert_equal %w[email name], privacy["fields"].keys.sort
      # PAM retains for 7 years unless a policy says otherwise.
      assert_equal({ "type" => "email", "sensitivity" => "confidential", "purposes" => ["contact"], "retention" => "P7Y" },
                   privacy["fields"]["email"])
      refute_includes stream(user).first.metadata.to_h.to_s, "ann@example.com", "never a value"
    end
  end

  # Monitor's update event carries the whole row as well as the change:
  # every declared attribute it carries is annotated, not only the changed.
  def test_an_update_is_stamped_with_every_declared_attribute_it_carries
    user = StampUser.create!(name: "Ann", email: "ann@example.com")
    user.update!(name: "Anna")

    event = stream(user).last
    carried = (event.data[:attributes] || {}).keys.map(&:to_s) | (event.data[:changes] || {}).keys.map(&:to_s)
    assert_equal carried & %w[email name], privacy_of(event)["fields"].keys.sort
    assert_includes privacy_of(event)["fields"].keys, "name"
  end

  def test_a_destroy_is_stamped_with_what_it_carries
    user = StampUser.create!(name: "Ann", email: "ann@example.com")
    user.destroy!

    assert_includes privacy_of(stream(user).last)["fields"].keys, "email"
  end

  def test_bypass_writes_and_imports_are_stamped_too
    user = StampUser.create!(name: "Ann", email: "ann@example.com")
    StampUser.where(id: user.id).update_all(name: "Anna")
    assert_equal %w[name], privacy_of(stream(user).last)["fields"].keys, "a bypass event"

    raw("INSERT INTO users (name, email, created_at, updated_at) VALUES ('Old', 'old@example.com', now(), now())")
    old_id = raw("SELECT id FROM users WHERE name = 'Old'")
    Lyra::Genesis.import_all(StampUser)
    imported = Lyra.config.event_store.read.stream("StampUser$#{old_id}").first
    assert_equal %w[email name], privacy_of(imported)["fields"].keys.sort, "an Imported event"
  end

  def test_domain_events_carry_the_stamp
    rules = [{ name: "MemberJoined", on: :create }]
    StampUser.monitor_with_lyra(privacy_policy: :stamp_policy, domain_events: rules)
    Lyra.config.monitor_model(StampUser, privacy_policy: :stamp_policy, domain_events: rules)
    user = StampUser.create!(name: "Ann", email: "ann@example.com")

    event = stream(user).first
    assert_equal "Lyra::Events::MemberJoined", event.event_type
    assert_equal "stamp_policy", privacy_of(event)["policy"]
  end

  # The stamp records the policy as it was when the data was written;
  # annotations_for would read today's policy.
  def test_a_later_reclassification_does_not_rewrite_the_stamp
    user = StampUser.create!(name: "Ann", email: "ann@example.com")
    PamDsl.reset!
    define_policy(email_sensitivity: :restricted)

    stored = stream(user).first
    assert_equal "confidential", privacy_of(stored)["fields"]["email"]["sensitivity"]
    assert_equal :restricted, Lyra::Privacy.annotations_for(stored)["email"].sensitivity
  end

  # Theorem 3, step 1: purpose limitation, retention period and the
  # applicable transformations.
  def test_the_stamp_carries_retention_and_transformations
    PamDsl.reset!
    PamDsl.define_policy(:stamp_policy) do
      field :email, type: :email, sensitivity: :confidential do
        allow_for :contact
        transform(:display) { |v| v.to_s.sub(/.*@/, "***@") }
      end
      field :name, type: :name
      purpose :contact do
        basis :contract
        requires :email
      end
      retention do
        default 5.years
        for_model("StampUser") { keep_for 7.years }
      end
    end
    user = StampUser.create!(name: "Ann", email: "ann@example.com")

    email = privacy_of(stream(user).first)["fields"]["email"]
    assert_equal "P7Y", email["retention"]
    assert_equal ["display"], email["transformations"]
  end

  def test_off_by_default_and_without_a_policy_nothing_is_stamped
    refute Lyra::Configuration.new.annotate_privacy

    Lyra.config.annotate_privacy = false
    user = StampUser.create!(name: "Ann", email: "ann@example.com")
    assert_nil privacy_of(stream(user).first)

    Lyra.config.annotate_privacy = true
    StampUser.monitor_with_lyra
    Lyra.config.monitor_model(StampUser)
    other = StampUser.create!(name: "Bob", email: "bob@example.com")
    assert_nil privacy_of(stream(other).first), "no policy, nothing to stamp"
  end

  private

  def define_policy(email_sensitivity:)
    PamDsl.define_policy(:stamp_policy) do
      field :email, type: :email, sensitivity: email_sensitivity do
        allow_for :contact
      end
      field :name, type: :name
      purpose :contact do
        basis :contract
        requires :email
      end
    end
  end

  def use(mode)
    case mode
    when :monitor then Lyra.config.enable_monitor!
    when :hijack then Lyra.config.enable_hijack!
    else
      Lyra.config.enable_event_sourcing!
      Lyra.config.projection_mode = :sync
    end
  end

  def privacy_of(event) = Lyra::Privacy.stamp_of(event)

  def stream(user) = Lyra.config.event_store.read.stream("StampUser$#{user.id}").to_a

  def raw(sql) = ActiveRecord::Base.connection.select_value(sql)

  def clean
    conn = ActiveRecord::Base.connection
    conn.execute("DELETE FROM users")
    conn.execute("DELETE FROM event_store_events_in_streams")
    conn.execute("DELETE FROM event_store_events")
  end
end
