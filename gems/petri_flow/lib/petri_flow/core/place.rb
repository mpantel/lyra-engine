# frozen_string_literal: true

module PetriFlow
  module Core
    # Represents a place in a Petri net
    # Places hold tokens and represent states in the system
    class Place
      attr_reader :id, :name, :tokens
      attr_accessor :capacity

      def initialize(id:, name: nil, initial_tokens: 0, capacity: Float::INFINITY)
        @id = id
        @name = name || id.to_s
        @tokens = initial_tokens
        @capacity = capacity
      end

      # Add tokens to this place
      def add_tokens(count = 1)
        raise CapacityError, "Cannot add #{count} tokens: would exceed capacity #{@capacity}" if @tokens + count > @capacity

        @tokens += count
      end

      # Remove tokens from this place
      def remove_tokens(count = 1)
        raise InsufficientTokensError, "Cannot remove #{count} tokens: only #{@tokens} available" if @tokens < count

        @tokens -= count
      end

      # Check if place has at least n tokens
      def has_tokens?(count = 1)
        @tokens >= count
      end

      # Check if place can accept n tokens
      def can_accept?(count = 1)
        @tokens + count <= @capacity
      end

      def to_s
        "Place(#{@name}, tokens: #{@tokens})"
      end

      def inspect
        "#<PetriFlow::Core::Place id=#{@id} name=#{@name} tokens=#{@tokens} capacity=#{@capacity}>"
      end
    end

    class CapacityError < StandardError; end
    class InsufficientTokensError < StandardError; end
  end
end
