# frozen_string_literal: true

module PetriFlow
  module Verification
    # Invariant checker for Petri nets
    # Verifies properties that should hold across all reachable states
    class InvariantChecker
      attr_reader :net, :reachability_analyzer, :invariants

      def initialize(net, reachability_analyzer = nil)
        @net = net
        @reachability_analyzer = reachability_analyzer ||
                                 ReachabilityAnalyzer.new(net)
        @invariants = []
      end

      # Add a custom invariant
      # @param name [String] Name of the invariant
      # @param checker [Proc] Block that takes marking and returns true/false
      def add_invariant(name, &checker)
        @invariants << { name: name, checker: checker }
      end

      # Check all invariants across all reachable markings
      def check_all_invariants
        results = {}

        @invariants.each do |invariant|
          results[invariant[:name]] = check_invariant(invariant)
        end

        results
      end

      # Check a specific invariant
      def check_invariant(invariant)
        violations = []

        @reachability_analyzer.reachable_markings.each do |marking|
          @net.set_marking(marking)

          unless invariant[:checker].call(marking, @net)
            violations << marking.dup
          end
        end

        {
          name: invariant[:name],
          holds: violations.empty?,
          violations: violations,
          violation_count: violations.size
        }
      end

      # Common invariant: Token conservation
      # Total tokens in system remains constant
      def check_token_conservation(expected_total)
        add_invariant("Token Conservation (#{expected_total})") do |marking|
          total_tokens = marking.to_h.values.sum
          total_tokens == expected_total
        end

        check_invariant(@invariants.last)
      end

      # Common invariant: Mutual exclusion
      # At most one of specified places has token
      def check_mutual_exclusion(place_ids)
        add_invariant("Mutual Exclusion (#{place_ids.join(', ')})") do |marking|
          tokens_in_places = place_ids.sum { |pid| marking.tokens_at(pid) }
          tokens_in_places <= 1
        end

        check_invariant(@invariants.last)
      end

      # Common invariant: Place bound
      # A place never exceeds a token limit
      def check_place_bound(place_id, max_tokens)
        add_invariant("Place Bound (#{place_id} <= #{max_tokens})") do |marking|
          marking.tokens_at(place_id) <= max_tokens
        end

        check_invariant(@invariants.last)
      end

      # Check liveness invariant: no deadlocks
      def check_no_deadlocks
        add_invariant("No Deadlocks") do |_marking, net|
          !net.deadlocked?
        end

        check_invariant(@invariants.last)
      end

      # Custom invariants for Lyra CRUD-Event mapping

      # Invariant: PII always detected before storage
      def check_pii_always_detected(pii_detected_place, storage_place)
        add_invariant("PII Always Detected Before Storage") do |marking|
          # If there are tokens in storage, there must have been tokens in PII detected
          # This is a simplified check - in practice we'd track causation
          marking.tokens_at(storage_place) <= marking.tokens_at(pii_detected_place)
        end

        check_invariant(@invariants.last)
      end

      # Invariant: Event-ORM consistency
      def check_event_orm_consistency(event_place, orm_place)
        add_invariant("Event-ORM Consistency") do |marking|
          # In Monitor mode, event count should match ORM count
          marking.tokens_at(event_place) == marking.tokens_at(orm_place)
        end

        check_invariant(@invariants.last)
      end

      # Generate comprehensive invariant report
      def report
        results = check_all_invariants

        {
          total_invariants: @invariants.size,
          passed: results.count { |_, r| r[:holds] },
          failed: results.count { |_, r| !r[:holds] },
          results: results,
          summary: generate_summary(results)
        }
      end

      private

      def generate_summary(results)
        if results.all? { |_, r| r[:holds] }
          "✓ All #{results.size} invariants hold"
        else
          failed = results.select { |_, r| !r[:holds] }
          "⚠ #{failed.size} invariant(s) violated: #{failed.keys.join(', ')}"
        end
      end
    end
  end
end
