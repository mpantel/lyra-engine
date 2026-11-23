# frozen_string_literal: true

module Lyra
  module Verification
    # Replays a recorded lock trace on a concurrency net, token by token (trace
    # conformance; benchmarks/petri-concurrent-writers/TRACE_CONFORMANCE_PLAN.md).
    #
    # A trace is a list of steps, each an actor of the net (w0, j0, ...) and an
    # action (:a, :s, :x, :h, :read, :append, :commit, ...), in the order the locks
    # were granted. +rules+ maps an action to the patterns of the transition
    # labels that may fire it, after "<actor>: "; an action mapped to nothing
    # is not in the net (the stream head in a net that leaves it out) and is
    # skipped. +silent+ lists label patterns the code does without a step of
    # its own (a job starting, a row brought up to date inside the locks): they
    # fire when the next step needs them. Among the enabled transitions of a
    # step's actor, the one whose label matches fires; the value places decide
    # which of a label's variants is enabled.
    #
    # Returns { fired:, steps:, divergences: [{ step:, enabled: }], done: },
    # where done says whether every actor reached its done place.
    class TraceReplay
      # +separator+ is what follows the actor in the net's labels ("w0: takes a",
      # or "w0 update: lock" with " ").
      def initialize(net, actors:, rules:, silent: [], separator: ": ")
        @separator = separator
        @net = net
        @actors = actors
        @rules = rules
        @silent = silent
      end

      def replay(steps)
        fired = 0
        divergences = []
        steps.each do |step|
          patterns = @rules.fetch(step.action) { [] }
          next if patterns.empty?

          if fire_matching(step.actor, patterns)
            fired += 1
          else
            divergences << { step: step.to_s, enabled: enabled_labels }
          end
        end
        finish_silently
        { fired: fired, steps: steps.count { @rules.fetch(_1.action) { [] }.any? }, divergences: divergences, done: done? }
      end

      private

      def fire_matching(actor, patterns, depth = 0)
        candidate = enabled_for(actor).find { |t| patterns.any? { |p| t.name.match?(p) } }
        if candidate
          @net.fire_transition(candidate.id)
          return true
        end
        return false if depth > 3

        silent = enabled_for(actor).find { |t| @silent.any? { |p| t.name.match?(p) } }
        return false unless silent

        @net.fire_transition(silent.id)
        fire_matching(actor, patterns, depth + 1)
      end

      def enabled_for(actor)
        prefix = "#{actor}#{@separator}"
        @net.enabled_transitions.select { _1.name.start_with?(prefix) }
      end

      def enabled_labels = @net.enabled_transitions.map(&:name).first(12)

      def finish_silently
        loop do
          silent = @net.enabled_transitions.find { |t| @silent.any? { |p| t.name.match?(p) } }
          break unless silent

          @net.fire_transition(silent.id)
        end
      end

      def done? = @actors.all? { @net.place(:"#{_1}_done")&.tokens.to_i.positive? }
    end
  end
end
