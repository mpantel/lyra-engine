# frozen_string_literal: true

require "test_helper"

# Lyra::Rights::Store from a connection whose open transaction recorded
# rights of its own: what it answers is the committed rights read afresh,
# with its own uncommitted ones in place of the committed state of the
# subjects it wrote. A restriction committed just before the transaction
# began (the write left the shared snapshot without its subject, to be read
# again) used to be missing inside it, because the snapshot was never read
# while the connection had rights of its own; and keys_in_force kept a
# subject whose restriction the transaction lifted.
class RightsStorePendingTest < Minitest::Test
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

  def test_a_restriction_committed_before_the_transaction_is_in_force_inside_it
    bob = rights.restrict!(subject: BOB, ground: :accuracy_contested)

    ActiveRecord::Base.transaction do
      ann = rights.restrict!(subject: ANN, ground: :accuracy_contested)

      assert_equal [bob.id], @store.active_for([BOB]).map(&:id)
      assert_equal [ann.id, bob.id].sort, @store.active.map(&:id).sort
      assert_equal [ann.id, bob.id].sort, @store.in_force_requests.map(&:id).sort
      assert_equal [ANN, BOB], @store.keys_in_force.sort
      assert @store.any_active?
      raise ActiveRecord::Rollback
    end

    assert_equal [BOB], @store.keys_in_force
    assert_equal [bob.id], @store.active.map(&:id)
  end

  # Another process's restriction, committed while the transaction is open,
  # applies inside it from the next refresh, as it does outside.
  def test_a_restriction_committed_by_another_connection_during_the_transaction
    ActiveRecord::Base.transaction do
      rights.restrict!(subject: ANN, ground: :accuracy_contested)
      other_process_restricts(BOB)

      @store.refresh!
      assert_equal [ANN, BOB], @store.keys_in_force.sort
      raise ActiveRecord::Rollback
    end
  end

  def test_keys_in_force_leaves_out_a_restriction_the_transaction_lifted
    lifted = rights.restrict!(subject: BOB, ground: :accuracy_contested)
    @store.refresh!

    ActiveRecord::Base.transaction do
      rights.notify_lift!(lifted.id)
      rights.lift!(lifted.id, reason: :accuracy_verified)

      assert_empty @store.active
      assert_empty @store.active_for([BOB])
      assert_equal [], @store.keys_in_force
      raise ActiveRecord::Rollback
    end

    assert_equal [BOB], @store.keys_in_force, "rolled back: in force again"
  end

  # Under REPEATABLE READ the connection reads the database as its
  # transaction began: what it reads is for itself only, and another thread
  # still sees a restriction committed after that.
  def test_a_repeatable_read_transaction_does_not_hide_a_later_restriction_from_others
    seen = nil
    ActiveRecord::Base.transaction(isolation: :repeatable_read) do
      rights.restrict!(subject: ANN, ground: :accuracy_contested)
      other_process_restricts(BOB)
      before = in_other_thread { @store.refresh!; @store.active_for([BOB]).size }
      @store.refresh!
      @store.keys_in_force
      after = in_other_thread { @store.active_for([BOB]).size }
      seen = [before, after]
      raise ActiveRecord::Rollback
    end

    assert_equal [1, 1], seen
    assert_equal [BOB], @store.keys_in_force
  end

  # A restriction another thread commits while this connection reads its
  # own snapshot (after the rows in force were read, before the snapshot is
  # kept) is not missed: the read is made again.
  def test_a_restriction_committed_while_the_connection_reads_its_snapshot_is_not_missed
    seen = nil
    ActiveRecord::Base.transaction do
      rights.restrict!(subject: ANN, ground: :accuracy_contested)
      main = Thread.current
      fired = false
      other = method(:other_thread_restricts)
      @store.singleton_class.define_method(:in_force_markers) do
        result = super()
        if Thread.current == main && !fired
          fired = true
          other.call(BOB)
        end
        result
      end
      @store.invalidate!
      @store.active_for([ANN])
      seen = [@store.active_for([BOB]).size, in_other_thread { @store.active_for([BOB]).size }]
      raise ActiveRecord::Rollback
    ensure
      @store.singleton_class.send(:remove_method, :in_force_markers) if @store.singleton_class.method_defined?(:in_force_markers, false)
    end

    assert_equal [1, 1], seen
  end

  # What the transaction wrote does not reach the snapshot other connections
  # read, and they still see what was committed.
  def test_other_connections_see_the_committed_rights_only
    lifted = rights.restrict!(subject: BOB, ground: :accuracy_contested)
    seen = nil

    ActiveRecord::Base.transaction do
      rights.restrict!(subject: ANN, ground: :accuracy_contested)
      rights.notify_lift!(lifted.id)
      rights.lift!(lifted.id, reason: :accuracy_verified)
      @store.keys_in_force
      seen = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection { [@store.keys_in_force, @store.active_for([BOB]).size] }
      end.value
      raise ActiveRecord::Rollback
    end

    assert_equal [[BOB], 1], seen
  end

  # The cost of a check: none while the snapshot is current, whether or not
  # the connection has rights of its own; inside such a transaction, one
  # read when it is due, then none until it is due again.
  def test_checks_read_the_table_only_when_due
    rights.restrict!(subject: BOB, ground: :accuracy_contested)
    @store.refresh!
    assert_equal 0, rights_queries { 3.times { @store.active_for([BOB]) } }

    ActiveRecord::Base.transaction do
      rights.restrict!(subject: ANN, ground: :accuracy_contested)
      @store.active_for([BOB])
      assert_equal 0, rights_queries { 3.times { @store.active_for([BOB]) } }
      raise ActiveRecord::Rollback
    end
  end

  private

  # A restriction recorded and committed by another process (its own store
  # and connection).
  def other_process_restricts(key)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Lyra::Rights::Store.new.append(
          [PamDsl::Rights.build_event("ProcessingRestricted", SecureRandom.uuid, key,
                                      { ground: :accuracy_contested, fields: [] }, at: nil, by: "other")],
          expected_version: 0
        )
      end
    end.join
  end

  # A restriction recorded through PAM DSL by another thread of this
  # process (the shared store; its write settles and invalidates).
  def other_thread_restricts(key)
    in_other_thread { PamDsl.rights.restrict!(subject: key, ground: :accuracy_contested) }
  end

  def in_other_thread(&block)
    Thread.new { ActiveRecord::Base.connection_pool.with_connection(&block) }.value
  end

  def rights_queries(&block)
    count = 0
    callback = ->(*, payload) { count += 1 if payload[:sql].include?(Lyra::Rights::TABLE) }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record", &block)
    count
  end
end
