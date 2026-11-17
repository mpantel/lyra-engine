# frozen_string_literal: true

require "test_helper"

# Conditions, orders and aggregates on typed columns in ES-NoProj (event
# sourcing, projections disabled), where reads are answered from records
# rebuilt from events instead of by SQL. Active Record casts a condition's
# value through the column's type before the database compares it, so
# where(amount: 250.0), where(amount: "250.00") and where(amount: 250) all find
# a decimal 250.00; where(kind: :card) finds "card"; where(active: "t") finds
# true. ES-NoProj compared the Ruby values as given: find_by on a decimal
# column read the event's "250.0" and missed with a Float or a BigDecimal, and
# a Symbol on a string column matched nothing.
#
# Every query below runs on the same rows twice: in Monitor, which reads the
# table (Active Record and PostgreSQL answer), and then, on the events Monitor
# recorded, in ES-NoProj. The two answers must be equal.
class EsNoprojTypedConditionsTest < Minitest::Test
  TABLE = "lyra_tc_items"

  def self.d(year, month, day) = Date.new(year, month, day)
  def self.t(*args) = Time.utc(*args)

  ROWS = [
    { label: "alpha", amount: BigDecimal("250"), ratio: 0.5, qty: 3, due_on: d(2026, 1, 10),
      at: t(2026, 1, 10, 10, 0, 0.123456r), active: true, data: { "a" => 1, "b" => [1, 2] },
      doc: { "k" => "v", "n" => 1 }, kind: "card", tag: "x", status: :draft, prefs: { "lang" => "el", "n" => [1] },
      tz_at: t(2026, 1, 31, 23), starts: "10:00", mood: :happy, email: "x@y.com", secret: "s1", code3: "ab" },
    { label: "Beta", amount: BigDecimal("250.5"), ratio: 1.25, qty: 10, due_on: d(2026, 2, 1),
      at: t(2026, 2, 1, 0, 0, 0), active: false, data: { "a" => 2 }, doc: { "k" => "w" }, code3: "cd ",
      kind: "web", tag: nil, status: :paid,
      tz_at: t(2026, 2, 1, 1), starts: "23:30", mood: :sad, email: "q@y.com", secret: "s2" },
    { label: "gamma", amount: BigDecimal("1000"), ratio: 2.0, qty: 0, due_on: d(2026, 1, 31),
      at: t(2026, 1, 31, 23, 59, 59.999999r), active: true, data: nil, doc: { "n" => 1, "k" => "v" },
      kind: "card", tag: "y", status: :paid, tz_at: t(2026, 2, 1), starts: "21:30" },
    { label: "delta" },
    { label: "eps", amount: BigDecimal("0.3"), ratio: 0.3, qty: -1, due_on: d(2025, 12, 31),
      at: t(2025, 12, 31, 22, 30, 0), active: false, kind: "web", tag: "x", status: :draft, prefs: { "lang" => "en" },
      mood: :happy }
  ].freeze

  # The labels of the rows a relation selects, sorted, or, for an ordered
  # relation, in its order.
  def self.labels(relation) = relation.map(&:label).sort
  def self.ordered(relation) = relation.map(&:label)

  Q = ->(*tags, &block) { [block, tags] }

  QUERIES = {
    # decimal(10, 2)
    decimal_integer: Q.call { labels(TcItem.where(amount: 250)) },
    decimal_float: Q.call(:coder) { labels(TcItem.where(amount: 250.0)) },
    decimal_bigdecimal: Q.call { labels(TcItem.where(amount: BigDecimal("250"))) },
    decimal_string: Q.call { labels(TcItem.where(amount: "250.00")) },
    decimal_integer_string: Q.call { labels(TcItem.where(amount: "250")) },
    decimal_beyond_scale: Q.call { labels(TcItem.where(amount: 250.004)) },
    decimal_float_arithmetic: Q.call { labels(TcItem.where(amount: 0.1 + 0.2)) },
    decimal_in: Q.call { labels(TcItem.where(amount: [250, "1000.0", BigDecimal("0.3")])) },
    decimal_in_with_nil: Q.call { labels(TcItem.where(amount: [250.0, nil])) },
    decimal_range: Q.call(:coder) { labels(TcItem.where(amount: 200..300)) },
    decimal_range_of_strings: Q.call { labels(TcItem.where(amount: "250".."250.5")) },
    decimal_exclusive_range: Q.call { labels(TcItem.where(amount: 250...250.5)) },
    decimal_endless_range: Q.call { labels(TcItem.where(amount: 300..)) },
    decimal_beginless_range: Q.call { labels(TcItem.where(amount: ..250.5)) },
    decimal_nil: Q.call { labels(TcItem.where(amount: nil)) },
    decimal_not: Q.call { labels(TcItem.where.not(amount: 250.0)) },
    decimal_not_in: Q.call { labels(TcItem.where.not(amount: [250, "1000"])) },
    decimal_not_in_with_nil: Q.call { labels(TcItem.where.not(amount: [250, nil])) },
    decimal_not_nil: Q.call { labels(TcItem.where.not(amount: nil)) },
    decimal_not_range: Q.call { labels(TcItem.where.not(amount: 200..300)) },
    decimal_fragment_greater: Q.call { labels(TcItem.where("amount > ?", 250)) },
    decimal_fragment_equal_string: Q.call { labels(TcItem.where("amount = ?", "250.00")) },
    decimal_fragment_not_equal: Q.call { labels(TcItem.where("amount <> ?", 250.0)) },
    decimal_find_by_float: Q.call(:coder) { TcItem.find_by(amount: 250.0)&.label },
    decimal_find_by_bigdecimal: Q.call { TcItem.find_by(amount: BigDecimal("250.50"))&.label },
    decimal_find_by_string: Q.call(:coder) { TcItem.find_by(amount: "1000")&.label },
    decimal_find_by_with_others: Q.call { TcItem.find_by(qty: "3", amount: 250.0, kind: :card)&.label },
    decimal_find_by_id_and_amount: Q.call { TcItem.find_by(id: TcItem.find_by(label: "alpha").id, amount: 250.0)&.label },
    decimal_find_by_bang: Q.call { TcItem.find_by!(amount: 250.0).label },
    decimal_exists: Q.call { TcItem.exists?(amount: 250.0) },
    decimal_where_exists: Q.call { TcItem.where(amount: "250.5").exists? },
    decimal_count: Q.call { TcItem.where(amount: 250.0).count },
    decimal_count_column: Q.call { TcItem.count(:amount) },
    decimal_order: Q.call(:coder) { ordered(TcItem.order(:amount)) },
    decimal_order_desc: Q.call { ordered(TcItem.order(amount: :desc)) },
    decimal_pluck: Q.call { TcItem.pluck(:label, :amount).to_h },
    decimal_pick: Q.call { TcItem.where(amount: 250.0).pick(:amount) },
    decimal_sum: Q.call(:coder) { TcItem.sum(:amount) },
    decimal_minimum: Q.call { TcItem.minimum(:amount) },
    decimal_maximum: Q.call { TcItem.maximum(:amount) },
    decimal_where_sum: Q.call { TcItem.where(amount: 200..).sum(:amount) },

    # float
    float_integer: Q.call { labels(TcItem.where(ratio: 2)) },
    float_string: Q.call { labels(TcItem.where(ratio: "0.5")) },
    float_bigdecimal: Q.call { labels(TcItem.where(ratio: BigDecimal("1.25"))) },
    float_arithmetic: Q.call { labels(TcItem.where(ratio: 0.1 + 0.2)) },
    float_in: Q.call { labels(TcItem.where(ratio: ["2", 0.5])) },
    float_range: Q.call { labels(TcItem.where(ratio: 0.5..1.25)) },
    float_range_of_strings: Q.call { labels(TcItem.where(ratio: "0.4".."1.5")) },
    float_find_by: Q.call { TcItem.find_by(ratio: "1.25")&.label },
    float_order: Q.call { ordered(TcItem.order(:ratio)) },
    float_fragment: Q.call { labels(TcItem.where("ratio <= ?", "1.25")) },

    # integer
    integer_string: Q.call { labels(TcItem.where(qty: "3")) },
    integer_float: Q.call { labels(TcItem.where(qty: 3.0)) },
    integer_fractional_float: Q.call { labels(TcItem.where(qty: 3.5)) },
    integer_bigdecimal: Q.call { labels(TcItem.where(qty: BigDecimal("10"))) },
    integer_decimal_string: Q.call { labels(TcItem.where(qty: "3.0")) },
    integer_non_numeric_string: Q.call { labels(TcItem.where(qty: "abc")) },
    integer_empty_string: Q.call { labels(TcItem.where(qty: "")) },
    integer_in: Q.call { labels(TcItem.where(qty: [3, "10", 0.0])) },
    integer_range: Q.call { labels(TcItem.where(qty: 0..3)) },
    integer_range_of_strings: Q.call { labels(TcItem.where(qty: "0".."3")) },
    integer_not: Q.call { labels(TcItem.where.not(qty: "3")) },
    integer_not_non_numeric: Q.call { labels(TcItem.where.not(qty: "abc")) },
    integer_find_by: Q.call { TcItem.find_by(qty: "10")&.label },
    integer_find_by_float: Q.call { TcItem.find_by(qty: 0.0)&.label },
    integer_exists: Q.call { TcItem.exists?(qty: "0") },
    integer_order_desc: Q.call { ordered(TcItem.order(qty: :desc)) },
    integer_fragment: Q.call { labels(TcItem.where("qty >= ?", "3")) },
    integer_sum: Q.call { TcItem.sum(:qty) },

    # date
    date_date: Q.call(:coder) { labels(TcItem.where(due_on: Date.new(2026, 1, 10))) },
    date_string: Q.call { labels(TcItem.where(due_on: "2026-01-10")) },
    date_time: Q.call(:zone) { labels(TcItem.where(due_on: Time.utc(2026, 1, 10, 15))) },
    date_range: Q.call { labels(TcItem.where(due_on: Date.new(2026, 1, 10)..Date.new(2026, 1, 31))) },
    date_range_of_strings: Q.call { labels(TcItem.where(due_on: "2026-01-10".."2026-01-31")) },
    date_range_of_times: Q.call(:zone) { labels(TcItem.where(due_on: Time.utc(2026, 1, 10, 12)..Time.utc(2026, 2, 1, 1))) },
    date_endless_range: Q.call { labels(TcItem.where(due_on: Date.new(2026, 1, 11)..)) },
    date_in: Q.call { labels(TcItem.where(due_on: ["2026-01-10", Date.new(2026, 2, 1)])) },
    date_find_by: Q.call(:coder) { TcItem.find_by(due_on: "2026-01-31")&.label },
    date_order: Q.call { ordered(TcItem.order(:due_on)) },
    date_fragment: Q.call { labels(TcItem.where("due_on < ?", "2026-01-31")) },
    date_minimum: Q.call { TcItem.minimum(:due_on) },

    # datetime
    datetime_time: Q.call(:coder) { labels(TcItem.where(at: Time.utc(2026, 1, 10, 10, 0, 0.123456r))) },
    datetime_time_with_zone: Q.call { labels(TcItem.where(at: Time.utc(2026, 1, 10, 10, 0, 0.123456r).in_time_zone("Athens"))) },
    datetime_beyond_precision: Q.call(:coder) { labels(TcItem.where(at: Time.utc(2026, 1, 10, 10, 0, 0.1234564r))) },
    datetime_string: Q.call(:zone) { labels(TcItem.where(at: "2026-02-01 00:00:00")) },
    datetime_date: Q.call(:zone) { labels(TcItem.where(at: Date.new(2026, 2, 1))) },
    datetime_range_of_dates: Q.call(:zone) { labels(TcItem.where(at: Date.new(2026, 1, 10)..Date.new(2026, 1, 31))) },
    datetime_range: Q.call { labels(TcItem.where(at: Time.utc(2026, 1, 10)..Time.utc(2026, 2, 1))) },
    datetime_exclusive_range: Q.call { labels(TcItem.where(at: Time.utc(2026, 1, 10)...Time.utc(2026, 2, 1))) },
    datetime_range_of_strings: Q.call(:zone) { labels(TcItem.where(at: "2026-01-10".."2026-02-01")) },
    datetime_find_by: Q.call(:coder) { TcItem.find_by(at: Time.utc(2026, 1, 31, 23, 59, 59.999999r))&.label },
    datetime_order_desc: Q.call { ordered(TcItem.order(at: :desc)) },
    datetime_fragment: Q.call(:zone) { labels(TcItem.where("at >= ?", Date.new(2026, 1, 31))) },
    datetime_maximum: Q.call { TcItem.maximum(:at) },
    datetime_pluck: Q.call { TcItem.pluck(:label, :at).to_h },

    # boolean
    boolean_true: Q.call { labels(TcItem.where(active: true)) },
    boolean_t: Q.call { labels(TcItem.where(active: "t")) },
    boolean_true_string: Q.call { labels(TcItem.where(active: "true")) },
    boolean_one: Q.call { labels(TcItem.where(active: 1)) },
    boolean_one_string: Q.call { labels(TcItem.where(active: "1")) },
    boolean_false: Q.call { labels(TcItem.where(active: false)) },
    boolean_f: Q.call { labels(TcItem.where(active: "f")) },
    boolean_zero: Q.call { labels(TcItem.where(active: 0)) },
    boolean_nil: Q.call { labels(TcItem.where(active: nil)) },
    boolean_empty_string: Q.call { labels(TcItem.where(active: "")) },
    boolean_in: Q.call { labels(TcItem.where(active: ["f", nil])) },
    boolean_not: Q.call { labels(TcItem.where.not(active: "t")) },
    boolean_find_by: Q.call { TcItem.find_by(active: "0", qty: "10")&.label },
    boolean_order: Q.call { ordered(TcItem.order(:active, :qty)) },
    boolean_fragment: Q.call { labels(TcItem.where("active = ?", "t")) },

    # string
    string_symbol: Q.call { labels(TcItem.where(kind: :card)) },
    string_symbols_in: Q.call { labels(TcItem.where(kind: [:web, "nope"])) },
    string_find_by_symbol: Q.call { TcItem.find_by(kind: :web, tag: "x")&.label },
    string_where_symbols_last: Q.call { TcItem.where(kind: :card, tag: :y).last&.label },
    string_integer: Q.call { labels(TcItem.where(label: 5)) },
    string_nil: Q.call { labels(TcItem.where(tag: nil)) },
    string_not: Q.call { labels(TcItem.where.not(tag: "x")) },
    string_not_nil: Q.call { labels(TcItem.where.not(tag: nil)) },
    string_not_in_with_nil: Q.call { labels(TcItem.where.not(tag: ["x", nil])) },
    string_exists_symbol: Q.call { TcItem.exists?(kind: :web) },
    string_count_symbol: Q.call { TcItem.where(kind: :card).count },

    # enum (integer column)
    enum_symbol: Q.call { labels(TcItem.where(status: :paid)) },
    enum_string: Q.call { labels(TcItem.where(status: "draft")) },
    enum_integer: Q.call { labels(TcItem.where(status: 0)) },
    enum_in: Q.call { labels(TcItem.where(status: [:draft, nil])) },
    enum_not: Q.call { labels(TcItem.where.not(status: :paid)) },
    enum_scope: Q.call { labels(TcItem.paid) },
    enum_find_by: Q.call { TcItem.find_by(status: "draft", qty: 3)&.label },
    enum_order: Q.call { ordered(TcItem.order(:status, :qty)) },
    enum_pluck: Q.call { TcItem.pluck(:label, :status).to_h },

    # json, jsonb
    json_read: Q.call(:coder) { TcItem.all.to_h { [_1.label, _1.data] } },
    jsonb_read: Q.call(:coder) { TcItem.all.to_h { [_1.label, _1.doc] } },
    jsonb_pluck: Q.call { TcItem.pluck(:label, :doc).to_h },
    json_nil: Q.call { labels(TcItem.where(data: nil)) },

    # serialized (coder: JSON on a text column)
    serialized_read: Q.call(:coder) { TcItem.all.to_h { [_1.label, _1.prefs] } },
    serialized_pluck: Q.call { TcItem.pluck(:label, :prefs).to_h },
    serialized_find_by: Q.call(:coder) { TcItem.find_by(amount: 250.0)&.prefs },

    # a list as Active Record builds it: two or more values are an IN of
    # those the type binds; a value bound as NULL ('abc' on an integer, an
    # unknown enum label, '' on a boolean) is left out of it, so the NOT IN
    # keeps the other rows. One value alone is an equality.
    list_not_in_unbindable: Q.call { labels(TcItem.where.not(qty: [9, "abc"])) },
    list_in_unbindable: Q.call { labels(TcItem.where(qty: [3, "abc"])) },
    list_not_in_only_unbindable: Q.call { labels(TcItem.where.not(qty: ["abc", "def"])) },
    list_not_in_unknown_enum_label: Q.call { labels(TcItem.where.not(status: [:paid, "bogus"])) },
    list_not_in_blank_boolean: Q.call { labels(TcItem.where.not(active: [true, ""])) },
    list_single_unbindable: Q.call { labels(TcItem.where.not(qty: ["abc"])) },
    # an integer the enum has no label for is bound as = 5: no row, NULL or not
    enum_unlabelled_integer: Q.call { labels(TcItem.where(status: 5)) },
    enum_unlabelled_integer_string: Q.call { labels(TcItem.where(status: "5")) },
    enum_unlabelled_integer_list: Q.call { labels(TcItem.where(status: [5])) },
    enum_unlabelled_find_by: Q.call { TcItem.find_by(status: 5)&.label },
    enum_not_unlabelled_integers: Q.call { labels(TcItem.where.not(status: [5, 7])) },
    enum_not_unlabelled_and_label: Q.call { labels(TcItem.where.not(status: [5, :paid])) },
    enum_unlabelled_or_nil: Q.call { labels(TcItem.where(status: [5, 7, nil])) },
    # an enum's unknown label is bound as IS NULL
    enum_unknown_label: Q.call { labels(TcItem.where(status: "bogus")) },
    enum_not_unknown_label: Q.call { labels(TcItem.where.not(status: "bogus")) },

    # character(3): trailing spaces are not part of the value
    blank_padded_equal: Q.call { labels(TcItem.where(code3: "ab ")) },
    blank_padded_unpadded: Q.call { labels(TcItem.where(code3: "cd")) },
    blank_padded_in: Q.call { labels(TcItem.where(code3: ["ab  ", "cd"])) },
    blank_padded_not: Q.call { labels(TcItem.where.not(code3: "ab")) },
    blank_padded_leading_space: Q.call { labels(TcItem.where(code3: " ab")) },

    # a serialized attribute compares as the text it is stored as
    serialized_same_text: Q.call { labels(TcItem.where(prefs: { "lang" => "el", "n" => [1] })) },
    serialized_other_key_order: Q.call { labels(TcItem.where(prefs: { "n" => [1], "lang" => "el" })) },
    serialized_in: Q.call { labels(TcItem.where(prefs: [{ "lang" => "el", "n" => [1] }, { "lang" => "en" }])) },

    # an attribute alias
    alias_float: Q.call { labels(TcItem.where(price: 250.0)) },
    alias_find_by: Q.call { TcItem.find_by(price: "1000")&.label },
    alias_order: Q.call { ordered(TcItem.order(:price)) },

    # values out of an integer column's range
    integer_out_of_range: Q.call { labels(TcItem.where(qty: 2**40)) },
    integer_range_to_out_of_range: Q.call { labels(TcItem.where(qty: 0..2**40)) },
    integer_range_from_out_of_range: Q.call { labels(TcItem.where(qty: 2**40..)) },
    integer_range_from_below_range: Q.call { labels(TcItem.where(qty: -2**40..3)) },
    integer_infinite_range: Q.call { labels(TcItem.where(qty: 3..Float::INFINITY)) },

    # several columns
    mixed_conditions: Q.call { labels(TcItem.where(amount: "250.00".."1000", active: "t", kind: :card)) },
    mixed_not: Q.call { labels(TcItem.where.not(kind: :card, active: false)) },
    mixed_or: Q.call { labels(TcItem.where(amount: 250.0).or(TcItem.where(qty: "10"))) },

    # an enum given its integer as a String or a Float: compared in the column's domain
    enum_integer_string: Q.call { labels(TcItem.where(status: "0")) },
    enum_integer_string_find_by: Q.call { TcItem.find_by(status: "1")&.label },
    enum_integer_string_exists: Q.call { TcItem.exists?(status: "0") },
    enum_integer_float: Q.call { labels(TcItem.where(status: 1.0)) },
    enum_integer_strings_in: Q.call { labels(TcItem.where(status: ["1", nil])) },

    # a string-backed enum
    string_enum_value: Q.call { labels(TcItem.where(mood: "h")) },
    string_enum_label: Q.call { labels(TcItem.where(mood: :sad)) },
    string_enum_label_string: Q.call { TcItem.find_by(mood: "happy", qty: -1)&.label },
    string_enum_scope: Q.call { labels(TcItem.mood_happy) },
    string_enum_order: Q.call { ordered(TcItem.where.not(mood: nil).order(:mood, :qty)) },
    string_enum_pluck: Q.call { TcItem.pluck(:label, :mood).to_h },

    # timestamptz: time-zone-aware; a string or a date is read in the database's clock
    timestamptz_string: Q.call(:zone) { labels(TcItem.where(tz_at: "2026-02-01 01:00:00")) },
    timestamptz_date: Q.call(:zone) { labels(TcItem.where(tz_at: Date.new(2026, 2, 1))) },
    timestamptz_time: Q.call(:coder) { labels(TcItem.where(tz_at: Time.utc(2026, 1, 31, 23))) },
    timestamptz_range_of_strings: Q.call(:zone) { labels(TcItem.where(tz_at: "2026-02-01 00:00:00".."2026-02-02")) },
    timestamptz_range_of_dates: Q.call(:zone) { labels(TcItem.where(tz_at: Date.new(2026, 2, 1)..Date.new(2026, 2, 2))) },
    timestamptz_find_by_string: Q.call(:zone) { TcItem.find_by(tz_at: "2026-02-01 00:00:00")&.label },
    timestamptz_order: Q.call { ordered(TcItem.where.not(tz_at: nil).order(:tz_at)) },
    timestamptz_fragment_date: Q.call(:zone) { labels(TcItem.where("tz_at >= ?", Date.new(2026, 2, 1))) },
    timestamptz_fragment_string: Q.call(:zone) { labels(TcItem.where("tz_at < ?", "2026-02-01")) },

    # time: time-zone-aware too
    time_string: Q.call(:zone) { labels(TcItem.where(starts: "10:00")) },
    time_find_by: Q.call(:zone, :coder) { TcItem.find_by(starts: "23:30")&.label },
    time_range_of_strings: Q.call(:zone) { labels(TcItem.where(starts: "09:00".."22:00")) },
    time_order: Q.call(:zone) { ordered(TcItem.where.not(starts: nil).order(:starts)) },
    time_pluck: Q.call { TcItem.pluck(:label, :starts).to_h },

    # SQL fragments: the value is quoted, not cast through the attribute's
    # type. A datetime reads a string or a date in the database's clock (as
    # the testbed's refund list filters requested_at by a date), a number is
    # not rounded to the column's scale or to an integer, and a string the
    # column cannot read is an error.
    datetime_fragment_date_from: Q.call(:zone) { labels(TcItem.where("at >= ?", Date.new(2026, 1, 31))) },
    datetime_fragment_date_until: Q.call(:zone) { labels(TcItem.where("at < ?", Date.new(2026, 2, 1))) },
    datetime_fragment_string_from: Q.call(:zone) { labels(TcItem.where("at >= ?", "2026-02-01")) },
    decimal_fragment_beyond_scale: Q.call { labels(TcItem.where("amount = ?", 250.004)) },
    decimal_fragment_below_beyond_scale: Q.call { labels(TcItem.where("amount < ?", 250.005)) },
    integer_fragment_fraction: Q.call { labels(TcItem.where("qty >= ?", 2.5)) },
    integer_fragment_fraction_string: Q.call { labels(TcItem.where("qty >= ?", "2.5")) },
    integer_fragment_non_numeric: Q.call { labels(TcItem.where("qty = ?", "abc")) },

    # encrypted deterministically, downcased: compared as its ciphertext is
    encrypted_exact: Q.call { labels(TcItem.where(email: "x@y.com")) },
    encrypted_other_case: Q.call { labels(TcItem.where(email: "X@Y.COM")) },
    encrypted_find_by: Q.call { TcItem.find_by(email: "Q@Y.com")&.label },
    encrypted_in_with_nil: Q.call { labels(TcItem.where(email: ["Q@Y.COM", nil])) },
    encrypted_read: Q.call { TcItem.all.to_h { [_1.label, _1.email] } },

    # encrypted non-deterministically: no bound value equals a ciphertext
    nondeterministic_equal: Q.call { labels(TcItem.where(secret: "s1")) },
    nondeterministic_find_by: Q.call { TcItem.find_by(secret: "s2")&.label },
    nondeterministic_nil: Q.call { labels(TcItem.where(secret: nil)) },
    nondeterministic_not: Q.call { labels(TcItem.where.not(secret: "s1")) },
    nondeterministic_read: Q.call { TcItem.all.to_h { [_1.label, _1.secret] } }
  }.freeze

  # The table's answer (Monitor) is the reference, in three settings: the
  # time zone, the event store's serializer (Lyra::EventSerializer, JSON as
  # applications use it: a decimal stored as "250.0", a time as an ISO 8601
  # string; or YAML, Ruby objects kept, as this suite's default store has
  # them), and the queries run in each. Every query runs in UTC with JSON;
  # those tagged :zone (a date, time or datetime given in a form Time.zone
  # could change) in Time.zone "Athens" too; those tagged :coder (an
  # attribute whose event value the serializer changes) with YAML too.
  SETTINGS = {
    monitor: ["UTC", :json, nil],
    monitor_athens: ["Athens", :json, :zone],
    monitor_yaml: ["UTC", :yaml, :coder]
  }.freeze

  def setup
    skip "Requires Rails and PostgreSQL" unless defined?(ActiveRecord::Base) && connection.adapter_name.match?(/postgres/i)

    ActiveRecord::Encryption.configure(primary_key: "p" * 32, deterministic_key: "d" * 32, key_derivation_salt: "s" * 32)
    connection.create_table(TABLE, force: true) do |t|
      t.string :label
      t.decimal :amount, precision: 10, scale: 2
      t.float :ratio
      t.integer :qty
      t.date :due_on
      t.datetime :at
      t.boolean :active
      t.json :data
      t.jsonb :doc
      t.string :kind
      t.string :tag
      t.integer :status
      t.text :prefs
      t.timestamptz :tz_at
      t.time :starts
      t.string :mood
      t.text :email
      t.text :secret
      t.column :code3, "char(3)"
      t.timestamps
    end
    Object.send(:remove_const, :TcItem) if Object.const_defined?(:TcItem)
    klass = Class.new(ActiveRecord::Base) do
      self.table_name = TABLE
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
      # Mapped so that the labels' order differs from the integers'.
      enum :status, { paid: 0, draft: 1 }
      serialize :prefs, coder: JSON
      alias_attribute :price, :amount
      enum :mood, { happy: "h", sad: "s" }, prefix: true
      encrypts :email, deterministic: true, downcase: true
      encrypts :secret
    end
    Object.const_set(:TcItem, klass)
    klass.reset_column_information
    clean
    Rails.cache.clear
    Lyra.config.monitor_model(klass)
  end

  def teardown
    return unless Object.const_defined?(:TcItem)

    Lyra.config.enable_monitor!
    Lyra.config.projection_mode = :sync
    clean
    Rails.cache.clear
    connection.drop_table(TABLE, if_exists: true)
  end

  SETTINGS.each do |truth, (zone, serializer, tag)|
    QUERIES.each do |name, (query, tags)|
      next if tag && !tags.include?(tag)

      define_method(:"test_#{name}_against_#{truth}") do
        use_serializer(serializer)
        Time.use_zone(zone) do
          seed(:monitor)
          expected = answer(&query)
          use(:es_noproj)
          # A read of the table would show; ES-NoProj reads the events.
          connection.execute("UPDATE #{TABLE} SET label = label || ' (table)'")
          got = answer(&query)
          assert_equal expected, got, "#{name}: ES-NoProj disagrees with #{truth}"
        end
      end
    end
  end

  # The read goes to the event store, not the table, in ES-NoProj.
  def test_es_noproj_reads_the_events
    use_serializer(:json)
    seed(:monitor)
    use(:es_noproj)
    connection.execute("DELETE FROM #{TABLE}")

    assert_equal "alpha", TcItem.find_by(amount: 250.0)&.label
    assert_kind_of Lyra::Projections::CachedRelation, TcItem.where(amount: 250.0)
  end

  private

  def answer(&query)
    self.class.instance_exec(&query)
  rescue ActiveRecord::RecordNotFound => e
    [:raised, e.class.name]
  rescue ActiveRecord::StatementInvalid, Lyra::Projections::UnsupportedQuery
    # The database rejects the query; ES-NoProj refuses it.
    :refused
  end

  def use_serializer(serializer)
    return unless serializer == :json

    Lyra.config.event_store = RailsEventStore::Client.new(
      repository: RubyEventStore::ActiveRecord::EventRepository.new(serializer: Lyra::EventSerializer)
    )
  end

  def seed(mode)
    use(mode)
    ROWS.each { |row| TcItem.create!(row) }
  end

  def use(mode)
    case mode
    when :monitor
      Lyra.config.enable_monitor!
    when :es_noproj
      Lyra.config.enable_event_sourcing!
      Lyra.config.projection_mode = :disabled
    end
  end

  def clean
    connection.execute("DELETE FROM #{TABLE}") if connection.table_exists?(TABLE)
    connection.execute("DELETE FROM event_store_events_in_streams")
    connection.execute("DELETE FROM event_store_events")
  end

  def connection = ActiveRecord::Base.connection
