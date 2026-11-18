# frozen_string_literal: true

require "test_helper"

# Lyra::Projections::AsyncCheckpoint on its own: a checkpoint per stream,
# moved forward by a later write, and forgotten by reset! (which leases a
# connection of its own when given none).
class AsyncCheckpointBranchesTest < Minitest::Test
  Checkpoint = Lyra::Projections::AsyncCheckpoint

  def setup
    skip "Requires PostgreSQL" unless defined?(ActiveRecord::Base) && connection.adapter_name.match?(/postgres/i)

    Checkpoint.reset!(connection)
  end

  def teardown
    Checkpoint.reset!(connection) if defined?(ActiveRecord::Base)
  end

  def test_a_checkpoint_per_stream_moves_forward_and_is_forgotten_on_reset
    assert_nil Checkpoint.read(connection, "CkWidget$1")

    Checkpoint.write(connection, "CkWidget$1", "e1")
    Checkpoint.write(connection, "CkWidget$2", "e7")
    Checkpoint.write(connection, "CkWidget$1", "e2")
    assert_equal %w[e2 e7], [Checkpoint.read(connection, "CkWidget$1"), Checkpoint.read(connection, "CkWidget$2")]

    Checkpoint.reset!
    assert_nil Checkpoint.read(connection, "CkWidget$1")
    assert_nil Checkpoint.read(connection, "CkWidget$2")
  end

  private

  def connection = ActiveRecord::Base.connection
end
