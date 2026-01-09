require "test_helper"

module Lyra
  class CorrelationTest < Minitest::Test
    def teardown
      # Clean up thread-local state
      Thread.current[:lyra_correlation_id] = nil
      Thread.current[:lyra_user_action_context] = nil
    end

    def test_generate_correlation_id
      id = Correlation.generate_id

      assert id.start_with?("corr_")
      assert_match(/^corr_\d+_[a-f0-9]{16}$/, id)
    end

    def test_current_id_when_not_set
      assert_nil Correlation.current_id
    end

    def test_with_id_sets_correlation_id
      generated_id = nil

      Correlation.with_id do |id|
        generated_id = id
        assert_equal id, Correlation.current_id
      end

      # Should be cleared after block
      assert_nil Correlation.current_id
    end

    def test_with_id_with_specific_id
      custom_id = "custom_correlation_123"

      Correlation.with_id(custom_id) do |id|
        assert_equal custom_id, id
        assert_equal custom_id, Correlation.current_id
      end

      assert_nil Correlation.current_id
    end

    def test_with_id_restores_previous_id
      first_id = "first_correlation"
      second_id = "second_correlation"

      Correlation.with_id(first_id) do
        assert_equal first_id, Correlation.current_id

        Correlation.with_id(second_id) do
          assert_equal second_id, Correlation.current_id
        end

        # Should restore first_id after nested block
        assert_equal first_id, Correlation.current_id
      end

      assert_nil Correlation.current_id
    end

  end

  # Tests for the Causation class (event chain tracking)
  class CausationTest < Minitest::Test
    def teardown
      Thread.current[:lyra_causation_id] = nil
    end

    def test_current_id_when_not_set
      assert_nil Causation.current_id
    end

    def test_with_id_sets_causation_id
      cause_event_id = "event-123"

      Causation.with_id(cause_event_id) do |id|
        assert_equal cause_event_id, id
        assert_equal cause_event_id, Causation.current_id
      end

      # Should be cleared after block
      assert_nil Causation.current_id
    end

    def test_with_id_restores_previous_id
      first_id = "first_cause"
      second_id = "second_cause"

      Causation.with_id(first_id) do
        assert_equal first_id, Causation.current_id

        Causation.with_id(second_id) do
          assert_equal second_id, Causation.current_id
        end

        # Should restore first_id after nested block
        assert_equal first_id, Causation.current_id
      end

      assert_nil Causation.current_id
    end

    def test_clear_causation
      Causation.with_id("some-event") do
        assert_equal "some-event", Causation.current_id
        Causation.clear
        assert_nil Causation.current_id
      end
    end

    def test_track_causation
      event1_id = "event-1"
      event2_id = "event-2"

      Causation.track(event1_id, event2_id)

      assert_equal event1_id, Causation.cause_of(event2_id)
    end

    def test_chain_for_with_multiple_levels
      event1_id = "event-1"
      event2_id = "event-2"
      event3_id = "event-3"

      Causation.track(event1_id, event2_id)
      Causation.track(event2_id, event3_id)

      chain = Causation.chain_for(event3_id)
      assert_equal [event1_id, event2_id, event3_id], chain
    end

    def test_chain_for_single_event
      event_id = "standalone-event"

      chain = Causation.chain_for(event_id)
      assert_equal [event_id], chain
    end

    def test_cause_of_unknown_event
      assert_nil Causation.cause_of("unknown-event")
    end
  end

  class UserActionContextTest < Minitest::Test
    def teardown
      Thread.current[:lyra_user_action_context] = nil
      Thread.current[:lyra_correlation_id] = nil
      Thread.current[:lyra_causation_id] = nil
    end

    def test_user_action_context_initialization
      context = UserActionContext.new(
        action_type: :web_request,
        user_id: "user-123",
        controller: "UsersController",
        action_name: "create"
      )

      assert_match(/^action_\d+_[a-f0-9]{12}$/, context.action_id)
      assert_equal :web_request, context.action_type
      assert_equal "user-123", context.user_id
      assert_equal "UsersController", context.controller
      assert_equal "create", context.action_name
    end

    def test_user_action_context_to_h
      context = UserActionContext.new(
        action_type: :api_call,
        user_id: "user-456"
      )

      hash = context.to_h

      assert hash.key?(:action_id)
      assert_equal :api_call, hash[:action_type]
      assert_equal "user-456", hash[:user_id]
      assert hash.key?(:started_at)
    end

    def test_user_action_context_sanitize_params
      context = UserActionContext.new(
        action_type: :web_request,
        params: {
          name: "Alice",
          email: "alice@example.com",
          password: "secret123",
          token: "abc-xyz"
        }
      )

      # Sensitive params should be removed
      refute context.params.key?(:password)
      refute context.params.key?(:token)
      # Non-sensitive params should remain
      assert_equal "Alice", context.params[:name]
      assert_equal "alice@example.com", context.params[:email]
    end

    def test_current_context_when_not_set
      assert_nil UserActionContext.current
    end

    def test_with_context_sets_current
      UserActionContext.with_context(action_type: :background_job, user_id: "user-789") do |context|
        assert_equal context, UserActionContext.current
        assert_equal :background_job, context.action_type
        assert_equal "user-789", context.user_id
      end

      # Should be cleared after block
      assert_nil UserActionContext.current
    end

    def test_with_context_sets_correlation_id
      UserActionContext.with_context(action_type: :console) do |context|
        # Correlation ID should be set to action_id
        assert_equal context.action_id, Correlation.current_id
      end

      assert_nil Correlation.current_id
    end

    def test_with_context_restores_previous_context
      UserActionContext.with_context(action_type: :web_request, user_id: "user-1") do |context1|
        assert_equal context1, UserActionContext.current

        UserActionContext.with_context(action_type: :api_call, user_id: "user-2") do |context2|
          assert_equal context2, UserActionContext.current
        end

        # Should restore context1 after nested block
        assert_equal context1, UserActionContext.current
      end

      assert_nil UserActionContext.current
    end
  end
end