end

# What ES-NoProj refuses rather than answer unlike the table, and STI
# subclasses whose enums and serialized attributes are their own.
class EsNoprojTypedConditionsEdgesTest < Minitest::Test
  TABLE = "lyra_tc_vehicles"
  CODED = "lyra_tc_coded"

  def setup
    skip "Requires Rails and PostgreSQL" unless defined?(ActiveRecord::Base) && connection.adapter_name.match?(/postgres/i)

    ActiveRecord::Encryption.configure(primary_key: "p" * 32, deterministic_key: "d" * 32, key_derivation_salt: "s" * 32)
    connection.create_table(TABLE, force: true) do |t|
      t.string :type
      t.string :label
      t.integer :status
      t.text :prefs
      t.text :secret
      t.timestamps
    end
    connection.create_table(CODED, primary_key: "code", force: true) { |t| t.string :label }
    %i[TcVehicle TcCar TcCoded].each { Object.send(:remove_const, _1) if Object.const_defined?(_1) }
    Object.const_set(:TcVehicle, Class.new(ActiveRecord::Base) do
      self.table_name = TABLE
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
      encrypts :secret
    end)
    Object.const_set(:TcCar, Class.new(TcVehicle) do
      enum :status, { paid: 0, draft: 1 }
      serialize :prefs, coder: JSON
    end)
    Object.const_set(:TcCoded, Class.new(ActiveRecord::Base) do
      self.table_name = CODED
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
    end)
    clean
    Rails.cache.clear
    [TcVehicle, TcCar, TcCoded].each { Lyra.config.monitor_model(_1) }
    Lyra.config.event_store = RailsEventStore::Client.new(
      repository: RubyEventStore::ActiveRecord::EventRepository.new(serializer: Lyra::EventSerializer)
    )
    Lyra.config.enable_monitor!
  end

  def teardown
    return unless Object.const_defined?(:TcVehicle)

    Lyra.config.enable_monitor!
    Lyra.config.projection_mode = :sync
    clean
    Rails.cache.clear
    [TABLE, CODED].each { connection.drop_table(_1, if_exists: true) }
  end

  # An enum or a serialized attribute declared on an STI subclass only: a
  # record read through the base class is built with its subclass's types.
  def test_an_sti_subclass_reads_its_own_enum_and_serialized_attribute
    TcCar.create!(label: "c", status: :draft, prefs: { "a" => 1 })
    TcVehicle.create!(label: "v")
    reads = lambda do
      [TcVehicle.all.map { [_1.class.name, _1.label, _1.attributes["status"], _1.try(:prefs)] }.sort_by { _1[1] },
       TcCar.where(status: :draft).map(&:label), TcCar.where(status: "1").map(&:label),
       TcVehicle.find_by(label: "c")&.status, TcCar.find_by(status: :draft)&.prefs, TcCar.all.map(&:status)]
    end
    expected = reads.call
    es_noproj

    assert_equal expected, reads.call
    assert_equal ["draft", { "a" => 1 }], [expected[3], expected[4]], "precondition: the table's answer"
  end

  # A condition on a column the table does not have is an error there
  # (id, where the primary key is code): refused, not answered empty.
  def test_a_condition_on_a_column_the_table_lacks_is_refused
    TcCoded.create!(label: "a")
    assert_raises(ActiveRecord::StatementInvalid) { TcCoded.where(id: "1").to_a }
    es_noproj

    assert_raises(Lyra::Projections::UnsupportedQuery) { TcCoded.where(id: "1").to_a }
    assert_raises(Lyra::Projections::UnsupportedQuery) { TcCoded.find_by(id: "1") }
    assert_raises(Lyra::Projections::UnsupportedQuery) { TcCoded.order(id: :desc).to_a }
    assert_equal ["a"], TcCoded.where(code: "1").map(&:label)
  end

  # A range or a pattern on a non-deterministically encrypted attribute
  # compares ciphertexts on the table: no answer here, so refused.
  def test_a_range_or_a_pattern_on_a_non_deterministic_ciphertext_is_refused
    TcVehicle.create!(label: "v", secret: "s1")
    es_noproj

    assert_raises(Lyra::Projections::UnsupportedQuery) { TcVehicle.where(secret: "a".."z").to_a }
    assert_raises(Lyra::Projections::UnsupportedQuery) { TcVehicle.where("secret LIKE ?", "s%").to_a }
    assert_raises(Lyra::Projections::UnsupportedQuery) { TcVehicle.where("secret = ?", "s1").to_a }
    # The table orders an encrypted attribute by its ciphertexts.
    assert_raises(Lyra::Projections::UnsupportedQuery) { TcVehicle.order(:secret).to_a }
    assert_equal [], TcVehicle.where(secret: "s1").to_a
    assert_equal ["v"], TcVehicle.where.not(secret: "s1").map(&:label)
  end

  private

  def es_noproj
    Lyra.config.enable_event_sourcing!
    Lyra.config.projection_mode = :disabled
  end

  def clean
    [TABLE, CODED].each { connection.execute("DELETE FROM #{_1}") if connection.table_exists?(_1) }
    connection.execute("DELETE FROM event_store_events_in_streams")
    connection.execute("DELETE FROM event_store_events")
  end

  def connection = ActiveRecord::Base.connection
end
