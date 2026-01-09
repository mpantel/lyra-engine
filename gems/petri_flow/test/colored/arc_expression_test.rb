# frozen_string_literal: true

require "test_helper"

module PetriFlow
  module Colored
    class ArcExpressionTest < Minitest::Test
      # ===========================================
      # Initialization Tests
      # ===========================================

      def test_initialization_with_name
        expr = ArcExpression.new(name: "transform")

        assert_equal "transform", expr.name
      end

      def test_initialization_with_transformation
        expr = ArcExpression.new(name: "double") { |data, _| data.transform_values { |v| v * 2 } }

        refute_nil expr.transformation
      end

      def test_initialization_anonymous
        expr = ArcExpression.new { |data, _| data }

        assert_nil expr.name
      end

      # ===========================================
      # Execute Tests
      # ===========================================

      def test_execute_returns_data_without_transformation
        expr = ArcExpression.new(name: "passthrough")

        result = expr.execute({ key: "value" })

        assert_equal({ key: "value" }, result)
      end

      def test_execute_applies_transformation
        expr = ArcExpression.new(name: "uppercase") do |data, _|
          data.transform_values { |v| v.to_s.upcase }
        end

        result = expr.execute({ name: "john", city: "paris" })

        assert_equal({ name: "JOHN", city: "PARIS" }, result)
      end

      def test_execute_receives_context
        expr = ArcExpression.new(name: "add_user") do |data, context|
          data.merge(user_id: context[:user_id])
        end

        result = expr.execute({ order: 123 }, { user_id: 456 })

        assert_equal 456, result[:user_id]
        assert_equal 123, result[:order]
      end

      def test_execute_with_empty_data
        expr = ArcExpression.new(name: "add_timestamp") do |data, _|
          data.merge(created_at: "2024-01-01")
        end

        result = expr.execute({})

        assert_equal "2024-01-01", result[:created_at]
      end

      # ===========================================
      # Then (Composition) Tests
      # ===========================================

      def test_then_chains_expressions
        add_one = ArcExpression.new(name: "add_one") do |data, _|
          { value: data[:value] + 1 }
        end

        double = ArcExpression.new(name: "double") do |data, _|
          { value: data[:value] * 2 }
        end

        combined = add_one.then(double)

        # (5 + 1) * 2 = 12
        result = combined.execute({ value: 5 })
        assert_equal 12, result[:value]
      end

      def test_then_combines_names
        expr1 = ArcExpression.new(name: "A") { |d, _| d }
        expr2 = ArcExpression.new(name: "B") { |d, _| d }

        combined = expr1.then(expr2)

        assert_includes combined.name, "then"
        assert_includes combined.name, "A"
        assert_includes combined.name, "B"
      end

      def test_then_multiple_chains
        add = ArcExpression.new(name: "add") { |d, _| { v: d[:v] + 1 } }
        mult = ArcExpression.new(name: "mult") { |d, _| { v: d[:v] * 2 } }
        sub = ArcExpression.new(name: "sub") { |d, _| { v: d[:v] - 3 } }

        # ((1 + 1) * 2) - 3 = 1
        combined = add.then(mult).then(sub)
        result = combined.execute({ v: 1 })

        assert_equal 1, result[:v]
      end

      # ===========================================
      # String Representation Tests
      # ===========================================

      def test_to_s
        expr = ArcExpression.new(name: "transform_data")

        assert_equal "ArcExpression(transform_data)", expr.to_s
      end

      def test_to_s_anonymous
        expr = ArcExpression.new { |d, _| d }

        assert_equal "ArcExpression(anonymous)", expr.to_s
      end

      def test_inspect
        expr = ArcExpression.new(name: "my_expr")

        output = expr.inspect

        assert_includes output, "PetriFlow::Colored::ArcExpression"
        assert_includes output, "name=my_expr"
      end

      # ===========================================
      # ArcExpressions Factory Tests
      # ===========================================

      def test_arc_expressions_identity
        expr = ArcExpressions.identity

        data = { a: 1, b: 2 }
        result = expr.execute(data)

        assert_equal data, result
      end

      def test_arc_expressions_map_fields
        expr = ArcExpressions.map_fields(old_name: :new_name, email: :user_email)

        result = expr.execute({ old_name: "John", email: "j@test.com", other: "value" })

        assert_equal "John", result[:new_name]
        assert_equal "j@test.com", result[:user_email]
        assert_equal "value", result[:other]
        refute result.key?(:old_name)
        refute result.key?(:email)
      end

      def test_arc_expressions_add_metadata
        expr = ArcExpressions.add_metadata({ source: "api", version: "1.0" })

        result = expr.execute({ data: "value" })

        assert_equal({ source: "api", version: "1.0" }, result[:metadata])
        assert_equal "value", result[:data]
      end

      def test_arc_expressions_extract_fields
        expr = ArcExpressions.extract_fields(:name, :email)

        result = expr.execute({ name: "John", email: "j@test.com", password: "secret", age: 30 })

        assert_equal({ name: "John", email: "j@test.com" }, result)
      end

      def test_arc_expressions_merge_context
        expr = ArcExpressions.merge_context(:user_id, :request_id)

        result = expr.execute(
          { data: "value" },
          { user_id: 123, request_id: "abc", other: "ignored" }
        )

        assert_equal 123, result[:user_id]
        assert_equal "abc", result[:request_id]
        assert_equal "value", result[:data]
        refute result.key?(:other)
      end

      def test_arc_expressions_detect_pii
        expr = ArcExpressions.detect_pii

        result = expr.execute({
          email: "test@example.com",
          name: "John",
          phone: "1234567890"
        })

        assert result[:pii_detected][:email]
        assert result[:pii_detected][:phone]
      end
    end
  end
end
