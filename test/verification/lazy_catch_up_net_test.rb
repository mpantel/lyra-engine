# frozen_string_literal: true

require "test_helper"

module Lyra
  module Verification
    # ES-Lazy's catch-up as a net (Lyra::Verification::LazyCatchUpNet),
    # explored exhaustively: 1.0.0 as released, and the design that moves the
    # catch-up out of the reader's transaction (design c).
    class LazyCatchUpNetTest < Minitest::Test
      def self.runnable_methods
        return [] unless defined?(PetriFlow)

        super
      end

      NET = LazyCatchUpNet

      def result(name)
        config = NET::CONFIGS.find { _1.name == name } or flunk "no configuration #{name}"
        NET.explore(config)
      end

      # 1.0.0: with_lock reads the row the catch-up before its lock left, so an
      # update under the lock can be lost (as the probes found in ES-Lazy).
      def test_lyra_1_0_0_with_lock_reads_stale_and_loses_an_update
        r = result("1.0.0, two with_lock updaters")
        assert r[:bad_stale_read]
        assert r[:bad_lost_update]
        assert_nil r[:deadlock]
      end

      # 1.0.0: the catch-up lock held to the reader's commit closes a cycle with
      # a transaction that holds the row and reads again (the Olist replay's
      # deadlocks at 16 threads).
      def test_lyra_1_0_0_deadlocks_when_a_row_lock_holder_reads_again
        assert result("1.0.0, a rereading with_lock and two plain updaters")[:deadlock]
      end

      # Plain read-modify-writes lose updates in plain Active Record too: not counted.
      def test_plain_updaters_are_not_counted_as_lyras_lost_updates
        assert_nil result("1.0.0, two plain updaters")[:bad_lost_update]
      end

      # Design c: no deadlock, no stale read under the lock, no lost update, in
      # every configuration explored.
      def test_design_c_is_clean
        NET::CONFIGS.select { _1.design == :own_transaction }.each do |config|
          r = NET.explore(config)
          NET::PROPERTIES.each { |property| assert_nil r[property], "#{config.name}: #{property} #{r[property].inspect}" }
        end
      end
    end
  end
end
