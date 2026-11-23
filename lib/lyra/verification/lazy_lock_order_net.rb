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
    #   c  the catch-up lock (advisory, global): a catch-up on its own connection
    #      takes it and lets it go when it commits; one in the reader's transaction
    #      (the fallback) holds it to the reader's commit
    # and the log's committed value (l0..lN) with the row's (r0..rN).
    #
    # Writers (kinds):
    #   :plain            reads (the catch-up), then a, h, commits value + 1
    #   :writes_then_reads a, h, appends, then reads again in its transaction:
    #                     the others' events are caught up on its own connection
    #                     (c, taken and let go; the reader waits for it in Ruby,
    #                     where PostgreSQL cannot see the wait); its own event is
    #                     not visible there, so it replays it onto the row, which
    #                     takes x; then commits
    #   :plain_inline     the fallback, where no second connection can be had (a
    #                     full pool, a pinned connection) or under REPEATABLE READ:
    #                     reads in its transaction first, catching up there (c,
    #                     held to its commit), then a, h, commits
    #   :writes_then_reads_inline  a, h, appends, then reads: the fallback's
    #                     catch-up (c, held), its own event replayed (x), commits
    #   :falls_back_then_reads  reads first in the fallback (c, held), a, h,
    #                     then reads again with a connection free: in place
    #                     (remembers) or on its own connection, waiting for the c
    #                     its own transaction holds
    # With own_wait :bounded, a catch-up waiting on its own connection can also
    # give up and run in its reader's transaction, taking c there (held).
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
    #                    PostgreSQL detects it and aborts one transaction, unless
    #                    the cycle passes through a wait on a catch-up's own
    #                    connection: then it is a hang, reported as hang too)
    #   hang             a deadlock with a writer waiting for c on its own
    #                    connection, so not every wait is in PostgreSQL's graph
    #   bad_lost_update  a with_lock commit computed from a value the log had
    #                    moved past
    class LazyLockOrderNet
      # +own_wait+: :bounded (1.0.1: the catch-up on its own connection waits at
      # most OWN_LOCK_WAIT for c, then runs in its reader's transaction) or
      # :unbounded (before). +remembers+: whether a transaction holding c from a
      # fallback catches up in place (1.0.1) or on its own connection (before).
      Config = Struct.new(:name, :kinds, :own_wait, :remembers, keyword_init: true)

      KINDS = %i[plain writes_then_reads bulk with_lock_x_first with_lock_a_first plain_inline writes_then_reads_inline
                 falls_back_then_reads].freeze
      PROPERTIES = %i[deadlock hang bad_lost_update].freeze

      attr_reader :config, :net, :n

      def initialize(config)
        @config = config
        @n = config.kinds.size + 1
        @names = {}
        @own_waits = []
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
        stuck = terminals.select { |m| (0...writers).any? { m.tokens_at(p(_1, :done)).zero? } }
        {
          states: markings.size,
          deadlock: witness(analyzer, stuck.first),
          hang: witness(analyzer, stuck.find { |m| @own_waits.any? { m.tokens_at(_1).positive? } }),
          bad_lost_update: witness(analyzer, markings.find { _1.tokens_at(:bad_lost_update).positive? })
        }
      end

      private

      def key(marking) = marking.to_h.sort.to_s
      def bounded? = config.own_wait != :unbounded
      def remembers? = config.remembers != false
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
        %i[a x h c bad_lost_update].each { place(_1, _1 == :bad_lost_update ? 0 : 1) }
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
          # the others' events, on its own connection: c taken and let go
          caught = p(i, :caught)
          place(caught)
          @own_waits << appended
          transition("w#{i}: catches up on its own connection (c)", from: [appended, :c], to: [caught, :c])
          # its own event, uncommitted, replayed onto the row: x, then commit
          replayed = acquire(i, caught, %i[x], "own")
          commit(i, replayed, %i[a h x], lost: false)
          if bounded?
            gave_up = p(i, :gave_up)
            place(gave_up)
            transition("w#{i}: waits OWN_LOCK_WAIT, then catches up in its transaction", from: appended, to: gave_up)
            inline = acquire(i, gave_up, %i[c x], "gu")
            commit(i, inline, %i[a h c x], lost: false)
          end
        when :falls_back_then_reads
          wrote = acquire(i, p(i, :start), %i[c a h], "fb")
          again = p(i, :read_again)
          place(again)
          if remembers?
            transition("w#{i}: holds c, catches up in place", from: wrote, to: again)
          else
            @own_waits << wrote
            transition("w#{i}: catches up on its own connection (c)", from: [wrote, :c], to: [again, :c])
            transition("w#{i}: waits OWN_LOCK_WAIT, then catches up in its transaction", from: wrote, to: again) if bounded?
          end
          commit(i, again, %i[c a h], lost: false)
        when :plain_inline
          held = acquire(i, p(i, :start), %i[c a h], "in")
          commit(i, held, %i[c a h], lost: false)
        when :writes_then_reads_inline
          held = acquire(i, p(i, :start), %i[a h c x], "in")
          commit(i, held, %i[a h c x], lost: false)
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
