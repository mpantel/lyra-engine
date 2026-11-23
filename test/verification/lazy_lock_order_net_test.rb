# frozen_string_literal: true

require "test_helper"

module Lyra
  module Verification
    # ES-Lazy's lock order under design c (Lyra::Verification::LazyLockOrderNet):
    # a locking reader that takes the row first and the aggregate lock after
    # closes wait cycles with bulk writes and with writers that read their own
    # events back; one that takes the aggregate lock first does not.
    class LazyLockOrderNetTest < Minitest::Test
      def self.runnable_methods
        return [] unless defined?(PetriFlow)

        super
      end

      NET = LazyLockOrderNet
      OTHERS = %i[plain writes_then_reads bulk].freeze

      def mixes(order, size) = (OTHERS + [order]).repeated_combination(size).select { _1.include?(order) }

      def test_the_row_first_deadlocks_with_a_bulk_write_and_with_a_writer_reading_its_own_events
        assert NET.explore(NET::Config.new(name: "x", kinds: %i[with_lock_x_first bulk]))[:deadlock]
        assert NET.explore(NET::Config.new(name: "x", kinds: %i[with_lock_x_first writes_then_reads]))[:deadlock]
      end

      def test_the_aggregate_lock_first_is_free_of_deadlock_and_lost_updates
        [2, 3].each do |size|
          mixes(:with_lock_a_first, size).each do |kinds|
            r = NET.explore(NET::Config.new(name: "x", kinds: kinds))
            assert_nil r[:deadlock], "#{kinds.join('+')}: #{r[:deadlock].inspect}"
            assert_nil r[:bad_lost_update], kinds.join("+")
          end
        end
      end
    end
  end
end
