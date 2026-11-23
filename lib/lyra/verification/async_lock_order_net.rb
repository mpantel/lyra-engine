# frozen_string_literal: true

require "set"

module Lyra
  module Verification
    # ES-Async's lock orders for one record, as the code takes them (1.0.1):
    # the projection job, writes that skip callbacks, read-your-writes and a
    # writer that holds the row first. It decides two questions left after
    # 1.0.0's locking work:
    # - can a job that reads its events before it takes the row (its fallback
    #   after ROW_WAITS) leave the row behind its log for good (an older value
    #   over a bypass write)? No, with lock_aggregate_before_append on: a bypass
    #   that takes no stream lock found the checkpoint current under the
    #   aggregate lock, so the job then finds nothing after its checkpoint.
    # - can ReadYourWrites#project (the stream lock, then the row) deadlock with
    #   a transaction that holds the row first? Yes, with a job's last pass; and
    #   a transaction that takes the row before the aggregate lock (with_lock,
    #   then a write) deadlocks with one that takes them the other way round.
    #   PostgreSQL detects both.
    #
    # Locks, one token each when free: a, the record's aggregate lock
    # (advisory; every ES-Async writer's before its append); s, the stream's
    # lock (advisory; the job's, project_pending's, read-your-writes'); x, the
    # row (FOR UPDATE). A held x also marks x_taken, so a job's SKIP LOCKED
    # skips only when another transaction holds the row. Values: the log's (l),
    # the row's (r) and the job checkpoint's (c), each 0..N.
    #
    # Kinds:
    #   :writer        a; appends; commits; its job runs after (AsyncProjectionJob)
    #   :with_lock     x (with_lock); a; appends; commits; its job runs after
    #   :bypass        a; if behind (c < l), s and the row brought up to date
    #                  (project_pending); x; writes the row and its event, moves c
    #   :ryw           a; appends; s; x; writes the row from its own write
    #                  (ReadYourWrites#project, each_write); its job runs after
    #   :ryw_with_lock x; a; appends; s; writes the row; its job runs after
    #   :record_bypass a record-level write that skips callbacks (touch,
    #                  update_columns) as it was before 1.0.1: a; x; writes the
    #                  row and its event, c left where it is. From 1.0.1 it takes
    #                  the path of :bypass (the stream's lock, the row brought up
    #                  to date, then the write)
    #   :with_lock_ordered, :ryw_with_lock_ordered  the fix this net checks (1.0.1):
    #                  the locking read takes a, then s, then the row, brings the
    #                  row up to date (project_pending), then writes as above
    # A job: s; the row with SKIP LOCKED: free, it reads and applies the events
    # after c under both; taken, it lets s go, waits for the row, and tries
    # again; after +retries+ tries (ROW_WAITS) it takes s, reads, and waits for
    # the row (perform's last pass).
    #
    # Properties:
    #   deadlock         a terminal marking with an actor not done (PostgreSQL
    #                    would detect it and abort one transaction)
    #   diverged_at_rest a terminal marking, every actor done, whose row is not
    #                    the log's value: the row stays behind its log until a
    #                    later write of the record
    class AsyncLockOrderNet
      # +last_pass+: :read_first, as 1.0.0 and 1.0.1 have it (the events read,
      # then the row taken at the write), or :row_first (the row taken, then
      # the events read: the fix this net checks).
      Config = Struct.new(:name, :kinds, :retries, :last_pass, keyword_init: true)

      KINDS = %i[writer with_lock bypass ryw ryw_with_lock with_lock_ordered ryw_with_lock_ordered record_bypass].freeze
      WITH_JOB = %i[writer with_lock ryw ryw_with_lock with_lock_ordered ryw_with_lock_ordered].freeze

      attr_reader :config, :net, :n

      def initialize(config)
        @config = config
        @n = config.kinds.size
        @names = {}
        @actors = []
        @net = PetriFlow.create_net(name: config.name)
        build
      end

      def self.explore(config) = new(config).explore

      def explore(max_states: 1_000_000)
        analyzer = PetriFlow::Verification::ReachabilityAnalyzer.new(net)
        stats = analyzer.analyze(max_states: max_states)
        raise "state space not exhausted" if stats[:max_states_reached]

        markings = analyzer.reachable_markings.to_a
        terminal_keys = analyzer.terminal_states.to_set
        terminals = markings.select { terminal_keys.include?(key(_1)) }
        done = ->(m) { @actors.all? { |a| m.tokens_at(:"#{a}_done").positive? } }
        diverged = terminals.find { |m| done.(m) && values.none? { |v| m.tokens_at(:"l#{v}").positive? && m.tokens_at(:"r#{v}").positive? } }
        {
          states: markings.size,
          deadlock: witness(analyzer, terminals.find { !done.(_1) }),
          diverged_at_rest: witness(analyzer, diverged)
        }
      end

      private

      def key(marking) = marking.to_h.sort.to_s
      def values = (0..n).to_a
      def up(v) = [v + 1, n].min

      def witness(analyzer, marking)
        return nil unless marking

        (analyzer.find_path(marking) || []).each_slice(2).filter_map { |_, t| @names[t] if t }
      end

      def place(id, tokens = 0)
        net.add_place(id: id, initial_tokens: tokens) unless net.places.key?(id)
        id
      end

      def transition(name, from:, to:)
        id = :"t#{@names.size}"
        @names[id] = name
        net.add_transition(id: id, name: name)
        Array(from).each { net.add_arc(source_id: _1, target_id: id) }
        Array(to).each { net.add_arc(source_id: id, target_id: _1) }
      end

      # Taking x also marks x_taken; releasing it unmarks it.
      def take(lock) = lock == :x ? [:x_taken] : []
      def unmark(locks) = locks.include?(:x) ? [:x_taken] : []

      def step(actor, from, lock, label)
        to = place(:"#{actor}_#{label}")
        transition("#{actor}: takes #{lock}", from: [from, lock], to: [to, *take(lock)])
        to
      end

      def build
        values.each do |v|
          place(:"l#{v}", v.zero? ? 1 : 0)
          place(:"r#{v}", v.zero? ? 1 : 0)
          place(:"c#{v}", v.zero? ? 1 : 0)
        end
        %i[a s x].each { place(_1, 1) }
        place(:x_taken)
        config.kinds.each_with_index { |kind, i| build_actor(:"w#{i}", kind) }
      end

      def build_actor(w, kind)
        @actors << w
        place(:"#{w}_start", 1)
        place(:"#{w}_done")
        job = WITH_JOB.include?(kind) ? build_job(:"j#{w.to_s.delete_prefix('w')}") : nil
        case kind
        when :writer then commit_append(w, step(w, :"#{w}_start", :a, "a"), %i[a], job)
        when :with_lock then commit_append(w, step(w, step(w, :"#{w}_start", :x, "x"), :a, "xa"), %i[x a], job)
        when :bypass then build_bypass(w)
        when :record_bypass then record_bypass_write(w, step(w, step(w, :"#{w}_start", :a, "a"), :x, "ax"))
        when :ryw then build_ryw(w, step(w, :"#{w}_start", :a, "a"), %i[a], job)
        when :ryw_with_lock then build_ryw(w, step(w, step(w, :"#{w}_start", :x, "x"), :a, "xa"), %i[x a], job)
        when :with_lock_ordered then commit_append(w, ordered_read(w), %i[a s x], job)
        when :ryw_with_lock_ordered then build_ryw(w, ordered_read(w), %i[a s x], job)
        end
      end

      # Append the log's next value and commit, releasing +held+; enqueue +job+.
      def commit_append(w, at, held, job)
        values.each do |v|
          transition("#{w}: appends #{up(v)} and commits", from: [at, :"l#{v}", *unmark(held)],
                                                        to: [:"#{w}_done", :"l#{up(v)}", *held, *Array(job)])
        end
      end

      # ReadYourWrites#project after the write: s, then the row (already held
      # by :ryw_with_lock), written from the write itself; c is not moved.
      def build_ryw(w, at, held, job)
        values.each do |v|
          appended = place(:"#{w}_app_#{v}")
          transition("#{w}: appends #{up(v)}", from: [at, :"l#{v}"], to: [appended, :"l#{up(v)}"])
          # An advisory lock the transaction holds is taken again at once
          # (PostgreSQL's are reentrant): s only when not held already.
          with_s = held.include?(:s) ? appended : place(:"#{w}_s_#{v}")
          transition("#{w}: takes s (project)", from: [appended, :s], to: [with_s]) unless held.include?(:s)
          row = held.include?(:x) ? with_s : place(:"#{w}_sx_#{v}")
          transition("#{w}: takes x (project)", from: [with_s, :x], to: [row, :x_taken]) unless held.include?(:x)
          locks = [*held, *(held.include?(:s) ? [] : [:s]), *(held.include?(:x) ? [] : [:x])]
          values.each do |rv|
            transition("#{w}: writes the row #{up(v)} and commits", from: [row, :"r#{rv}", :x_taken],
                                                                   to: [:"#{w}_done", :"r#{up(v)}", *locks, *Array(job)])
          end
        end
      end

      # The fixed locking read: a, s, x, and the row brought up to the log.
      def ordered_read(w)
        rows = step(w, step(w, step(w, :"#{w}_start", :a, "oa"), :s, "oas"), :x, "oasx")
        ready = place(:"#{w}_ordered")
        values.each do |lv|
          values.each do |rv|
            values.each do |cv|
              to = cv < lv ? [ready, :"l#{lv}", :"r#{lv}", :"c#{lv}"] : [ready, :"l#{lv}", :"r#{rv}", :"c#{cv}"]
              transition("#{w}: brings the row up to date under a, s, x", from: [rows, :"l#{lv}", :"r#{rv}", :"c#{cv}"], to: to)
            end
          end
        end
        ready
      end
      
      # update_columns in ES-Async: a; behind, s and project_pending; x; the
      # row and its event written, c moved to it.
      def build_bypass(w)
        at = step(w, :"#{w}_start", :a, "a")
        values.each do |lv|
          values.each do |cv|
            if cv < lv
              behind = place(:"#{w}_behind")
              transition("#{w}: finds the row behind (c #{cv} < l #{lv})", from: [at, :"l#{lv}", :"c#{cv}"],
                                                                         to: [behind, :"l#{lv}", :"c#{cv}"])
            else
              clean = place(:"#{w}_clean")
              transition("#{w}: finds the row current (c #{cv})", from: [at, :"l#{lv}", :"c#{cv}"],
                                                                 to: [clean, :"l#{lv}", :"c#{cv}"])
            end
          end
        end
        if net.places.key?(:"#{w}_behind")
          with_s = step(w, :"#{w}_behind", :s, "s")
          rows = step(w, with_s, :x, "sx")
          projected = place(:"#{w}_projected_s")
          values.each do |lv|
            values.each do |rv|
              values.each do |cv|
                transition("#{w}: brings the row up to #{lv} (project_pending)", from: [rows, :"l#{lv}", :"r#{rv}", :"c#{cv}"],
                                                                                to: [projected, :"l#{lv}", :"r#{lv}", :"c#{lv}"])
              end
            end
          end
          bypass_write(w, projected, %i[a s x])
        end
        bypass_write(w, step(w, :"#{w}_clean", :x, "x"), %i[a x]) if net.places.key?(:"#{w}_clean")
      end

      def bypass_write(w, at, held)
        values.each do |lv|
          values.each do |rv|
            values.each do |cv|
              transition("#{w}: writes row and event #{up(lv)}, moves c, commits",
                         from: [at, :"l#{lv}", :"r#{rv}", :"c#{cv}", :x_taken],
                         to: [:"#{w}_done", :"l#{up(lv)}", :"r#{up(lv)}", :"c#{up(lv)}", *held])
            end
          end
        end
      end

      # The record-level write before 1.0.1: the row and the event, c unmoved.
      def record_bypass_write(w, at)
        values.each do |lv|
          values.each do |rv|
            transition("#{w}: writes row and event #{up(lv)}, commits (c unmoved)",
                       from: [at, :"l#{lv}", :"r#{rv}", :x_taken],
                       to: [:"#{w}_done", :"l#{up(lv)}", :"r#{up(lv)}", :a, :x])
          end
        end
      end

      # AsyncProjectionJob#perform for one event, enqueued at its writer's commit.
      def build_job(j)
        @actors << j
        place(:"#{j}_start")
        place(:"#{j}_done")
        retries = config.retries || 1
        tries = (0...retries).map { place(:"#{j}_try_#{_1}") }
        # retries 0: straight to the last pass (ROW_WAITS = 0)
        transition("#{j}: starts", from: [:"#{j}_start"], to: [tries.first || place(:"#{j}_last")])
        tries.each_with_index do |try, k|
          with_s = place(:"#{j}_s_#{k}")
          transition("#{j}: takes s", from: [try, :s], to: [with_s])
          both = place(:"#{j}_sx")
          transition("#{j}: takes the row (SKIP LOCKED)", from: [with_s, :x], to: [both, :x_taken])
          waiting = place(:"#{j}_wait_#{k}")
          transition("#{j}: row taken, lets s go", from: [with_s, :x_taken], to: [waiting, :x_taken, :s])
          after = k + 1 < retries ? tries[k + 1] : place(:"#{j}_last")
          transition("#{j}: waits for the row", from: [waiting, :x], to: [after, :x])
        end
        apply(j, place(:"#{j}_sx")) # unreachable with retries 0
        last = step(j, :"#{j}_last", :s, "last_s")
        if config.last_pass == :row_first
          apply(j, step(j, last, :x, "last_sx"))
        else
          values.each do |lv|
            read = place(:"#{j}_read_#{lv}")
            values.each do |cv|
              if cv >= lv
                # Nothing after the checkpoint: project_stream writes nothing.
                transition("#{j}: nothing after c #{cv} (last pass), commits", from: [last, :"l#{lv}", :"c#{cv}"],
                                                                              to: [:"#{j}_done", :"l#{lv}", :"c#{cv}", :s])
              else
                transition("#{j}: reads #{lv} after c #{cv}, before the row (last pass)", from: [last, :"l#{lv}", :"c#{cv}"],
                                                                                         to: [read, :"l#{lv}", :"c#{cv}"])
              end
            end
            row = place(:"#{j}_read_#{lv}_x")
            transition("#{j}: takes the row", from: [read, :x], to: [row, :x_taken])
            values.each do |rv|
              values.each do |cv|
                transition("#{j}: writes #{lv} and commits", from: [row, :"r#{rv}", :"c#{cv}", :x_taken],
                                                            to: [:"#{j}_done", :"r#{lv}", :"c#{lv}", :s, :x])
              end
            end
          end
        end
        :"#{j}_start"
      end

      # Under s and the row: the log as it stands onto the row, and c to it.
      def apply(j, at)
        values.each do |lv|
          values.each do |rv|
            values.each do |cv|
              # The events after the checkpoint (events_to_apply): none when it
              # is current, and the job then writes nothing.
              if cv >= lv
                transition("#{j}: nothing after c #{cv}, commits", from: [at, :"l#{lv}", :"r#{rv}", :"c#{cv}", :x_taken],
                                                                  to: [:"#{j}_done", :"l#{lv}", :"r#{rv}", :"c#{cv}", :s, :x])
              else
                transition("#{j}: applies #{lv} and commits", from: [at, :"l#{lv}", :"r#{rv}", :"c#{cv}", :x_taken],
                                                             to: [:"#{j}_done", :"l#{lv}", :"r#{lv}", :"c#{lv}", :s, :x])
              end
            end
          end
        end
      end
    end
  end
end
