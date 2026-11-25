# frozen_string_literal: true

require "test_helper"

module Lyra
  module Verification
    # Locks across records (Lyra::Verification::MultiRecordLockNet): over every
    # mix of two transactions of two steps on three records, the mixes that can
    # deadlock with ES-NoProj's locking read as released are exactly those that
    # can in plain Active Record; with the 1.0.1 campaign's code, which locked
    # every record of the model, more can (among them the Olist replay's).
    class MultiRecordLockNetTest < Minitest::Test
      def self.runnable_methods
        return [] unless defined?(PetriFlow)

        super
      end

      NET = MultiRecordLockNet

      def explore(read, *programs) = NET.explore(NET::Config.new(name: "x", records: 3, programs: programs, read: read))

      def test_the_locking_read_adds_no_deadlock_to_plain_active_record
        plain = NET.census(:plain)
        own = NET.census(:own)

        assert_equal 666, plain[:mixes]
        refute_empty plain[:deadlocking], "plain Active Record deadlocks on writes in opposite orders"
        assert_equal plain[:deadlocking], own[:deadlocking]
      end

      def test_locking_every_record_adds_deadlocks
        plain = NET.census(:plain)
        all = NET.census(:all)
        added = all[:deadlocking] - plain[:deadlocking]

        refute_empty added
        assert_includes added, [[[:write, 1], [:lock_read, 0]], [[:lock_read, 2], [:write, 2]]], "the Olist replay's"
      end

      # The Olist replay's (the scaling step, 2 threads): an order that has
      # written one stock item and then reads another under with_lock, against
      # a with_lock on a third.
      def test_the_olist_deadlock
        olist = [[[:write, 1], [:lock_read, 0]], [[:lock_read, 2]]]

        assert explore(:all, *olist)[:deadlock]
        assert_nil explore(:own, *olist)[:deadlock]
        assert_nil explore(:plain, *olist)[:deadlock]
      end

      def test_writes_in_opposite_orders_deadlock_everywhere
        %i[plain own all].each do |read|
          assert explore(read, [[:write, 0], [:write, 1]], [[:write, 1], [:write, 0]])[:deadlock], read.to_s
        end
      end

      def test_the_aggregate_lock_order
        net = NET.new(NET::Config.new(name: "x", records: 3, programs: [], read: :own))
        assert_equal [1, 0], net.aggregate_lock_order([[:write, 1], [:lock_read, 0]])
        all = NET.new(NET::Config.new(name: "x", records: 3, programs: [], read: :all))
        assert_equal [1, 0, 2], all.aggregate_lock_order([[:write, 1], [:lock_read, 0]])
      end
    end
  end
end
