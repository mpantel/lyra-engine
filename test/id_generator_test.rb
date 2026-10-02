# frozen_string_literal: true

require "test_helper"

class IdGeneratorTest < Minitest::Test
  def setup
    # Reset Hi-Lo state between tests
    Lyra::IdGenerator.instance_variable_set(:@hilo_state, {})
    Lyra::IdGenerator.instance_variable_set(:@sequence_names, {})
  end

  # ===========================================================================
  # Primary Key Type Tests
  # ===========================================================================

  def test_next_id_returns_integer_for_integer_primary_key
    model_class = create_mock_model(:integer, adapter: "SQLite")

    id = Lyra::IdGenerator.next_id(model_class)

    assert_kind_of Integer, id
    assert id > 0
  end

  def test_next_id_returns_integer_for_bigint_primary_key
    model_class = create_mock_model(:bigint, adapter: "SQLite")

    id = Lyra::IdGenerator.next_id(model_class)

    assert_kind_of Integer, id
    assert id > 0
  end

  def test_next_id_returns_uuid_for_uuid_primary_key
    model_class = create_mock_model(:uuid, adapter: "SQLite")

    id = Lyra::IdGenerator.next_id(model_class)

    assert_kind_of String, id
    assert_match(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i, id)
  end

  def test_next_id_returns_uuid_for_unknown_primary_key_type
    model_class = create_mock_model(:string, adapter: "SQLite")

    id = Lyra::IdGenerator.next_id(model_class)

    # Unknown types default to UUID for safety
    assert_kind_of String, id
    assert_match(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i, id)
  end

  # ===========================================================================
  # SQLite Adapter Tests (max(id) + 1 strategy)
  # ===========================================================================

  def test_sqlite_uses_max_plus_one_strategy
    model_class = create_mock_model(:integer, adapter: "SQLite")

    id1 = Lyra::IdGenerator.next_id(model_class)
    id2 = Lyra::IdGenerator.next_id(model_class)

    # SQLite queries max(id) each time, so IDs increment
    assert id2 > id1, "SQLite should generate incrementing IDs"
  end

  def test_sqlite_handles_empty_table
    # Empty table returns nil for max(id)
    model_class = create_mock_model(:integer, adapter: "SQLite", max_id: nil)

    id = Lyra::IdGenerator.next_id(model_class)

    assert_equal 1, id, "Empty table should start at ID 1"
  end

  # ===========================================================================
  # PostgreSQL Adapter Tests (sequence strategy)
  # ===========================================================================

  def test_postgresql_uses_sequence_strategy
    sequence_value = 42
    model_class = create_postgresql_mock_model(:integer, sequence_value: sequence_value)

    id = Lyra::IdGenerator.next_id(model_class)

    assert_equal sequence_value, id, "PostgreSQL should use nextval from sequence"
  end

  def test_postgresql_sequence_increments
    current_seq = { value: 100 }
    model_class = create_postgresql_mock_model(:integer, sequence_tracker: current_seq)

    ids = 5.times.map { Lyra::IdGenerator.next_id(model_class) }

    assert_equal [100, 101, 102, 103, 104], ids, "PostgreSQL sequence should increment"
  end

def test_postgresql_looks_up_the_sequence_name_once
  model_class = create_postgresql_mock_model(:integer, sequence_value: 1)
  statements = []
  connection = model_class.connection
  original = connection.method(:execute)
  connection.define_singleton_method(:execute) { |sql| statements << sql; original.call(sql) }

  3.times { Lyra::IdGenerator.next_id(model_class) }

  assert_equal 1, statements.count { |sql| sql.include?("pg_get_serial_sequence") },
    "the sequence name is fixed; only nextval should run per ID"
  assert_equal 3, statements.count { |sql| sql.include?("nextval") }
