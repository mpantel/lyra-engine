# frozen_string_literal: true

require "test_helper"
require_relative "es_noproj_uniqueness_test"

# ES-NoProj's uniqueness validation on a column with a unique index reads the
# value's holders from its value stream, not every record of the model
# (1.0.1), and answers as the full read does: a record that moved to another
# value or was destroyed holds it no longer, and an update keeping its value
# is not its own duplicate. Without a unique index, or under
# case_sensitive: false on a column that is not citext, every record is read
# as before.
class EsNoprojUniquenessHoldersTest < EsNoprojUniquenessTest
  EsNoprojUniquenessTest.instance_methods(false).grep(/^test_/).each { undef_method(_1) }

  SNAPSHOT = Lyra::Projections::Uniqueness::Snapshot

  def test_a_column_with_a_unique_index_is_checked_against_its_value_s_holders
    use(:es_noproj)
    30.times { |i| UqRaced.create!(code: "B#{i}") }
    UqRaced.find_by(code: "B4").update!(code: "B4x")
    UqRaced.find_by(code: "B5").destroy!

    SNAPSHOT.expects(:records).never
    assert taken?(UqRaced.new(code: "B3"), :code)
    refute taken?(UqRaced.new(code: "new"), :code)
    refute taken?(UqRaced.new(code: "B4"), :code), "its holder moved to another value"
    assert taken?(UqRaced.new(code: "B4x"), :code)
    refute taken?(UqRaced.new(code: "B5"), :code), "its holder was destroyed"
    keeping = UqRaced.find_by(code: "B6").tap { _1.note = "n" }
    refute taken?(keeping, :code), "an update keeping its value"
    moving = UqRaced.find_by(code: "B7").tap { _1.code = "B8" }
    assert taken?(moving, :code)
  end

  # A validation a unique index covers takes no value lock (from 1.0.1): the
  # append-time index check refuses a duplicate under its own lock, as the
  # table's index does in Monitor. One no index covers keeps its lock.
  def test_a_validation_an_index_covers_takes_no_value_lock
    use(:es_noproj)
    locks = lambda do |&write|
      sql = []
      callback = ->(*, payload) { sql << payload[:sql] }
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { UqRaced.transaction(&write) }
      sql.grep(/pg_advisory_xact_lock.*lyra_unique/).size
    end
    assert_equal 0, locks.call { UqRaced.new(code: "V1").valid? }, "code: a unique index covers it"
    assert_operator locks.call { UqRaced.new(code: "V2", amount: 7).valid? }, :>=, 1, "amount: no index"
    assert_operator locks.call { UqRaced.new(code: "V3", name: "Nm").valid? }, :>=, 1, "name: case_sensitive: false, no index"
  end

  def test_without_a_unique_index_or_case_sensitivity_every_record_is_read
    use(:es_noproj)
    UqRaced.create!(code: "C1", name: "Same", amount: 5)
    all = SNAPSHOT.records(UqRaced)
    SNAPSHOT.expects(:records).with(UqRaced).at_least(2).returns(all)
    assert taken?(UqRaced.new(code: "C2", name: "SAME"), :name), "case_sensitive: false on a string column"
    assert taken?(UqRaced.new(code: "C3", amount: 5), :amount), "no unique index on amount"
  end
end
