# frozen_string_literal: true

require "set"

module Lyra
  module Verification
    # The mode gate's check against writes in flight (Lyra::ModeTransition
    # .run_check and .settled_position, 1.0.1): can a certificate cover an
    # event that neither the comparison nor the re-check saw?
    #
    # The gate reads the event store's position P, settles it, compares each
    # record's row with its log, reads the final position P2, settles it, and
    # re-checks every record with an event above P; the certificate keeps P2,
    # and a later switch re-checks only what moved past it. An event id is
    # taken when the event is inserted, and becomes visible when its
    # transaction commits, so an event below a position read can still be in
    # flight. To settle a position is to wait for every transaction that held
    # a transaction id when it was read (pg_stat_activity.backend_xid), or to
    # refuse after a timeout (config.mode_transition_settle_timeout).
    #
    # Writers, one event each, on records of their own: begin; take a
    # transaction id; insert the event (its id, the next in order); commit. In
    # Lyra the transaction id comes first, because a write moves the record's
    # stream head before it appends (Lyra::StreamHeads); without that, the
    # event's id is taken in the same INSERT that takes the transaction id,
    # first (+xid_first+ false).
    #
    # A record's event is seen when it had committed by its record's
    # comparison, or by the re-check with an id above P. The property,
    # checked on every terminal marking with a certificate:
    #   missed  an event with an id up to P2 that was seen by neither
    # The gate's refusal (the settle timed out) certifies nothing, and is
    # never a violation.
    class GateSettleNet
      # +settle+: whether a position read is settled (1.0.1) or not (1.0.0).
      # +xid_first+: whether a writer holds its transaction id before its
      # event takes an id (Lyra's head first).
      Config = Struct.new(:name, :writers, :settle, :xid_first, keyword_init: true)

      CONFIGS = [
        Config.new(name: "1.0.0: the position alone", writers: 2, settle: false, xid_first: true),
        Config.new(name: "1.0.1: the position settled", writers: 2, settle: true, xid_first: true),
        Config.new(name: "1.0.1, three writers", writers: 3, settle: true, xid_first: true),
        Config.new(name: "settled, without the head first", writers: 2, settle: true, xid_first: false)
      ].freeze

      attr_reader :config, :net, :n

      def initialize(config)
        @config = config
        @n = config.writers
        @names = {}
        @net = PetriFlow.create_net(name: config.name)
        build
      end

      def self.explore(config) = new(config).explore

      # { states:, certified:, missed: counterexample or nil }
      def explore(max_states: 500_000)
        analyzer = PetriFlow::Verification::ReachabilityAnalyzer.new(net)
        stats = analyzer.analyze(max_states: max_states)
        raise "state space not exhausted" if stats[:max_states_reached]

        markings = analyzer.reachable_markings.to_a
        terminal_keys = analyzer.terminal_states.to_set
        terminals = markings.select { terminal_keys.include?(key(_1)) }
        certified = terminals.select { _1.tokens_at(:g_certified).positive? }
        missed = certified.find { |m| (0...n).any? { |i| missed?(m, i) } }
        { states: markings.size, certified: certified.size, missed: witness(analyzer, missed) }
      end

      private

      def key(marking) = marking.to_h.sort.to_s
      def ids = (1..n).to_a
      def w(i, name) = :"w#{i}_#{name}"

      def witness(analyzer, marking)
        return nil unless marking

        (analyzer.find_path(marking) || []).each_slice(2).filter_map { |_, t| @names[t] if t }
      end

      def place(id, tokens = 0) = net.add_place(id: id, initial_tokens: tokens)

      def transition(name, from:, to:)
        id = :"t#{@names.size}"
        @names[id] = name
        net.add_transition(id: id, name: name)
        Array(from).each { net.add_arc(source_id: _1, target_id: id) }
        Array(to).each { net.add_arc(source_id: id, target_id: _1) }
      end

      def committed_id(m, i) = ids.find { m.tokens_at(w(i, :"committed_#{_1}")).positive? }
      def value(m, prefix) = (0..n).find { m.tokens_at(:"#{prefix}_#{_1}").positive? }

      def missed?(m, i)
        k = committed_id(m, i)
        k && k <= value(m, :g_p2) && m.tokens_at(w(i, :seen)).zero? && m.tokens_at(w(i, :rechecked)).zero?
      end

      # A writer's states: idle, xid (a transaction id, no event yet), pre_k
      # (event id k taken, no transaction id yet: only without xid_first),
      # inflight_k (both), committed_k.
      def states(i)
        [w(i, :idle), w(i, :xid), *ids.map { w(i, :"pre_#{_1}") }, *ids.map { w(i, :"inflight_#{_1}") },
         *ids.map { w(i, :"committed_#{_1}") }]
      end

      def holds_xid?(state) = state.to_s.match?(/_(xid|inflight_\d+)\z/)
      def committed_k(state) = state.to_s[/_committed_(\d+)\z/, 1]&.to_i

      def build
        ids.each { place(:"next_#{_1}", _1 == 1 ? 1 : 0) }
        place(:"next_#{n + 1}")
        (0...n).each { build_writer(_1) }
        build_gate
      end

      def build_writer(i)
        states(i).each { place(_1, _1 == w(i, :idle) ? 1 : 0) }
        place(w(i, :seen))
        place(w(i, :rechecked))
        ids.each do |k|
          if config.xid_first
            transition("w#{i}: event takes id #{k}", from: [w(i, :xid), :"next_#{k}"], to: [w(i, :"inflight_#{k}"), :"next_#{k + 1}"])
          else
            transition("w#{i}: event takes id #{k}", from: [w(i, :idle), :"next_#{k}"], to: [w(i, :"pre_#{k}"), :"next_#{k + 1}"])
            transition("w#{i}: takes its transaction id", from: w(i, :"pre_#{k}"), to: w(i, :"inflight_#{k}"))
          end
          transition("w#{i}: commits", from: w(i, :"inflight_#{k}"), to: w(i, :"committed_#{k}"))
        end
        transition("w#{i}: begins, moves the head (transaction id)", from: w(i, :idle), to: w(i, :xid)) if config.xid_first
      end

      # Every combination of the writers' states, for a transition that reads
      # them all (each state taken and put back).
      def combinations = (0...n).map { states(_1) }.reduce { |a, b| a.product(b).map(&:flatten) }.map { Array(_1) }

      def build_gate
        %i[g_start g_read1 g_settled1 g_read2 g_settled2 g_certified g_refused].each { place(_1, _1 == :g_start ? 1 : 0) }
        (0..n).each { place(:"g_p_#{_1}"); place(:"g_p2_#{_1}") }
        (0..n).each { |i| place(:"g_cmp_#{i}") }
        (0..n).each { |i| place(:"g_rc_#{i}") }
        if config.settle
          (0...n).each { |i| [1, 2].each { |r| place(w(i, :"wait#{r}")); place(w(i, :"nowait#{r}")) } }
        end
        build_read(:g_start, :g_read1, :g_p, 1)
        build_settle(:g_read1, :g_settled1, 1)
        # compare each record, in turn
        transition("gate: compares", from: :g_settled1, to: :g_cmp_0)
        (0...n).each do |i|
          states(i).each do |s|
            to = [:"g_cmp_#{i + 1}", s]
            to << w(i, :seen) if committed_k(s)
            transition("gate: compares w#{i}'s record#{' (sees its event)' if committed_k(s)}", from: [:"g_cmp_#{i}", s], to: to)
          end
        end
        place(:g_read2_at)
        transition("gate: compared", from: :"g_cmp_#{n}", to: :g_read2_at)
        build_read(:g_read2_at, :g_read2, :g_p2, 2)
        build_settle(:g_read2, :g_settled2, 2)
        transition("gate: re-checks", from: :g_settled2, to: :g_rc_0)
        (0...n).each do |i|
          (0..n).each do |p|
            states(i).each do |s|
              k = committed_k(s)
              to = [:"g_rc_#{i + 1}", s, :"g_p_#{p}"]
              to << w(i, :rechecked) if k && k > p
              transition("gate: re-checks w#{i}'s record (P #{p})#{' (above P)' if k && k > p}", from: [:"g_rc_#{i}", s, :"g_p_#{p}"], to: to)
            end
          end
        end
        transition("gate: certifies", from: :"g_rc_#{n}", to: :g_certified)
      end

      # A position read: the highest committed id; with the settle, each writer
      # holding a transaction id then is waited for (wait_<r>), the others not.
      def build_read(from, to, prefix, round)
        combinations.each do |combo|
          p = combo.filter_map { committed_k(_1) }.max || 0
          marks = []
          if config.settle
            combo.each_with_index { |s, i| marks << w(i, :"#{holds_xid?(s) ? 'wait' : 'nowait'}#{round}") }
          end
          transition("gate: reads position #{p}#{" (#{round == 1 ? 'P' : 'P2'})"}", from: [from, *combo], to: [to, *combo, :"#{prefix}_#{p}", *marks])
        end
      end

      def build_settle(from, to, round)
        unless config.settle
          transition("gate: goes on", from: from, to: to)
          return
        end

        (0...n).each do |i|
          ids.each do |k|
            transition("gate: w#{i} has ended", from: [w(i, :"wait#{round}"), w(i, :"committed_#{k}")],
                                                to: [w(i, :"nowait#{round}"), w(i, :"committed_#{k}")])
          end
        end
        transition("gate: settled", from: [from, *(0...n).map { w(_1, :"nowait#{round}") }], to: to)
        transition("gate: the settle times out, refuses", from: from, to: :g_refused)
      end
    end
  end
end
