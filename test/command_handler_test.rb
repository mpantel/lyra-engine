# frozen_string_literal: true

require "test_helper"

module Lyra
  class CommandHandlerTest < Minitest::Test
    def setup
      Lyra.reset_config!

      # Create a mock event store
      @mock_event_store = Object.new
      @mock_event_store.define_singleton_method(:publish) { |*_args| true }
      @mock_event_store.define_singleton_method(:read) do
        reader = Object.new
        reader.define_singleton_method(:stream) { |_| self }
        reader.define_singleton_method(:to_a) { [] }
        reader
      end

      # Configure Lyra with the mock event store
      Lyra.configure do |config|
        config.mode = :hijack
        config.event_store = @mock_event_store
      end

      # Create a mock model class with integer primary key
      @model_class = Class.new do
        def self.name
          "TestModel"
        end

        def self.primary_key
          "id"
        end

        def self.columns_hash
          {
            "id" => OpenStruct.new(type: :integer)
          }
        end
      end

      # Create a mock model class with UUID primary key
      @uuid_model_class = Class.new do
        def self.name
          "UuidModel"
        end

        def self.primary_key
          "id"
        end

        def self.columns_hash
          {
            "id" => OpenStruct.new(type: :uuid)
          }
        end
      end

      # These are unit tests with stub models and no database. ID generation has
      # its own tests (id_generator_test.rb); here a reserved integer is enough.
      Lyra::IdGenerator.stubs(:next_id).returns(1001)
      Lyra::IdGenerator.stubs(:next_id).with(@uuid_model_class).returns(SecureRandom.uuid)
      # Stub models have no table: say the ids can be reserved safely, as on
      # PostgreSQL with a sequence. The unsafe case has its own test below.
      Lyra::IdGenerator.stubs(:reserves_safely?).returns(true)

      # Configure Lyra to monitor these models
      Lyra.config.monitor_model(@model_class, event_prefix: "TestModel")
      Lyra.config.monitor_model(@uuid_model_class, event_prefix: "UuidModel")
    end

    def teardown
      Lyra.reset_config!
    end

    # =========================================================================
    # Integer Primary Key Tests
    # =========================================================================

    def test_handle_create_assigns_reserved_id_for_integer_primary_key
      command = Commands::CreateCommand.new(@model_class, { name: "Test" })
      result = CommandHandler.handle(command)

      assert result.success?
      # The row must be inserted under the ID the Created event carries. Leaving
      # it to the database used to strand the Created event in a placeholder
      # stream.
      assert_equal 1001, result.attributes[:id]
    end

    def test_handle_create_succeeds_for_a_namespaced_model
      # Solidus-style model name. The default event prefix is the model name, so
      # the event class name contains "::", which is not a valid constant name
      # unless it is stripped (as every other Lyra event path already does).
      namespaced = Class.new do
        def self.name = "Shop::Widget"
        def self.primary_key = "id"
        def self.columns_hash = { "id" => OpenStruct.new(type: :integer) }
      end
      Lyra.config.monitor_model(namespaced)

      result = CommandHandler.handle(Commands::CreateCommand.new(namespaced, { name: "Test" }))

      assert result.success?, result.error
      assert_equal Lyra::Events::ShopWidgetCreated, result.events.first.class
    end

    def test_handle_create_assigns_uuid_for_uuid_primary_key
      command = Commands::CreateCommand.new(@uuid_model_class, { name: "Test" })
      result = CommandHandler.handle(command)

      assert result.success?
      # For UUID primary keys, id should be assigned
      assert result.attributes.key?(:id), "ID should be assigned for UUID primary key models"
      assert_match(/\A[0-9a-f-]{36}\z/i, result.attributes[:id])
    end

    # =========================================================================
    # Missing Aggregate Handling Tests
    # =========================================================================

    def test_handle_update_succeeds_without_prior_event_history
      # Update a record that has no event history (e.g., seeded data)
      command = Commands::UpdateCommand.new(@model_class, 12345, { name: ["Old", "New"] })
      result = CommandHandler.handle(command)

      # Should succeed even without prior aggregate
      assert result.success?, "Update should succeed for records without event history"
      assert result.events.any?, "Should generate update event"
    end

    def test_handle_destroy_succeeds_without_prior_event_history
      # Destroy a record that has no event history
      command = Commands::DestroyCommand.new(@model_class, 67890)
      result = CommandHandler.handle(command)

      # Should succeed even without prior aggregate
      assert result.success?, "Destroy should succeed for records without event history"
      assert result.events.any?, "Should generate destroy event"
    end

    # =========================================================================
    # Event Generation Tests
    # =========================================================================

    def test_handle_create_generates_created_event
      command = Commands::CreateCommand.new(@model_class, { name: "Test", email: "test@example.com" })
      result = CommandHandler.handle(command)

      assert result.success?
      assert_equal 1, result.events.length

      event = result.events.first
      assert_equal "TestModelCreated", event.class.name.split("::").last
    end

    def test_handle_update_generates_updated_event
      command = Commands::UpdateCommand.new(@model_class, 1, { name: ["Old", "New"] })
      result = CommandHandler.handle(command)

      assert result.success?
      assert_equal 1, result.events.length

      event = result.events.first
      assert_equal "TestModelUpdated", event.class.name.split("::").last
    end

    def test_handle_destroy_generates_destroyed_event
      command = Commands::DestroyCommand.new(@model_class, 1)
      result = CommandHandler.handle(command)

      assert result.success?
      assert_equal 1, result.events.length

      event = result.events.first
      assert_equal "TestModelDestroyed", event.class.name.split("::").last
    end

    # =========================================================================
    # Event Data Tests
    # =========================================================================

    def test_create_event_contains_model_class
      command = Commands::CreateCommand.new(@model_class, { name: "Test" })
      result = CommandHandler.handle(command)

      event = result.events.first
      assert_equal "TestModel", event.data[:model_class]
    end

    def test_create_event_contains_operation
      command = Commands::CreateCommand.new(@model_class, { name: "Test" })
      result = CommandHandler.handle(command)

      event = result.events.first
      assert_equal :created, event.data[:operation]
    end

    def test_create_event_contains_timestamp
      command = Commands::CreateCommand.new(@model_class, { name: "Test" })
      result = CommandHandler.handle(command)

      event = result.events.first
      assert event.data[:timestamp].present?
    end

    def test_update_event_contains_changes
      command = Commands::UpdateCommand.new(@model_class, 1, { name: ["Old", "New"] })
      result = CommandHandler.handle(command)

      event = result.events.first
      assert event.data[:changes].present?
    end

    # =========================================================================
    # Event Metadata Tests
    # =========================================================================

    def test_event_contains_source_metadata
      command = Commands::CreateCommand.new(@model_class, { name: "Test" })
      result = CommandHandler.handle(command)

      event = result.events.first
      assert_equal "lyra_command_handler", event.metadata[:source]
    end

    def test_event_contains_correlation_id
      Lyra::Correlation.stubs(:current_id).returns("test-correlation-id")

      command = Commands::CreateCommand.new(@model_class, { name: "Test" })
      result = CommandHandler.handle(command)

      event = result.events.first
      assert_equal "test-correlation-id", event.metadata[:correlation_id]
    end

    def test_event_contains_causation_id
      Lyra::Causation.stubs(:current_id).returns("test-causation-id")

      command = Commands::CreateCommand.new(@model_class, { name: "Test" })
      result = CommandHandler.handle(command)

      event = result.events.first
      assert_equal "test-causation-id", event.metadata[:causation_id]
    end

    # =========================================================================
    # Error Handling Tests
    # =========================================================================

    def test_handle_unknown_command_returns_failure
      unknown_command = Object.new

      result = CommandHandler.handle(unknown_command)

      refute result.success?
      assert_includes result.error, "Unknown command type"
    end

    def test_handle_returns_failure_on_exception
      # Create a mock model class that raises during aggregate creation
      broken_model_class = Class.new do
        def self.name
          raise StandardError, "Model access failed"
        end

        def self.primary_key
          "id"
        end

        def self.columns_hash
          { "id" => OpenStruct.new(type: :integer) }
        end
      end

      # Register this model but it will fail when trying to get event name
      Lyra.config.monitor_model(broken_model_class, event_prefix: "BrokenModel")

      command = Commands::CreateCommand.new(broken_model_class, { name: "Test" })
      result = CommandHandler.handle(command)

      refute result.success?
      assert result.error.present?
    end

    # =========================================================================
    # Event Sourcing Mode Tests
    # =========================================================================

    def test_event_sourcing_mode_assigns_id_for_integer_primary_key
      Lyra.config.mode = :event_sourcing
      Lyra::IdGenerator.stubs(:next_id).returns(999)

      command = Commands::CreateCommand.new(@model_class, { name: "Test" })
      result = CommandHandler.handle(command)

      assert result.success?
      assert_equal 999, result.attributes[:id]
    end

    def test_hijack_mode_reserves_the_real_id_for_integer_key
      Lyra.config.mode = :hijack
      Lyra::IdGenerator.stubs(:next_id).returns(42)

      command = Commands::CreateCommand.new(@model_class, { name: "Test" })
      result = CommandHandler.handle(command)

      # The ID the row will be inserted with is the one the event carries,
      # never a "pending-" placeholder that no later event or reader can find.
      assert result.success?
      assert_equal 42, result.attributes[:id]
      event = result.events.first
      assert_equal 42, event.data[:model_id] || event.data["model_id"]
    end

    # =========================================================================
    # Aggregate Tests
    # =========================================================================

    def test_uses_generic_aggregate_when_no_custom_class
      command = Commands::CreateCommand.new(@model_class, { name: "Test" })
      result = CommandHandler.handle(command)

      # Should succeed using GenericAggregate
      assert result.success?
    end

    def test_an_explicit_id_is_kept_under_a_single_key
      command = Commands::CreateCommand.new(@uuid_model_class, { "id" => "chosen-id", name: "Test" })
      result = CommandHandler.handle(command)

      assert result.success?
      # The application's id is kept (it used to be replaced by a generated
      # one), and only as :id, so the string key cannot conflict with it.
      assert_equal "chosen-id", result.attributes[:id]
      refute result.attributes.key?("id")
      assert_equal "chosen-id", result.events.first.data[:model_id]
    end

    # Hijack mode inserts the row while the database may assign ids to other
    # inserts. Where Lyra cannot reserve an id that the database will never
    # hand out (no UUID key, no PostgreSQL sequence), it must not guess one.
    def test_hijack_mode_falls_back_to_a_placeholder_where_reserving_is_unsafe
      Lyra.config.mode = :hijack
      Lyra::IdGenerator.stubs(:reserves_safely?).returns(false)
      Lyra::IdGenerator.expects(:next_id).never

      result = CommandHandler.handle(Commands::CreateCommand.new(@model_class, { name: "Test" }))

      assert result.success?
      refute result.attributes.key?(:id), "the database assigns the id"
      assert_match(/\Apending-/, result.events.first.data[:model_id])
    end

    # =========================================================================
    # Class Method Tests
    # =========================================================================

    def test_class_handle_method_delegates_to_instance
      command = Commands::CreateCommand.new(@model_class, { name: "Test" })

      result = CommandHandler.handle(command)

      assert result.success?
    end

    def test_command_accessor
      command = Commands::CreateCommand.new(@model_class, { name: "Test" })
      handler = CommandHandler.new(command)

      assert_equal command, handler.command
    end
  end
end
