# frozen_string_literal: true

require "test_helper"

module Lyra
  module Consistency
    # The controller concern wraps each action in a read-your-writes block
    # under ES-Async; lyra_read_your_writes chooses, per controller and its
    # subclasses, whether writes are projected as they are made or when the
    # action ends.
    class ControllerConcernTest < Minitest::Test
      def setup
        skip "Requires Rails" unless defined?(ActionController::Base)

        @base = Class.new(ActionController::Base) { include ControllerConcern }
        Lyra.config.enable_event_sourcing!
        Lyra.config.projection_mode = :async
      end

      def teardown
        Lyra.config.projection_mode = :sync if defined?(ActionController::Base)
      end

      def test_by_default_writes_are_projected_when_the_action_ends
        refute @base.lyra_read_your_writes_each_write
        assert_equal false, each_write_inside(@base)
      end

      def test_each_write_can_be_turned_on_for_a_controller_and_its_subclasses
        @base.lyra_read_your_writes each_write: true
        child = Class.new(@base)
        other = Class.new(ActionController::Base) { include ControllerConcern }

        assert_equal true, each_write_inside(@base)
        assert_equal true, each_write_inside(child), "inherited"
        assert_equal false, each_write_inside(other), "another controller keeps the default"
      end

      def test_a_subclass_can_turn_it_back_off
        @base.lyra_read_your_writes each_write: true
        child = Class.new(@base) { lyra_read_your_writes each_write: false }

        assert_equal false, each_write_inside(child)
        assert_equal true, each_write_inside(@base)
      end

      def test_the_block_wraps_actions_only_under_es_async
        controller = @base.new
        assert controller.send(:lyra_consistency_enabled?)

        Lyra.config.projection_mode = :sync
        refute controller.send(:lyra_consistency_enabled?)
      end

      private

      # The each_write setting in force inside the action's block.
      def each_write_inside(controller_class)
        seen = nil
        controller_class.new.send(:with_lyra_consistency) { seen = Thread.current[:lyra_ryw_each_write] }
        seen
      end
    end
  end
end
