# frozen_string_literal: true

require "set"

module Lyra
  module Verification
    # Several writers on one aggregate, with the lock on the aggregate as a
    # place (thesis, future work of Chapter 7: "a net with several writers and
    # a place for the lock, explored with the lock and without it").
    #
    # A P/T net, built per configuration and explored exhaustively with
    # PetriFlow's reachability analysis. It models what Theorem 5 (Serialized
    # Aggregate Access) and the history clauses of Hypothesis H are about, not
    # the CRUD mapping, which the other nets cover.
    #
    # Shared places, one token each among their alternatives:
    # - the stream's committed status (absent, live, gone) and value (0..N);
    # - the row's committed status and value, where the configuration has a row;
    # - the lock (one token when free), where the configuration has one.
    # A value counts the updates applied: a create writes 0, an update that read
    # k writes k + 1.
    #
    # Each writer runs one operation (create, update or destroy) through:
    #   [lock] -> read (updates: the value k, from the row or the stream)
    #   -> [lock] -> check (the guard, on the stream's committed status)
    #   -> commit (the event and, in a table-backed mode, the row: one step,
    #      since another transaction sees neither before the commit) -> [release]
    # A lagging mode projects the row afterwards, from the whole stream (as
    # Rebuild.replay_record does, under the per-stream projection lock), at any
    # later point and outside the writer's transaction.
    #
    # Monitor writes the row first, with the database's own refusals: an INSERT
    # of a live key fails, an UPDATE or DELETE that reaches no row writes and
    # records nothing.
    #
    # Violation places collect a token each time a run breaks a property, so a
    # property holds when its place is empty in every reachable marking:
    #   bad_double_created  a Created appended to a live stream (H)
    #   bad_headless        an update or destroy appended to a stream with no record (H)
    #   bad_after_destroy   an update or destroy appended after the destroy (H)
    #   bad_lost_update     an update computed from a value another commit had
    #                       already replaced (only Lyra's fault when the writer
    #                       read under the lock, as with_lock does)
    #   bad_overlap         two writers inside the lock's critical section (Theorem 5)
    # and, checked on the terminal markings, the row and the stream agreeing at rest.
    class ConcurrentWritersNet
      OPS = %i[create update destroy].freeze
      STATUSES = %i[absent live gone].freeze
      BAD = %i[bad_double_created bad_headless bad_after_destroy bad_lost_update].freeze

      # mode:        :table (Hijack, ES-Sync), :lagging (ES-Async, ES-Lazy), :events_only (ES-NoProj), :monitor
      # lock:        :none, :before_append (assumption L as Lyra takes it), :before_read (with_lock)
      # lock_creates: whether a create takes the lock (Lyra 1.0.0: no)
      # guard:       :none, :destroyed (1.0.0: refuse an update or destroy after a destroy), :h1 (the history clauses of H)
      # read_from:   :row or :stream, for an update's read (ES-NoProj always reads the stream)
      # start:       the record's state before the writers run: :absent or :live (value 0)
      Config = Struct.new(:name, :mode, :lock, :lock_creates, :guard, :read_from, keyword_init: true)

      # The configurations explored: Lyra 1.0.0 as released, and the design that
      # enforces the history clauses of Hypothesis H (H1) at the append.
      # with_lock is the lock taken before the read; in 1.0.0's ES-NoProj it
      # locks no row and so excludes no other writer (lock: :none).
      CONFIGS = [
        Config.new(name: "1.0.0 Hijack, ES-Sync", mode: :table, lock: :before_append, lock_creates: false, guard: :destroyed, read_from: :row),
        Config.new(name: "1.0.0 Hijack, ES-Sync, lock off", mode: :table, lock: :none, lock_creates: false, guard: :destroyed, read_from: :row),
        Config.new(name: "1.0.0 Hijack, ES-Sync, with_lock", mode: :table, lock: :before_read, lock_creates: false, guard: :destroyed, read_from: :row),
        Config.new(name: "1.0.0 ES-Async, ES-Lazy", mode: :lagging, lock: :before_append, lock_creates: false, guard: :destroyed, read_from: :row),
        Config.new(name: "1.0.0 ES-Async, ES-Lazy, with_lock", mode: :lagging, lock: :before_read, lock_creates: false, guard: :destroyed, read_from: :row),
        Config.new(name: "1.0.0 ES-NoProj, with_lock", mode: :events_only, lock: :none, lock_creates: false, guard: :destroyed, read_from: :stream),
        Config.new(name: "Monitor", mode: :monitor, lock: :none, lock_creates: false, guard: :none, read_from: :row),
        Config.new(name: "Monitor, with_lock", mode: :monitor, lock: :before_read, lock_creates: true, guard: :none, read_from: :row),
        Config.new(name: "H1 Hijack, ES-Sync", mode: :table, lock: :before_append, lock_creates: true, guard: :h1, read_from: :row),
        Config.new(name: "H1 Hijack, ES-Sync, with_lock", mode: :table, lock: :before_read, lock_creates: true, guard: :h1, read_from: :row),
        Config.new(name: "H1 ES-Async, ES-Lazy", mode: :lagging, lock: :before_append, lock_creates: true, guard: :h1, read_from: :row),
        Config.new(name: "H1 ES-Async, ES-Lazy, with_lock reading the row", mode: :lagging, lock: :before_read, lock_creates: true, guard: :h1, read_from: :row),
        Config.new(name: "H1 ES-Async, ES-Lazy, with_lock reading the stream", mode: :lagging, lock: :before_read, lock_creates: true, guard: :h1, read_from: :stream),
        Config.new(name: "H1 ES-NoProj, with_lock", mode: :events_only, lock: :before_read, lock_creates: true, guard: :h1, read_from: :stream)
      ].freeze

      PROPERTIES = (BAD + %i[bad_overlap diverged_at_rest deadlock]).freeze

      # Every combination of +writers+ operations, from an absent and from a
      # live record. Returns { property => [combination, counterexample] or nil }
      # and the number of states explored.
      def self.explore_all(config, writers: 2)
        found = {}
        states = 0
        OPS.repeated_combination(writers).each do |ops|
          %i[absent live].each do |start|
            result = new(config, ops, start: start).explore
            states += result[:states]
            PROPERTIES.each { |property| found[property] ||= ["#{ops.join('+')} from #{start}", result[property]] if result[property] }
          end
        end
        [PROPERTIES.to_h { [_1, found[_1]] }, states]
      end

      attr_reader :config, :ops, :start, :net, :n

      def initialize(config, ops, start:)
        @config = config
        @ops = ops
        @start = start
        @n = ops.size
        @names = {}
        @net = PetriFlow.create_net(name: "#{config.name} #{ops.join('/')} from #{start}")
        build
      end

      def has_row? = !%i[events_only].include?(config.mode)
      def lock? = config.lock != :none
      def locks?(op) = lock? && (op != :create || config.lock_creates || config.mode == :monitor)
      def read_from = config.mode == :events_only ? :stream : config.read_from

      # Explore every reachable marking. Returns the properties, each with a
      # shortest counterexample (the transitions fired) where one exists.
      def explore(max_states: 200_000)
        analyzer = PetriFlow::Verification::ReachabilityAnalyzer.new(net)
        stats = analyzer.analyze(max_states: max_states)
        raise "state space not exhausted (#{stats[:total_states]} states)" if stats[:max_states_reached]

        markings = analyzer.reachable_markings.to_a
        terminal_keys = analyzer.terminal_states.to_set
        terminals = markings.select { terminal_keys.include?(key(_1)) }
        result = { states: markings.size, terminal: terminals.size }
        BAD.each do |bad|
          witness = markings.find { _1.tokens_at(bad).positive? }
          result[bad] = witness ? trace(analyzer, witness) : nil
        end
        critical = (0...n).map { |i| critical_places(i) }
        overlap = markings.find { |m| critical.count { |ps| ps.any? { m.tokens_at(_1).positive? } } > 1 }
        result[:bad_overlap] = overlap ? trace(analyzer, overlap) : nil
        stuck = terminals.find { |m| (0...n).any? { |i| m.tokens_at(p(i, :done)).zero? } }
        result[:deadlock] = stuck ? trace(analyzer, stuck) : nil
        diverged = has_row? ? terminals.find { !at_rest_agree?(_1) } : nil
        result[:diverged_at_rest] = diverged ? trace(analyzer, diverged) : nil
        result
      end

      private

      def p(i, name) = :"w#{i}_#{name}"
      def key(marking) = marking.to_h.sort.to_s

      def trace(analyzer, marking)
        path = analyzer.find_path(marking) || []
        path.each_slice(2).filter_map { |_, t| @names[t] if t }
      end

      def status_of(m, prefix) = STATUSES.find { m.tokens_at(:"#{prefix}_#{_1}").positive? }
      def value_of(m, prefix) = (0..n).find { m.tokens_at(:"#{prefix}_v#{_1}").positive? }

      def at_rest_agree?(m)
        s = status_of(m, :s)
        r = status_of(m, :r)
        return false unless s == r || (s == :gone && r == :absent) || (s == :absent && r == :gone)
        s != :live || value_of(m, :s) == value_of(m, :r)
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
        start_status = start
        %i[s r].each do |prefix|
          next if prefix == :r && !has_row?

          STATUSES.each { place(:"#{prefix}_#{_1}", _1 == start_status ? 1 : 0) }
          (0..n).each { place(:"#{prefix}_v#{_1}", _1.zero? ? 1 : 0) }
        end
        place(:lock, 1) if lock?
        BAD.each { place(_1) }
        ops.each_with_index { |op, i| build_writer(i, op) }
      end

      # The places a writer passes through: start, (locked_read), read_k / read_x,
      # (locked), check_k, go_k, done; pending, for a lagging projection.
      def build_writer(i, op)
        %i[start locked_read read_x locked_x go_x done pending].each { place(p(i, _1), _1 == :start ? 1 : 0) }
        (0..n).each { |k| %i[read locked go].each { place(p(i, :"#{_1}_#{k}")) } }
        reads = op == :update ? (0..n).to_a : [:x]
        before_read = config.lock == :before_read && locks?(op)
        before_append = config.lock == :before_append && locks?(op)

        # [lock] -> read
        if before_read
          transition("w#{i} #{op}: lock", from: [p(i, :start), :lock], to: p(i, :locked_read))
          after_lock = p(i, :locked_read)
        else
          after_lock = p(i, :start)
        end
        if op == :update
          source = read_from == :row ? :r : :s
          (0..n).each do |k|
            transition("w#{i} update: read #{k} from the #{read_from}",
                       from: [after_lock, :"#{source}_v#{k}"], to: [p(i, :"read_#{k}"), :"#{source}_v#{k}"])
          end
        else
          transition("w#{i} #{op}: begin", from: after_lock, to: p(i, :read_x))
        end

        reads.each do |k|
          read = p(i, :"read_#{k}")
          # [lock] -> check
          if before_append
            transition("w#{i} #{op}: lock", from: [read, :lock], to: p(i, :"locked_#{k}"))
            checking = p(i, :"locked_#{k}")
          else
            checking = read
          end
          go = p(i, :"go_#{k}")
          # Inside the lock's critical section another writer's presence is an overlap.
          STATUSES.each do |status|
            if allowed?(op, status)
              transition("w#{i} #{op}: check passes (stream #{status})", from: [checking, :"s_#{status}"], to: [go, :"s_#{status}"])
            else
              transition("w#{i} #{op}: refused (stream #{status})", from: [checking, :"s_#{status}"],
                         to: [p(i, :done), :"s_#{status}", *release(op)])
            end
          end
          build_commit(i, op, k, go)
        end
        build_projection(i) if config.mode == :lagging
      end

      def release(op) = locks?(op) ? [:lock] : []

      def allowed?(op, status)
        case config.guard
        when :none then true
        when :destroyed then !(op != :create && status == :gone)
        when :h1 then op == :create ? status != :live : status == :live
        end
      end

      # The commit: the stream's event and, by mode, the row, in one step.
      def build_commit(i, op, k, go)
        STATUSES.each do |s|
          (0..n).each do |sv|
            row_cases = has_row? ? STATUSES.product((0..n).to_a) : [[nil, nil]]
            row_cases.each do |r, rv|
              outcome = commit_outcome(op, k, s, sv, r, rv)
              next unless outcome

              from = [go, :"s_#{s}", :"s_v#{sv}"]
              from += [:"r_#{r}", :"r_v#{rv}"] if r
              to = [p(i, :done), :"s_#{outcome[:s]}", :"s_v#{outcome[:sv]}", *outcome[:bad], *release(op)]
              to += [:"r_#{outcome[:r]}", :"r_v#{outcome[:rv]}"] if r
              to << p(i, :pending) if config.mode == :lagging && outcome[:appended]
              transition("w#{i} #{op}: commit#{" (computed from #{k})" if op == :update}, stream #{s}#{" row #{r}" if r}",
                         from: from, to: to)
            end
          end
        end
      end

      def commit_outcome(op, k, s, sv, r, rv)
        if config.mode == :monitor
          # The row first, with the database's refusals; an event only for a row write.
          case op
          when :create
            return { s: s, sv: sv, r: r, rv: rv, bad: [], appended: false } if r == :live # RecordNotUnique

            r, rv = :live, 0
          when :update
            return { s: s, sv: sv, r: r, rv: rv, bad: [], appended: false } unless r == :live

            rv = [k + 1, n].min
          when :destroy
            return { s: s, sv: sv, r: r, rv: rv, bad: [], appended: false } unless r == :live

            r = :gone
          end
          stream = append(op, k, s, sv)
          return stream.merge(r: r, rv: rv, appended: true)
        end

        stream = append(op, k, s, sv)
        if config.mode == :table
          r, rv = project(op, k, r, rv)
        end
        stream.merge(r: r, rv: rv, appended: true)
      end

      # The event appended to a stream in status s, value sv.
      def append(op, k, s, sv)
        bad = []
        case op
        when :create
          bad << :bad_double_created if s == :live
          s, sv = :live, 0
        when :update
          if s == :live
            bad << :bad_lost_update if sv != k
            sv = [k + 1, n].min
          else
            bad << (s == :absent ? :bad_headless : :bad_after_destroy)
          end
        when :destroy
          if s == :live
            s = :gone
          else
            bad << (s == :absent ? :bad_headless : :bad_after_destroy)
          end
        end
        { s: s, sv: sv, bad: bad }
      end

      # One event's projection onto the row (ModelProjection): a create inserts
      # unless the row exists, an update reaches a live row only, a destroy deletes.
      def project(op, k, r, rv)
        case op
        when :create then r == :live ? [r, rv] : [:live, 0]
        when :update then r == :live ? [r, [k + 1, n].min] : [r, rv]
        when :destroy then r == :live ? [:gone, rv] : [r, rv]
        end
      end

      # A lagging mode's projection job: the row becomes the replay of the whole stream.
      def build_projection(i)
        STATUSES.product((0..n).to_a).each do |s, sv|
          STATUSES.product((0..n).to_a).each do |r, rv|
            nr = s == :absent ? r : s
            nrv = s == :live ? sv : rv
            transition("w#{i} projection job (stream #{s} #{sv})",
                       from: [p(i, :pending), :"s_#{s}", :"s_v#{sv}", :"r_#{r}", :"r_v#{rv}"],
                       to: [:"s_#{s}", :"s_v#{sv}", :"r_#{nr}", :"r_v#{nrv}"])
          end
        end
      end

      # Theorem 5 checked directly: the places in which a locking writer holds
      # the lock. Two writers in them at once is an overlap.
      def critical_places(i)
        return [] unless locks?(ops[i])

        held = config.lock == :before_read ? [p(i, :locked_read), p(i, :read_x), *(0..n).map { p(i, :"read_#{_1}") }] : [p(i, :locked_x), *(0..n).map { p(i, :"locked_#{_1}") }]
        # go_x: a create or destroy, which reads no value, waits for its commit there
        held + [p(i, :go_x)] + (0..n).map { p(i, :"go_#{_1}") }
      end
    end
  end
end
