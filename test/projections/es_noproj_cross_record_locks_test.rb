# frozen_string_literal: true

require "test_helper"

# ES-NoProj's aggregate locks across records and models, against plain Active
# Record's row locks and Lyra::Verification::MultiRecordLockNet: Rails' writes
# of other records (touch: true, dependent: :destroy) take their locks in the
# order plain Active Record writes the rows; a locking read of several
# records takes them in stream-name order and a bulk write in the order of
# their keys' hashes, two of the orders plain Active Record's scans can take.
class EsNoprojCrossRecordLocksTest < Minitest::Test
  PARENTS = "lyra_xrec_parents"
  KIDS = "lyra_xrec_kids"
  NET = defined?(Lyra::Verification::MultiRecordLockNet) ? Lyra::Verification::MultiRecordLockNet : nil

  def setup
    skip "Requires Rails and PostgreSQL" unless defined?(ActiveRecord::Base) && connection.adapter_name.match?(/postgres/i)

    connection.create_table(PARENTS, force: true) do |t|
      t.integer :kids_count, null: false, default: 0
      t.integer :n, default: 0
      t.timestamps
    end
    connection.create_table(KIDS, force: true) do |t|
      t.integer :xrec_parent_id
      t.integer :n, default: 0
      t.timestamps
    end
    clean
  end

  def teardown
    return unless defined?(ActiveRecord::Base) && connection.adapter_name.match?(/postgres/i)

    Lyra.config.projection_mode = :sync
    Lyra.reset_config!
    clean
    connection.drop_table(KIDS, if_exists: true)
    connection.drop_table(PARENTS, if_exists: true)
  end

  # A kid's update touches its parent: the kid's row, then the parent's.
  def test_touch_takes_the_locks_in_plain_active_records_order
    plain, lyra = both { |_, kids| kids.first.update!(n: 5) }

    assert_equal [[KIDS, 0], [PARENTS, 0]], plain
    assert_equal plain, lyra
  end

  # A parent's destroy with dependent: :destroy: its kids, then itself.
  def test_dependent_destroy_takes_the_locks_in_plain_active_records_order
    plain, lyra = both { |parents, _| parents.first.destroy! }

    assert_equal [[KIDS, 0], [KIDS, 1], [PARENTS, 0]], plain
    assert_equal plain, lyra
  end

  # Records of two models in one transaction: a kid's write, which touches
  # its parent, and a locking read of another parent. Rails defers the touch
  # to just before the commit (touch_later), so the touched parent comes
  # last, in plain Active Record and in ES-NoProj; the net's order, records
  # numbered kid, locked parent, touched parent.
  def test_records_of_two_models_follow_plain_active_record_and_the_net
    plain, lyra = both do |parents, kids|
      kids.last.update!(n: 1)
      parents[1].with_lock { parents[1].update!(n: 2) }
    end
    expected = net_order([[:write, 0], [:lock_read, 1], [:write, 2]], [[KIDS, 1], [PARENTS, 1], [PARENTS, 0]])

    assert_equal expected, lyra
    assert_equal plain, lyra
  end

  # A locking read of several records: stream-name order, the net's.
  def test_a_locking_read_of_several_records_takes_them_in_stream_name_order
    _, lyra = both(plain: false) { |parents, _| XrecParent.lock.where(id: parents.map(&:id)).to_a }
    streams = lyra.map { stream(*_1) }

    assert_equal streams.sort, streams
    assert_equal 3, streams.size
  end

  # A bulk write: its records' aggregate locks in one statement, in the order
  # of their keys' hashes (the net's +bulk_order+), then their heads.
  def test_a_bulk_write_takes_its_locks_in_hash_order_in_one_statement
    statements = []
    _, lyra = both(plain: false, statements: statements) { |parents, _| XrecParent.where(id: parents.map(&:id)).update_all(n: 9) }
    ids = @parents.map(&:id)
    keys = ids.map { "lyra_aggregate/#{Lyra.stream_name(XrecParent, _1)}" }
    hashes = keys.to_h { [_1, connection.select_value("SELECT hashtext(#{connection.quote(_1)})").to_i] }
    order = keys.each_index.sort_by { hashes[keys[_1]] }

    assert_equal ids.size, lyra.size, "every record's lock"
    assert(statements.any? { |sql| sql.include?("ORDER BY h") && keys.all? { sql.include?(_1) } }, "one statement, ordered by hash")
    net_order = NET.new(NET::Config.new(name: "bulk", records: 3, programs: [], read: :own, bulk_order: order))
                    .aggregate_lock_order([[:bulk, [0, 1, 2]]])
    assert_equal order, net_order
  end

  # A counter cache, which ES-NoProj does not keep: plain Active Record
  # updates the parent's row (the counter and its timestamp) when a kid is
  # created; ES-NoProj takes no lock on the parent and leaves it as it was.
  def test_a_counter_cache_takes_no_lock_in_es_noproj
    plain, lyra = both { |parents, _| XrecKid.create!(xrec_parent: parents[2]) }

    assert_equal [[PARENTS, 2]], plain.select { _1.first == PARENTS }
    assert_empty lyra.select { _1.first == PARENTS }
    assert_equal 0, XrecParent.find(@parents[2].id).kids_count
  end

  def test_a_counter_cache_on_destroy_takes_no_lock_in_es_noproj
    plain, lyra = both { |_, kids| kids.first.destroy! }

    assert_equal [[KIDS, 0], [PARENTS, 0]], plain
    assert_equal [[KIDS, 0]], lyra
    assert_equal 0, XrecParent.find(@parents[0].id).kids_count
  end

  private

  # Runs +block+ (given the seeded parents and kids) in a transaction, with
  # plain Active Record and then in ES-NoProj, on fresh rows each time.
  # Returns the rows plain Active Record writes and the records whose
  # aggregate locks ES-NoProj takes, in order, as [table, index among the
  # seeded rows], first occurrences only.
  def both(plain: true, statements: nil, &block)
    results = [plain ? record(false, &block) : nil, record(true, statements: statements, &block)]
    results.map { _1&.uniq }
  end

  def record(lyra, statements: nil, &block)
    define_models(lyra)
    clean
    seed
    seq = []
    sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      sql = payload[:sql].to_s
      statements << sql if statements && sql.include?("lyra_aggregate/")
      lyra ? seq.concat(aggregate_streams(sql, payload)) : seq.concat(row_writes(sql, payload))
    end
    ActiveRecord::Base.transaction { block.call(@parents, @kids) }
    seq.filter_map { index_of(*_1) }
  ensure
    ActiveSupport::Notifications.unsubscribe(sub) if sub
  end

  def aggregate_streams(sql, payload)
    keys = sql.scan(/'lyra_aggregate\/([^']*)'/).flatten
    keys += Array(payload[:binds]).map { _1.respond_to?(:value) ? _1.value.to_s : _1.to_s }
                                  .select { _1.start_with?("lyra_aggregate/") }.map { _1.delete_prefix("lyra_aggregate/") }
    keys.map { |s| [s.start_with?("XrecKid$") ? KIDS : PARENTS, Integer(s.split("$").last)] }
  end

  def row_writes(sql, payload)
    return [] unless (m = sql.match(/\A\s*(?:INSERT INTO|UPDATE|DELETE FROM)\s+"?(#{PARENTS}|#{KIDS})"?/o))

    table = m[1]
    return [[table, :inserted]] if sql.lstrip.start_with?("INSERT")

    Array(payload[:type_casted_binds]).select { _1.is_a?(Integer) }.last(1).map { [table, _1] }
  end

  def index_of(table, id)
    return nil if id == :inserted

    list = table == PARENTS ? @parents : @kids
    i = list.index { _1.id == id }
    i && [table, i]
  end

  def net_order(program, records)
    net = NET.new(NET::Config.new(name: "trace", records: records.size, programs: [], read: :own))
    net.aggregate_lock_order(program).map { records[_1] }
  end

  def stream(table, index) = Lyra.stream_name(table == PARENTS ? XrecParent : XrecKid, (table == PARENTS ? @parents : @kids)[index].id)

  def define_models(lyra)
    %i[XrecParent XrecKid].each { Object.send(:remove_const, _1) if Object.const_defined?(_1) }
    Object.const_set(:XrecParent, Class.new(ActiveRecord::Base) do
      self.table_name = PARENTS
      has_many :xrec_kids, class_name: "XrecKid", foreign_key: :xrec_parent_id, dependent: :destroy
    end)
    Object.const_set(:XrecKid, Class.new(ActiveRecord::Base) do
      self.table_name = KIDS
      belongs_to :xrec_parent, class_name: "XrecParent", touch: true, counter_cache: :kids_count
    end)
    return unless lyra

    [XrecParent, XrecKid].each do |model|
      model.include Lyra::Interceptors::CrudInterceptor
      model.monitor_with_lyra
    end
    Lyra.config.enable_event_sourcing!
    Lyra.config.projection_mode = :disabled
    [XrecParent, XrecKid].each { Lyra.config.monitor_model(_1) }
  end

  def seed
    @parents = Array.new(3) { |i| XrecParent.create!(n: i) }
    @kids = Array.new(2) { XrecKid.create!(xrec_parent: @parents[0]) }
  end

  def clean
    connection.execute("DELETE FROM event_store_events_in_streams")
    connection.execute("DELETE FROM event_store_events")
    connection.execute("DELETE FROM #{Lyra::StreamHeads::TABLE}") if connection.table_exists?(Lyra::StreamHeads::TABLE)
    [KIDS, PARENTS].each { connection.execute("DELETE FROM #{_1}") if connection.table_exists?(_1) }
  end

  def connection = ActiveRecord::Base.connection
end