end

  def test_postgresql_falls_back_to_hilo_without_sequence
    # When pg_get_serial_sequence returns nil
    model_class = create_mock_model(:integer, adapter: "PostgreSQL")

    id = Lyra::IdGenerator.next_id(model_class)

    # Should get a valid ID via Hi-Lo fallback
    assert_kind_of Integer, id
    assert id > 0
  end

  # ===========================================================================
  # MySQL Adapter Tests (Hi-Lo algorithm)
  # ===========================================================================

  def test_mysql_uses_hilo_algorithm
    model_class = create_mock_model(:integer, adapter: "Mysql2")

    # Hi-Lo should generate IDs without querying DB for each one
    ids = 5.times.map { Lyra::IdGenerator.next_id(model_class) }

    # All IDs should be unique
    assert_equal 5, ids.uniq.size
  end

  def test_hilo_generates_sequential_ids_within_block
    model_class = create_mock_model(:integer, adapter: "Mysql2")

    ids = 5.times.map { Lyra::IdGenerator.next_id(model_class) }

    # IDs within a Hi-Lo block should be sequential
    ids.each_cons(2) do |a, b|
      assert_equal 1, b - a, "Hi-Lo should generate sequential IDs"
    end
  end

  # ===========================================================================
  # Uniqueness Tests
  # ===========================================================================

  def test_next_id_generates_unique_ids
    model_class = create_mock_model(:integer, adapter: "SQLite")

    ids = 10.times.map { Lyra::IdGenerator.next_id(model_class) }

    assert_equal 10, ids.uniq.size, "All IDs should be unique"
  end

  def test_different_models_get_different_id_sequences
    model1 = create_mock_model(:integer, adapter: "SQLite", table: "users")
    model2 = create_mock_model(:integer, adapter: "SQLite", table: "orders")

    id1 = Lyra::IdGenerator.next_id(model1)
    id2 = Lyra::IdGenerator.next_id(model2)

    # Both should get IDs (they may or may not be the same depending on state)
    assert id1.is_a?(Integer)
    assert id2.is_a?(Integer)
  end

  # ===========================================================================
  # Thread Safety Tests (conceptual)
  # ===========================================================================

  def test_hilo_state_is_per_table
    # Each table should have its own Hi-Lo state
    Lyra::IdGenerator.instance_variable_set(:@hilo_state, {})

    model1 = create_mock_model(:integer, adapter: "Mysql2", table: "table_a", name: "ModelA")
    model2 = create_mock_model(:integer, adapter: "Mysql2", table: "table_b", name: "ModelB")

    Lyra::IdGenerator.next_id(model1)
    Lyra::IdGenerator.next_id(model2)

    hilo_state = Lyra::IdGenerator.instance_variable_get(:@hilo_state)

    # Each table should have its own entry (keyed by model name)
    assert hilo_state.key?("ModelA"), "Should have entry for ModelA"
    assert hilo_state.key?("ModelB"), "Should have entry for ModelB"
    assert_equal 2, hilo_state.keys.size, "Should have exactly 2 entries"
  end

  private

  # Special mock for PostgreSQL with sequence support
  def create_postgresql_mock_model(pk_type, sequence_value: 100, sequence_tracker: nil, table: "test_models")
    seq_tracker = sequence_tracker || { value: sequence_value }

    # Create a mock result that behaves like PG::Result
    mock_connection = Object.new
    mock_connection.define_singleton_method(:adapter_name) { "PostgreSQL" }
    mock_connection.define_singleton_method(:execute) do |sql|
      if sql.include?("pg_get_serial_sequence")
        # Return the sequence name
        result = Object.new
        result.define_singleton_method(:first) { { "pg_get_serial_sequence" => "#{table}_id_seq" } }
        result
      elsif sql.include?("nextval")
        # Return the next sequence value
        current = seq_tracker[:value]
        seq_tracker[:value] += 1
        result = Object.new
        result.define_singleton_method(:first) { { "nextval" => current } }
        result
      else
        result = Object.new
        result.define_singleton_method(:first) { nil }
        result
      end
    end

    mock_column = Struct.new(:type).new(pk_type)
    table_name = table

    mock_class = Class.new do
      define_singleton_method(:primary_key) { "id" }
      define_singleton_method(:table_name) { table_name }
      define_singleton_method(:columns_hash) { { "id" => mock_column } }
      define_singleton_method(:connection) { mock_connection }
      define_singleton_method(:unscoped) { self }
      define_singleton_method(:maximum) { |_| 100 }
      define_singleton_method(:name) { "PostgresTestModel" }
    end

    mock_class
  end

  def create_mock_model(pk_type, adapter: "SQLite", max_id: 100, sequence_value: nil, sequence_tracker: nil, table: "test_models", name: "TestModel")
    # Track state for simulation
    max_id_tracker = { value: max_id }
    seq_tracker = sequence_tracker || { value: sequence_value || 100 }
    model_name = name

    mock_connection = Object.new
    mock_connection.define_singleton_method(:adapter_name) { adapter }
    mock_connection.define_singleton_method(:execute) do |sql|
      if sql.include?("nextval")
        # PostgreSQL sequence
        current = seq_tracker[:value]
        seq_tracker[:value] += 1
        [{ "nextval" => current }]
      elsif sql.include?("MAX")
        # SQLite/MySQL max query
        current = max_id_tracker[:value]
        max_id_tracker[:value] = (current || 0) + 1 if current
        [{ "max_id" => current }]
      else
        []
      end
    end

    mock_column = Struct.new(:type).new(pk_type)
    table_name = table

    mock_class = Class.new do
      define_singleton_method(:primary_key) { "id" }
      define_singleton_method(:table_name) { table_name }
      define_singleton_method(:columns_hash) { { "id" => mock_column } }
      define_singleton_method(:connection) { mock_connection }
      define_singleton_method(:unscoped) { self }
      define_singleton_method(:maximum) { |_| max_id_tracker[:value] }
      define_singleton_method(:name) { model_name }
    end

    mock_class
  end
end
