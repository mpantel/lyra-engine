# frozen_string_literal: true

require "test_helper"

module PetriFlow
  module Verification
    class LivenessCheckerTest < Minitest::Test
      # The four-place CRUD-to-event pipeline: one token runs from p_crud to
      # p_aggregate and stops there, as it is meant to.
      def pipeline
        net = PetriFlow.create_net(name: "CRUD_to_Event")
        net.add_place(id: :p_crud, initial_tokens: 1)
        net.add_place(id: :p_event)
        net.add_place(id: :p_published)
        net.add_place(id: :p_aggregate)
        net.add_transition(id: :t_map)
        net.add_transition(id: :t_publish)
        net.add_transition(id: :t_apply)
        net.add_arc(source_id: :p_crud, target_id: :t_map)
        net.add_arc(source_id: :t_map, target_id: :p_event)
        net.add_arc(source_id: :p_event, target_id: :t_publish)
        net.add_arc(source_id: :t_publish, target_id: :p_published)
        net.add_arc(source_id: :p_published, target_id: :t_apply)
        net.add_arc(source_id: :t_apply, target_id: :p_aggregate)
        net
      end

      def test_plain_deadlock_freedom_counts_the_intended_end_as_a_deadlock
        liveness = PetriFlow.verify(pipeline)[:liveness]

        refute liveness[:deadlock_free]
        refute liveness[:terminates_properly], "with no terminal places the two checks agree"
      end

      def test_terminal_places_make_the_intended_end_proper_termination
        liveness = PetriFlow.verify(pipeline, terminal_places: [:p_aggregate])[:liveness]

        assert liveness[:terminates_properly]
        assert_equal 0, liveness[:improper_dead_markings]
        refute liveness[:deadlock_free], "the raw check is unchanged"
      end

      def test_a_dead_end_outside_the_terminal_places_is_still_a_deadlock
        net = pipeline
        net.add_place(id: :p_stuck)
        net.add_transition(id: :t_lose)
        net.add_arc(source_id: :p_event, target_id: :t_lose)
        net.add_arc(source_id: :t_lose, target_id: :p_stuck)

        liveness = PetriFlow.verify(net, terminal_places: [:p_aggregate])[:liveness]

        refute liveness[:terminates_properly]
        assert_equal 1, liveness[:improper_dead_markings]
      end
    end
  end
end
