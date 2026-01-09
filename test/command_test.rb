require "test_helper"

module Lyra
  class CommandTest < Minitest::Test
    def setup
      @model_class = Class.new
      @model_class.define_singleton_method(:name) { "TestModel" }
    end

    def test_command_initialization
      command = Command.new(@model_class, { name: "Test" })

      assert_equal @model_class, command.model_class
      assert_equal({ name: "Test" }, command.data)
    end

    def test_command_aggregate_id_with_symbol_key
      command = Command.new(@model_class, { id: 123, name: "Test" })

      assert_equal 123, command.aggregate_id
    end

    def test_command_aggregate_id_with_string_key
      command = Command.new(@model_class, { 'id' => 456, name: "Test" })

      assert_equal 456, command.aggregate_id
    end

    def test_create_command
      attributes = { name: "Alice", email: "alice@example.com" }
      command = Commands::CreateCommand.new(@model_class, attributes)

      assert_equal @model_class, command.model_class
      assert_equal attributes, command.attributes
    end

    def test_update_command
      changes = { name: ["Old", "New"] }
      command = Commands::UpdateCommand.new(@model_class, 123, changes)

      assert_equal @model_class, command.model_class
      assert_equal 123, command.id
      assert_equal changes, command.changes
    end

    def test_destroy_command
      command = Commands::DestroyCommand.new(@model_class, 789)

      assert_equal @model_class, command.model_class
      assert_equal 789, command.id
    end

    def test_command_result_success
      result = CommandResult.success(
        attributes: { id: 1, name: "Test" },
        events: [:event1, :event2]
      )

      assert result.success?
      refute result.failure?
      assert_equal({ id: 1, name: "Test" }, result.attributes)
      assert_equal [:event1, :event2], result.events
      assert_nil result.error
    end

    def test_command_result_failure
      result = CommandResult.failure(error: "Something went wrong")

      refute result.success?
      assert result.failure?
      assert_equal "Something went wrong", result.error
      assert_equal({}, result.attributes)
      assert_equal [], result.events
    end

    def test_command_result_initialization
      result = CommandResult.new(
        success: true,
        attributes: { id: 1 },
        events: [:event],
        error: nil
      )

      assert result.success?
      assert_equal({ id: 1 }, result.attributes)
      assert_equal [:event], result.events
    end
  end
end
