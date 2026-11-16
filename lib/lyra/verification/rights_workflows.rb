# frozen_string_literal: true

module Lyra
  module Verification
    # The data lifecycle of a personal value (the thesis's data-lifecycle
    # CPN, D_0..D_3) with the Restricted place D_R of Art. 18, as a PetriFlow
    # net. A specification checked by exploration, as the CRUD nets are, not
    # runtime machinery: the runtime is PAM DSL's PamDsl::Rights.project, and
    # a test matches its transitions against this net's.
    #
    # Places: Active (D_0), Retained (D_1), Deleted (D_2), Anonymized (D_3),
    # and D_R split by where the data came from (the token keeps its origin)
    # and by whether the Art. 18(3) notice is recorded:
    #
    #   restricted / restricted_retained          (code state :active)
    #   lift_notified / lift_notified_retained    (code state :lift_notified)
    #
    # Transitions: d1 deactivate (D_0 -> D_1), d2 delete (D_1 -> D_2), d3
    # anonymize (D_1 -> D_3), d4 erase on request (D_0 -> D_2); r1 restrict
    # (D_0 or D_1 -> D_R), the notice (D_R -> D_R notified), r2 lift (back to
    # the origin). d2, d3 and d4 are not enabled from D_R: Deleted and
    # Anonymized are reached from Restricted only through the notice and the
    # lift (Lyra::Erasure.erase!(..., lifting:) is the lift then d4).
    class DataLifecycleWorkflow < PetriFlow::Workflow
      workflow_name "Data Lifecycle with Restriction (Art. 18)"

      places :active, :retained, :deleted, :anonymized,
             :restricted, :lift_notified, :restricted_retained, :lift_notified_retained

      initial_place :active
      terminal_places :deleted, :anonymized

      transition :deactivate, from: :active, to: :retained, trigger: "d1: active use ends"
      transition :delete, from: :retained, to: :deleted, trigger: "d2: retention expired, :hard_delete"
      transition :anonymize, from: :retained, to: :anonymized, trigger: "d3: retention expired, :anonymize"
      transition :erase, from: :active, to: :deleted, trigger: "d4: Art. 17 request"

      transition :restrict, from: :active, to: :restricted, trigger: "r1: ProcessingRestricted"
      transition :restrict, from: :retained, to: :restricted_retained, trigger: "r1: ProcessingRestricted"
      transition :notify_lift, from: :restricted, to: :lift_notified, trigger: "RestrictionLiftNotified (Art. 18(3))"
      transition :notify_lift, from: :restricted_retained, to: :lift_notified_retained,
                               trigger: "RestrictionLiftNotified (Art. 18(3))"
      transition :lift, from: :lift_notified, to: :active, trigger: "r2: RestrictionLifted"
      transition :lift, from: :lift_notified_retained, to: :retained, trigger: "r2: RestrictionLifted"

      # The PAM DSL event each restriction transition records.
      EVENTS = { restrict: "ProcessingRestricted", notify_lift: "RestrictionLiftNotified",
                 lift: "RestrictionLifted" }.freeze

      # The state of the restriction (PamDsl::Rights::Restriction#state) a
      # token in a D_R place stands for.
      RESTRICTION_STATES = { restricted: :active, restricted_retained: :active, lift_notified: :lift_notified,
                             lift_notified_retained: :lift_notified }.freeze

      class << self
        # The restriction's steps the net allows, as the code's state
        # machine reads them: { [state before, event type] => state after },
        # :none before a restriction is recorded and :lifted after it ends.
        def restriction_steps
          defined_transitions.filter_map do |t|
            event = EVENTS[t[:name]]
            next unless event

            [[RESTRICTION_STATES.fetch(t[:from].first, :none), event], RESTRICTION_STATES.fetch(t[:to].first, :lifted)]
          end.to_h
        end

        # The ids of the lift transitions (r2).
        def lift_transitions
          defined_transitions.select { |t| t[:name] == :lift }.map { |t| t[:id] }
        end
      end
    end

    # An objection (Art. 21) to one purpose, as a PetriFlow net in the style
    # of the consent net: received (pending, with its Art. 18(1)(d)
    # restriction of the purpose), then upheld (the purpose stops for the
    # subject), overridden (compelling grounds, with the Art. 18(3) notice),
    # rejected (no right to object applies) or withdrawn by the subject (a
    # pending or an upheld objection). Matched against
    # PamDsl::Rights.project by a test.
    class ObjectionWorkflow < PetriFlow::Workflow
      workflow_name "Objection (Art. 21)"

      places :none, :pending, :upheld, :overridden, :rejected, :withdrawn

      initial_place :none
      terminal_places :overridden, :rejected, :withdrawn

      transition :receive, from: :none, to: :pending, trigger: "ObjectionReceived (with ProcessingRestricted, 18(1)(d))"
      transition :uphold, from: :pending, to: :upheld, trigger: "ObjectionUpheld (21(3): at once for direct marketing)"
      transition :override, from: :pending, to: :overridden, trigger: "ObjectionOverridden (21(1), notice 18(3))"
      transition :reject, from: :pending, to: :rejected, trigger: "ObjectionRejected (no right to object)"
      transition :withdraw, from: :pending, to: :withdrawn, trigger: "ObjectionWithdrawn"
      transition :withdraw, from: :upheld, to: :withdrawn, trigger: "ObjectionWithdrawn"

      EVENTS = { receive: "ObjectionReceived", uphold: "ObjectionUpheld", override: "ObjectionOverridden",
                 reject: "ObjectionRejected", withdraw: "ObjectionWithdrawn" }.freeze

      # { [state before, event type] => state after }, the places being the
      # code's objection states (:none before one is recorded).
      def self.steps
        defined_transitions.to_h { |t| [[t[:from].first, EVENTS.fetch(t[:name])], t[:to].first] }
      end
    end

    # An objection under Art. 21(1) or 21(6) together with the Art. 18(1)(d)
    # restriction it creates: two tokens, one per request, so the net shows
    # how the decision ends the restriction. Upheld or withdrawn, the
    # restriction is lifted without a notice (processing does not resume, or
    # the subject asked); overridden, only after the Art. 18(3) notice. A
    # notice before the decision is not possible.
    class ObjectionRestrictionWorkflow < PetriFlow::Workflow
      workflow_name "Objection and its Art. 18(1)(d) restriction"

      places :o_none, :o_pending, :o_upheld, :o_overridden, :o_withdrawn,
             :r_none, :r_active, :r_lift_notified, :r_lifted

      initial_place :o_none
      terminal_places :r_lifted

      transition :receive, from: :o_none, to: :o_pending, trigger: "ObjectionReceived"
      transition :restrict, from: %i[o_pending r_none], to: %i[o_pending r_active],
                            trigger: "ProcessingRestricted (objection_id)"
      transition :uphold, from: %i[o_pending r_active], to: %i[o_upheld r_active], trigger: "ObjectionUpheld"
      transition :override, from: %i[o_pending r_active], to: %i[o_overridden r_active], trigger: "ObjectionOverridden"
      transition :withdraw, from: %i[o_pending r_active], to: %i[o_withdrawn r_active], trigger: "ObjectionWithdrawn"
      transition :withdraw, from: %i[o_upheld r_active], to: %i[o_withdrawn r_active], trigger: "ObjectionWithdrawn"
      # (a name of its own: PetriFlow names a transition by its first input place)
      transition :withdraw_lifted, from: %i[o_upheld r_lifted], to: %i[o_withdrawn r_lifted], trigger: "ObjectionWithdrawn"
      transition :lift, from: %i[o_upheld r_active], to: %i[o_upheld r_lifted], trigger: "RestrictionLifted (no notice)"
      transition :lift, from: %i[o_withdrawn r_active], to: %i[o_withdrawn r_lifted], trigger: "RestrictionLifted (no notice)"
      transition :notify_lift, from: %i[o_overridden r_active], to: %i[o_overridden r_lift_notified],
                               trigger: "RestrictionLiftNotified (Art. 18(3))"
      transition :lift, from: %i[o_overridden r_lift_notified], to: %i[o_overridden r_lifted], trigger: "RestrictionLifted"

      EVENTS = { receive: "ObjectionReceived", restrict: "ProcessingRestricted", uphold: "ObjectionUpheld",
                 override: "ObjectionOverridden", withdraw: "ObjectionWithdrawn", withdraw_lifted: "ObjectionWithdrawn",
                 notify_lift: "RestrictionLiftNotified",
                 lift: "RestrictionLifted" }.freeze

      # The initial marking: no objection and no restriction yet.
      def initial_marking
        PetriFlow::Core::Marking.new(self.class.defined_places.to_h { |p| [p, %i[o_none r_none].include?(p) ? 1 : 0] })
      end

      # { [[objection state, restriction state], event type] => [states after] }
      # over the reachable markings, the code's states named as the places
      # without their prefix.
      def steps
        analyzer = PetriFlow::Verification::ReachabilityAnalyzer.new(net, initial_marking)
        analyzer.analyze
        by_key = analyzer.reachable_markings.to_h { |m| [analyzer.send(:marking_to_key, m), states_of(m)] }
        ids = self.class.defined_transitions.to_h { |t| [t[:id], EVENTS.fetch(t[:name])] }
        analyzer.state_graph.flat_map do |key, edges|
          edges.map { |transition, after| [[by_key.fetch(key), ids.fetch(transition)], by_key.fetch(after)] }
        end.to_h
      end

      private

      def states_of(marking)
        %w[o r].map do |prefix|
          place = self.class.defined_places.find { |p| p.to_s.start_with?("#{prefix}_") && marking.tokens_at(p).positive? }
          place.to_s.delete_prefix("#{prefix}_").to_sym
        end
      end
    end
  end
end
