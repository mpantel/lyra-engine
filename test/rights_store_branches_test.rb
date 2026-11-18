# frozen_string_literal: true

require "test_helper"

# Lyra::Rights::Store (PamDsl.rights_store): what the main rights store tests
# leave out. Appends it refuses, the subject key of a request whose row is not
# in lyra_rights, and what a connection sees of the rights its own open
# transaction recorded (active, in_force_requests, keys_in_force,
# snapshot_token), before and after the transaction ends.
class RightsStoreBranchesTest < Minitest::Test
  ANN = "Payer$7"
  BOB = "Payer$8"

  def setup
    skip "Requires Rails and database" unless defined?(ActiveRecord::Base) && ActiveRecord::Base.connection.table_exists?(:users)
    skip "Requires pam_dsl" unless Lyra.pam_dsl_available?

    PamDsl.reset!
    PamDsl.logger = Logger.new(nil)
    LyraRightsIsolation.purge!
    @store = Lyra::Rights.store
  end

  def teardown
    return unless defined?(PamDsl)

    LyraRightsIsolation.purge!
    PamDsl.reset!
    PamDsl.logger = nil
  end

  def rights = PamDsl.rights

  # ── Appends it refuses ──

  def test_an_append_of_no_events_is_refused
    assert_raises(ArgumentError) { @store.append([], expected_version: 0) }
  end

  def test_an_append_for_two_subjects_is_refused_and_stores_nothing
    events = [ANN, BOB].map do |key|
      PamDsl::Rights.build_event("ProcessingRestricted", SecureRandom.uuid, key, { ground: :accuracy_contested, fields: [] },
                                 at: nil, by: "dpo")
    end

    error = assert_raises(ArgumentError) { @store.append(events, expected_version: 0) }
    assert_includes error.message, "exactly one subject key"
    assert_empty @store.events_for(ANN)
    assert_empty @store.events_for(BOB)
  end

  # ── subject_key_for ──

  # A request whose row is not in lyra_rights (the table being rebuilt) is
  # found in the index stream; an unknown request has no key.
  def test_the_subject_key_of_a_request_without_a_row_comes_from_the_index_stream
    r = rights.restrict!(subject: ANN, ground: :accuracy_contested)
    rights.restrict!(subject: BOB, ground: :accuracy_contested)
    ActiveRecord::Base.connection.execute("DELETE FROM #{Lyra::Rights::TABLE}")

    assert_equal ANN, @store.subject_key_for(r.id)
    assert_nil @store.subject_key_for(SecureRandom.uuid)
  end

  # ── Keys in force ──

  def test_keys_in_force_are_the_subjects_with_a_request_in_force
    r = rights.restrict!(subject: ANN, ground: :accuracy_contested)
    rights.restrict!(subject: BOB, ground: :needed_for_legal_claims)
    assert_equal [ANN, BOB], Lyra::Rights.keys_in_force.sort

    rights.notify_lift!(r.id)
    rights.lift!(r.id, reason: :accuracy_verified)
    @store.refresh!
    assert_equal [BOB], Lyra::Rights.keys_in_force
  end

  # ── Its own transaction's rights ──

  # Inside the transaction that recorded it, a restriction is in force for
  # this connection (read afresh, not from the shared snapshot); a request
  # lifted in it is not. Once the transaction rolls back, neither stays.
  def test_a_transaction_sees_the_rights_it_recorded_until_it_rolls_back
    lifted = rights.restrict!(subject: BOB, ground: :accuracy_contested)
    shared = @store.snapshot_token

    ActiveRecord::Base.transaction do
      r = rights.restrict!(subject: ANN, ground: :accuracy_contested)
      rights.notify_lift!(lifted.id)
      rights.lift!(lifted.id, reason: :accuracy_verified)

      assert_equal [r.id], @store.active.map(&:id)
      assert_equal [r.id], @store.in_force_requests.map(&:id)
      assert_nil @store.snapshot_token, "nothing derived from the rights holds while the transaction has its own"
      assert_same @store, @store.refresh!, "the shared snapshot is not filled from this transaction"
      assert_equal [ANN], @store.active_for([ANN, BOB]).map(&:subject_key)
      raise ActiveRecord::Rollback
    end

    assert_equal [lifted.id], @store.active.map(&:id)
    assert_equal [BOB], @store.keys_in_force
    assert_equal shared, @store.snapshot_token, "the committed rights again"
  end

  # keys_in_force adds the keys the transaction put in force to the
  # committed ones, and drops them again when it rolls back.
  def test_keys_in_force_inside_a_transaction
    rights.restrict!(subject: BOB, ground: :accuracy_contested)
    @store.refresh!

    ActiveRecord::Base.transaction do
      rights.restrict!(subject: ANN, ground: :accuracy_contested)
      assert_equal [ANN, BOB], @store.keys_in_force.sort
      raise ActiveRecord::Rollback
    end

    assert_equal [BOB], @store.keys_in_force
  end

  # Another connection does not see an uncommitted restriction.
  def test_another_connection_does_not_see_an_uncommitted_restriction
    seen = nil
    ActiveRecord::Base.transaction do
      rights.restrict!(subject: ANN, ground: :accuracy_contested)
      seen = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          @store.refresh!
          [@store.keys_in_force, @store.active.size, @store.any_active?]
        end
      end.value
      raise ActiveRecord::Rollback
    end

    assert_equal [[], 0, false], seen
  end
end
