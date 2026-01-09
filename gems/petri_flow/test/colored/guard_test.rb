# frozen_string_literal: true

require "test_helper"

module PetriFlow
  module Colored
    class GuardTest < Minitest::Test
      # ===========================================
      # Initialization Tests
      # ===========================================

      def test_initialization_with_name
        guard = Guard.new(name: "check_status")

        assert_equal "check_status", guard.name
      end

      def test_initialization_with_condition
        guard = Guard.new(name: "positive") { |ctx| ctx[:value] > 0 }

        refute_nil guard.condition
      end

      def test_initialization_anonymous
        guard = Guard.new { |ctx| ctx[:active] }

        assert_nil guard.name
      end

      # ===========================================
      # Satisfied? Tests
      # ===========================================

      def test_satisfied_returns_true_without_condition
        guard = Guard.new(name: "no_condition")

        assert guard.satisfied?({})
        assert guard.satisfied?({ anything: "value" })
      end

      def test_satisfied_evaluates_condition
        guard = Guard.new(name: "check_status") do |context|
          context[:status] == "active"
        end

        assert guard.satisfied?({ status: "active" })
        refute guard.satisfied?({ status: "inactive" })
        refute guard.satisfied?({})
      end

      def test_satisfied_with_complex_context
        guard = Guard.new(name: "check_tokens") do |context|
          context.dig(:tokens, :p1, :data, :amount).to_i >= 100
        end

        assert guard.satisfied?({ tokens: { p1: { data: { amount: 100 } } } })
        assert guard.satisfied?({ tokens: { p1: { data: { amount: 500 } } } })
        refute guard.satisfied?({ tokens: { p1: { data: { amount: 50 } } } })
      end

      # ===========================================
      # AND Combination Tests
      # ===========================================

      def test_and_combines_guards
        guard1 = Guard.new(name: "positive") { |ctx| ctx[:value] > 0 }
        guard2 = Guard.new(name: "even") { |ctx| ctx[:value].even? }

        combined = guard1.and(guard2)

        assert combined.satisfied?({ value: 4 })
        refute combined.satisfied?({ value: 3 })  # odd
        refute combined.satisfied?({ value: -2 }) # negative
      end

      def test_and_name_reflects_combination
        guard1 = Guard.new(name: "A") { true }
        guard2 = Guard.new(name: "B") { true }

        combined = guard1.and(guard2)

        assert_includes combined.name, "AND"
        assert_includes combined.name, "A"
        assert_includes combined.name, "B"
      end

      # ===========================================
      # OR Combination Tests
      # ===========================================

      def test_or_combines_guards
        guard1 = Guard.new(name: "admin") { |ctx| ctx[:role] == "admin" }
        guard2 = Guard.new(name: "owner") { |ctx| ctx[:is_owner] }

        combined = guard1.or(guard2)

        assert combined.satisfied?({ role: "admin", is_owner: false })
        assert combined.satisfied?({ role: "user", is_owner: true })
        assert combined.satisfied?({ role: "admin", is_owner: true })
        refute combined.satisfied?({ role: "user", is_owner: false })
      end

      def test_or_name_reflects_combination
        guard1 = Guard.new(name: "A") { true }
        guard2 = Guard.new(name: "B") { true }

        combined = guard1.or(guard2)

        assert_includes combined.name, "OR"
      end

      # ===========================================
      # NOT Tests
      # ===========================================

      def test_not_negates_guard
        guard = Guard.new(name: "blocked") { |ctx| ctx[:blocked] }

        negated = guard.not

        assert negated.satisfied?({ blocked: false })
        refute negated.satisfied?({ blocked: true })
      end

      def test_not_name_reflects_negation
        guard = Guard.new(name: "active") { true }

        negated = guard.not

        assert_includes negated.name, "NOT"
        assert_includes negated.name, "active"
      end

      # ===========================================
      # Complex Combinations Tests
      # ===========================================

      def test_complex_combination
        admin = Guard.new(name: "admin") { |ctx| ctx[:role] == "admin" }
        active = Guard.new(name: "active") { |ctx| ctx[:status] == "active" }
        banned = Guard.new(name: "banned") { |ctx| ctx[:banned] }

        # (admin OR active) AND NOT banned
        combined = admin.or(active).and(banned.not)

        assert combined.satisfied?({ role: "admin", status: "inactive", banned: false })
        assert combined.satisfied?({ role: "user", status: "active", banned: false })
        refute combined.satisfied?({ role: "admin", status: "active", banned: true })
        refute combined.satisfied?({ role: "user", status: "inactive", banned: false })
      end

      # ===========================================
      # String Representation Tests
      # ===========================================

      def test_to_s
        guard = Guard.new(name: "check_amount")

        assert_equal "Guard(check_amount)", guard.to_s
      end

      def test_to_s_anonymous
        guard = Guard.new { true }

        assert_equal "Guard(anonymous)", guard.to_s
      end

      def test_inspect
        guard = Guard.new(name: "my_guard")

        output = guard.inspect

        assert_includes output, "PetriFlow::Colored::Guard"
        assert_includes output, "name=my_guard"
      end

      # ===========================================
      # Guards Factory Tests
      # ===========================================

      def test_guards_field_equals
        guard = Guards.field_equals(:status, "active")

        assert guard.satisfied?({ token: { data: { status: "active" } } })
        refute guard.satisfied?({ token: { data: { status: "inactive" } } })
      end

      def test_guards_field_matches
        guard = Guards.field_matches(:email, /@example\.com$/)

        assert guard.satisfied?({ token: { data: { email: "test@example.com" } } })
        refute guard.satisfied?({ token: { data: { email: "test@other.com" } } })
      end

      def test_guards_always_true
        guard = Guards.always_true

        assert guard.satisfied?({})
        assert guard.satisfied?({ any: "data" })
      end

      def test_guards_always_false
        guard = Guards.always_false

        refute guard.satisfied?({})
        refute guard.satisfied?({ any: "data" })
      end

      def test_guards_condition
        guard = Guards.condition("custom") { |ctx| ctx[:value] == 42 }

        assert guard.satisfied?({ value: 42 })
        refute guard.satisfied?({ value: 0 })
      end
    end
  end
end
