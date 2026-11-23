# frozen_string_literal: true

require "test_helper"

module Lyra
  module Verification
    # The multi-writer nets' properties for any number of writers
    # (Lyra::Verification::TemplateInvariants): locality, the lock's place
    # invariant, and that only the lock's holder changes the log. Checked on
    # the nets for 1 to 4 writers; the template argument extends them to any.
    class TemplateInvariantsTest < Minitest::Test
      def self.runnable_methods
        return [] unless defined?(PetriFlow)

        super
      end

      INV = TemplateInvariants
      WRITERS = (1..4).freeze

      def owner(place) = place.to_s[/\Aw(\d+)_/, 1]&.to_i

      # The writers net (Lyra::Verification::ConcurrentWritersNet), in the
      # configurations whose writers all take the lock.
      def writers_nets(name)
        config = ConcurrentWritersNet::CONFIGS.find { _1.name == name } or flunk "no configuration #{name}"
        WRITERS.flat_map do |n|
          ConcurrentWritersNet::OPS.repeated_combination(n).map { ConcurrentWritersNet.new(config, _1, start: :live) }
        end
      end

      def check_writers_net(name, lost_updates_excluded:)
        writers_nets(name).each do |w|
          held = (0...w.n).flat_map { w.send(:critical_places, _1) }
          weights = { lock: 1 }.merge(held.to_h { [_1, 1] })
          label = "#{name} #{w.ops.join('+')}"
          assert_empty INV.locality_violations(w.net) { owner(_1) }, label
          assert_empty INV.invariant_violations(w.net, weights), "#{label}: lock + holders = 1"
          next unless lost_updates_excluded

          stream = w.net.places.keys.grep(/\As_/)
          assert_empty INV.unguarded_changes(w.net, data: stream, lock: :lock, held: held), "#{label}: only the holder appends"
        end
      end

      # H1 with with_lock: one holder at a time, and only the holder appends,
      # so an update computed under the lock is not lost, for any number.
      def test_h1_with_lock_holds_for_any_number_of_writers
        check_writers_net("H1 Hijack, ES-Sync, with_lock", lost_updates_excluded: true)
      end

      # H1 without with_lock: mutual exclusion at the append for any number
      # (Theorem 5); the read before the lock is the application's, as in
      # plain Active Record, so no lost-update claim.
      def test_h1_lock_at_the_append_holds_for_any_number_of_writers
        check_writers_net("H1 Hijack, ES-Sync", lost_updates_excluded: false)
        check_writers_net("H1 ES-Async, ES-Lazy", lost_updates_excluded: false)
      end

      # ES-Lazy's design c: the row lock has one holder at a time, the catch-up
      # lock is never held across steps, and only the row lock's holder, or a
      # writer taking the free lock at its append, changes the log.
      def test_lazy_design_c_holds_for_any_number_of_writers
        WRITERS.each do |n|
          [%i[with_lock] * n, %i[plain] * n, (%i[with_lock] * n).tap { _1[-1] = :plain }].uniq.each do |locking|
            net = LazyCatchUpNet.new(LazyCatchUpNet::Config.new(name: "c", design: :own_transaction, locking: locking))
            held = locking.each_with_index.flat_map do |kind, i|
              next [] unless kind == :with_lock

              net.net.places.keys.select { _1.to_s.match?(/\Aw#{i}_(locked|caught|read_x_\d+)\z/) }
            end
            label = "design c #{locking.join('+')}"
            assert_empty INV.locality_violations(net.net) { owner(_1) }, label
            assert_empty INV.invariant_violations(net.net, { x: 1 }.merge(held.to_h { [_1, 1] })), "#{label}: x + holders = 1"
            assert_empty INV.invariant_violations(net.net, { g: 1 }), "#{label}: the catch-up lock is never held across steps"
            log = net.net.places.keys.grep(/\Al\d+\z/)
            assert_empty INV.unguarded_changes(net.net, data: log, lock: :x, held: held), "#{label}: only the holder commits"
          end
        end
      end

      # The checks find what they look for: 1.0.0's ES-Lazy holds the catch-up
      # lock across steps (to the reader's commit), the invariant that design c
      # keeps.
      def test_the_checks_see_1_0_0s_catch_up_lock_held_across_steps
        net = LazyCatchUpNet.new(LazyCatchUpNet::Config.new(name: "1.0.0", design: :in_transaction, locking: %i[with_lock plain]))
        refute_empty INV.invariant_violations(net.net, { g: 1 })
      end
    end
  end
end
