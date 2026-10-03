# frozen_string_literal: true

require "test_helper"

class CachedRelationTest < Minitest::Test
  # Simple mock record class for testing
  class MockRecord
    attr_accessor :id, :name, :status, :active, :amount

    def initialize(attrs = {})
      @id = attrs[:id]
      @name = attrs[:name]
      @status = attrs[:status]
      @active = attrs[:active]
      @amount = attrs[:amount]
    end

    def read_attribute(name)
      public_send(name)
    end

    def inspect
      "#<MockRecord id=#{id}, name=#{name}>"
    end
  end

  # Mock model class for CachedRelation
  class MockModel
    def self.name
      "MockModel"
    end

    def self.primary_key
      "id"
    end

    def self.arel_table
      Arel::Table.new(:mock_models)
    end

    def self.connection
      nil
    end

    def self.table_name
      "mock_models"
    end

    def self.column_names
      %w[id name status active amount]
    end

    def self.type_for_attribute(name)
      Struct.new(:type).new(name.to_s == "active" ? :boolean : (%w[id amount].include?(name.to_s) ? :integer : :string))
    end

    # Simulate AR model responding to scopes
    def self.respond_to?(method, include_private = false)
      [:active, :by_status, :recent].include?(method) || super
    end
  end

  def setup
    @records = [
      MockRecord.new(id: 1, name: "First", status: "active", active: true, amount: 100),
      MockRecord.new(id: 2, name: "Second", status: "pending", active: false, amount: 200),
      MockRecord.new(id: 3, name: "Third", status: "active", active: true, amount: 150)
    ]

    @relation = Lyra::Projections::CachedRelation.new(MockModel, @records)
  end

  # ===========================================================================
  # Basic Enumerable Tests
  # ===========================================================================

  def test_enumerable_each
    names = []
    @relation.each { |r| names << r.name }
    assert_equal %w[First Second Third], names
  end

  def test_to_a_returns_array_copy
    arr = @relation.to_a
    assert_equal 3, arr.size
    assert_instance_of Array, arr
  end

  def test_count_returns_size
    assert_equal 3, @relation.count
  end

  def test_empty_returns_false_when_records_exist
    refute @relation.empty?
  end

  def test_empty_returns_true_when_no_records
    empty_relation = Lyra::Projections::CachedRelation.new(MockModel, [])
    assert empty_relation.empty?
  end

  # ===========================================================================
  # Finder Tests
  # ===========================================================================

  def test_first_returns_first_record
    assert_equal 1, @relation.first.id
  end

  def test_last_returns_last_record
    assert_equal 3, @relation.last.id
  end

  def test_find_by_id
    record = @relation.find(2)
    assert_equal "Second", record.name
  end

  def test_find_by_attributes
    record = @relation.find_by(status: "pending")
    assert_equal "Second", record.name
  end

  def test_find_by_returns_nil_when_not_found
    record = @relation.find_by(status: "nonexistent")
    assert_nil record
  end

  # ===========================================================================
  # Where Filtering Tests
  # ===========================================================================

  def test_where_filters_by_hash_condition
    result = @relation.where(status: "active")
    assert_equal 2, result.count
    assert result.all? { |r| r.status == "active" }
  end

  def test_where_chains_multiple_conditions
    result = @relation.where(status: "active").where(id: 1)
    assert_equal 1, result.count
    assert_equal "First", result.first.name
  end

  def test_where_filters_by_array
    result = @relation.where(id: [1, 3])
    assert_equal 2, result.count
    assert_equal %w[First Third], result.map(&:name)
  end

  def test_where_not_excludes_matching_records
    result = @relation.where(:chain).not(status: "pending")
    assert_equal 2, result.count
    assert result.none? { |r| r.status == "pending" }
  end

  # ===========================================================================
  # Type Coercion Tests
  # ===========================================================================

  def test_type_coercion_string_to_integer
    # Simulates params[:id] = "2" matching record.id = 2
    result = @relation.where(id: "2")
    assert_equal 1, result.count
    assert_equal "Second", result.first.name
  end

  def test_type_coercion_integer_id_in_array
    # Simulates params[:ids] = ["1", "3"]
    result = @relation.where(id: ["1", "3"])
    assert_equal 2, result.count
  end

  def test_type_coercion_boolean_string_true
    result = @relation.where(active: "true")
    assert_equal 2, result.count
    assert result.all?(&:active)
  end

  def test_type_coercion_boolean_string_false
    result = @relation.where(active: "false")
    assert_equal 1, result.count
    refute result.first.active
  end

  # ===========================================================================
  # Order Tests
  # ===========================================================================

  def test_order_by_symbol_ascending
    result = @relation.order(:amount)
    assert_equal [100, 150, 200], result.map(&:amount)
  end

  def test_order_by_hash_descending
    result = @relation.order(amount: :desc)
    assert_equal [200, 150, 100], result.map(&:amount)
  end

  def test_order_by_primary_key_asc
    # Records in non-ID order
    unordered = Lyra::Projections::CachedRelation.new(MockModel, [
      MockRecord.new(id: 3, name: "Third"),
      MockRecord.new(id: 1, name: "First"),
      MockRecord.new(id: 2, name: "Second")
    ])
    result = unordered.order(id: :asc)
    assert_equal [1, 2, 3], result.map(&:id)
  end

  def test_order_by_primary_key_desc
    result = @relation.order(id: :desc)
    assert_equal [3, 2, 1], result.map(&:id)
  end

  # ===========================================================================
  # Pagination Tests
  # ===========================================================================

  def test_limit_returns_subset
    result = @relation.limit(2)
    assert_equal 2, result.count
  end

  def test_offset_skips_records
    result = @relation.offset(1)
    assert_equal 2, result.count
    assert_equal "Second", result.first.name
  end

  def test_page_and_per_pagination
    result = @relation.page(2).per(1)
    assert_equal 1, result.count
    assert_equal "Second", result.first.name
  end

  # ===========================================================================
  # Aggregation Tests
  # ===========================================================================

  def test_sum_column
    assert_equal 450, @relation.sum(:amount)
  end

  def test_average_column
    assert_equal 150.0, @relation.average(:amount)
  end

  def test_minimum_column
    assert_equal 100, @relation.minimum(:amount)
  end

  def test_maximum_column
    assert_equal 200, @relation.maximum(:amount)
  end

  def test_pluck_single_column
    assert_equal %w[First Second Third], @relation.pluck(:name)
  end

  def test_pluck_multiple_columns
    result = @relation.pluck(:id, :name)
    assert_equal [[1, "First"], [2, "Second"], [3, "Third"]], result
  end

  # ===========================================================================
  # AR-like Chaining Methods (No-ops)
  # ===========================================================================

  def test_includes_is_noop
    result = @relation.includes(:association)
    assert_equal 3, result.count
  end

  # A join changes which records match, so it is refused rather than ignored
  # (it used to be a silent no-op).
  def test_joins_raises
    assert_raises(Lyra::Projections::UnsupportedQuery) { @relation.joins(:other) }
  end

  def test_preload_is_noop
    result = @relation.preload(:items)
    assert_equal 3, result.count
  end

  def test_distinct_removes_duplicates
    dup_records = @records + [@records[0]]
    dup_relation = Lyra::Projections::CachedRelation.new(MockModel, dup_records)
    result = dup_relation.distinct
    assert_equal 3, result.count
  end

  # ===========================================================================
  # Complex Chaining Tests
  # ===========================================================================

  def test_complex_chain
    result = @relation
      .where(status: "active")
      .order(amount: :desc)
      .limit(1)

    assert_equal 1, result.count
    assert_equal "Third", result.first.name
    assert_equal 150, result.first.amount
  end

  def test_filter_then_order_then_paginate
    result = @relation
      .where(active: true)
      .order(id: :asc)
      .page(1)
      .per(1)

    assert_equal 1, result.count
    assert_equal "First", result.first.name
  end
end
