# frozen_string_literal: true

require "test_helper"

# Rails' uniqueness validation (validates :x, uniqueness: true) under ES-NoProj
# (event sourcing, projections disabled), where a monitored model's table
# stays empty and its records are rebuilt from events. The validator asks the
# table whether another row holds the value (relation.exists?); the table had
# no rows, so every value passed and duplicates were saved. A unique index
# could not catch them either: no row is ever written.
#
# One table of expectations, run in Monitor (the table is the store, Active
# Record and PostgreSQL answer) and in ES-NoProj: the two must agree. The
# expectations are what Rails 8.1 answers: the check reads through
# Model.unscoped (a default scope is not applied), from the first non-abstract
# class up to the one that declared the validation (under STI, the declaring
# class's type condition), and on update leaves the record itself out by the
# primary key it has in the database.
#
# The tables have no unique index, so that Monitor answers by the validation
# alone. The race between two writers of one value is tested at the end.
class EsNoprojUniquenessTest < Minitest::Test
  MODELS = %i[UqTenant UqItem UqSoft UqAnimal UqDog UqCat UqCoded UqRaced UqFolded].freeze
  TABLES = %i[lyra_uq_tenants lyra_uq_items lyra_uq_softs lyra_uq_animals lyra_uq_codeds lyra_uq_raced lyra_uq_folded].freeze

  Seed = Struct.new(:tenant_a, :tenant_b, :alpha, :beta, :blank, :none, :dog, :cat, keyword_init: true)

  # Whether +record+ is invalid with +attribute+ taken, with the uniqueness
  # validations of +kind+ (UqItem) switched on.
  def taken?(record, attribute, kind = nil)
    with_kind(kind) do
      record.valid?
      record.errors.of_kind?(attribute, :taken)
    end
  end

  def item(kind, attribute = :code, **attributes)
    taken?(UqItem.new(**attributes), attribute, kind)
  end

  def changed(kind, record_id, attribute = :code, **attributes)
    record = UqItem.find(record_id)
    record.assign_attributes(attributes)
    taken?(record, attribute, kind)
  end

  def refused
    yield
    :answered
  rescue Lyra::Projections::UnsupportedQuery
    :refused
  end

  # [what is checked, what Rails 8.1 answers]
  EXPECTATIONS = {
    # validates :code, uniqueness: true
    plain_duplicate: [->(_) { item(:plain, code: "X1") }, true],
    plain_new_value: [->(_) { item(:plain, code: "X9") }, false],
    plain_other_case: [->(_) { item(:plain, code: "x1") }, false],
    plain_nil_taken_by_a_nil: [->(_) { item(:plain, code: nil) }, true],
    plain_blank_taken_by_a_blank: [->(_) { item(:plain, code: "") }, true],
    plain_update_leaves_the_record_out: [->(s) { changed(:plain, s.alpha, name: "Renamed") }, false],
    plain_update_same_value_assigned: [->(s) { changed(:plain, s.alpha, code: "X1", name: "Renamed") }, false],
    plain_update_to_a_taken_value: [->(s) { changed(:plain, s.alpha, code: "X2") }, true],
    plain_update_to_a_free_value: [->(s) { changed(:plain, s.alpha, code: "X7") }, false],
    plain_destroyed_record_frees_its_value: [->(s) { UqItem.find(s.beta).destroy! && item(:plain, code: "X2") }, false],
    plain_updated_record_frees_its_old_value: [->(s) { UqItem.find(s.beta).update!(code: "X5") && [item(:plain, code: "X2"), item(:plain, code: "X5")] },
                                               [false, true]],
    # scope:
    scoped_same_tenant: [->(s) { item(:scoped, code: "X1", tenant_id: s.tenant_a) }, true],
    scoped_other_tenant: [->(s) { item(:scoped, code: "X1", tenant_id: s.tenant_b) }, false],
    scoped_nil_tenant: [->(_) { item(:scoped, code: "X1", tenant_id: nil) }, false],
    scoped_nil_both: [->(_) { item(:scoped, code: nil, tenant_id: nil) }, true],
    scoped_update_moves_tenant: [->(s) { changed(:scoped, s.beta, code: "X1", tenant_id: s.tenant_a) }, true],
    scoped_two_columns_taken: [->(s) { item(:scoped_two, code: "X1", tenant_id: s.tenant_a, archived: false) }, true],
    scoped_two_columns_free: [->(s) { item(:scoped_two, code: "X1", tenant_id: s.tenant_a, archived: true) }, false],
    scoped_by_association_taken: [->(s) { item(:scoped_association, code: "X1", uq_tenant: UqTenant.find(s.tenant_a)) }, true],
    scoped_by_association_free: [->(s) { item(:scoped_association, code: "X1", uq_tenant: UqTenant.find(s.tenant_b)) }, false],
    # case_sensitive:
    case_insensitive_upper: [->(_) { item(:case_insensitive, :name, name: "ALPHA") }, true],
    case_insensitive_lower: [->(_) { item(:case_insensitive, :name, name: "beta") }, true],
    case_insensitive_mixed: [->(_) { item(:case_insensitive, :name, name: "BeTa") }, true],
    case_insensitive_longer: [->(_) { item(:case_insensitive, :name, name: "Alphab") }, false],
    case_insensitive_greek: [->(_) { item(:case_insensitive, :name, name: "ΩΜΈΓΑ") }, true],
    case_insensitive_update_self: [->(s) { changed(:case_insensitive, s.beta, :name, name: "BETA") }, false],
    case_insensitive_update_taken: [->(s) { changed(:case_insensitive, s.beta, :name, name: "alpha") }, true],
    case_insensitive_nil: [->(_) { item(:case_insensitive, :name, name: nil) }, true],
    case_sensitive_other_case: [->(_) { item(:case_sensitive, :name, name: "ALPHA") }, false],
    case_sensitive_same: [->(_) { item(:case_sensitive, :name, name: "Alpha") }, true],
    # conditions:
    conditions_leave_out: [->(_) { item(:conditions, code: "X2") }, false],
    conditions_keep: [->(_) { item(:conditions, code: "X1") }, true],
    conditions_not_leave_out: [->(_) { item(:conditions_not, code: "X2") }, false],
    conditions_not_keep: [->(_) { item(:conditions_not, code: "X1") }, true],
    # where.not(status: :paid) leaves out the rows whose status is NULL.
    conditions_not_null_unknown: [->(_) { item(:conditions_not, code: nil) }, false],
    conditions_with_the_record_taken: [->(s) { item(:conditions_record, code: "X1", tenant_id: s.tenant_a) }, true],
    conditions_with_the_record_free: [->(s) { item(:conditions_record, code: "X1", tenant_id: s.tenant_b) }, false],
    conditions_range_keep: [->(_) { item(:conditions_range, code: "X1") }, true],
    conditions_range_leave_out: [->(_) { item(:conditions_range, code: "X2") }, false],
    conditions_named_scope_keep: [->(_) { item(:conditions_scope, code: "X1") }, true],
    conditions_named_scope_leave_out: [->(_) { item(:conditions_scope, code: "X2") }, false],
    conditions_named_scope_update: [->(s) { changed(:conditions_scope, s.alpha, name: "Renamed") }, false],
    conditions_named_scope_update_taken: [->(s) { changed(:conditions_scope, s.blank, code: "X1") }, true],
    conditions_or_keep: [->(_) { item(:conditions_or, code: "X1") }, true],
    conditions_or_leave_out: [->(_) { item(:conditions_or, code: "X2") }, false],
    # Comparisons in the conditions: X1's amount is 250, X2's 100.5.
    conditions_at_most_leave_out: [->(_) { item(:conditions_at_most, code: "X1") }, false],
    conditions_at_most_keep: [->(_) { item(:conditions_at_most, code: "X2") }, true],
    conditions_below_leave_out_the_bound: [->(_) { item(:conditions_below, code: "X2") }, false],
    conditions_below_keep: [->(_) { item(:conditions_below, code: "X3") }, false],
    conditions_between_keep: [->(_) { [item(:conditions_between, code: "X1"), item(:conditions_between, code: "X2")] }, [true, false]],
    conditions_greater_than: [->(_) { [item(:conditions_greater_than, code: "X1"), item(:conditions_greater_than, code: "X2")] }, [true, false]],
    conditions_not_at_most: [->(_) { [item(:conditions_not_at_most, code: "X1"), item(:conditions_not_at_most, code: "X2")] }, [true, false]],
    # where.not of two conditions is NOT (a AND b).
    conditions_not_both: [->(_) { [item(:conditions_not_both, code: "X1"), item(:conditions_not_both, code: "X2")] }, [true, false]],
    # allow_nil, allow_blank
    allow_nil_skips_nil: [->(_) { item(:allow_nil, code: nil) }, false],
    allow_nil_checks_a_value: [->(_) { item(:allow_nil, code: "X1") }, true],
    allow_blank_skips_blank: [->(_) { item(:allow_blank, code: "") }, false],
    allow_blank_checks_a_value: [->(_) { item(:allow_blank, code: "X2") }, true],
    # A hash condition's list leaves out the values its type binds as NULL
    # (HomogeneousIn): NOT IN (9), not NOT IN (9, NULL), which no row passes.
    conditions_not_in_unbindable: [->(_) { item(:conditions_not_in_unbindable, code: "X1") }, true],
    conditions_not_in_unknown_enum_label: [->(_) { item(:conditions_not_in_unknown_enum_label, code: "X1") }, true],
    conditions_not_in_blank_boolean: [->(_) { item(:conditions_not_in_blank_boolean, code: "X1") }, true],
    # An Arel NOT IN keeps its NULL: unknown for every row.
    conditions_arel_not_in_null: [->(_) { item(:conditions_arel_not_in_null, code: "X1") }, false],
    # An integer the enum has no label for is bound as = 5: no row equals it.
    conditions_arel_in_unlabelled: [->(_) { item(:conditions_arel_in_unlabelled, code: "X1") }, false],
    conditions_arel_not_in_unlabelled: [->(_) { item(:conditions_arel_not_in_unlabelled, code: "X1") }, true],
    conditions_not_in_unlabelled: [->(_) { item(:conditions_not_in_unlabelled, code: "X1") }, true],
    # An Arel literal out of the column's range cannot be quoted: Active
    # Record runs no query and answers that no row exists.
    conditions_arel_literal_out_of_range: [->(_) { item(:conditions_arel_literal_out_of_range, code: "X1") }, false],
    # character(3): 'ab' and 'ab ' are one value; under case_sensitive: false
    # LOWER(column) reads it as text, without the padding, and LOWER(value)
    # keeps the value's.
    blank_padded_taken: [->(_) { item(:tag, :tag, tag: "ab ") }, true],
    blank_padded_same: [->(_) { item(:tag, :tag, tag: "ab") }, true],
    blank_padded_leading_space: [->(_) { item(:tag, :tag, tag: " ab") }, false],
    blank_padded_case_insensitive: [->(_) { item(:tag_ci, :tag, tag: "AB") }, true],
    blank_padded_case_insensitive_padded_value: [->(_) { item(:tag_ci, :tag, tag: "AB ") }, false],
    # A serialized attribute compares as the text it is stored as.
    serialized_same_text: [->(_) { item(:prefs, :prefs, prefs: { "a" => 1, "b" => 2 }) }, true],
    serialized_other_key_order: [->(_) { item(:prefs, :prefs, prefs: { "b" => 2, "a" => 1 }) }, false],
    # typed comparisons: a decimal(10, 2), an enum, a datetime
    decimal_integer: [->(_) { item(:amount, :amount, amount: 250) }, true],
    decimal_string: [->(_) { item(:amount, :amount, amount: "250.00") }, true],
    decimal_float: [->(_) { item(:amount, :amount, amount: 100.5) }, true],
    decimal_rounded_to_scale: [->(_) { item(:amount, :amount, amount: 250.004) }, true],
    decimal_free: [->(_) { item(:amount, :amount, amount: 100.4) }, false],
    enum_label_taken: [->(_) { item(:status, :status, status: :paid) }, true],
    enum_string_taken: [->(_) { item(:status, :status, status: "draft") }, true],
    enum_free: [->(_) { item(:status, :status, status: :void) }, false],
    enum_nil_taken_by_a_nil: [->(_) { item(:status, :status, status: nil) }, true],
    datetime_same_instant: [->(_) { item(:happened_at, :happened_at, happened_at: Time.utc(2026, 2, 1, 10)) }, true],
    datetime_string: [->(_) { item(:happened_at, :happened_at, happened_at: "2026-02-01 10:00:00 UTC") }, true],
    datetime_other_zone: [->(_) { item(:happened_at, :happened_at, happened_at: "2026-02-01 12:00:00 +02:00") }, true],
    datetime_a_second_later: [->(_) { item(:happened_at, :happened_at, happened_at: Time.utc(2026, 2, 1, 10, 0, 1)) }, false],
    # STI: declared on the base class, the check covers every type; declared
    # on a subclass, only that subclass's records.
    sti_base_declared_across_types: [->(_) { taken?(UqCat.new(name: "Rex"), :name) }, true],
    sti_base_declared_free: [->(_) { taken?(UqCat.new(name: "Felix"), :name) }, false],
    sti_subclass_declared_other_type: [->(_) { taken?(UqDog.new(name: "Fido", tag: "t2"), :tag) }, false],
    sti_subclass_declared_same_type: [->(_) { taken?(UqDog.new(name: "Fido", tag: "t1"), :tag) }, true],
    sti_update_leaves_the_record_out: [->(s) { d = UqDog.find(s.dog); d.name = "Rex"; taken?(d, :name) }, false],
    sti_update_to_a_sibling_value: [->(s) { d = UqDog.find(s.dog); d.name = "Tom"; taken?(d, :name) }, true],
    # A soft-delete default scope is not applied (Model.unscoped): a
    # soft-deleted record still holds its value, unless the conditions say so.
    soft_deleted_still_holds_its_value: [->(_) { taken?(UqSoft.new(code: "S1"), :code) }, true],
    soft_live_holds_its_value: [->(_) { taken?(UqSoft.new(code: "S2"), :code) }, true],
    soft_free: [->(_) { taken?(UqSoft.new(code: "S3"), :code) }, false],
    soft_conditions_leave_the_deleted_out: [->(_) { taken?(UqSoft.new(code: "S1"), :code, :live_only) }, false],
    soft_conditions_keep_the_live: [->(_) { taken?(UqSoft.new(code: "S2"), :code, :live_only) }, true],
    # A custom primary key: the update leaves the record out by its code.
    custom_key_taken: [->(_) { taken?(UqCoded.new(code: "C", label: "L1"), :label) }, true],
    custom_key_update_leaves_the_record_out: [->(_) { r = UqCoded.find("A"); r.label = "L1"; r.note = "n"; taken?(r, :label) }, false],
    custom_key_update_taken: [->(_) { r = UqCoded.find("A"); r.label = "L2"; taken?(r, :label) }, true],
    # save refuses the duplicate; create! raises.
    save_refuses: [->(_) { with_kind(:plain) { [UqItem.new(code: "X1").save, UqItem.where(code: "X1").count] } }, [false, 1]],
    create_bang_raises: [->(_) { with_kind(:plain) { UqItem.create!(code: "X2") } rescue :invalid }, :invalid]
  }.freeze

  # Each validation of UqItem, switched on by name for one check.
  KINDS = {
    plain: [:code, { uniqueness: true }],
    scoped: [:code, { uniqueness: { scope: :tenant_id } }],
    scoped_two: [:code, { uniqueness: { scope: %i[tenant_id archived] } }],
    scoped_association: [:code, { uniqueness: { scope: :uq_tenant } }],
    case_insensitive: [:name, { uniqueness: { case_sensitive: false } }],
    case_sensitive: [:name, { uniqueness: { case_sensitive: true } }],
    conditions: [:code, { uniqueness: { conditions: -> { where(archived: false) } } }],
    conditions_not: [:code, { uniqueness: { conditions: -> { where.not(status: :paid) } } }],
    conditions_record: [:code, { uniqueness: { conditions: ->(record) { where(tenant_id: record.tenant_id) } } }],
    conditions_range: [:code, { uniqueness: { conditions: -> { where(happened_at: Time.utc(2026, 1, 1)..) } } }],
    conditions_scope: [:code, { uniqueness: { conditions: -> { live } } }],
    conditions_or: [:code, { uniqueness: { conditions: -> { where(archived: false).or(where(status: :draft)) } } }],
    conditions_sql: [:code, { uniqueness: { conditions: -> { where("archived = ?", false) } } }],
    allow_nil: [:code, { uniqueness: { allow_nil: true } }],
    allow_blank: [:code, { uniqueness: { allow_blank: true } }],
    amount: [:amount, { uniqueness: true }],
    status: [:status, { uniqueness: true }],
    happened_at: [:happened_at, { uniqueness: true }],
    conditions_not_in_unbindable: [:code, { uniqueness: { conditions: -> { where.not(tenant_id: [987_654, "abc"]) } } }],
    conditions_not_in_unknown_enum_label: [:code, { uniqueness: { conditions: -> { where.not(status: [:void, "bogus"]) } } }],
    conditions_not_in_blank_boolean: [:code, { uniqueness: { conditions: -> { where.not(archived: [true, ""]) } } }],
    conditions_arel_not_in_null: [:code, { uniqueness: { conditions: -> { where(arel_table[:tenant_id].not_in([nil])) } } }],
    conditions_arel_in_unlabelled: [:code, { uniqueness: { conditions: -> { where(arel_table[:status].in([5])) } } }],
    conditions_arel_not_in_unlabelled: [:code, { uniqueness: { conditions: -> { where(arel_table[:status].not_in([5])) } } }],
    conditions_not_in_unlabelled: [:code, { uniqueness: { conditions: -> { where.not(status: [5, 7]) } } }],
    conditions_arel_literal_out_of_range: [:code, { uniqueness: { conditions: -> { where(arel_table[:tenant_id].not_in([2**70])) } } }],
    tag: [:tag, { uniqueness: true }],
    tag_ci: [:tag, { uniqueness: { case_sensitive: false } }],
    prefs: [:prefs, { uniqueness: true }],
    conditions_at_most: [:code, { uniqueness: { conditions: -> { where(amount: ..200) } } }],
    conditions_below: [:code, { uniqueness: { conditions: -> { where(amount: ...100.5) } } }],
    conditions_between: [:code, { uniqueness: { conditions: -> { where(amount: 200..300) } } }],
    conditions_greater_than: [:code, { uniqueness: { conditions: -> { where(arel_table[:amount].gt(200)) } } }],
    conditions_not_at_most: [:code, { uniqueness: { conditions: -> { where(arel_table[:amount].lteq(200).not) } } }],
    conditions_not_both: [:code, { uniqueness: { conditions: -> { where.not(archived: true, status: :paid) } } }]
  }.freeze

  def setup
    skip "Requires Rails and PostgreSQL" unless defined?(ActiveRecord::Base) && ActiveRecord::Base.connection.adapter_name.match?(/postgres/i)

    create_tables
    MODELS.reverse_each { |c| Object.send(:remove_const, c) if Object.const_defined?(c) }
    define_models
    clean
    Rails.cache.clear
    MODELS.each { |name| Lyra.config.monitor_model(Object.const_get(name)) }
  end

  def teardown
    return unless defined?(UqItem)

    Thread.current[:uq_kind] = nil
    Lyra.config.enable_monitor!
    Lyra.config.projection_mode = :sync
    clean
    Rails.cache.clear
    drop_tables
  end

  %i[monitor es_noproj].each do |mode|
    EXPECTATIONS.each do |name, (check, expected)|
      define_method(:"test_#{name}_in_#{mode}") do
        s = seed(mode)
        assert_equal expected, instance_exec(s, &check)
      end
    end
  end

  # The check is answered from the events: the table has no row.
  def test_the_table_is_empty_in_es_noproj
    seed(:es_noproj)

    assert_equal 0, Lyra::ModeTransition.send(:bypass) { UqItem.unscoped.count }
    assert item(:plain, code: "X1")
  end

  # An SQL fragment in the conditions is evaluated by the database in
  # Monitor; ES-NoProj cannot evaluate it exactly and refuses the check
  # rather than pass the value (or refuse it) on a guess.
  def test_sql_conditions_in_monitor
    seed(:monitor)

    assert item(:conditions_sql, code: "X1")
    refute item(:conditions_sql, code: "X2")
  end

  def test_sql_conditions_are_refused_in_es_noproj
    seed(:es_noproj)

    assert_equal :refused, refused { item(:conditions_sql, code: "X1") }
  end

  # Other modes keep Active Record's relation: the table answers.
  def test_other_modes_query_the_table
    seed(:monitor)
    queries = []
    callback = ->(*, payload) { queries << payload[:sql] if payload[:name].to_s.end_with?("Exists?") }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { item(:plain, code: "X1") }

    assert_equal 1, queries.size
  end

  # The lock is taken in ES-NoProj, inside a transaction only (valid? alone
  # has none to hold it), and never in the table modes.
  def test_the_lock_is_taken_in_es_noproj_inside_a_transaction_only
    { es_noproj: [1, 0], monitor: [0, 0] }.each do |mode, (inside, outside)|
      clean
      use(mode)
      locks = lambda do |&block|
        statements = []
        callback = ->(*, payload) { statements << payload[:sql] if payload[:sql].include?("pg_advisory_xact_lock(hashtext('lyra_unique/") }
        ActiveSupport::Notifications.subscribed(callback, "sql.active_record", &block)
        statements.size
      end

      assert_equal inside, locks.call { UqItem.transaction { item(:plain, code: "X1") } }, mode
      assert_equal outside, locks.call { item(:plain, code: "X1") }, mode
    end
  end

  # --- two writers of one value -------------------------------------------
  #
  # A uniqueness validation is a check and then a write: two writers can
  # both check before either commits, and both pass. In the table modes a
  # unique index refuses the second INSERT (RecordNotUnique). ES-NoProj
  # writes no row, so there is no index to refuse it: the check takes a
  # transaction-level advisory lock on (model, attribute, value) before it
  # reads, so the second writer's check waits until the first commits, and
  # then finds its record.

  def test_two_writers_of_one_value_with_a_unique_index_in_monitor
    use(:monitor)

    results = race { UqRaced.create!(code: "R1") }

    assert_equal 1, results.count(:saved), results.inspect
    assert_equal 1, results.count { _1.is_a?(ActiveRecord::RecordNotUnique) }, results.inspect
    assert_equal 1, UqRaced.where(code: "R1").count
  end

  # code has a unique index: from 1.0.1 its validation takes no lock, both
  # writers may pass it as in Monitor, and the second is refused at its append
  # by the index check (RecordNotUnique, the table's index's error in Monitor).
  def test_two_writers_of_one_value_in_es_noproj
    use(:es_noproj)

    results = race { UqRaced.create!(code: "R1") }

    assert_equal 1, results.count(:saved), results.inspect
    assert_equal 1, results.count { _1.is_a?(ActiveRecord::RecordNotUnique) }, results.inspect
    assert_equal 1, UqRaced.where(code: "R1").count
  end

  # Two equal values bound differently ("250", 250.00) are one value.
  def test_two_writers_of_one_decimal_value_in_es_noproj
    use(:es_noproj)

    values = [250, "250.00"]
    results = race { |i| UqRaced.create!(code: "R#{i}", amount: values[i]) }

    assert_equal 1, results.count(:saved), results.inspect
    assert_equal 1, UqRaced.where(amount: 250).count
  end

  # Writers of different values do not wait for each other.
  def test_two_writers_of_different_values_in_es_noproj
    use(:es_noproj)

    results = race(timeout: 5) { |i| UqRaced.create!(code: "R#{i}") }

    assert_equal %i[saved saved], results
  end

  # A save that claims no value (a persisted record whose attribute and
  # scope keep their values) takes no lock, though Rails still runs the
  # check (case_sensitive: makes it run on every save): another record's
  # save does not wait for it.
  def test_an_unrelated_update_does_not_wait_in_es_noproj
    use(:es_noproj)
    first = UqRaced.create!(code: "R1", name: "One")
    second = UqRaced.create!(code: "R2", name: "Two")

    waited, = while_held(-> { UqRaced.find(first.id).update!(note: "x") }) { UqRaced.find(second.id).update!(note: "y") }

    assert_operator waited, :<, 1.0
  end

  # Under case_sensitive: false the lock's key is LOWER(value), as the
  # database computes it: a writer of another value does not wait; a writer
  # of the same value in another case waits, then finds it taken.
  def test_case_insensitive_writers_wait_only_for_the_same_value_in_es_noproj
    use(:es_noproj)
    first = UqRaced.create!(code: "R1", name: "One")
    second = UqRaced.create!(code: "R2", name: "Two")
    third = UqRaced.create!(code: "R3", name: "Three")

    waited, = while_held(-> { UqRaced.find(first.id).update!(name: "Renamed") }) { UqRaced.find(second.id).update!(name: "Other") }
    assert_operator waited, :<, 1.0

    waited, result = while_held(-> { UqRaced.find(first.id).update!(name: "Again") }) do
      UqRaced.find(third.id).update!(name: "aGAIN")
    rescue ActiveRecord::RecordInvalid => e
      e
    end
    assert_operator waited, :>=, 1.0
    assert_kind_of ActiveRecord::RecordInvalid, result
  end

  # Two transactions updating records of two models in opposite orders,
  # each validated case-insensitively: unrelated columns, or each its own
  # new value. They complete, as in Monitor; with a lock on the attribute
  # they deadlocked.
  def test_updates_in_opposite_orders_complete_in_es_noproj
    %i[monitor es_noproj].each do |mode|
      [->(i) { { note: "n#{i}" } }, ->(i) { { name: "New #{i}" } }].each do |change|
        clean
        use(mode)
        items = 2.times.map { |i| with_kind(:case_insensitive) { UqItem.create!(code: "I#{i}", name: "Item #{i}") } }
        raced = 2.times.map { |i| UqRaced.create!(code: "R#{i}", name: "Raced #{i}") }
        item_change = ->(i) { change.call(i).key?(:note) ? { archived: true } : { name: "Item new #{i}" } }
        steps = [
          [-> { UqRaced.find(raced[0].id).update!(change.call(0)) }, -> { UqItem.find(items[0].id).update!(item_change.call(0)) }],
          [-> { UqItem.find(items[1].id).update!(item_change.call(1)) }, -> { UqRaced.find(raced[1].id).update!(change.call(1)) }]
        ]

        assert_equal %i[ok ok], opposite_orders(steps), "#{mode} #{change.call(0).keys}"
      end
    end
  end

  # A check reads each record of the shared copy once and answers from what
  # it read: another thread replacing an entry meanwhile (here with its own
  # uncommitted rename of X1) cannot make the check see that thread's
  # uncommitted state. The hook runs between the check's read of the copy
  # and its answer.
  def test_a_check_never_sees_another_threads_uncommitted_record
    %i[monitor es_noproj].each do |mode|
      clean
      use(mode)
      item = UqItem.create!(code: "X1")
      with_kind(:plain) { item(:plain, code: "X1") } # warms the copy
      snapshot = Lyra::Projections::Uniqueness::Snapshot
      hook = Module.new { def prune(copy, versions) = (Thread.current[:uq_snapshot_hook]&.call; super) }
      snapshot.singleton_class.prepend(hook)
      paused = Queue.new
      resume = Queue.new
      renamed = Queue.new
      release = Queue.new
      checker = Thread.new do
        Thread.current[:uq_snapshot_hook] = -> { paused << true; resume.pop(timeout: 5) }
        Thread.current[:uq_kind] = :plain
        item(:plain, code: "X1")
      end
      paused.pop(timeout: 5) if mode == :es_noproj
      renamer = Thread.new do
        Thread.current[:uq_kind] = :plain
        UqItem.transaction do
          UqItem.find(item.id).update!(code: "X7")
          item(:plain, code: "X7")
          renamed << true
          release.pop(timeout: 5)
          raise ActiveRecord::Rollback
        end
      end
      renamed.pop(timeout: 5)
      resume << true
      taken = checker.value
      release << true
      renamer.join

      assert taken, "#{mode}: X1 is taken until the rename commits"
      assert item(:plain, code: "X1"), mode
    ensure
      if hook
        hook.send(:remove_method, :prune)
      end
    end
  end

  # The copy is kept within its byte budget, beside the projection cache's;
  # a model with more streams than LIMIT is read through the projection
  # cache instead; a copy is rebuilt when its model's types change. The copy is
  # what a check reads where no value stream answers it (from 1.0.1: a column
  # without a unique index, or value links off, as here).
  def test_the_copy_is_bounded_and_follows_the_schema
    use(:es_noproj)
    Lyra::Projections::ReferenceLinks.stubs(:values_enabled?).returns(false)
    snapshot = Lyra::Projections::Uniqueness::Snapshot
    snapshot.reset!
    20.times { |i| UqRaced.create!(code: "B#{i}", name: "n#{i}" * 20) }
    10.times { |i| UqSoft.create!(code: "S#{i}") }

    with_constant(snapshot, :BYTES, 4_000) do
      UqRaced.new(code: "new").valid?
      UqSoft.new(code: "new").valid?
      assert_operator snapshot.bytes, :<=, 4_000
    end

    with_constant(snapshot, :LIMIT, 5) do
      Lyra::Projections::CachedProjection.expects(:all).with(UqRaced).returns([]).once
      refute taken?(UqRaced.new(code: "B1"), :code)
    end
    Lyra::Projections::CachedProjection.unstub(:all)

    assert taken?(UqRaced.new(code: "B1"), :code)
    UqRaced.reset_column_information
    copies = snapshot.instance_variable_get(:@copies)
    before = copies[UqRaced]
    assert taken?(UqRaced.new(code: "B2"), :code)
    refute_same before, copies[UqRaced]
  end

  # Under case_sensitive: false, values that differ only in case are one
  # value to the check, and take one lock (LOWER(value)).
  def test_two_writers_of_one_value_in_two_cases_in_es_noproj
    use(:es_noproj)

    names = %w[Same SAME]
    results = race { |i| UqRaced.create!(code: "R#{i}", name: names[i]) }

    assert_equal 1, results.count(:saved), results.inspect
  end

  # A citext column compares without case in the database (=), as LOWER
  # does: so does the check from events.
  def test_citext_column
    begin
      ActiveRecord::Base.connection.enable_extension("citext")
    rescue ActiveRecord::StatementInvalid
      skip "citext is not available"
    end
    ActiveRecord::Base.connection.create_table(:lyra_uq_folded, force: true) { |t| t.column :email, :citext }
    UqFolded.reset_column_information

    %i[monitor es_noproj].each do |mode|
      clean
      use(mode)
      UqFolded.create!(email: "Ann@Example.org")

      assert taken?(UqFolded.new(email: "ann@example.ORG"), :email), mode
      refute taken?(UqFolded.new(email: "bob@example.org"), :email), mode
    end
  end

  private

  # Runs +block+ in two threads, each in its own transaction on its own
  # connection; each waits after its validation until the other has
  # validated too (or +timeout+ passes), so that without a lock both check
  # before either writes. [result of thread 0, result of thread 1]: :saved or
  # the exception.
  def race(timeout: 2, &block)
    validated = Queue.new
    proceed = [Queue.new, Queue.new]
    UqRaced.after_validation_hook = lambda do |index|
      validated << index
      proceed[index].pop(timeout: timeout)
    end
    coordinator = Thread.new do
      2.times { validated.pop(timeout: timeout * 2) }
      proceed.each { _1 << :go }
    end
    threads = 2.times.map do |i|
      Thread.new do
        Thread.current[:uq_race_index] = i
        ActiveRecord::Base.connection_pool.with_connection do
          ActiveRecord::Base.transaction { block.call(i) }
          :saved
        rescue StandardError => e
          e
        end
      end
    end
    results = threads.map(&:value)
    coordinator.kill
    results
  ensure
    UqRaced.after_validation_hook = nil
  end

  # Runs +hold+ in a transaction in a thread, which keeps it open 1.5 s;
  # meanwhile runs the block in a transaction of its own (another thread).
  # [seconds the block took, its value].
  def while_held(hold, &block)
    started = Queue.new
    holder = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        ActiveRecord::Base.transaction do
          hold.call
          started << true
          sleep 1.5
        end
      end
    end
    started.pop(timeout: 5)
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection { ActiveRecord::Base.transaction(&block) }
    end.value
    waited = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
    holder.join
    [waited, result]
  end

  # Two transactions, each running its two steps with a rendezvous between
  # them; :ok or the exception class, per transaction.
  def opposite_orders(steps)
    gates = [Queue.new, Queue.new]
    threads = steps.each_with_index.map do |(first, second), i|
      Thread.new do
        Thread.current[:uq_kind] = :case_insensitive
        ActiveRecord::Base.connection_pool.with_connection do
          ActiveRecord::Base.transaction do
            first.call
            gates[1 - i] << true
            gates[i].pop(timeout: 3)
            second.call
          end
          :ok
        rescue StandardError => e
          e.class
        end
      end
    end
    threads.map(&:value)
  end

  def with_constant(owner, name, value)
    previous = owner.const_get(name)
    owner.send(:remove_const, name)
    owner.const_set(name, value)
    yield
  ensure
    owner.send(:remove_const, name)
    owner.const_set(name, previous)
  end

  def with_kind(kind)
    previous = Thread.current[:uq_kind]
    Thread.current[:uq_kind] = kind
    yield
  ensure
    Thread.current[:uq_kind] = previous
  end

  def seed(mode)
    use(mode)
    a = UqTenant.create!(name: "A")
    b = UqTenant.create!(name: "B")
    alpha = UqItem.create!(code: "X1", name: "Alpha", tenant_id: a.id, archived: false, status: :draft,
                           amount: 250, happened_at: Time.utc(2026, 2, 1, 10), tag: "ab", prefs: { "a" => 1, "b" => 2 })
    beta = UqItem.create!(code: "X2", name: "beta", tenant_id: b.id, archived: true, status: :paid,
                          amount: BigDecimal("100.5"), happened_at: Time.utc(2025, 6, 1))
    none = UqItem.create!(code: nil, name: nil, tenant_id: nil, archived: false, status: nil)
    blank = UqItem.create!(code: "", name: "Ωμέγα", tenant_id: a.id, archived: false, status: :paid)
    dog = UqDog.create!(name: "Rex", tag: "t1")
    cat = UqCat.create!(name: "Tom", tag: "t2")
    UqSoft.create!(code: "S1").update!(deleted_at: Time.current)
    UqSoft.create!(code: "S2")
    UqCoded.create!(code: "A", label: "L1")
    UqCoded.create!(code: "B", label: "L2")
    Seed.new(tenant_a: a.id, tenant_b: b.id, alpha: alpha.id, beta: beta.id, blank: blank.id, none: none.id,
             dog: dog.id, cat: cat.id)
  end

  def use(mode)
    if mode == :es_noproj
      Lyra.config.enable_event_sourcing!
      Lyra.config.projection_mode = :disabled
    else
      Lyra.config.enable_monitor!
      Lyra.config.projection_mode = :sync
    end
  end

  def create_tables
    connection = ActiveRecord::Base.connection
    connection.create_table(:lyra_uq_tenants, force: true) { |t| t.string :name }
    connection.create_table(:lyra_uq_items, force: true) do |t|
      t.string :code
      t.string :name
      t.integer :tenant_id
      t.boolean :archived, default: false
      t.integer :status
      t.decimal :amount, precision: 10, scale: 2
      t.datetime :happened_at
      t.column :tag, "char(3)"
      t.text :prefs
    end
    connection.create_table(:lyra_uq_softs, force: true) do |t|
      t.string :code
      t.datetime :deleted_at
    end
    connection.create_table(:lyra_uq_animals, force: true) do |t|
      t.string :type
      t.string :name
      t.string :tag
    end
    connection.create_table(:lyra_uq_codeds, id: :string, primary_key: "code", force: true) do |t|
      t.string :label
      t.string :note
    end
    connection.create_table(:lyra_uq_raced, force: true) do |t|
      t.string :code
      t.string :name
      t.decimal :amount, precision: 10, scale: 2
      t.string :note
    end
    connection.add_index(:lyra_uq_raced, :code, unique: true)
    connection.create_table(:lyra_uq_folded, force: true) { |t| t.string :email }
  end

  def drop_tables
    TABLES.each { ActiveRecord::Base.connection.drop_table(_1, if_exists: true) }
  end

  def define_models
    monitored = lambda do |table, parent = ActiveRecord::Base, &body|
      Class.new(parent) do
        self.table_name = table.to_s
        include Lyra::Interceptors::CrudInterceptor
        monitor_with_lyra
        class_eval(&body) if body
      end
    end
    Object.const_set(:UqTenant, monitored.call(:lyra_uq_tenants))
    Object.const_set(:UqItem, monitored.call(:lyra_uq_items) do
      enum :status, { draft: 0, paid: 1, void: 2 }
      serialize :prefs, coder: JSON
      belongs_to :uq_tenant, optional: true, foreign_key: :tenant_id
      scope :live, -> { where(archived: false) }
      KINDS.each do |kind, (attribute, options)|
        validates attribute, **options.merge(if: -> { Thread.current[:uq_kind] == kind })
      end
    end)
    Object.const_set(:UqSoft, monitored.call(:lyra_uq_softs) do
      default_scope { where(deleted_at: nil) }
      validates :code, uniqueness: true, unless: -> { Thread.current[:uq_kind] == :live_only }
      validates :code, uniqueness: { conditions: -> { where(deleted_at: nil) } }, if: -> { Thread.current[:uq_kind] == :live_only }
    end)
    Object.const_set(:UqAnimal, monitored.call(:lyra_uq_animals) { validates :name, uniqueness: true })
    Object.const_set(:UqDog, Class.new(UqAnimal) { validates :tag, uniqueness: true })
    Object.const_set(:UqCat, Class.new(UqAnimal))
    Object.const_set(:UqCoded, monitored.call(:lyra_uq_codeds) do
      self.primary_key = "code"
      validates :label, uniqueness: true
    end)
    Object.const_set(:UqRaced, monitored.call(:lyra_uq_raced) do
      class << self
        attr_accessor :after_validation_hook
      end
      validates :code, uniqueness: true
      validates :amount, uniqueness: true, allow_nil: true
      validates :name, uniqueness: { case_sensitive: false }, allow_nil: true
      after_validation { self.class.after_validation_hook&.call(Thread.current[:uq_race_index]) }
    end)
    Object.const_set(:UqFolded, monitored.call(:lyra_uq_folded) { validates :email, uniqueness: true })
  end

  def clean
    conn = ActiveRecord::Base.connection
    TABLES.each { conn.execute("DELETE FROM #{_1}") if conn.table_exists?(_1) }
    conn.execute("DELETE FROM event_store_events_in_streams")
    conn.execute("DELETE FROM event_store_events")
    MODELS.each do |name|
      Lyra::Projections::CachedProjection.invalidate_all(Object.const_get(name)) if Object.const_defined?(name)
    end
  end
end
