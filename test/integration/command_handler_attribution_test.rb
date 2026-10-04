# frozen_string_literal: true

require "test_helper"

# Hijack and event-sourcing writes go through the CommandHandler. Their events
# carry the same attribution metadata as Monitor's (user_id, request_id, the
# user action, config.metadata_proc), their updates and destroys load the
# aggregate's history, and the audit trail reads user_id from the metadata.
class CommandHandlerAttributionTest < Minitest::Test
  class AttributionCurrent < ActiveSupport::CurrentAttributes
    attribute :user, :request_id
  end

  # Records every aggregate GenericAggregate.load returns while switched on.
  module LoadedAggregates
    class << self
      attr_accessor :list

      def install
        Lyra::GenericAggregate.singleton_class.prepend(self) unless Lyra::GenericAggregate.singleton_class.include?(self)
      end
    end

    def load(*args)
      super.tap { |aggregate| LoadedAggregates.list&.push(aggregate) }
    end
  end

  def setup
    skip "Requires Rails and database" unless defined?(ActiveRecord::Base) && ActiveRecord::Base.connection.table_exists?(:users)

    Object.send(:remove_const, :AttrUser) if defined?(AttrUser)
    Object.const_set(:AttrUser, Class.new(ActiveRecord::Base) do
      self.table_name = "users"
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
    end)
    Lyra.config.monitor_model(AttrUser)
    clean
  end

  def teardown
    return unless defined?(AttrUser)

    Lyra.config.metadata_proc = nil
    Lyra.config.projection_mode = :sync
    LoadedAggregates.list = nil
    clean
  end

  [:monitor, :hijack, :event_sourcing].each do |mode|
    define_method("test_#{mode}_events_carry_user_request_and_metadata_proc") do
      Lyra.config.mode = mode
      Lyra.config.projection_mode = :sync
      Lyra.config.metadata_proc = ->(record, operation) { { tenant: "t-#{record.name}", op: operation.to_s } }

      user = with_current(user_id: 42, request_id: "req-9") do
        u = AttrUser.create!(name: "Ann", email: "ann@example.com")
        u.update!(name: "Ann")
        u.update!(email: "ann2@example.com")
        u
      end

      metadata = stream(user).map { |e| e.metadata.to_h }
      assert_equal 3, metadata.size
      metadata.each do |m|
        assert_equal 42, m[:user_id], "#{mode}: user_id"
        assert_equal "req-9", m[:request_id], "#{mode}: request_id"
        assert_equal "t-Ann", m[:tenant], "#{mode}: metadata_proc reaches the event"
      end
      assert_equal %w[created updated], metadata.map { |m| m[:op] }.uniq
      assert_equal "lyra_command_handler", metadata.first[:source] unless mode == :monitor
    end
  end

  def test_a_command_without_a_record_still_works
    Lyra.config.mode = :hijack
    Lyra.config.metadata_proc = ->(_record, _operation) { raise "must not be called without a record" }

    result = Lyra::CommandHandler.handle(Lyra::Commands::CreateCommand.new(AttrUser, { "name" => "Bo", "email" => "bo@example.com" }))

    assert result.success?, result.error.inspect
    metadata = result.events.first.metadata.to_h
    assert_equal "lyra_command_handler", metadata[:source]
    assert_nil metadata[:user_id]
  end

  [:hijack, :event_sourcing].each do |mode|
    define_method("test_#{mode}_update_and_destroy_load_a_custom_aggregate_history") do
      Lyra.config.mode = mode
      Lyra.config.projection_mode = :sync
      LoadedAggregates.install
      LoadedAggregates.list = []
      Lyra.config.model_config(AttrUser).aggregate_class = Class.new(Lyra::GenericAggregate)

      user = AttrUser.create!(name: "Cy", email: "cy@example.com")
      user.update!(name: "Cy2")
      user.reload.destroy!

      versions = LoadedAggregates.list.map(&:version)
      assert_equal [1, 2], versions, "the update loads the created event, the destroy both"
      assert_equal "AttrUser$#{user.id}", LoadedAggregates.list.first.stream_name
    ensure
      Lyra.config.model_config(AttrUser).aggregate_class = nil if defined?(AttrUser)
    end

    # The default aggregate decides nothing from history, so its updates and
    # destroys read no stream (no SQL added to the write).
    define_method("test_#{mode}_default_aggregate_reads_no_history") do
      Lyra.config.mode = mode
      Lyra.config.projection_mode = :sync
      LoadedAggregates.install
      LoadedAggregates.list = []

      user = AttrUser.create!(name: "Di", email: "di@example.com")
      user.update!(name: "Di2")
      user.reload.destroy!

      assert_empty LoadedAggregates.list
    end
  end

  def test_generic_aggregate_load_needs_and_uses_the_model_class
    Lyra.config.mode = :hijack
    user = AttrUser.create!(name: "Di", email: "di@example.com")

    aggregate = Lyra::GenericAggregate.load(user.id, Lyra.config.event_store, AttrUser)
    assert_equal 1, aggregate.version
    assert_raises(ArgumentError) { Lyra::GenericAggregate.load(user.id, Lyra.config.event_store) }
  end

  def test_a_programming_error_loading_the_aggregate_fails_the_write_visibly
    Lyra.config.mode = :hijack
    user = AttrUser.create!(name: "Ed", email: "ed@example.com")
    broken = Class.new(Lyra::GenericAggregate) do
      def self.name = "BrokenAggregate"
      def self.load(*) = nil.undefined_method_here
    end
    Lyra.config.model_config(AttrUser).aggregate_class = broken

    refute user.update(name: "Ed2"), "the write is refused, not made from an empty aggregate"
    assert_match(/undefined method/, user.errors[:base].join)
  ensure
    Lyra.config.model_config(AttrUser).aggregate_class = nil if defined?(AttrUser)
  end

  [:monitor, :hijack, :event_sourcing].each do |mode|
    define_method("test_#{mode}_audit_trail_reads_user_id_from_the_event_metadata") do
      Lyra.config.mode = mode
      Lyra.config.projection_mode = :sync
      user = with_current(user_id: 7) do
        AttrUser.create!(name: "Fa", email: "fa@example.com").tap { |u| u.update!(name: "Fa2") }
      end

      trail = Lyra::AuditProjection.audit_trail(AttrUser, user.id)
      assert_equal [7, 7], trail.map { |entry| entry[:user_id] }
    end
  end

  def test_audit_trail_falls_back_to_user_id_nested_in_old_event_data
    event = Lyra::Event.new(data: { operation: :created, metadata: { user_id: 3 } })
    Lyra.config.event_store.publish(event, stream_name: "AttrUser$999")

    assert_equal [3], Lyra::AuditProjection.audit_trail(AttrUser, 999).map { |entry| entry[:user_id] }
  end

  private

  def stream(user)
    Lyra.config.event_store.read.stream("AttrUser$#{user.id}").to_a
  end

  def with_current(user_id:, request_id: nil)
    original = Object.send(:remove_const, :Current) if Object.const_defined?(:Current, false)
    Object.const_set(:Current, AttributionCurrent)
    AttributionCurrent.user = Struct.new(:id).new(user_id)
    AttributionCurrent.request_id = request_id
    yield
  ensure
    AttributionCurrent.reset
    Object.send(:remove_const, :Current) if Object.const_defined?(:Current, false)
    Object.const_set(:Current, original) if original
  end

  def clean
    conn = ActiveRecord::Base.connection
    conn.execute("DELETE FROM users")
    conn.execute("DELETE FROM event_store_events_in_streams")
    conn.execute("DELETE FROM event_store_events")
  end
end
