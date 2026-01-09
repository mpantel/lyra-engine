# frozen_string_literal: true

require "test_helper"

module PetriFlow
  module Matrix
    class LineageTest < Minitest::Test
      def setup
        @lineage = Lineage.new
        @base_time = Time.now
      end

      # ===========================================
      # Initialization Tests
      # ===========================================

      def test_initialization
        assert_empty @lineage.fields
        assert_empty @lineage.events
        assert_kind_of Hash, @lineage.matrix
      end

      # ===========================================
      # Record Modification Tests
      # ===========================================

      def test_record_modification
        @lineage.record_modification(:email, :event1, old_value: "old@test.com", new_value: "new@test.com")

        assert_includes @lineage.fields, :email
        assert_includes @lineage.events, :event1
      end

      def test_record_modification_with_timestamp
        timestamp = Time.now - 3600

        @lineage.record_modification(:status, :event1, old_value: "pending", new_value: "active", timestamp: timestamp)

        lineage = @lineage.field_lineage(:status)
        assert_equal timestamp, lineage.first[:timestamp]
      end

      def test_record_multiple_modifications
        @lineage.record_modification(:email, :event1, old_value: nil, new_value: "a@test.com")
        @lineage.record_modification(:email, :event2, old_value: "a@test.com", new_value: "b@test.com")
        @lineage.record_modification(:name, :event3, old_value: nil, new_value: "John")

        assert_equal 2, @lineage.fields.size
        assert_equal 3, @lineage.events.size
      end

      # ===========================================
      # Modified? Tests
      # ===========================================

      def test_modified_returns_true_when_modified
        @lineage.record_modification(:email, :event1)

        assert @lineage.modified?(:email, :event1)
      end

      def test_modified_returns_false_when_not_modified
        @lineage.record_modification(:email, :event1)

        refute @lineage.modified?(:email, :event2)
        refute @lineage.modified?(:unknown_field, :event1)
      end

      # ===========================================
      # Events For Field Tests
      # ===========================================

      def test_events_for_field
        @lineage.record_modification(:email, :event1)
        @lineage.record_modification(:email, :event2)
        @lineage.record_modification(:name, :event3)

        events = @lineage.events_for_field(:email)

        assert_includes events, :event1
        assert_includes events, :event2
        refute_includes events, :event3
        assert_equal 2, events.size
      end

      def test_events_for_field_returns_empty_for_unknown
        assert_empty @lineage.events_for_field(:unknown)
      end

      # ===========================================
      # Fields For Event Tests
      # ===========================================

      def test_fields_for_event
        @lineage.record_modification(:email, :event1)
        @lineage.record_modification(:name, :event1)
        @lineage.record_modification(:status, :event2)

        fields = @lineage.fields_for_event(:event1)

        assert_includes fields, :email
        assert_includes fields, :name
        refute_includes fields, :status
        assert_equal 2, fields.size
      end

      def test_fields_for_event_returns_empty_for_unknown
        assert_empty @lineage.fields_for_event(:unknown)
      end

      # ===========================================
      # Field Lineage Tests
      # ===========================================

      def test_field_lineage
        t1 = @base_time
        t2 = @base_time + 60
        t3 = @base_time + 120

        @lineage.record_modification(:status, :e1, old_value: nil, new_value: "pending", timestamp: t1)
        @lineage.record_modification(:status, :e2, old_value: "pending", new_value: "active", timestamp: t2)
        @lineage.record_modification(:status, :e3, old_value: "active", new_value: "closed", timestamp: t3)

        lineage = @lineage.field_lineage(:status)

        assert_equal 3, lineage.size
        assert_equal :e1, lineage[0][:event_id]
        assert_equal :e2, lineage[1][:event_id]
        assert_equal :e3, lineage[2][:event_id]
      end

      def test_field_lineage_sorted_by_timestamp
        t1 = @base_time
        t2 = @base_time + 60

        # Record in reverse order
        @lineage.record_modification(:status, :e2, old_value: "a", new_value: "b", timestamp: t2)
        @lineage.record_modification(:status, :e1, old_value: nil, new_value: "a", timestamp: t1)

        lineage = @lineage.field_lineage(:status)

        assert_equal :e1, lineage[0][:event_id]
        assert_equal :e2, lineage[1][:event_id]
      end

      def test_field_lineage_returns_empty_for_unknown
        assert_empty @lineage.field_lineage(:unknown)
      end

      # ===========================================
      # Reconstruct Value Tests
      # ===========================================

      def test_reconstruct_value
        t1 = @base_time
        t2 = @base_time + 60
        t3 = @base_time + 120

        @lineage.record_modification(:status, :e1, old_value: nil, new_value: "pending", timestamp: t1)
        @lineage.record_modification(:status, :e2, old_value: "pending", new_value: "active", timestamp: t2)
        @lineage.record_modification(:status, :e3, old_value: "active", new_value: "closed", timestamp: t3)

        # At different points in time
        assert_equal "pending", @lineage.reconstruct_value(:status, t1 + 30)
        assert_equal "active", @lineage.reconstruct_value(:status, t2 + 30)
        assert_equal "closed", @lineage.reconstruct_value(:status, t3 + 30)
      end

      def test_reconstruct_value_returns_nil_before_first_modification
        t1 = @base_time

        @lineage.record_modification(:status, :e1, old_value: nil, new_value: "pending", timestamp: t1)

        assert_nil @lineage.reconstruct_value(:status, t1 - 60)
      end

      def test_reconstruct_value_returns_nil_for_unknown_field
        assert_nil @lineage.reconstruct_value(:unknown, @base_time)
      end

      # ===========================================
      # Value Chain Tests
      # ===========================================

      def test_value_chain
        @lineage.record_modification(:status, :e1, old_value: nil, new_value: "pending", timestamp: @base_time)
        @lineage.record_modification(:status, :e2, old_value: "pending", new_value: "active", timestamp: @base_time + 60)
        @lineage.record_modification(:status, :e3, old_value: "active", new_value: "closed", timestamp: @base_time + 120)

        chain = @lineage.value_chain(:status)

        assert_equal %w[pending active closed], chain
      end

      def test_value_chain_includes_initial_value
        @lineage.record_modification(:status, :e1, old_value: "draft", new_value: "pending", timestamp: @base_time)

        chain = @lineage.value_chain(:status)

        assert_equal %w[draft pending], chain
      end

      def test_value_chain_deduplicates
        @lineage.record_modification(:status, :e1, old_value: nil, new_value: "pending", timestamp: @base_time)
        @lineage.record_modification(:status, :e2, old_value: "pending", new_value: "pending", timestamp: @base_time + 60)

        chain = @lineage.value_chain(:status)

        assert_equal ["pending"], chain
      end

      def test_value_chain_returns_empty_for_unknown
        assert_empty @lineage.value_chain(:unknown)
      end

      # ===========================================
      # To Matrix Tests
      # ===========================================

      def test_to_matrix
        @lineage.record_modification(:email, :event1)
        @lineage.record_modification(:email, :event2)
        @lineage.record_modification(:name, :event1)

        matrix = @lineage.to_matrix

        assert_instance_of ::Matrix, matrix
        assert_equal 2, matrix.row_count    # 2 fields
        assert_equal 2, matrix.column_count  # 2 events
      end

      def test_to_matrix_values
        @lineage.record_modification(:email, :event1)
        @lineage.record_modification(:name, :event2)

        matrix = @lineage.to_matrix

        # email (row 0) modified by event1 (col 0)
        assert_equal 1, matrix[0, 0]
        # email (row 0) not modified by event2 (col 1)
        assert_equal 0, matrix[0, 1]
        # name (row 1) not modified by event1 (col 0)
        assert_equal 0, matrix[1, 0]
        # name (row 1) modified by event2 (col 1)
        assert_equal 1, matrix[1, 1]
      end

      # ===========================================
      # Stats Tests
      # ===========================================

      def test_stats
        @lineage.record_modification(:email, :event1)
        @lineage.record_modification(:email, :event2)
        @lineage.record_modification(:name, :event3)

        stats = @lineage.stats

        assert_equal 2, stats[:total_fields]
        assert_equal 3, stats[:total_events]
        assert_equal 3, stats[:total_modifications]
        assert_equal :email, stats[:most_modified_field]
      end

      def test_stats_empty
        stats = @lineage.stats

        assert_equal 0, stats[:total_fields]
        assert_equal 0, stats[:total_events]
        assert_equal 0, stats[:total_modifications]
      end

      # ===========================================
      # To String Tests
      # ===========================================

      def test_to_s
        @lineage.record_modification(:email, :event1)
        @lineage.record_modification(:name, :event2)

        output = @lineage.to_s

        assert_includes output, "LineageMatrix"
        assert_includes output, "2 fields"
        assert_includes output, "2 events"
      end
    end
  end
end
