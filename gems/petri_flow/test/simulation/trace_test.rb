# frozen_string_literal: true

require "test_helper"

module PetriFlow
  module Simulation
    class TraceTest < Minitest::Test
      def setup
        @trace = Trace.new
        @marking1 = Core::Marking.new({ p1: 1, p2: 0 })
        @marking2 = Core::Marking.new({ p1: 0, p2: 1 })
        @marking3 = Core::Marking.new({ p1: 0, p2: 0 })
      end

      # ===========================================
      # Initialization Tests
      # ===========================================

      def test_initialization
        assert_empty @trace.transitions
        assert_empty @trace.markings
        assert_nil @trace.initial_marking
      end

      def test_initial_steps_is_zero
        assert_equal 0, @trace.steps
      end

      # ===========================================
      # Recording Tests
      # ===========================================

      def test_record_initial_marking
        @trace.record_initial_marking(@marking1)

        refute_nil @trace.initial_marking
        assert_equal 1, @trace.initial_marking.tokens_at(:p1)
        assert_equal 1, @trace.markings.size
      end

      def test_record_transition
        @trace.record_initial_marking(@marking1)

        @trace.record_transition(
          step: 0,
          transition_id: :t1,
          transition_name: "fire_t1",
          marking_before: @marking1,
          marking_after: @marking2
        )

        assert_equal 1, @trace.steps
        assert_equal 2, @trace.markings.size
      end

      def test_record_multiple_transitions
        @trace.record_initial_marking(@marking1)

        @trace.record_transition(
          step: 0,
          transition_id: :t1,
          transition_name: "step1",
          marking_before: @marking1,
          marking_after: @marking2
        )

        @trace.record_transition(
          step: 1,
          transition_id: :t2,
          transition_name: "step2",
          marking_before: @marking2,
          marking_after: @marking3
        )

        assert_equal 2, @trace.steps
        assert_equal 3, @trace.markings.size
      end

      # ===========================================
      # Firing Sequence Tests
      # ===========================================

      def test_firing_sequence
        record_sample_trace

        sequence = @trace.firing_sequence

        assert_equal [:t1, :t2], sequence
      end

      def test_firing_sequence_names
        record_sample_trace

        names = @trace.firing_sequence_names

        assert_equal %w[step1 step2], names
      end

      def test_firing_sequence_empty_for_new_trace
        assert_empty @trace.firing_sequence
      end

      # ===========================================
      # Transition Firing Counts Tests
      # ===========================================

      def test_transition_firing_counts
        @trace.record_initial_marking(@marking1)

        # Fire t1 twice, t2 once
        @trace.record_transition(step: 0, transition_id: :t1, transition_name: "t1",
                                  marking_before: @marking1, marking_after: @marking2)
        @trace.record_transition(step: 1, transition_id: :t1, transition_name: "t1",
                                  marking_before: @marking2, marking_after: @marking2)
        @trace.record_transition(step: 2, transition_id: :t2, transition_name: "t2",
                                  marking_before: @marking2, marking_after: @marking3)

        counts = @trace.transition_firing_counts

        assert_equal 2, counts[:t1]
        assert_equal 1, counts[:t2]
      end

      def test_transition_firing_counts_empty_for_new_trace
        counts = @trace.transition_firing_counts

        assert_empty counts
      end

      # ===========================================
      # Visited Markings Tests
      # ===========================================

      def test_visited_markings
        record_sample_trace

        visited = @trace.visited_markings

        assert_equal 3, visited.size
      end

      def test_visited_markings_deduplicates
        @trace.record_initial_marking(@marking1)

        # Record same marking transition multiple times
        @trace.record_transition(step: 0, transition_id: :t1, transition_name: "t1",
                                  marking_before: @marking1, marking_after: @marking2)
        @trace.record_transition(step: 1, transition_id: :t2, transition_name: "t2",
                                  marking_before: @marking2, marking_after: @marking1) # Back to marking1

        visited = @trace.visited_markings

        # Should have 2 unique markings even though we visited marking1 twice
        assert_equal 2, visited.size
      end

      # ===========================================
      # Clear Tests
      # ===========================================

      def test_clear
        record_sample_trace

        @trace.clear

        assert_empty @trace.transitions
        assert_empty @trace.markings
        assert_nil @trace.initial_marking
        assert_equal 0, @trace.steps
      end

      # ===========================================
      # Export Tests
      # ===========================================

      def test_to_h
        record_sample_trace

        hash = @trace.to_h

        assert_equal 2, hash[:steps]
        assert_kind_of Hash, hash[:initial_marking]
        assert_kind_of Array, hash[:transitions]
        assert_kind_of Array, hash[:markings]
        assert_equal [:t1, :t2], hash[:firing_sequence]
        assert_equal 3, hash[:unique_states]
      end

      def test_to_s
        record_sample_trace

        output = @trace.to_s

        assert_includes output, "Trace (2 steps)"
        assert_includes output, "step1"
        assert_includes output, "step2"
      end

      # ===========================================
      # Stats Tests
      # ===========================================

      def test_stats
        record_sample_trace

        stats = @trace.stats

        assert_equal 2, stats[:steps]
        assert_equal 3, stats[:unique_states]
        assert_equal 2, stats[:unique_transitions]
        assert_kind_of Hash, stats[:firing_counts]
      end

      def test_stats_most_fired_transition
        @trace.record_initial_marking(@marking1)

        # Fire t1 three times, t2 once
        3.times do |i|
          @trace.record_transition(step: i, transition_id: :t1, transition_name: "t1",
                                    marking_before: @marking1, marking_after: @marking2)
        end
        @trace.record_transition(step: 3, transition_id: :t2, transition_name: "t2",
                                  marking_before: @marking2, marking_after: @marking3)

        stats = @trace.stats

        assert_equal :t1, stats[:most_fired_transition]
      end

      private

      def record_sample_trace
        @trace.record_initial_marking(@marking1)

        @trace.record_transition(
          step: 0,
          transition_id: :t1,
          transition_name: "step1",
          marking_before: @marking1,
          marking_after: @marking2
        )

        @trace.record_transition(
          step: 1,
          transition_id: :t2,
          transition_name: "step2",
          marking_before: @marking2,
          marking_after: @marking3
        )
      end
    end
  end
end
