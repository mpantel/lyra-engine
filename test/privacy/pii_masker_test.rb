# frozen_string_literal: true

require "test_helper"

module Lyra
  module Privacy
    class PIIMaskerTest < Minitest::Test
      class MaskerTestUserUpdated < Lyra::Event; end

      def setup
        skip "PAM DSL not loaded" unless defined?(Lyra::Privacy::PIIMasker)
      end

      def build_event(data)
        MaskerTestUserUpdated.new(
          event_id: "11111111-2222-3333-4444-555555555555",
          data: data,
          metadata: { correlation_id: "corr-1", event_type: "MaskerTestUserUpdated" }
        )
      end

      def test_mask_events_returns_masked_copies_of_the_same_events
        event = build_event(
          operation: :updated, model_class: "User", model_id: 7,
          attributes: { email: "jane@example.com", count: 3 },
          changes: { email: ["old@example.com", "jane@example.com"], count: [2, 3] }
        )

        masked = PIIMasker.mask_events([event]).first

        assert_instance_of MaskerTestUserUpdated, masked
        assert_equal event.event_id, masked.event_id
        assert_equal event.event_type, masked.event_type
        assert_equal "corr-1", masked.metadata[:correlation_id]
        assert_equal :updated, masked.operation
        assert_equal "User", masked.model_class
        assert_equal 7, masked.model_id

        refute_equal "jane@example.com", masked.attributes[:email]
        assert_includes masked.attributes[:email], "@example.com"
        assert_equal 3, masked.attributes[:count]
        refute_includes masked.changes[:email], "old@example.com"
        refute_includes masked.changes[:email], "jane@example.com"
        assert_equal [2, 3], masked.changes[:count]

        # The original is untouched.
        assert_equal "jane@example.com", event.attributes[:email]
      end

      def test_mask_events_keeps_string_keys_after_serialization
        event = build_event(
          "operation" => "created", "model_class" => "User", "model_id" => 1,
          "attributes" => { "email" => "jane@example.com" }
        )

        masked = PIIMasker.mask_events([event], strategy: :full).first

        assert masked.data.key?("attributes")
        refute masked.data.key?(:attributes)
        refute_equal "jane@example.com", masked.attributes["email"]
      end
    end
  end
end
