require "test_helper"

module PetriFlow
  module Core
    class NetTest < Minitest::Test
      def setup
        @net = Net.new(name: "test_net")
      end

      def test_net_initialization
        assert_equal "test_net", @net.name
        assert_empty @net.places
        assert_empty @net.transitions
      end

      def test_add_place
        place = @net.add_place(id: "p1", name: "Place 1", initial_tokens: 1)

        assert @net.places.key?("p1")
        assert_equal place, @net.places["p1"]
        assert_equal 1, @net.places.size
      end

      def test_add_transition
        transition = @net.add_transition(id: "t1", name: "Transition 1")

        assert @net.transitions.key?("t1")
        assert_equal transition, @net.transitions["t1"]
        assert_equal 1, @net.transitions.size
      end

      def test_add_arc_connects_place_to_transition
        place = @net.add_place(id: "p1", initial_tokens: 1)
        transition = @net.add_transition(id: "t1")

        arc = @net.add_arc(source_id: "p1", target_id: "t1", weight: 1)

        assert_equal 1, @net.arcs.size
        assert_equal arc, @net.arcs.first
      end

      def test_add_arc_connects_transition_to_place
        place = @net.add_place(id: "p1")
        transition = @net.add_transition(id: "t1")

        arc = @net.add_arc(source_id: "t1", target_id: "p1", weight: 1)

        assert_equal 1, @net.arcs.size
      end

      def test_places_stored_as_hash
        @net.add_place(id: "p1")
        @net.add_place(id: "p2")
        @net.add_place(id: "p3")

        assert_equal 3, @net.places.size
        assert @net.places.is_a?(Hash)
        assert @net.places.key?("p1")
        assert @net.places.key?("p2")
        assert @net.places.key?("p3")
      end

      def test_transitions_stored_as_hash
        @net.add_transition(id: "t1")
        @net.add_transition(id: "t2")

        assert_equal 2, @net.transitions.size
        assert @net.transitions.is_a?(Hash)
        assert @net.transitions.key?("t1")
        assert @net.transitions.key?("t2")
      end

      def test_net_with_capacity
        place = @net.add_place(id: "p1", initial_tokens: 2, capacity: 5)

        assert_equal 2, place.tokens
        assert_equal 5, place.capacity
      end
    end
  end
end
