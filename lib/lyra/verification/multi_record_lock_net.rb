# frozen_string_literal: true

require "set"

module Lyra
  module Verification
    # Locks across records: transactions that write records, of one model or
    # several, and read others under a lock, the case the one-record nets
    # leave out. It checks that ES-NoProj's locks add no deadlock to plain
    # Active Record: every mix of transactions that can deadlock in ES-NoProj
    # can deadlock in plain Active Record, for some order of its scans.
    #
    # Records 0..records-1, of any models (a lock belongs to a record's
    # stream, Model$id). Locks, one token each when free, held to the commit:
    #   a<r>  in plain Active Record the record's row lock; in ES-NoProj, which
    #         keeps no rows, its aggregate lock (advisory), which every write of
    #         it takes before its append
    #   h<r>  in ES-NoProj, the record's stream head (a row of
    #         lyra_stream_heads), which the append moves (Lyra::StreamHeads)
    #
    # A transaction is a program of steps, taking only the locks it does not
    # hold yet, and commits after its last step:
    #   [:write, r]          plain: a<r>; ES-NoProj: a<r>, then h<r>. Rails'
    #                        writes of other records (touch: true, dependent:
    #                        :destroy) are write steps in Rails' order; the
    #                        trace tests check that ES-NoProj takes their locks
    #                        in it. (A counter cache ES-NoProj does not keep: it
    #                        takes no lock there.)
    #   [:lock_read, r]      a locking read of r (with_lock, lock!, lock.find_by):
    #                        plain a<r>; :own a<r> (Lyra 1.0.1 as released);
    #                        :all every record's a in their order (the 1.0.1
    #                        campaign's code, which locked what all.lock selected
    #                        before find_by!(id:) narrowed it)
    #   [:lock_read_set, rs] a locking read of several records (lock.where,
    #                        lock.find(ids)): plain their row locks in the scan's
    #                        order, any; ES-NoProj their a in stream-name order
    #                        (record order here)
    #   [:bulk, rs]          a bulk write (update_all, delete_all, update_counters,
    #                        touch_all): plain the row locks in the scan's order,
    #                        any; ES-NoProj their a in one statement, in the order
    #                        of the keys' hashes (+bulk_order+, a permutation of
    #                        the records), then their h
    # Plain Active Record's scan order is a choice made before the step takes
    # a lock (a transition that takes none), as a query plan is.
    #
    # Property:
    #   deadlock  a terminal marking with a transaction not done: a wait cycle,
    #             which PostgreSQL detects and breaks by aborting a transaction
    #
    # For any number of transactions, steps and records, the census aside,
    # conditions (structural, checked by #conditions):
    #   heads_under_aggregate  a transaction takes h<r> only while it holds a<r>
    #   own_records_only       a step takes the a of its own records only
    #   plain_order            the order a step takes its a in is one plain
    #                          Active Record can take them in
    # give the result. By the first, a transaction that takes h<r> holds a<r>,
    # which no other then holds, and every holder of h<r> holds a<r>: h<r> is
    # free, and no transaction ever waits for a head. Removing the heads leaves
    # transactions that take, by the other two, the a plain Active Record takes,
    # in an order it can take them in; so a reachable marking of ES-NoProj, with
    # each transaction's scan order chosen as ES-NoProj's, is one of plain
    # Active Record's, a terminal one with a transaction not done included.
    # With no set steps the converse holds too, and the deadlocking mixes are
    # equal. Assumed: each record's lock is its own (two streams whose 32-bit
    # hashtext keys collide share one, which can add a wait PostgreSQL detects).
    class MultiRecordLockNet
      Config = Struct.new(:name, :records, :programs, :read, :bulk_order, keyword_init: true)

      READS = %i[plain own all].freeze
      KINDS = %i[write lock_read lock_read_set bulk].freeze
      SET_KINDS = %i[lock_read_set bulk].freeze

      attr_reader :config, :net

      def initialize(config)
        raise ArgumentError, "read must be one of #{READS.join(', ')}" unless READS.include?(config.read)

        @config = config
        @bulk_order = config.bulk_order || (0...config.records).to_a.reverse
        unless @bulk_order.sort == (0...config.records).to_a
          raise ArgumentError, "bulk_order must be a permutation of the records"
        end

        @names = {}
        @net = PetriFlow.create_net(name: config.name)
        build
      end

      def self.explore(config) = new(config).explore

      # The steps on +records+ records: one per record for write and lock_read,
      # one per set of two or more records for the set kinds (+sets+: false
      # leaves them out).
      def self.steps(records, sets: false)
        singles = %i[write lock_read].product((0...records).to_a)
        return singles unless sets

        groups = (2..records).flat_map { (0...records).to_a.combination(_1).to_a }
        singles + SET_KINDS.product(groups)
      end

      # Every program of +length+ steps.
      def self.programs(records, length: 2, sets: false) = steps(records, sets: sets).repeated_permutation(length).to_a

      # Every mix of +size+ transactions (with repetition) of such programs.
      def self.mixes(records, size: 2, length: 2, sets: false)
        programs(records, length: length, sets: sets).repeated_combination(size).to_a
      end

      # The mixes (all, or +sample+ of them with +seed+) that can deadlock
      # under +read+, and the states explored.
      def self.census(read, records: 3, size: 2, length: 2, sets: false, sample: nil, seed: 1, bulk_order: nil)
        all = mixes(records, size: size, length: length, sets: sets)
        all = all.sample(sample, random: Random.new(seed)) if sample
        states = 0
        deadlocking = all.select do |programs|
          result = explore(Config.new(name: "census", records: records, programs: programs, read: read,
                                      bulk_order: bulk_order))
          states += result[:states]
          result[:deadlock]
        end
        { mixes: all.size, deadlocking: deadlocking, states: states }
      end

      def explore(max_states: 500_000)
        analyzer = PetriFlow::Verification::ReachabilityAnalyzer.new(net)
        stats = analyzer.analyze(max_states: max_states)
        raise "state space not exhausted" if stats[:max_states_reached]

        markings = analyzer.reachable_markings.to_a
        terminal_keys = analyzer.terminal_states.to_set
        stuck = markings.find do |m|
          terminal_keys.include?(key(m)) && config.programs.each_index.any? { m.tokens_at(p(_1, :done)).zero? }
        end
        { states: markings.size, deadlock: witness(analyzer, stuck) }
      end

      # The aggregate locks a transaction running +program+ takes, in order, as
      # record numbers (ES-NoProj; plain Active Record's scans in record
      # order): what the trace tests compare with the code's.
      def aggregate_lock_order(program)
        held = []
        program.flat_map do |kind, target|
          taken = lyra_locks(kind, target, held)
          held.concat(taken)
          taken.filter_map { aggregate_record(_1) }
        end
      end

      # The three conditions of the proof above, for every transaction of the
      # configuration: { heads_under_aggregate:, own_records_only:, plain_order: }.
      def conditions
        results = { heads_under_aggregate: true, own_records_only: true, plain_order: true }
        config.programs.each do |program|
          held = []
          program.each do |kind, target|
            records = Array(target)
            taken = lyra_locks(kind, target, held)
            taken.each_with_index do |l, j|
              next unless (r = head_record(l))

              results[:heads_under_aggregate] &&= (held + taken.first(j)).include?(lock(r))
            end
            aggregates = taken.filter_map { aggregate_record(_1) }
            results[:own_records_only] &&= (aggregates - records).empty?
            results[:plain_order] &&= plain_orders(kind, records, held).include?(aggregates)
            held.concat(taken)
          end
        end
        results
      end

      private

      def key(marking) = marking.to_h.sort.to_s
      def p(i, name) = :"t#{i}_#{name}"
      def lock(r) = :"a#{r}"
      def head(r) = :"h#{r}"
      def lyra? = config.read != :plain
      def aggregate_record(place) = place.to_s.start_with?("a") ? place.to_s.delete_prefix("a").to_i : nil
      def head_record(place) = place.to_s.start_with?("h") ? place.to_s.delete_prefix("h").to_i : nil

      def witness(analyzer, marking)
        return nil unless marking

        (analyzer.find_path(marking) || []).each_slice(2).filter_map { |_, t| @names[t] if t }
      end

      def place(id, tokens = 0)
        net.add_place(id: id, initial_tokens: tokens)
        id
      end

      def transition(name, from:, to:)
        id = :"x#{@names.size}"
        @names[id] = name
        net.add_transition(id: id, name: name)
        Array(from).each { net.add_arc(source_id: _1, target_id: id) }
        Array(to).each { net.add_arc(source_id: id, target_id: _1) }
      end

      def build
        config.records.times { place(lock(_1), 1) }
        config.records.times { place(head(_1), 1) } if lyra?
        config.programs.each_with_index { |program, i| build_transaction(i, program) }
      end

      def check_step!(kind, target)
        raise ArgumentError, "unknown step #{kind}" unless KINDS.include?(kind)
        return if SET_KINDS.include?(kind) == target.is_a?(Array)

        raise ArgumentError, "#{kind} takes #{SET_KINDS.include?(kind) ? 'an array of records' : 'one record'}"
      end

      # ES-NoProj's locks for a step, in order, given those the transaction holds.
      def lyra_locks(kind, target, held)
        check_step!(kind, target)
        locks = case kind
                when :write then [lock(target), head(target)]
                when :lock_read then config.read == :all ? (0...config.records).map { lock(_1) } : [lock(target)]
                when :lock_read_set then target.uniq.sort.map { lock(_1) }
                when :bulk
                  ordered = @bulk_order.select { target.include?(_1) }
                  ordered.map { lock(_1) } + ordered.sort.map { head(_1) }
                end
        locks.uniq - held
      end

      # The orders (as record lists) in which plain Active Record can take a
      # step's row locks, given those the transaction holds.
      def plain_orders(kind, records, held)
        free = records.uniq.reject { held.include?(lock(_1)) }
        SET_KINDS.include?(kind) ? free.permutation.to_a : [free]
      end

      def chain(i, from, label, locks)
        locks.each_with_index.reduce(from) do |at, (l, j)|
          nxt = place(p(i, :"#{label}_#{j}"))
          transition("t#{i}: #{label}: takes #{l}", from: [at, l], to: nxt)
          nxt
        end
      end

      def build_transaction(i, program)
        at = place(p(i, :start), 1)
        held = []
        program.each_with_index do |(kind, target), k|
          label = "s#{k} #{kind} #{Array(target).join(',')}"
          if lyra?
            taken = lyra_locks(kind, target, held)
            at = chain(i, at, label, taken)
            held.concat(taken)
          else
            check_step!(kind, target)
            orders = plain_orders(kind, Array(target), held)
            after = place(p(i, :"s#{k}_end"))
            orders.each_with_index do |order, o|
              chosen = place(p(i, :"s#{k}_o#{o}"))
              transition("t#{i}: #{label}: scans in order #{order.join(',')}", from: at, to: chosen)
              last = chain(i, chosen, "#{label} o#{o}", order.map { lock(_1) })
              transition("t#{i}: #{label}: done", from: last, to: after)
            end
            at = after
            held.concat(orders.first.map { lock(_1) })
          end
        end
        transition("t#{i}: commits", from: at, to: [place(p(i, :done))] + held)
      end
    end
  end
end
