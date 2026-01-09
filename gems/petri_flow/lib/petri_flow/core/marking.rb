# frozen_string_literal: true

module PetriFlow
  module Core
    # Represents a marking (state) of a Petri net
    # A marking is a distribution of tokens across places
    class Marking
      attr_reader :tokens_by_place

      def initialize(tokens_by_place = {})
        @tokens_by_place = tokens_by_place.dup
      end

      # Get token count for a place
      def tokens_at(place)
        place_id = place.is_a?(Place) ? place.id : place
        @tokens_by_place[place_id] || 0
      end

      # Set token count for a place
      def set_tokens(place, count)
        place_id = place.is_a?(Place) ? place.id : place
        @tokens_by_place[place_id] = count
      end

      # Check if this marking is equal to another
      def ==(other)
        return false unless other.is_a?(Marking)

        @tokens_by_place == other.tokens_by_place
      end

      alias_method :eql?, :==

      def hash
        @tokens_by_place.hash
      end

      # Create a copy of this marking
      def dup
        self.class.new(@tokens_by_place)
      end

      # Convert marking to array format for comparison
      def to_a(places)
        places.map { |place| tokens_at(place) }
      end

      # Convert to hash representation
      def to_h
        @tokens_by_place.dup
      end

      def to_s
        place_strings = @tokens_by_place.map { |place_id, count| "#{place_id}:#{count}" }
        "Marking(#{place_strings.join(', ')})"
      end

      def inspect
        "#<PetriFlow::Core::Marking #{to_s}>"
      end
    end
  end
end
