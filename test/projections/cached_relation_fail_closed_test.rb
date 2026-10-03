# frozen_string_literal: true

require "test_helper"

# ES-NoProj answers reads from the event store through CachedRelation, which
# evaluates queries in Ruby. It used to fall back to an unfiltered or partly
# filtered answer whenever it met a query it could not evaluate: a SQL-string
# where kept every record, an unrecognised condition was dropped, a join was
# ignored, a scope that failed or returned no conditions gave the whole set.
# Wrong records are worse than an error, so it must now answer exactly or
# raise UnsupportedQuery.
class CachedRelationFailClosedTest < Minitest::Test
  UnsupportedQuery = Lyra::Projections::UnsupportedQuery

  def setup
    skip "Requires ActiveRecord with a database" unless defined?(ActiveRecord::Base) && ActiveRecord::Base.connection.table_exists?(:users)

    Object.send(:remove_const, :FailClosedUser) if defined?(FailClosedUser)
    Object.const_set(:FailClosedUser, Class.new(ActiveRecord::Base) do
      self.table_name = "users"
      scope :named, ->(name) { where(name: name) }
      scope :named_any, ->(names) { where(name: names) }
      scope :not_named, ->(name) { where.not(name: name) }
      scope :named_sql, ->(name) { where("name = ?", name) }
      scope :newest_first, -> { order(created_at: :desc) }
      scope :top_named, ->(name) { where(name: name).order(id: :desc).limit(1) }
      scope :grouped, -> { group(:name) }
      scope :failing, -> { raise "scope failed" }
      def self.revenue_total = 42
    end)
    @alice = FailClosedUser.new(id: 1, name: "Alice", email: "a@example.com")
    @bob = FailClosedUser.new(id: 2, name: "Bob", email: "b@example.com")
    @relation = Lyra::Projections::CachedRelation.new(FailClosedUser, [@alice, @bob])
  end

  # -- what it can answer, it answers exactly --------------------------------

  def test_hash_conditions_filter_exactly
    assert_equal [@bob], @relation.where(name: "Bob").to_a
    assert_equal [@alice, @bob], @relation.where(name: %w[Alice Bob]).to_a
  end

  def test_a_scope_of_hash_conditions_is_applied
    assert_equal [@alice], @relation.named("Alice").to_a
    assert_equal [@bob], @relation.named_any(%w[Bob Carol]).to_a
  end

  def test_loading_hints_do_not_change_the_answer
    assert_equal 2, @relation.includes(:anything).preload(:anything).references(:anything).count
  end

  # -- what it cannot answer, it refuses --------------------------------------

  def test_a_sql_string_condition_raises
    assert_raises(UnsupportedQuery) { @relation.where("LOWER(name) = ?", "bob") }
  end

  def test_a_condition_on_an_unknown_attribute_raises
    assert_raises(UnsupportedQuery) { @relation.where(nickname: "Bobby").to_a }
  end

  def test_a_condition_on_an_associated_table_raises
    assert_raises(UnsupportedQuery) { @relation.where(orders: { state: "complete" }) }
  end

  def test_joins_raise
    assert_raises(UnsupportedQuery) { @relation.joins(:orders) }
    assert_raises(UnsupportedQuery) { @relation.left_joins(:orders) }
    assert_raises(UnsupportedQuery) { @relation.left_outer_joins(:orders) }
  end

  def test_a_scope_with_a_condition_it_cannot_read_raises
    assert_raises(UnsupportedQuery) { @relation.not_named("Alice") }
    assert_raises(UnsupportedQuery) { @relation.named_sql("Alice") }
  end

  def test_a_scope_with_clauses_beyond_conditions_raises
    assert_raises(UnsupportedQuery) { @relation.grouped }
  end

  # A scope's order and limit are applied after its conditions, as SQL does.
  def test_a_scope_with_order_and_limit_is_applied
    @alice.created_at = 2.days.ago
    @bob.created_at = 1.day.ago
    assert_equal [@bob, @alice], @relation.newest_first.to_a
    assert_equal [@alice], @relation.top_named("Alice").to_a
  end

  def test_or_of_two_relations_is_their_union
    assert_equal [@alice, @bob], @relation.where(name: "Alice").or(@relation.where(id: 2)).to_a
    assert_equal [@alice], @relation.where(name: "Alice").or(@relation.where(id: 1)).to_a, "each record once"
  end

  # The search-box fragment: col [I]LIKE ? OR ...; SQL patterns, matched exactly.
  def test_a_like_search_fragment_is_evaluated
    assert_equal [@alice], @relation.where("name ILIKE ?", "%LIC%").to_a
    assert_equal [], @relation.where("name LIKE ?", "%LIC%").to_a, "LIKE is case-sensitive"
    assert_equal [@bob], @relation.where("name ILIKE ? OR email ILIKE ?", "zzz", "b@%").to_a
    assert_equal [@bob], @relation.where("name LIKE ?", "B_b").to_a
    assert_equal [], @relation.where("email LIKE ?", "a\\_example%").to_a, "an escaped _ is literal"
  end

  def test_any_other_fragment_is_still_refused
    assert_raises(UnsupportedQuery) { @relation.where("name ILIKE ? AND email ILIKE ? OR id = ?", "a", "b", 1) }
    assert_raises(UnsupportedQuery) { @relation.where("(name ILIKE ?)", "a") }
    assert_raises(UnsupportedQuery) { @relation.where("id::text LIKE ?", "1") }
    assert_raises(UnsupportedQuery) { @relation.where("nickname ILIKE ?", "a") }
  end

  def test_comparison_fragments_are_evaluated_with_sql_null_semantics
    @alice.created_at = 2.days.ago
    @bob.created_at = nil
    assert_equal [@alice], @relation.where("created_at <= ?", Time.current).to_a, "NULL is not <= anything"
    assert_equal [@bob], @relation.where("id > ? AND name <> ?", "1", "Alice").to_a
    assert_equal [], @relation.where("created_at >= ?", Time.current).to_a
  end

  # An ordering it cannot read used to compare as equal: silently unordered.
  def test_orders_are_read_or_refused
    assert_equal [@bob, @alice], @relation.order("name DESC").to_a
    assert_equal [@bob, @alice], @relation.order(FailClosedUser.arel_table[:name].desc).to_a
    assert_raises(UnsupportedQuery) { @relation.order("LOWER(name)") }
  end

  def test_a_scope_that_fails_raises_instead_of_returning_everything
    error = assert_raises(UnsupportedQuery) { @relation.failing }
    assert_equal "scope failed", error.cause&.message
  end

  def test_a_class_method_that_is_not_a_scope_raises
    assert_raises(UnsupportedQuery) { @relation.revenue_total }
  end

  def test_the_error_says_what_to_do_instead
    error = assert_raises(UnsupportedQuery) { @relation.where("LOWER(name) = ?", "bob") }
    assert_match(/FailClosedUser/, error.message)
    assert_match(/projection_mode :lazy/, error.message)
  end
end
