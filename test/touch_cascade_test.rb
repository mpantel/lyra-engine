# frozen_string_literal: true

require "test_helper"

# belongs_to ... touch: true: when a child is written, Rails touches the
# parent through touch_later, which sets the parent's updated_at at once,
# clears its change, and calls touch when the transaction commits. Lyra's
# touch saw no change by then and published nothing, so the parent's row
# moved and its stream did not; with timestamps compared, DualView then
# reported every touched parent.
class TouchCascadeTest < Minitest::Test
  def setup
    skip "Requires Rails and database" unless defined?(ActiveRecord::Base) && ActiveRecord::Base.connection.table_exists?(:articles)

    Object.send(:remove_const, :CascadeChild) if defined?(CascadeChild)
    Object.send(:remove_const, :CascadeParent) if defined?(CascadeParent)
    Object.const_set(:CascadeParent, Class.new(ActiveRecord::Base) { self.table_name = "users" })
    Object.const_set(:CascadeChild, Class.new(ActiveRecord::Base) do
      self.table_name = "articles"
      belongs_to :author, class_name: "CascadeParent", optional: true, touch: true
    end)
    [CascadeParent, CascadeChild].each do |model|
      model.include(Lyra::Interceptors::CrudInterceptor)
      model.monitor_with_lyra
      Lyra.config.monitor_model(model)
    end
    clean
  end

  def teardown
    return unless defined?(CascadeParent)

    Lyra.config.enable_monitor!
    clean
  end

  %i[enable_monitor! enable_hijack!].each do |mode|
    define_method(:"test_a_touch_cascade_records_the_parent_s_updated_at_in_#{mode.to_s.delete_suffix('!').delete_prefix('enable_')}") do
      Lyra.config.public_send(mode)
      parent = CascadeParent.create!(name: "Ann", email: "ann-#{mode}@example.com")
      child = CascadeChild.create!(title: "t", author: parent)
      before = row_updated_at(parent)
      sleep 0.01
      child.update!(title: "u")

      assert_operator row_updated_at(parent), :>, before, "Rails touched the parent's row"
      last = stream(parent).last
      changes = last.data[:changes] || last.data["changes"]
      assert changes.key?("updated_at"), "the touch is in the parent's stream: #{stream(parent).map(&:event_type).inspect}"
      assert_equal({}, Lyra::DualView.new(CascadeParent, parent.id).calculate_differences, "row and events agree")
    end
  end

  def test_two_deferred_touches_in_one_transaction_record_the_first_old_value
    Lyra.config.enable_monitor!
    parent = CascadeParent.create!(name: "Bo", email: "bo@example.com")
    child = CascadeChild.create!(title: "t", author: parent)
    before = row_updated_at(parent)
    sleep 0.01
    CascadeChild.transaction do
      child.update!(title: "u")
      child.update!(title: "v")
    end

    changes = stream(parent).last.data.then { |d| d[:changes] || d["changes"] }
    old_value = changes["updated_at"].first
    old_value = Time.zone.parse(old_value) if old_value.is_a?(String)
    assert_in_delta before.to_f, old_value.to_f, 0.001, "the old value is the row's before the transaction"
    assert_equal({}, Lyra::DualView.new(CascadeParent, parent.id).calculate_differences)
  end

  private

  def stream(record) = Lyra.config.event_store.read.stream(Lyra.stream_name(record.class, record.id)).to_a

  def row_updated_at(record)
    ActiveRecord::Base.connection.select_value("SELECT updated_at FROM users WHERE id = #{record.id}")
  end

  def clean
    conn = ActiveRecord::Base.connection
    conn.execute("DELETE FROM articles")
    conn.execute("DELETE FROM users")
    conn.execute("DELETE FROM event_store_events_in_streams")
    conn.execute("DELETE FROM event_store_events")
  end
end
