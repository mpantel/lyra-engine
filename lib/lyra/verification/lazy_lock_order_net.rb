# frozen_string_literal: true

require "set"

module Lyra
  module Verification
    # The order in which ES-Lazy's writers and locking readers take their
    # locks, under design c (the catch-up in a transaction of its own that
    # skips rows another transaction holds): the net that decides the order
    # before it is built.
    #
    # One record. Locks, one token each when free:
    #   a  the record's aggregate lock (advisory), every writer's before its append
    #   x  the record's row lock: with_lock's SELECT ... FOR UPDATE, a bulk write's
    #      rows, and the row write of a reader replaying its own uncommitted events
    #   h  the record's stream head, taken at the append (Lyra::StreamHeads)
    # and the log's committed value (l0..lN) with the row's (r0..rN).
    #
    # Writers (kinds):
    #   :plain            reads (the catch-up), then a, h, commits value + 1
    #   :writes_then_reads a, h, appends, then reads again in its transaction: its
    #                     own event is not visible to the catch-up's connection, so
    #                     it replays its own record onto the row, which takes x;
    #                     then commits
    #   :bulk             a, then x (update_all's rows), then h, commits
    #   :with_lock_x_first  x (the SQL), then a, then h; replays the record, reads,
    #                     commits value + 1  (part 1 as first written)
    #   :with_lock_a_first  a, then x, then h  (Lyra takes the aggregate lock before
    #                     the SQL, for a record-level lock! or with_lock)
    # The catch-up on its own connection takes no lock a writer holds: it applies
    # the row if x is free and skips it otherwise, never waiting, so no wait
    # cycle passes through it, and it is left out.
    #
    # Properties:
    #   deadlock         a terminal marking with a writer not done (a wait cycle;
    #                    PostgreSQL would detect it and abort one transaction)
    #   bad_lost_update  a with_lock commit computed from a value the log had
    #                    moved past
    class LazyLockOrderNet
      Config = Struct.new(:name, :kinds, keyword_init: true)

      KINDS = %i[plain writes_then_reads bulk with_lock_x_first with_lock_a_first].freeze
      PROPERTIES = %i[deadlock bad_lost_update].freeze

      attr_reader :config, :net, :n

      def initialize(config)
        @config = config
        @n = config.kinds.size + 1
        @names = {}
        @net = PetriFlow.create_net(name: config.name)
        build
      end

      def self.explore(config) = new(config).explore

      def explore(max_states: 500_000)
        analyzer = PetriFlow::Verification::ReachabilityAnalyzer.new(net)
        stats = analyzer.analyze(max_states: max_states)
        raise "state space not exhausted" if stats[:max_states_reached]

        markings = analyzer.reachable_markings.to_a
        terminal_keys = analyzer.terminal_states.to_set
        terminals = markings.select { terminal_keys.include?(key(_1)) }
        writers = config.kinds.size
        {
          states: markings.size,
          deadlock: witness(analyzer, terminals.find { |m| (0...writers).any? { m.tokens_at(p(_1, :done)).zero? } }),
          bad_lost_update: witness(analyzer, markings.find { _1.tokens_at(:bad_lost_update).positive? })
        }
      end

      private

      def key(marking) = marking.to_h.sort.to_s
      def p(i, name) = :"w#{i}_#{name}"
      def values = (0..n).to_a

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

      # Take +locks+ in order, from place +from+, through numbered places.
      def acquire(i, from, locks, label)
        locks.each_with_index.reduce(from) do |at, (lock, k)|
          nxt = p(i, :"#{label}_#{k}")
          place(nxt)
          transition("w#{i}: takes #{lock}", from: [at, lock], to: nxt)
          nxt
        end
      end

      def build
        values.each { |v| place(:"l#{v}", v.zero? ? 1 : 0) }
        values.each { |v| place(:"r#{v}", v.zero? ? 1 : 0) }
        %i[a x h bad_lost_update].each { place(_1, _1 == :bad_lost_update ? 0 : 1) }
        config.kinds.each_with_index { |kind, i| build_writer(i, kind) }
      end

      def build_writer(i, kind)
        place(p(i, :start), 1)
        place(p(i, :done))
        case kind
        when :plain
          held = acquire(i, p(i, :start), %i[a h], "lk")
          commit(i, held, %i[a h], lost: false)
        when :bulk
          held = acquire(i, p(i, :start), %i[a x h], "lk")
          commit(i, held, %i[a x h], lost: false)
        when :writes_then_reads
          appended = acquire(i, p(i, :start), %i[a h], "lk")
          # its own event, uncommitted, replayed onto the row: x, then commit
          replayed = acquire(i, appended, %i[x], "own")
          commit(i, replayed, %i[a h x], lost: false)
        when :with_lock_x_first, :with_lock_a_first
          order = kind == :with_lock_x_first ? %i[x a h] : %i[a x h]
          held = acquire(i, p(i, :start), order, "lk")
          # under all three, no writer of the record can commit: replay, read
          values.each do |lv|
            values.each do |rv|
              read = p(i, :"read_#{lv}")
              place(read) unless net.places.key?(read)
              transition("w#{i}: replays (row #{rv} -> #{lv}) and reads #{lv}",
                         from: [held, :"l#{lv}", :"r#{rv}"], to: [read, :"l#{lv}", :"r#{lv}"])
            end
          end
          values.each do |k|
            values.each do |lv|
              nv = [k + 1, n].min
              bad = lv == k ? [] : [:bad_lost_update]
              transition("w#{i}: commits #{nv} (read #{k}, log #{lv})",
                         from: [p(i, :"read_#{k}"), :"l#{lv}"], to: [p(i, :done), :"l#{nv}", *order, *bad])
            end
          end
        end
      end

      # Commit value + 1 from the log as it stands (no read under the lock), and
      # release +locks+.
      def commit(i, from, locks, lost:)
        values.each do |lv|
          nv = [lv + 1, n].min
          transition("w#{i}: commits #{nv}", from: [from, :"l#{lv}"], to: [p(i, :done), :"l#{nv}", *locks])
        end
      end
    end
  end
end
