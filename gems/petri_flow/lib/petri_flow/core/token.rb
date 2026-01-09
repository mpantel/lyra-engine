# frozen_string_literal: true

module PetriFlow
  module Core
    # Represents a token in a colored Petri net
    # Basic Petri nets just count tokens, colored nets attach data to tokens
    class Token
      attr_reader :id, :color, :data, :timestamp

      def initialize(id: SecureRandom.uuid, color: :default, data: {}, timestamp: Time.current)
        @id = id
        @color = color
        @data = data
        @timestamp = timestamp
      end

      # Create a copy of this token with updated data
      def with_data(new_data)
        self.class.new(
          id: SecureRandom.uuid,
          color: @color,
          data: @data.merge(new_data),
          timestamp: Time.current
        )
      end

      # Create a copy of this token with a different color
      def with_color(new_color)
        self.class.new(
          id: SecureRandom.uuid,
          color: new_color,
          data: @data,
          timestamp: Time.current
        )
      end

      def to_h
        {
          id: @id,
          color: @color,
          data: @data,
          timestamp: @timestamp
        }
      end

      def to_s
        "Token(#{@color}, #{@data})"
      end

      def inspect
        "#<PetriFlow::Core::Token id=#{@id} color=#{@color} data=#{@data}>"
      end
    end
  end
end
