# frozen_string_literal: true

require "test_helper"

# The configuration surface the thesis describes (FEATURE_GAP_PLAN F2):
# config.models=, config.verify_mapping! and config.privacy_policy=.
class ConfigurationSurfaceTest < Minitest::Test
  def setup
    skip "Requires Rails and database" unless defined?(ActiveRecord::Base) && ActiveRecord::Base.connection.table_exists?(:users)

    %i[SurfaceUser SurfaceArticle SurfaceGhost].each { |c| Object.send(:remove_const, c) if Object.const_defined?(c) }
    Object.const_set(:SurfaceUser, Class.new(ActiveRecord::Base) { self.table_name = "users" })
    Object.const_set(:SurfaceArticle, Class.new(ActiveRecord::Base) { self.table_name = "articles" })
    connection.execute("DELETE FROM users")
    connection.execute("DELETE FROM event_store_events_in_streams")
    connection.execute("DELETE FROM event_store_events")
    Lyra.config.enable_monitor!
  end

  def teardown
    return unless defined?(SurfaceUser)

    connection.execute("DELETE FROM users")
    connection.execute("DELETE FROM event_store_events_in_streams")
    connection.execute("DELETE FROM event_store_events")
  end

  def test_models_declared_by_name_are_monitored_without_editing_them
    Lyra.config.models = %w[SurfaceUser SurfaceArticle]
    Lyra.config.apply_declared_models!

    assert SurfaceUser.lyra_monitored
    assert_includes Lyra.config.monitored_models, SurfaceArticle
    SurfaceUser.create!(name: "Ann", email: "ann@example.com")
    assert_equal 1, connection.select_value("SELECT count(*) FROM event_store_events").to_i
  end

  def test_declared_models_take_their_options
    Lyra.config.models = { "SurfaceUser" => { event_prefix: "Member" } }
    Lyra.config.apply_declared_models!

    SurfaceUser.create!(name: "Ann", email: "ann@example.com")
    assert_equal "Lyra::Events::MemberCreated", connection.select_value("SELECT event_type FROM event_store_events")
  end

  def test_a_name_that_does_not_resolve_fails
    Lyra.config.models = %w[SurfaceUser NoSuchModel]
    error = assert_raises(ArgumentError) { Lyra.config.apply_declared_models! }
    assert_match(/NoSuchModel/, error.message)
  end

  def test_the_default_privacy_policy_applies_unless_a_model_names_its_own
    skip "Requires pam_dsl" unless Lyra.pam_dsl_available?

    PamDsl.define_policy(:surface_default) { field :email, type: :email }
    PamDsl.define_policy(:surface_own) { field :name, type: :name }
    Lyra.config.privacy_policy = :surface_default
    SurfaceUser.monitor_with_lyra
    SurfaceArticle.monitor_with_lyra(privacy_policy: :surface_own)

    assert_equal :surface_default, Lyra::Privacy.policy_for(SurfaceUser).name
    assert_equal :surface_own, Lyra::Privacy.policy_for(SurfaceArticle).name
  ensure
    PamDsl.reset! if Lyra.pam_dsl_available?
  end

  def test_verify_mapping_passes_on_a_sound_configuration
    skip "Requires petri_flow" unless Lyra.petri_flow_available?

    SurfaceUser.monitor_with_lyra
    report = Lyra.verify_mapping!
    assert report[:summary][:deadlock_free]
    assert report[:summary][:bypass_covered]
  end

  def test_verify_mapping_names_a_model_without_a_table
    skip "Requires petri_flow" unless Lyra.petri_flow_available?

    Object.const_set(:SurfaceGhost, Class.new(ActiveRecord::Base) { self.table_name = "no_such_table" })
    SurfaceGhost.monitor_with_lyra
    error = assert_raises(Lyra::MappingVerificationError) { Lyra.verify_mapping! }
    assert_match(/SurfaceGhost: table no_such_table does not exist/, error.message)
  end

  def test_in_the_initializer_verify_mapping_waits_for_boot
    booted = Lyra.booted?
    Lyra.instance_variable_set(:@booted, false)
    Lyra.config.verify_mapping!
    assert Lyra.config.verify_mapping_at_boot?
  ensure
    Lyra.instance_variable_set(:@booted, booted)
  end

  private

  def connection = ActiveRecord::Base.connection
end
