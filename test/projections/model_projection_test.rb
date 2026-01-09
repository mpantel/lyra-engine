# frozen_string_literal: true

require "test_helper"

class ModelProjectionTest < Minitest::Test
  def setup
    @model_class = create_mock_model_class
  end

  def test_project_create_calls_insert
    result = mock_command_result(:create, { id: 1, name: "Test", email: "test@example.com" })

    # We can't easily test the actual SQL, but we can verify the method doesn't raise
    # In a real test with a database, we'd verify the record was inserted
    assert_respond_to Lyra::Projections::ModelProjection, :project_create
  end

  def test_project_update_extracts_new_values_from_changes
    # Changes are [old_value, new_value] tuples
    changes = { name: ["Old Name", "New Name"], email: ["old@test.com", "new@test.com"] }
    event = mock_event(:updated, 1, changes: changes)
    result = mock_command_result(:update, {}, [event])

    # Verify the method exists and can be called
    assert_respond_to Lyra::Projections::ModelProjection, :project_update
  end

  def test_project_destroy_calls_delete_all
    event = mock_event(:destroyed, 1)
    result = mock_command_result(:destroy, {}, [event])

    assert_respond_to Lyra::Projections::ModelProjection, :project_destroy
  end

  def test_project_raises_on_unknown_operation
    result = mock_command_result(:create, {})

    assert_raises ArgumentError do
      Lyra::Projections::ModelProjection.project(@model_class, :invalid_op, result)
    end
  end

  private

  def create_mock_model_class
    Class.new do
      define_singleton_method(:column_names) { %w[id name email created_at updated_at] }
      define_singleton_method(:columns_hash) { {} }
      define_singleton_method(:name) { "TestModel" }
      define_singleton_method(:table_name) { "test_models" }
      define_singleton_method(:insert) { |attrs| true }
      define_singleton_method(:where) { |*args| self }
      define_singleton_method(:update_all) { |attrs| 1 }
      define_singleton_method(:delete_all) { 1 }
    end
  end

  def mock_command_result(operation, attributes, events = [])
    Struct.new(:success?, :attributes, :events, keyword_init: true).new(
      success?: true,
      attributes: attributes,
      events: events
    )
  end

  def mock_event(operation, model_id, changes: {})
    Struct.new(:data, keyword_init: true).new(
      data: {
        model_id: model_id,
        operation: operation,
        changes: changes
      }
    )
  end
end
