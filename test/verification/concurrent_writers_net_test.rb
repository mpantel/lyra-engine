# frozen_string_literal: true

require "test_helper"

module Lyra
  module Verification
    # The net of several writers on one aggregate, explored exhaustively for
    # two writers: what Lyra 1.0.0 allows, and what the design that enforces the
    # history clauses of Hypothesis H (H1) must exclude. Each expectation names
    # the probe of benchmarks/probes-1.0.0 that shows the same in the code.
    class ConcurrentWritersNetTest < Minitest::Test
      def self.runnable_methods
        return [] unless defined?(PetriFlow)

        super
      end

      NET = ConcurrentWritersNet

      def reachable(name)
        config = NET::CONFIGS.find { _1.name == name } or flunk "no configuration #{name}"
        found, = NET.explore_all(config, writers: 2)
        found.compact.keys.sort
      end

      # Theorem 5 and soundness hold in every configuration: no two writers in
      # the lock's critical section, and every run ends with every writer done.
      def test_no_overlap_and_no_deadlock_anywhere
        NET::CONFIGS.each do |config|
          found, = NET.explore_all(config, writers: 2)
          assert_nil found[:bad_overlap], config.name
          assert_nil found[:deadlock], config.name
        end
      end

      # 1.0.0, Hijack and ES-Sync: a create takes no lock and is not checked
      # against the stream, an update reaches a stream with no record, and a
      # create on a live key leaves the row and the log apart, each reproduced on
      # 1.0.0's code. The lost update is the application's, as in plain Active
      # Record: the read is not locked.
      def test_lyra_1_0_0_table_backed
        assert_equal %i[bad_double_created bad_headless bad_lost_update diverged_at_rest],
                     reachable("1.0.0 Hijack, ES-Sync")
      end

      # with_lock orders the reads in Hijack and ES-Sync (two increments give 2).
      def test_lyra_1_0_0_table_backed_with_lock_loses_no_update
        refute_includes reachable("1.0.0 Hijack, ES-Sync, with_lock"), :bad_lost_update
      end

      # with_lock does not stop a lost update where the row lags (two increments
      # give 1 in ES-Async and ES-Lazy on 1.0.0) or where there is no row to lock
      # (ES-NoProj).
      def test_lyra_1_0_0_with_lock_loses_updates_where_the_row_lags_or_is_absent
        assert_includes reachable("1.0.0 ES-Async, ES-Lazy, with_lock"), :bad_lost_update
        assert_includes reachable("1.0.0 ES-NoProj, with_lock"), :bad_lost_update
      end

      # Monitor writes the row first, so the database refuses what H excludes.
      def test_monitor_with_lock_is_clean
        assert_empty reachable("Monitor, with_lock")
      end

      # The H1 design: no history H excludes, in any of its configurations,
      # and the row agrees with the log at rest.
      def test_h1_excludes_the_histories_h_excludes
        NET::CONFIGS.select { _1.guard == :h1 }.each do |config|
          found, = NET.explore_all(config, writers: 2)
          %i[bad_double_created bad_headless bad_after_destroy diverged_at_rest].each do |property|
            assert_nil found[property], "#{config.name}: #{property} #{found[property].inspect}"
          end
        end
      end

      # H1 alone does not make with_lock safe where the row lags: the read under
      # the lock has to come from the stream.
      def test_h1_with_lock_needs_the_stream_where_the_row_lags
        assert_includes reachable("H1 ES-Async, ES-Lazy, with_lock reading the row"), :bad_lost_update
        assert_empty reachable("H1 ES-Async, ES-Lazy, with_lock reading the stream")
        assert_empty reachable("H1 ES-NoProj, with_lock")
        assert_empty reachable("H1 Hijack, ES-Sync, with_lock")
      end

      # Without the lock, two writers can also leave an update after the destroy
      # (the reason lock_aggregate_before_append is on by default).
      def test_lock_off_appends_after_a_destroy
        assert_includes reachable("1.0.0 Hijack, ES-Sync, lock off"), :bad_after_destroy
        refute_includes reachable("1.0.0 Hijack, ES-Sync"), :bad_after_destroy
      end
    end
  end
end
