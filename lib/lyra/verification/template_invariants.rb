# frozen_string_literal: true

module Lyra
  module Verification
    # Properties of the multi-writer nets that hold for any number of writers.
    #
    # Exploring a net covers the number of writers it was built with. These
    # checks are structural instead: they look at each transition, not at the
    # reachable markings, so they extend to any number of writers by the
    # following argument.
    #
    # The net for N writers is the shared places (the lock, the log, the row)
    # plus N copies of one writer's places and transitions. If
    #   (1) locality: every transition touches the places of at most one writer
    #       (besides the shared ones), and
    #   (2) the weights of a place invariant are the same for every writer's
    #       copy of a place (a template weight), and every transition preserves
    #       the weighted token sum,
    # then the invariant holds in every reachable marking of the net for any N:
    # a transition of writer i changes only shared places and writer i's, and
    # preserves the sum whatever the other writers' tokens are. The generators
    # build writer i's transitions from the same code for every i; the
    # transitions over the record's values (0..N) differ in number with N, but
    # those places have weight 0. The checks are run on the nets for N = 1..4,
    # which exercises each generator path; the argument does the rest.
    #
    # The invariant used: lock + (tokens in places where a writer holds the
    # lock) = 1, so at most one writer holds the lock (mutual exclusion,
    # Theorem 5's premise), for any N. And a guard check:
    #   (3) every transition that changes the log consumes the lock, or a place
    #       in which its writer holds the lock.
    # With (2), between a lock holder's read and its commit no other writer can
    # change the log, so an update computed under the lock is never lost, for
    # any N.
    module TemplateInvariants
      module_function

      # Transitions (their names) that change the weighted token sum.
      def invariant_violations(net, weights)
        net.transitions.values.filter_map do |t|
          gained = t.output_arcs.sum { |a| weights.fetch(a.target.id, 0) * a.weight }
          lost = t.input_arcs.sum { |a| weights.fetch(a.source.id, 0) * a.weight }
          t.name unless gained == lost
        end
      end

      # Transitions that touch the places of more than one writer. +owner+ maps
      # a place id to its writer, or nil for a shared place.
      def locality_violations(net, &owner)
        net.transitions.values.filter_map do |t|
          places = (t.input_arcs.map(&:source) + t.output_arcs.map(&:target)).map(&:id)
          t.name if places.filter_map { owner.call(_1) }.uniq.size > 1
        end
      end

      # Transitions that change +data+ places (a token moves between them) but
      # consume neither +lock+ nor a place of +held+ (the places in which the
      # transition's own writer holds the lock).
      def unguarded_changes(net, data:, lock:, held:)
        net.transitions.values.filter_map do |t|
          ins = t.input_arcs.map { _1.source.id }
          outs = t.output_arcs.map { _1.target.id }
          changes = (ins & data).sort != (outs & data).sort
          next unless changes

          t.name unless ins.include?(lock) || ins.intersect?(held)
        end
      end
    end
  end
end
