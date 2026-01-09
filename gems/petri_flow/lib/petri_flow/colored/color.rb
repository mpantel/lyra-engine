# frozen_string_literal: true

module PetriFlow
  module Colored
    # Represents a color (data type) for tokens in a colored Petri net
    class Color
      attr_reader :name, :attributes, :validator

      def initialize(name:, attributes: {}, validator: nil)
        @name = name
        @attributes = attributes
        @validator = validator
      end

      # Validate data conforms to this color definition
      def valid?(data)
        return true unless @validator

        @validator.call(data)
      end

      # Create a token of this color
      def create_token(data = {})
        raise ColorValidationError, "Invalid data for color #{@name}" unless valid?(data)

        Core::Token.new(color: @name, data: data)
      end

      def to_s
        "Color(#{@name})"
      end

      def inspect
        "#<PetriFlow::Colored::Color name=#{@name} attributes=#{@attributes.keys}>"
      end
    end

    class ColorValidationError < StandardError; end
  end
end
