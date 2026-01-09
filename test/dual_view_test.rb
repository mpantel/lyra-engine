require "test_helper"

module Lyra
  class DualViewTest < Minitest::Test
    def setup
      @model_class = Class.new
      @model_class.define_singleton_method(:name) { "TestModel" }
      @model_id = 123
      @dual_view = DualView.new(@model_class, @model_id)
    end

    def test_initialization
      assert_equal @model_class, @dual_view.model_class
      assert_equal @model_id, @dual_view.model_id
    end

    def test_calculate_differences_with_no_differences
      # Mock the state methods
      def @dual_view.crud_state
        { exists: true, attributes: { name: "Alice", age: 30 } }
      end

      def @dual_view.event_sourced_state
        { exists: true, state: { name: "Alice", age: 30 } }
      end

      differences = @dual_view.calculate_differences

      assert_equal({ no_differences: true }, differences)
    end

    def test_calculate_differences_with_attribute_differences
      def @dual_view.crud_state
        { exists: true, attributes: { name: "Alice", age: 30 } }
      end

      def @dual_view.event_sourced_state
        { exists: true, state: { name: "Alice", age: 31 } }
      end

      differences = @dual_view.calculate_differences

      assert differences.key?(:age)
      assert_equal 30, differences[:age][:crud]
      assert_equal 31, differences[:age][:event_sourced]
    end

    def test_calculate_differences_with_extra_crud_attributes
      def @dual_view.crud_state
        { exists: true, attributes: { name: "Bob", email: "bob@example.com", age: 25 } }
      end

      def @dual_view.event_sourced_state
        { exists: true, state: { name: "Bob", age: 25 } }
      end

      differences = @dual_view.calculate_differences

      assert differences.key?(:email)
      assert_equal "bob@example.com", differences[:email][:crud]
      assert_nil differences[:email][:event_sourced]
    end

    def test_calculate_differences_with_extra_event_sourced_attributes
      def @dual_view.crud_state
        { exists: true, attributes: { name: "Charlie" } }
      end

      def @dual_view.event_sourced_state
        { exists: true, state: { name: "Charlie", metadata: "extra_data" } }
      end

      differences = @dual_view.calculate_differences

      assert differences.key?(:metadata)
      assert_nil differences[:metadata][:crud]
      assert_equal "extra_data", differences[:metadata][:event_sourced]
    end

    def test_calculate_differences_with_existence_mismatch_crud_exists
      def @dual_view.crud_state
        { exists: true, attributes: { name: "David" } }
      end

      def @dual_view.event_sourced_state
        { exists: false }
      end

      differences = @dual_view.calculate_differences

      assert_equal({ exists_mismatch: true }, differences)
    end

    def test_calculate_differences_with_existence_mismatch_es_exists
      def @dual_view.crud_state
        { exists: false }
      end

      def @dual_view.event_sourced_state
        { exists: true, state: { name: "Eve" } }
      end

      differences = @dual_view.calculate_differences

      assert_equal({ exists_mismatch: true }, differences)
    end

    def test_calculate_differences_with_both_not_existing
      def @dual_view.crud_state
        { exists: false }
      end

      def @dual_view.event_sourced_state
        { exists: false }
      end

      differences = @dual_view.calculate_differences

      assert_equal({ no_differences: true }, differences)
    end
  end

  class StateAnalyzerTest < Minitest::Test
    def test_generate_recommendations_for_no_differences
      view = Object.new
      def view.compare
        {
          crud_view: { exists: true },
          event_sourced_view: { exists: true, events_count: 5 },
          differences: { no_differences: true }
        }
      end

      recommendations = StateAnalyzer.generate_recommendations(view)

      assert_empty recommendations
    end

    def test_generate_recommendations_for_existence_mismatch
      view = Object.new
      def view.compare
        {
          crud_view: { exists: true },
          event_sourced_view: { exists: false },
          differences: { exists_mismatch: true }
        }
      end

      recommendations = StateAnalyzer.generate_recommendations(view)

      assert recommendations.any? { |r| r.include?("existence mismatch") }
    end

    def test_generate_recommendations_for_attribute_differences
      view = Object.new
      def view.compare
        {
          crud_view: { exists: true },
          event_sourced_view: { exists: true, events_count: 3 },
          differences: { name: { crud: "Old", event_sourced: "New" }, age: { crud: 25, event_sourced: 26 } }
        }
      end

      recommendations = StateAnalyzer.generate_recommendations(view)

      assert recommendations.any? { |r| r.include?("Attribute differences") }
      assert recommendations.any? { |r| r.include?("name, age") }
    end

    def test_generate_recommendations_for_crud_without_events
      view = Object.new
      def view.compare
        {
          crud_view: { exists: true },
          event_sourced_view: { events_count: 0 },
          differences: { exists_mismatch: true }
        }
      end

      recommendations = StateAnalyzer.generate_recommendations(view)

      assert recommendations.any? { |r| r.include?("created before Lyra") }
    end
  end

  # Additional DualView tests for better coverage
  class DualViewExtendedTest < Minitest::Test
    def setup
      @model_class = Class.new
      @model_class.define_singleton_method(:name) { "TestModel" }
      @model_id = 123
      @dual_view = DualView.new(@model_class, @model_id)
    end

    def test_normalize_value_with_time
      dual_view = DualView.new(@model_class, @model_id)

      # Create two times that are equal when normalized
      def dual_view.crud_state
        { exists: true, attributes: { timestamp: Time.utc(2024, 1, 15, 12, 0, 0) } }
      end

      def dual_view.event_sourced_state
        { exists: true, state: { timestamp: Time.utc(2024, 1, 15, 12, 0, 0) } }
      end

      differences = dual_view.calculate_differences

      assert_equal({ no_differences: true }, differences)
    end

    def test_normalize_value_with_big_decimal
      def @dual_view.crud_state
        { exists: true, attributes: { price: BigDecimal("10.5") } }
      end

      def @dual_view.event_sourced_state
        { exists: true, state: { price: 10.5 } }
      end

      differences = @dual_view.calculate_differences

      assert_equal({ no_differences: true }, differences)
    end

    def test_normalize_value_with_numeric_string
      def @dual_view.crud_state
        { exists: true, attributes: { count: "42" } }
      end

      def @dual_view.event_sourced_state
        { exists: true, state: { count: 42 } }
      end

      differences = @dual_view.calculate_differences

      assert_equal({ no_differences: true }, differences)
    end

    def test_normalize_value_with_float_precision
      def @dual_view.crud_state
        # Use values that round to same 6-decimal place result
        { exists: true, attributes: { amount: 10.1234561 } }
      end

      def @dual_view.event_sourced_state
        { exists: true, state: { amount: 10.1234564 } }
      end

      differences = @dual_view.calculate_differences

      # After rounding to 6 decimals, both round to 10.123456 and should be equal
      assert_equal({ no_differences: true }, differences)
    end

    def test_ignores_timestamp_fields
      def @dual_view.crud_state
        { exists: true, attributes: { name: "Test", created_at: Time.now, updated_at: Time.now } }
      end

      def @dual_view.event_sourced_state
        { exists: true, state: { name: "Test" } }
      end

      differences = @dual_view.calculate_differences

      # Should ignore created_at and updated_at
      assert_equal({ no_differences: true }, differences)
    end

    def test_handles_string_and_symbol_keys
      def @dual_view.crud_state
        { exists: true, attributes: { "name" => "Test", "age" => 30 } }
      end

      def @dual_view.event_sourced_state
        { exists: true, state: { name: "Test", age: 30 } }
      end

      differences = @dual_view.calculate_differences

      assert_equal({ no_differences: true }, differences)
    end

    def test_handles_boolean_values
      def @dual_view.crud_state
        { exists: true, attributes: { active: true, verified: false } }
      end

      def @dual_view.event_sourced_state
        { exists: true, state: { active: true, verified: false } }
      end

      differences = @dual_view.calculate_differences

      assert_equal({ no_differences: true }, differences)
    end

    def test_handles_nil_values
      def @dual_view.crud_state
        { exists: true, attributes: { name: "Test", nickname: nil } }
      end

      def @dual_view.event_sourced_state
        { exists: true, state: { name: "Test", nickname: nil } }
      end

      differences = @dual_view.calculate_differences

      assert_equal({ no_differences: true }, differences)
    end

    def test_detects_nil_vs_non_nil_difference
      def @dual_view.crud_state
        { exists: true, attributes: { nickname: "Nick" } }
      end

      def @dual_view.event_sourced_state
        { exists: true, state: { nickname: nil } }
      end

      differences = @dual_view.calculate_differences

      assert differences.key?(:nickname)
      assert_equal "Nick", differences[:nickname][:crud]
      assert_nil differences[:nickname][:event_sourced]
    end

    def test_normalize_timestamp_string
      def @dual_view.crud_state
        { exists: true, attributes: { created: "2024-01-15T12:00:00Z" } }
      end

      def @dual_view.event_sourced_state
        { exists: true, state: { created: Time.utc(2024, 1, 15, 12, 0, 0) } }
      end

      differences = @dual_view.calculate_differences

      assert_equal({ no_differences: true }, differences)
    end

    def test_handles_non_standard_types
      # Objects that aren't Time, BigDecimal, String, etc. get converted to_s
      custom_obj = Object.new
      def custom_obj.to_s
        "custom_value"
      end

      def @dual_view.crud_state
        { exists: true, attributes: { custom: "custom_value" } }
      end

      # Can't easily test with dynamic object in event_sourced_state
      # so just verify no crash with missing attributes
      def @dual_view.event_sourced_state
        { exists: true, state: {} }
      end

      differences = @dual_view.calculate_differences

      assert differences.key?(:custom)
    end

    def test_handles_empty_attributes
      def @dual_view.crud_state
        { exists: true, attributes: {} }
      end

      def @dual_view.event_sourced_state
        { exists: true, state: {} }
      end

      differences = @dual_view.calculate_differences

      assert_equal({ no_differences: true }, differences)
    end

    def test_handles_nil_attributes
      def @dual_view.crud_state
        { exists: true, attributes: nil }
      end

      def @dual_view.event_sourced_state
        { exists: true, state: nil }
      end

      differences = @dual_view.calculate_differences

      assert_equal({ no_differences: true }, differences)
    end
  end

  # Tests for compare, crud_state, event_sourced_state, and helper methods
  class DualViewIntegrationTest < Minitest::Test
    def setup
      @event_store = RailsEventStore::Client.new
      Lyra.configure do |config|
        config.event_store = @event_store
        config.mode = :monitor
      end
    end

    def teardown
      Lyra.reset_config!
    end

    def test_compare_returns_full_comparison_structure
      dual_view = DualView.new(::User, 999)

      # Stub the state methods
      def dual_view.crud_state
        { exists: false }
      end

      def dual_view.event_sourced_state
        { exists: false, events_count: 0 }
      end

      result = dual_view.compare

      assert result.key?(:crud_view)
      assert result.key?(:event_sourced_view)
      assert result.key?(:differences)
      assert result.key?(:metadata)
    end

    def test_compare_metadata_includes_model_info
      dual_view = DualView.new(::User, 123)

      def dual_view.crud_state
        { exists: false }
      end

      def dual_view.event_sourced_state
        { exists: false }
      end

      result = dual_view.compare

      assert_equal "User", result[:metadata][:model_class]
      assert_equal 123, result[:metadata][:model_id]
      assert result[:metadata][:timestamp].is_a?(Time)
      assert_equal Lyra.config.mode, result[:metadata][:mode]
    end

    def test_crud_state_returns_exists_false_for_missing_record
      dual_view = DualView.new(::User, 999999)

      result = dual_view.crud_state

      assert_equal false, result[:exists]
    end

    def test_crud_state_returns_record_attributes
      user = ::User.create!(name: "TestCrud", email: "testcrud#{rand(10000)}@example.com")

      begin
        dual_view = DualView.new(::User, user.id)
        result = dual_view.crud_state

        assert_equal true, result[:exists]
        assert_equal "TestCrud", result[:attributes]["name"]
        assert result[:timestamps][:created_at].is_a?(Time)
      ensure
        user.destroy
      end
    end

    def test_event_sourced_state_returns_exists_false_for_no_events
      dual_view = DualView.new(::User, 999999)
      result = dual_view.event_sourced_state

      assert_equal false, result[:exists]
      assert_equal 0, result[:events_count]
    end

    def test_event_sourced_state_handles_event_store_errors
      dual_view = DualView.new(::User, 1)

      # Stub event store to raise error
      mock_event_store = mock("event_store")
      mock_event_store.stubs(:read).raises(StandardError.new("Connection failed"))
      Lyra.config.stubs(:event_store).returns(mock_event_store)

      result = dual_view.event_sourced_state

      assert_equal false, result[:exists]
      assert result[:error].include?("Connection failed")
      assert_equal 0, result[:events_count]
    end

    def test_event_timestamp_with_timestamp_method
      event = mock("event")
      event.stubs(:timestamp).returns(Time.now)
      event.stubs(:respond_to?).with(:timestamp).returns(true)

      dual_view = DualView.new(::User, 1)
      result = dual_view.event_timestamp(event)

      assert result.is_a?(Time)
    end

    def test_event_timestamp_from_data_hash
      event = mock("event")
      event.stubs(:respond_to?).with(:timestamp).returns(true)
      event.stubs(:timestamp).returns(nil)
      event.stubs(:data).returns({ timestamp: Time.utc(2024, 1, 1) })
      event.stubs(:metadata).returns({})

      dual_view = DualView.new(::User, 1)
      result = dual_view.event_timestamp(event)

      assert_equal Time.utc(2024, 1, 1), result
    end

    def test_event_timestamp_from_metadata
      event = mock("event")
      event.stubs(:respond_to?).with(:timestamp).returns(true)
      event.stubs(:timestamp).returns(nil)
      event.stubs(:data).returns({})
      event.stubs(:metadata).returns({ timestamp: Time.utc(2024, 6, 15) })

      dual_view = DualView.new(::User, 1)
      result = dual_view.event_timestamp(event)

      assert_equal Time.utc(2024, 6, 15), result
    end

    def test_event_operation_with_operation_method
      event = mock("event")
      event.stubs(:respond_to?).with(:operation).returns(true)
      event.stubs(:operation).returns(:created)

      dual_view = DualView.new(::User, 1)
      result = dual_view.event_operation(event)

      assert_equal :created, result
    end

    def test_event_operation_from_data_hash
      event = mock("event")
      event.stubs(:respond_to?).with(:operation).returns(false)
      event.stubs(:data).returns({ operation: :updated })

      dual_view = DualView.new(::User, 1)
      result = dual_view.event_operation(event)

      assert_equal :updated, result
    end

    def test_event_operation_converts_string_to_symbol
      event = mock("event")
      event.stubs(:respond_to?).with(:operation).returns(false)
      event.stubs(:data).returns({ operation: "destroyed" })

      dual_view = DualView.new(::User, 1)
      result = dual_view.event_operation(event)

      assert_equal :destroyed, result
    end

    def test_audit_trail_delegates_to_audit_projection
      AuditProjection.stubs(:audit_trail).with(::User, 123).returns([{ event: "created" }])

      dual_view = DualView.new(::User, 123)
      result = dual_view.audit_trail

      assert_equal [{ event: "created" }], result
    end
  end

  # Tests for class methods
  class DualViewClassMethodsTest < Minitest::Test
    def setup
      @event_store = RailsEventStore::Client.new
      Lyra.configure do |config|
        config.event_store = @event_store
        config.mode = :monitor
      end
    end

    def teardown
      Lyra.reset_config!
      ::User.delete_all
    end

    def test_compare_all_compares_each_record
      user1 = ::User.create!(name: "User1", email: "user1_#{rand(10000)}@example.com")
      user2 = ::User.create!(name: "User2", email: "user2_#{rand(10000)}@example.com")

      results = DualView.compare_all(::User)

      assert_equal 2, results.size
      assert results.all? { |r| r.key?(:crud_view) }
      assert results.all? { |r| r.key?(:event_sourced_view) }
    ensure
      user1&.destroy
      user2&.destroy
    end

    def test_find_discrepancies_returns_only_records_with_differences
      user1 = ::User.create!(name: "User1", email: "user1_#{rand(10000)}@example.com")

      # Stub to simulate discrepancy
      DualView.stubs(:compare_all).returns([
        { differences: { no_differences: true } },
        { differences: { name: { crud: "A", event_sourced: "B" } } }
      ])

      results = DualView.find_discrepancies(::User)

      assert_equal 1, results.size
      assert results.first[:differences].key?(:name)
    ensure
      user1&.destroy
    end

    def test_find_discrepancies_returns_empty_when_no_discrepancies
      DualView.stubs(:compare_all).returns([
        { differences: { no_differences: true } },
        { differences: { no_differences: true } }
      ])

      results = DualView.find_discrepancies(::User)

      assert_empty results
    end
  end

  # Tests for StateAnalyzer
  class StateAnalyzerExtendedTest < Minitest::Test
    def setup
      @event_store = RailsEventStore::Client.new
      Lyra.configure do |config|
        config.event_store = @event_store
        config.mode = :monitor
      end
    end

    def teardown
      Lyra.reset_config!
    end

    def test_analyze_returns_full_analysis
      user = ::User.create!(name: "AnalyzeTest", email: "analyze#{rand(10000)}@example.com")

      DualView.any_instance.stubs(:compare).returns({
        crud_view: { exists: true },
        event_sourced_view: { exists: true, events_count: 1 },
        differences: { no_differences: true }
      })
      DualView.any_instance.stubs(:audit_trail).returns([])

      result = StateAnalyzer.analyze(::User, user.id)

      assert result.key?(:comparison)
      assert result.key?(:audit_trail)
      assert result.key?(:recommendations)
    ensure
      user&.destroy
    end

    def test_generate_recommendations_empty_for_synced_state
      view = Object.new
      def view.compare
        {
          crud_view: { exists: true },
          event_sourced_view: { exists: true, events_count: 5 },
          differences: { no_differences: true }
        }
      end

      recommendations = StateAnalyzer.generate_recommendations(view)

      assert_empty recommendations
    end

    def test_generate_recommendations_for_existence_mismatch
      view = Object.new
      def view.compare
        {
          crud_view: { exists: true },
          event_sourced_view: { exists: false, events_count: 0 },
          differences: { exists_mismatch: true }
        }
      end

      recommendations = StateAnalyzer.generate_recommendations(view)

      assert recommendations.any? { |r| r.include?("existence mismatch") }
    end

    def test_generate_recommendations_for_attribute_differences
      view = Object.new
      def view.compare
        {
          crud_view: { exists: true },
          event_sourced_view: { exists: true, events_count: 3 },
          differences: { status: { crud: "active", event_sourced: "inactive" } }
        }
      end

      recommendations = StateAnalyzer.generate_recommendations(view)

      assert recommendations.any? { |r| r.include?("Attribute differences") }
      assert recommendations.any? { |r| r.include?("status") }
    end

    def test_generate_recommendations_for_pre_lyra_records
      view = Object.new
      def view.compare
        {
          crud_view: { exists: true },
          event_sourced_view: { exists: false, events_count: 0 },
          differences: { exists_mismatch: true }
        }
      end

      recommendations = StateAnalyzer.generate_recommendations(view)

      assert recommendations.any? { |r| r.include?("before Lyra") }
    end
  end
end
