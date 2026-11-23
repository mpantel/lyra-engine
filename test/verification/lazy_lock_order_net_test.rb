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

      # The fallback (the catch-up in the reader's transaction, c held to its
      # commit) against a reader that holds the record and catches up on its own
      # connection: a wait cycle through that connection, which PostgreSQL's
      # detector cannot see, so a hang (reproduced on 23 Nov with a full pool).
      # Two fallbacks: a cycle PostgreSQL detects. Without the fallback: none.
      def test_the_fallback_hangs_against_an_own_connection_catch_up
        before = { own_wait: :unbounded, remembers: false }
        r = NET.explore(NET::Config.new(name: "x", kinds: %i[plain_inline writes_then_reads], **before))
        assert r[:hang], "a hang: #{r.inspect}"
        assert NET.explore(NET::Config.new(name: "x", kinds: %i[falls_back_then_reads], **before))[:hang], "waits for itself"
        # 1.0.1: the bounded wait turns the cycle into one PostgreSQL detects, and a
        # transaction holding c catches up in place.
        fixed = NET.explore(NET::Config.new(name: "x", kinds: %i[plain_inline writes_then_reads]))
        assert_nil fixed[:hang]
        assert fixed[:deadlock], "detected: #{fixed.inspect}"
        assert_nil NET.explore(NET::Config.new(name: "x", kinds: %i[falls_back_then_reads]))[:deadlock]
        %i[plain writes_then_reads bulk falls_back_then_reads].repeated_combination(2).each do |kinds|
          assert_nil NET.explore(NET::Config.new(name: "x", kinds: kinds))[:hang], kinds.join("+")
        end
        detected = NET.explore(NET::Config.new(name: "x", kinds: %i[plain_inline writes_then_reads_inline]))
        assert detected[:deadlock]
        assert_nil detected[:hang]
        assert_nil NET.explore(NET::Config.new(name: "x", kinds: %i[plain_inline plain_inline]))[:deadlock]
        %i[plain writes_then_reads bulk].repeated_combination(2).each do |kinds|
          assert_nil NET.explore(NET::Config.new(name: "x", kinds: kinds))[:deadlock], kinds.join("+")
        end
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
