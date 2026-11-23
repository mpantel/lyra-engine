# frozen_string_literal: true

require "test_helper"

module Lyra
  module Verification
    # The mode gate against writes in flight (Lyra::Verification::GateSettleNet):
    # with the position alone (1.0.0) a certificate can cover an event no
    # check saw; settled (1.0.1), it cannot, because a writer holds its
    # transaction id before its event takes an id (the stream head first).
    class GateSettleNetTest < Minitest::Test
      def self.runnable_methods
        return [] unless defined?(PetriFlow)

        super
      end

      NET = GateSettleNet

      def config(name) = NET::CONFIGS.find { _1.name.start_with?(name) }

      def test_the_position_alone_can_certify_an_event_no_check_saw
        result = NET.explore(config("1.0.0"))
        assert result[:missed], "a missed event: #{result.inspect}"
      end

      def test_the_settled_position_certifies_only_what_was_checked
        ["1.0.1: the position settled", "1.0.1, three writers"].each do |name|
          result = NET.explore(config(name))
          assert_nil result[:missed], "#{name}: #{result[:missed].inspect}"
          assert_operator result[:certified], :>, 0, name
        end
      end

      def test_the_settle_depends_on_the_transaction_id_before_the_event_id
        result = NET.explore(config("settled, without the head first"))
        assert result[:missed], "a missed event: #{result.inspect}"
      end
    end
  end
end
