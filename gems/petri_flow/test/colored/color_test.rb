# frozen_string_literal: true

require "test_helper"

module PetriFlow
  module Colored
    class ColorTest < Minitest::Test
      # ===========================================
      # Initialization Tests
      # ===========================================

      def test_initialization_with_name
        color = Color.new(name: :user_data)

        assert_equal :user_data, color.name
        assert_empty color.attributes
        assert_nil color.validator
      end

      def test_initialization_with_attributes
        color = Color.new(
          name: :user,
          attributes: { email: :string, age: :integer }
        )

        assert_equal({ email: :string, age: :integer }, color.attributes)
      end

      def test_initialization_with_validator
        validator = ->(data) { data[:email]&.include?("@") }
        color = Color.new(name: :email_data, validator: validator)

        refute_nil color.validator
      end

      # ===========================================
      # Validation Tests
      # ===========================================

      def test_valid_returns_true_without_validator
        color = Color.new(name: :any_data)

        assert color.valid?({ anything: "goes" })
        assert color.valid?({})
        assert color.valid?(nil)
      end

      def test_valid_uses_validator
        color = Color.new(
          name: :positive_number,
          validator: ->(data) { data[:value].is_a?(Numeric) && data[:value] > 0 }
        )

        assert color.valid?({ value: 10 })
        assert color.valid?({ value: 0.5 })
        refute color.valid?({ value: -1 })
        refute color.valid?({ value: "not a number" })
      end

      def test_valid_with_email_validator
        color = Color.new(
          name: :email,
          validator: ->(data) { data[:email].to_s.match?(/@/) }
        )

        assert color.valid?({ email: "test@example.com" })
        refute color.valid?({ email: "invalid" })
      end

      # ===========================================
      # Create Token Tests
      # ===========================================

      def test_create_token
        color = Color.new(name: :order)

        token = color.create_token({ order_id: 123, status: "pending" })

        assert_instance_of Core::Token, token
        assert_equal :order, token.color
        assert_equal 123, token.data[:order_id]
        assert_equal "pending", token.data[:status]
      end

      def test_create_token_with_empty_data
        color = Color.new(name: :simple)

        token = color.create_token

        assert_instance_of Core::Token, token
        assert_empty token.data
      end

      def test_create_token_raises_on_invalid_data
        color = Color.new(
          name: :positive,
          validator: ->(data) { data[:value].to_i > 0 }
        )

        assert_raises(ColorValidationError) do
          color.create_token({ value: -5 })
        end
      end

      # ===========================================
      # String Representation Tests
      # ===========================================

      def test_to_s
        color = Color.new(name: :order_event)

        assert_equal "Color(order_event)", color.to_s
      end

      def test_inspect
        color = Color.new(name: :user, attributes: { email: :string, name: :string })

        output = color.inspect

        assert_includes output, "PetriFlow::Colored::Color"
        assert_includes output, "name=user"
        assert_includes output, "attributes="
      end
    end
  end
end
