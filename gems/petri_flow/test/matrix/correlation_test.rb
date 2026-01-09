# frozen_string_literal: true

require "test_helper"

module PetriFlow
  module Matrix
    class CorrelationTest < Minitest::Test
      def setup
        @correlation = Correlation.new
      end

      # ===========================================
      # Initialization Tests
      # ===========================================

      def test_initialization
        assert_empty @correlation.events
        assert_kind_of Hash, @correlation.matrix
      end

      # ===========================================
      # Record Correlation Tests
      # ===========================================

      def test_record_correlation
        @correlation.record_correlation(:event1, :event2, "corr-123")

        assert_includes @correlation.events, :event1
        assert_includes @correlation.events, :event2
      end

      def test_record_correlation_is_symmetric
        @correlation.record_correlation(:event1, :event2, "corr-123")

        assert @correlation.correlated?(:event1, :event2)
        assert @correlation.correlated?(:event2, :event1)
      end

      def test_record_multiple_correlations
        @correlation.record_correlation(:e1, :e2, "corr-1")
        @correlation.record_correlation(:e2, :e3, "corr-2")
        @correlation.record_correlation(:e4, :e5, "corr-3")

        assert_equal 5, @correlation.events.size
      end

      # ===========================================
      # Correlated? Tests
      # ===========================================

      def test_correlated_returns_true_for_correlated_events
        @correlation.record_correlation(:event1, :event2, "corr-123")

        assert @correlation.correlated?(:event1, :event2)
      end

      def test_correlated_returns_false_for_uncorrelated_events
        @correlation.record_correlation(:event1, :event2, "corr-123")

        refute @correlation.correlated?(:event1, :event3)
        refute @correlation.correlated?(:unknown1, :unknown2)
      end

      # ===========================================
      # Get Correlation ID Tests
      # ===========================================

      def test_get_correlation_id
        @correlation.record_correlation(:event1, :event2, "corr-123")

        assert_equal "corr-123", @correlation.get_correlation_id(:event1, :event2)
        assert_equal "corr-123", @correlation.get_correlation_id(:event2, :event1)
      end

      def test_get_correlation_id_returns_nil_for_uncorrelated
        assert_nil @correlation.get_correlation_id(:unknown1, :unknown2)
      end

      # ===========================================
      # Correlated Events Tests
      # ===========================================

      def test_correlated_events
        @correlation.record_correlation(:e1, :e2, "corr-1")
        @correlation.record_correlation(:e1, :e3, "corr-2")

        correlated = @correlation.correlated_events(:e1)

        assert_includes correlated, :e2
        assert_includes correlated, :e3
        assert_equal 2, correlated.size
      end

      def test_correlated_events_returns_empty_for_unknown
        assert_empty @correlation.correlated_events(:unknown)
      end

      # ===========================================
      # Correlation Groups Tests
      # ===========================================

      def test_correlation_groups
        @correlation.record_correlation(:e1, :e2, "group-a")
        @correlation.record_correlation(:e2, :e3, "group-a")
        @correlation.record_correlation(:e4, :e5, "group-b")

        groups = @correlation.correlation_groups

        assert_equal 2, groups.size
        assert_includes groups.keys, "group-a"
        assert_includes groups.keys, "group-b"
      end

      def test_correlation_groups_contains_all_events
        @correlation.record_correlation(:e1, :e2, "group-a")
        @correlation.record_correlation(:e2, :e3, "group-a")

        groups = @correlation.correlation_groups

        assert_includes groups["group-a"], :e1
        assert_includes groups["group-a"], :e2
        assert_includes groups["group-a"], :e3
      end

      def test_correlation_groups_empty_when_no_correlations
        groups = @correlation.correlation_groups

        assert_empty groups
      end

      # ===========================================
      # To Matrix Tests
      # ===========================================

      def test_to_matrix
        @correlation.record_correlation(:e1, :e2, "corr-1")
        @correlation.record_correlation(:e2, :e3, "corr-2")

        matrix = @correlation.to_matrix

        assert_instance_of ::Matrix, matrix
        assert_equal 3, matrix.row_count
        assert_equal 3, matrix.column_count
      end

      def test_to_matrix_values
        @correlation.record_correlation(:e1, :e2, "corr-1")

        matrix = @correlation.to_matrix

        # e1 correlates with e2
        assert_equal 1, matrix[0, 1]
        assert_equal 1, matrix[1, 0]
        # e1 doesn't correlate with itself via record_correlation
        assert_equal 0, matrix[0, 0]
      end

      # ===========================================
      # Stats Tests
      # ===========================================

      def test_stats
        @correlation.record_correlation(:e1, :e2, "group-a")
        @correlation.record_correlation(:e3, :e4, "group-b")

        stats = @correlation.stats

        assert_equal 4, stats[:total_events]
        assert_equal 2, stats[:correlation_groups]
        assert stats[:average_group_size] > 0
      end

      def test_stats_empty
        stats = @correlation.stats

        assert_equal 0, stats[:total_events]
        assert_equal 0, stats[:correlation_groups]
      end

      # ===========================================
      # To String Tests
      # ===========================================

      def test_to_s
        @correlation.record_correlation(:e1, :e2, "corr-1")

        output = @correlation.to_s

        assert_includes output, "CorrelationMatrix"
        assert_includes output, "2 events"
        assert_includes output, "1 groups"
      end
    end
  end
end
