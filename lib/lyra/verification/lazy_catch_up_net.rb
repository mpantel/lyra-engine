# frozen_string_literal: true

require "set"

module Lyra
  module Verification
    # ES-Lazy's catch-up, with updaters that lock a record (with_lock) and the
    # catch-up's global lock as places: the net for ES-Lazy's deadlock and lost
    # update in Lyra 1.0.0, and for the design that moves the catch-up out of
    # the reader's transaction (design c).
    #
    # One record. Shared places, one token each among their alternatives:
    # - the log's committed value (l0..lN) and the row's projected value (r0..rN);
    #   the net starts with one event committed and not yet projected (l1, r0);
    # - the catch-up's global lock (g, one token when free);
    # - the record's row lock (x, one token when free): with_lock's
    #   SELECT ... FOR UPDATE, and the row write of applying an event.
    # Writers (locking): :plain, :with_lock (reads once, as lock.find), :rereads
    # (with_lock, then reads again under the lock, as Solidus code does).
    # Each writer updates the record once: it reads (the read catches the table
    # up), computes value + 1 and commits it to the log. A with_lock updater
    # holds x from its locking read to its commit; a plain one takes the
    # record's lock at its append (x free at that point).
    #
    # Designs:
    # - :in_transaction (Lyra 1.0.0): the catch-up runs before the read's SQL,
    #   so before with_lock's SELECT ... FOR UPDATE takes x, in the reader's
    #   transaction: it takes g and holds it to the reader's commit, and applying
    #   the event writes the row, taking x, also held to the commit.
    # - :own_transaction (design c): with_lock takes x first; under x, which no
    #   writer of the record can pass, the reader replays its record itself, then
    #   reads. Any other catch-up runs in a transaction of its own: g, the row if
    #   x is free (else the row is skipped and left to x's holder), commit, both
    #   released at once.
    #
    # Properties, over every reachable marking:
    #   deadlock         a terminal marking with a writer not done (a wait cycle)
    #   bad_lost_update  a with_lock commit computed from a value the log had moved
    #                    past (a plain read-modify-write loses updates in plain
    #                    Active Record too, so it is not counted)
    #   bad_stale_read   a read under x of a row behind the log
    # A row behind the log at rest is ES-Lazy by design: the next read catches up.
    class LazyCatchUpNet
      Config = Struct.new(:name, :design, :locking, keyword_init: true)

      CONFIGS = [
        Config.new(name: "1.0.0, two with_lock updaters", design: :in_transaction, locking: %i[with_lock with_lock]),
        Config.new(name: "1.0.0, a with_lock and a plain updater", design: :in_transaction, locking: %i[with_lock plain]),
        Config.new(name: "1.0.0, two plain updaters", design: :in_transaction, locking: %i[plain plain]),
        Config.new(name: "1.0.0, a rereading with_lock and two plain updaters", design: :in_transaction, locking: %i[rereads plain plain]),
        Config.new(name: "design c, two with_lock updaters", design: :own_transaction, locking: %i[with_lock with_lock]),
        Config.new(name: "design c, a with_lock and a plain updater", design: :own_transaction, locking: %i[with_lock plain]),
        Config.new(name: "design c, two plain updaters", design: :own_transaction, locking: %i[plain plain]),
        Config.new(name: "design c, three with_lock updaters", design: :own_transaction, locking: %i[with_lock with_lock with_lock]),
        Config.new(name: "design c, two with_lock and a plain updater", design: :own_transaction, locking: %i[with_lock with_lock plain]),
        Config.new(name: "design c, a rereading with_lock and two plain updaters", design: :own_transaction, locking: %i[rereads plain plain])
      ].freeze

      PROPERTIES = %i[deadlock bad_lost_update bad_stale_read].freeze

      attr_reader :config, :net, :n

      def initialize(config)
        @config = config
        @n = config.locking.size + 1
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
        writers = config.locking.size
        {
          states: markings.size,
          deadlock: witness(analyzer, terminals.find { |m| (0...writers).any? { m.tokens_at(p(_1, :done)).zero? } }),
          bad_lost_update: witness(analyzer, markings.find { _1.tokens_at(:bad_lost_update).positive? }),
          bad_stale_read: witness(analyzer, markings.find { _1.tokens_at(:bad_stale_read).positive? })
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

      def build
        values.each { |v| place(:"l#{v}", v == 1 ? 1 : 0) }
        values.each { |v| place(:"r#{v}", v.zero? ? 1 : 0) }
        place(:g, 1)
        place(:x, 1)
        place(:bad_lost_update)
        place(:bad_stale_read)
        config.locking.each_with_index do |locking, i|
          holds_x = %i[with_lock rereads].include?(locking)
          config.design == :in_transaction ? writer_1_0_0(i, holds_x, rereads: locking == :rereads) : writer_design_c(i, holds_x)
        end
      end

      # A reader's read and its commit, from +ready+ (the table caught up as far
      # as this writer saw to it), holding +held+ (places released at commit).
      def read_and_commit(i, ready, holds_x, held, label)
        values.each do |k|
          read = p(i, :"read_#{label}_#{k}")
          place(read)
          transition("w#{i}: reads #{k}", from: [ready, :"r#{k}"], to: [read, :"r#{k}"])
          values.each do |lv|
            nv = [k + 1, n].min
            stale = holds_x && lv != k ? [:bad_stale_read] : []
            lost = holds_x && lv != k ? [:bad_lost_update] : []
            if holds_x
              transition("w#{i}: commits #{nv} (read #{k}, log #{lv})",
                         from: [read, :"l#{lv}"], to: [p(i, :done), :"l#{nv}", *held, *stale, *lost])
            else
              # a plain updater takes the record's lock at its append
              need_x = held.include?(:x) ? [] : [:x]
              transition("w#{i}: commits #{nv} (read #{k}, log #{lv})",
                         from: [read, :"l#{lv}", *need_x], to: [p(i, :done), :"l#{nv}", *held, *need_x])
            end
          end
        end
      end

      # Lyra 1.0.0: catch up (in the reader's transaction) before the read's
      # SQL, so before with_lock takes x.
      def writer_1_0_0(i, holds_x, rereads: false)
        %i[start applying caught_nog caught_gx locked_nog done].each { place(p(i, _1), _1 == :start ? 1 : 0) }
        values.each do |v|
          transition("w#{i}: table up to date (#{v})", from: [p(i, :start), :"l#{v}", :"r#{v}"],
                                                        to: [p(i, :caught_nog), :"l#{v}", :"r#{v}"])
        end
        values.product(values).each do |lv, rv|
          next if lv == rv

          transition("w#{i}: behind (log #{lv}, row #{rv}): takes the catch-up lock, held to its commit",
                     from: [p(i, :start), :g, :"l#{lv}", :"r#{rv}"], to: [p(i, :applying), :"l#{lv}", :"r#{rv}"])
          # applying writes the row: x, held to the commit
          transition("w#{i}: applies the row (#{rv} -> #{lv}), taking the row lock",
                     from: [p(i, :applying), :x, :"l#{lv}", :"r#{rv}"], to: [p(i, :caught_gx), :"l#{lv}", :"r#{lv}"])
        end
        if holds_x
          # with_lock's SELECT ... FOR UPDATE, after the catch-up
          transition("w#{i}: with_lock takes the row lock", from: [p(i, :caught_nog), :x], to: p(i, :locked_nog))
          # The transaction reads again under the row lock (Solidus's code does):
          # that read catches up first, and needs g if the log moved on.
          place(p(i, :second))
          place(p(i, :second_applying))
          values.each do |v|
            transition("w#{i}: second read: up to date (#{v})", from: [p(i, :locked_nog), :"l#{v}", :"r#{v}"],
                                                                 to: [p(i, :second), :"l#{v}", :"r#{v}"])
          end
          values.product(values).each do |lv, rv|
            next if lv == rv

            transition("w#{i}: second read: behind (log #{lv}, row #{rv}): takes the catch-up lock",
                       from: [p(i, :locked_nog), :g, :"l#{lv}", :"r#{rv}"], to: [p(i, :second_applying), :"l#{lv}", :"r#{rv}"])
            transition("w#{i}: second read: applies the row (#{rv} -> #{lv}) under its own row lock",
                       from: [p(i, :second_applying), :"l#{lv}", :"r#{rv}"], to: [p(i, :caught_gx), :"l#{lv}", :"r#{lv}"])
          end
          read_and_commit(i, p(i, :second), true, [:x], "x")
          # A with_lock updater that reads once (lock.find) reads the row as the
          # catch-up before the lock left it; one that rereads catches up again.
          read_and_commit(i, p(i, :locked_nog), true, [:x], "x1") unless rereads
          read_and_commit(i, p(i, :caught_gx), true, %i[g x], "gx")
        else
          read_and_commit(i, p(i, :caught_nog), false, [], "nog")
          read_and_commit(i, p(i, :caught_gx), false, %i[g x], "gx")
        end
      end

      # Design c: with_lock takes x first and replays its record under it; any
      # other catch-up commits at once and skips a row x's holder has.
      def writer_design_c(i, holds_x)
        %i[start locked caught waiting done].each { place(p(i, _1), _1 == :start ? 1 : 0) }
        if holds_x
          transition("w#{i}: with_lock takes the row lock", from: [p(i, :start), :x], to: p(i, :locked))
          values.product(values).each do |lv, rv|
            to = [p(i, :caught), :"l#{lv}", :"r#{lv}"]
            name = lv == rv ? "table up to date (#{lv})" : "behind (log #{lv}, row #{rv}): replays its record under its row lock"
            transition("w#{i}: #{name}", from: [p(i, :locked), :"l#{lv}", :"r#{rv}"], to: to)
          end
          read_and_commit(i, p(i, :caught), true, [:x], "x")
        else
          values.each do |v|
            transition("w#{i}: table up to date (#{v})", from: [p(i, :start), :"l#{v}", :"r#{v}"],
                                                          to: [p(i, :caught), :"l#{v}", :"r#{v}"])
          end
          values.product(values).each do |lv, rv|
            next if lv == rv

            transition("w#{i}: behind (log #{lv}, row #{rv}): the catch-up applies the row and commits at once",
                       from: [p(i, :start), :g, :x, :"l#{lv}", :"r#{rv}"], to: [p(i, :caught), :g, :x, :"l#{lv}", :"r#{lv}"])
            # x held by another transaction: the row is skipped (pending), the
            # catch-up commits, and the reader reads what the table has
            transition("w#{i}: behind (log #{lv}, row #{rv}), row locked by another: skips it",
                       from: [p(i, :start), :g, :"l#{lv}", :"r#{rv}"], to: [p(i, :caught), :g, :"l#{lv}", :"r#{rv}"])
          end
          read_and_commit(i, p(i, :caught), false, [], "plain")
        end
      end
    end
  end
end
