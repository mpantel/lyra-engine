# frozen_string_literal: true

require "set"

module Lyra
  module Verification
    # Locks across records: transactions that write several records of one
    # model and read others under a lock (with_lock, lock!, lock.find_by), the
    # case the one-record nets leave out. It checks that a locking read adds no
    # order of locks across records that the application did not choose: that
    # the mixes of transactions that can deadlock are those that can in plain
    # Active Record.
    #
    # Records 0..records-1. Locks, one token each when free, held to the commit:
    #   a<r>  in plain Active Record the record's row lock; in ES-NoProj, which
    #         keeps no rows, its aggregate lock (advisory), which every write of
    #         it takes before its append
    #   h<r>  in ES-NoProj, the record's stream head (a row of
    #         lyra_stream_heads), which the append moves (Lyra::StreamHeads)
    #
    # A transaction is a program of steps, each on one record, taking only the
    # locks it does not hold yet, and commits after its last step:
    #   [:write, r]      plain: a<r>; ES-NoProj: a<r>, then h<r>
    #   [:lock_read, r]  a locking read of r (with_lock, lock!, lock.find_by):
    #                    :plain  a<r>, the row lock (plain Active Record)
    #                    :own    a<r> (Lyra 1.0.1 as released: the locked
    #                            relation narrowed by find_by's conditions)
    #                    :all    every record's a, in their order, before the
    #                            read (the 1.0.1 campaign's code, which locked what
    #                            all.lock selected before find_by!(id:) narrowed it)
    #
    # Property:
    #   deadlock  a terminal marking with a transaction not done: a wait cycle,
    #             which PostgreSQL detects and breaks by aborting a transaction
    class MultiRecordLockNet
      Config = Struct.new(:name, :records, :programs, :read, keyword_init: true)

      READS = %i[plain own all].freeze
      KINDS = %i[write lock_read].freeze

      attr_reader :config, :net

      def initialize(config)
        raise ArgumentError, "read must be one of #{READS.join(', ')}" unless READS.include?(config.read)

        @config = config
        @names = {}
        @net = PetriFlow.create_net(name: config.name)
        build
      end

      def self.explore(config) = new(config).explore

      # Every program of +length+ steps on +records+ records.
      def self.programs(records, length: 2)
        KINDS.product((0...records).to_a).repeated_permutation(length).to_a
      end

      # Every mix of +size+ transactions (with repetition) of such programs.
      def self.mixes(records, size: 2, length: 2)
        programs(records, length: length).repeated_combination(size).to_a
      end

      # The mixes that can deadlock under +read+, and the states explored.
      def self.census(read, records: 3, size: 2, length: 2)
        all = mixes(records, size: size, length: length)
        states = 0
        deadlocking = all.select do |programs|
          result = explore(Config.new(name: "census", records: records, programs: programs, read: read))
          states += result[:states]
          result[:deadlock]
        end
        { mixes: all.size, deadlocking: deadlocking, states: states }
      end

      def explore(max_states: 200_000)
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
      # record numbers: what the trace test compares with the code's.
      def aggregate_lock_order(program)
        held = []
        program.flat_map do |kind, record|
          taken = wanted(kind, record, held)
          held.concat(taken)
          taken.filter_map { aggregate_record(_1) }
        end
      end

      private

      def key(marking) = marking.to_h.sort.to_s
      def p(i, name) = :"t#{i}_#{name}"
      def lock(r) = :"a#{r}"
      def head(r) = :"h#{r}"
      def lyra? = config.read != :plain
      def aggregate_record(place) = place.to_s.start_with?("a") ? place.to_s.delete_prefix("a").to_i : nil

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

      # The locks a step takes, in order, given those the transaction holds.
      def wanted(kind, record, held)
        raise ArgumentError, "unknown step #{kind}" unless KINDS.include?(kind)

        locks = if kind == :lock_read
                  config.read == :all ? (0...config.records).map { lock(_1) } : [lock(record)]
                else
                  lyra? ? [lock(record), head(record)] : [lock(record)]
                end
        locks - held
      end

      def build_transaction(i, program)
        at = place(p(i, :start), 1)
        held = []
        program.each_with_index do |(kind, record), k|
          wanted(kind, record, held).each_with_index do |l, j|
            nxt = place(p(i, :"s#{k}_#{j}"))
            transition("t#{i}: #{kind} #{record}: takes #{l}", from: [at, l], to: nxt)
            at = nxt
            held << l
          end
        end
        transition("t#{i}: commits", from: at, to: [place(p(i, :done))] + held)
      end
    end
  end
end
