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
    assert_raises(UnsupportedQuery) { @relation.where("name = ?", "Bob") }
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
    assert_raises(UnsupportedQuery) { @relation.newest_first }
  end

  def test_a_scope_that_fails_raises_instead_of_returning_everything
    error = assert_raises(UnsupportedQuery) { @relation.failing }
    assert_equal "scope failed", error.cause&.message
  end

  def test_a_class_method_that_is_not_a_scope_raises
    assert_raises(UnsupportedQuery) { @relation.revenue_total }
  end

  def test_the_error_says_what_to_do_instead
    error = assert_raises(UnsupportedQuery) { @relation.where("name = ?", "Bob") }
    assert_match(/FailClosedUser/, error.message)
    assert_match(/projection_mode :lazy/, error.message)
  end
end
