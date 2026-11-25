# frozen_string_literal: true

require "test_helper"

module Lyra
  module Verification
    # Locks across records (Lyra::Verification::MultiRecordLockNet): over every
    # mix of two transactions of two steps on three records, the mixes that can
    # deadlock in ES-NoProj as released are exactly those that can in plain
    # Active Record; with the 1.0.1 campaign's locking read, which locked every
    # record of the model, more can (among them the Olist replay's). With
    # locking reads of several records and bulk writes, ES-NoProj's deadlocks
    # are among plain Active Record's; and the conditions under which that
    # holds for any number of transactions, steps and records hold.
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

      # Locking reads of several records and bulk writes, in a sample of the
      # mixes (the whole census, 19,306 mixes, is run by hand): every mix that
      # can deadlock in ES-NoProj can in plain Active Record, for some order of
      # its scans; some only there (ES-NoProj's orders are fixed).
      def test_with_set_steps_es_noproj_deadlocks_are_among_plain_active_records
        own = NET.census(:own, sets: true, sample: 400, seed: 3)
        plain = NET.census(:plain, sets: true, sample: 400, seed: 3)

        refute_empty own[:deadlocking]
        assert_empty own[:deadlocking] - plain[:deadlocking]
      end

      # A bulk write against a locking read of the same records: their orders
      # (hash and stream name) differ, so they can deadlock, as two scans of
      # plain Active Record in those orders can.
      def test_a_bulk_write_and_a_locking_read_in_different_orders
        mix = [[[:bulk, [0, 1]]], [[:lock_read_set, [0, 1]]]]

        assert explore(:own, *mix)[:deadlock]
        assert explore(:plain, *mix)[:deadlock]
        assert_nil NET.explore(NET::Config.new(name: "x", records: 3, programs: mix, read: :own, bulk_order: [0, 1, 2]))[:deadlock]
      end

      # The proof's conditions, for mixes larger than any census: four
      # transactions of five steps on six records, every step kind.
      def test_the_conditions_hold_for_large_mixes
        rng = Random.new(11)
        steps = NET.steps(6, sets: true)
        100.times do
          programs = Array.new(4) { Array.new(5) { steps.sample(random: rng) } }
          conditions = NET.new(NET::Config.new(name: "c", records: 6, programs: programs, read: :own)).conditions

          assert_equal({ heads_under_aggregate: true, own_records_only: true, plain_order: true }, conditions, programs.inspect)
        end
      end

      def test_the_campaigns_locking_read_breaks_the_conditions
        conditions = NET.new(NET::Config.new(name: "c", records: 3, programs: [[[:lock_read, 0]]], read: :all)).conditions

        refute conditions[:own_records_only]
        refute conditions[:plain_order]
      end

      # What the conditions give, explored: random mixes of three transactions of
      # two steps on three records, every step kind.
      def test_es_noproj_deadlocks_are_plain_active_records_in_random_mixes
        rng = Random.new(5)
        steps = NET.steps(3, sets: true)
        found = 0
        60.times do
          programs = Array.new(3) { Array.new(2) { steps.sample(random: rng) } }
          config = ->(read) { NET::Config.new(name: "x", records: 3, programs: programs, read: read) }
          next unless NET.explore(config.(:own))[:deadlock]

          found += 1
          assert NET.explore(config.(:plain))[:deadlock], programs.inspect
        end
        assert_operator found, :>, 0
      end
    end
  end
end
