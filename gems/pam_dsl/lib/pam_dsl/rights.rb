# frozen_string_literal: true

require "securerandom"
require "date"

module PamDsl
  # Restriction of processing (Art. 18) and the right to object (Art. 21) at
  # run time.
  #
  # The rights belong to the data subject, not to a policy: PamDsl.rights
  # records each request, notice, decision and lift as an Event in
  # PamDsl.rights_store (see RightsStore for the protocol), and a request's
  # current state is computed from its events (Rights.project), which refuses
  # a transition the rights do not allow. Condition 6 of Def. 1
  # (Rights.violations_for, called by Policy#validate_access!) refuses an
  # access that a subject's request in force covers.
  #
  # PAM records the controller's decisions; it does not weigh grounds, verify
  # accuracy or tell anyone anything. PamDsl.on_rights_event lets the
  # application notify the subject or the recipients (Art. 19).
  module Rights
    # The grounds of Art. 18(1). Only object! creates :objection_pending.
    RESTRICTION_GROUNDS = {
      accuracy_contested: "Art. 18(1)(a)",
      unlawful_erasure_opposed: "Art. 18(1)(b)",
      needed_for_legal_claims: "Art. 18(1)(c)",
      objection_pending: "Art. 18(1)(d)"
    }.freeze

    # The grounds on which a controller may override an objection, by the
    # article the objection was made under. Art. 21(2) objections are never
    # weighed: they are upheld at once (Art. 21(3)). An Art. 21(6) objection
    # has none: Art. 21(6) yields only to a task carried out in the public
    # interest, and a purpose open to the objection is one its policy declares
    # not to be such a task (research_or_statistics! public_interest_task: false).
    OVERRIDING_GROUNDS = {
      "Art. 21(1)" => %i[compelling_legitimate_grounds legal_claims],
      "Art. 21(6)" => []
    }.freeze

    EVENT_TYPES = %w[
      ProcessingRestricted RestrictionLiftNotified RestrictionLifted
      ObjectionReceived ObjectionUpheld ObjectionOverridden ObjectionRejected ObjectionWithdrawn
    ].freeze

    # One recorded step. +at+ is when it happened (for a request, when the
    # subject asked: the month of Art. 12(3) runs from it); +recorded_at+ is
    # when it was recorded. Both are Time objects (a store that serialises
    # events returns them as Time). +data+ holds names, grounds and the
    # controller's reasons, never personal data values: symbol keys, and
    # values that are symbols, strings, Times or arrays of them.
    Event = Data.define(:type, :request_id, :subject_key, :data, :at, :recorded_at, :recorded_by)

    # A restriction (Art. 18(1)). States: :active, then :lift_notified (the
    # Art. 18(3) notice), then :lifted. Fields empty means all of the subject's
    # data. A restriction with an objection_id is the 18(1)(d) restriction an
    # objection created: it covers the objected purpose only, and ends with
    # the decision on the objection.
    Restriction = Struct.new(
      :id, :subject_key, :ground, :fields, :policy, :purpose, :objection_id, :recipients,
      :requested_at, :recorded_at, :recorded_by, :state,
      :lift_notified_at, :lift_notified_by, :lifted_at, :lifted_by, :lift_reason, :history,
      keyword_init: true
    ) do
      def kind = :restriction
      def article = RESTRICTION_GROUNDS[ground]
      def in_force? = state != :lifted
      def open? = in_force?
      def age(now = Time.now) = now - requested_at

      # Does it cover an access by (policy, purpose) to these fields?
      def covers?(policy_name, purpose_name, field_names)
        if objection_id
          policy.to_s == policy_name.to_s && purpose.to_s == purpose_name.to_s
        else
          fields.empty? || fields.intersect?(field_names)
        end
      end
    end

    # An objection (Art. 21) to one purpose of one policy (+policy+ and
    # +purpose+ name the one objected to). States: :pending, then :upheld,
    # :overridden or :withdrawn (an upheld one can be withdrawn too);
    # :rejected when no right to object applies. +grounds+ are the subject's;
    # +decision_grounds+ and +reason+ the controller's. A pending objection's
    # 18(1)(d) restriction is +restriction_id+.
    Objection = Struct.new(
      :id, :subject_key, :policy, :purpose, :article, :grounds, :requested_at, :recorded_at, :recorded_by,
      :state, :restriction_id, :decided_at, :decided_by, :decision_grounds, :reason, :notified_at,
      :withdrawn_at, :rejection_reason, :history,
      keyword_init: true
    ) do
      def kind = :objection
      def in_force? = %i[pending upheld].include?(state)
      def open? = state == :pending
      def age(now = Time.now) = now - requested_at
      def direct_marketing? = article == "Art. 21(2)"

      # Does it stop processing for this purpose (a PamDsl::Purpose) of this
      # policy? An upheld objection to direct marketing stops every purpose
      # marked direct_marketing!, in every policy (Art. 21(3)); any other
      # upheld objection stops the purpose objected to.
      def blocks?(policy_name, purpose)
        return false unless state == :upheld
        return purpose.direct_marketing? if direct_marketing?

        policy.to_s == policy_name.to_s && self.purpose.to_s == purpose.name.to_s
      end
    end

    # A subject's rights: every request with its history, and every event.
    SubjectState = Struct.new(:subject_key, :restrictions, :objections, :events, keyword_init: true)

    class << self
      # Fold a subject's events into its requests, in the order they were
      # made. Raises RightsTransitionError for a step the rights do not allow
      # (a lift without the Art. 18(3) notice, a decision on a decided
      # objection, a step for an unknown request, an unknown event type), so a
      # store that projects before it stores cannot be made to skip one.
      def project(events)
        requests = {}
        events.each do |event|
          request = apply(requests, event)
          request.history << event
        end
        requests.each_value { |request| request.history.freeze }.values.each(&:freeze)
      end

      # The key a request is recorded under: the first of PamDsl.subject_keys
      # (with Lyra's resolver, a record's own key). Raises ArgumentError when
      # the subject names no one.
      def subject_key!(subject)
        key = PamDsl.subject_keys(subject).first
        return key if key

        raise ArgumentError, "A right is exercised by one data subject: #{subject.inspect} names none"
      end

      # The keys of a subject when no resolver answers for it: a non-empty
      # String, Symbol or Integer is its own key; nil and a model-wide
      # subject ("Model$*") have none. Anything else raises ArgumentError,
      # so that a right is never recorded, or looked up, under a key that
      # matches nothing (install PamDsl.subject_key_resolver for records).
      def default_subject_keys(subject)
        return [] if subject.nil?
        unless subject.is_a?(String) || subject.is_a?(Symbol) || subject.is_a?(Integer)
          raise ArgumentError, "Without PamDsl.subject_key_resolver a data subject is a String, Symbol or Integer " \
                               "key, not #{subject.class}"
        end

        key = subject.to_s
        raise ArgumentError, "A data subject key cannot be blank" if key.strip.empty?

        key.end_with?("$*") ? [] : [key]
      end

      # A time argument: a Time (ActiveSupport::TimeWithZone counts as one),
      # or a DateTime, returned as a Time; nil gives +default+. A Date, a
      # String or a number raises ArgumentError.
      def time!(value, name, default: nil)
        return default if value.nil?
        return value.to_time if value.is_a?(DateTime)
        return value if value.is_a?(Time)

        raise ArgumentError, "#{name} must be a Time (or DateTime), not #{value.inspect}"
      end

      # Condition 6 of Def. 1, for an access with a subject: an upheld
      # objection that covers this purpose gives ObjectedProcessingError; a
      # restriction in force that covers the access, unless the purpose
      # declares an Art. 18(2) exception that applies, gives
      # RestrictedProcessingError.
      #
      # The subject's keys are resolved (which may cost the host a read, a
      # record's links to its people) only when a request in force could
      # cover this access at all: an upheld objection that blocks the
      # purpose, or a restriction that covers it and that no exception of the
      # purpose other than :consent admits.
      def violations_for(policy, purpose, field_names, subject)
        store = PamDsl.rights_store
        return [] unless store.any_active?

        fields = Array(field_names).map(&:to_sym)
        return [] unless could_apply?(store, policy, purpose, fields)

        keys = PamDsl.subject_keys(subject)
        return [] if keys.empty?

        in_force = store.active_for(keys)
        return [] if in_force.empty?

        violations_among(in_force, policy, purpose, fields, subject)
      end

      # Condition 6 over +in_force+, the requests in force of one subject
      # (+subject+ is asked for the :consent exception): the errors, as
      # violations_for gives them. For a host that already holds the
      # requests (Lyra, deciding whom a model-wide query leaves out).
      def violations_among(in_force, policy, purpose, fields, subject)
        objected = in_force.select { |r| r.kind == :objection && r.blocks?(policy.name, purpose) }
        consent_refusals = []
        restricted = in_force.select do |r|
          r.kind == :restriction && r.covers?(policy.name, purpose.name, fields) &&
            !excepted?(r, policy, purpose, subject, consent_refusals)
        end
        objected.map { |o| objected_error(o, policy, purpose) } +
          restricted.map { |r| restricted_error(r, purpose, fields) } + consent_refusals.uniq(&:message)
      end

      # Could any request in force cover an access by (policy, purpose) to
      # +fields+, whoever its subject? A store answering in_force_requests
      # (Lyra's: its snapshot) is asked that; any other, active.
      def could_apply?(store, policy, purpose, fields)
        applicable(in_force_requests(store), policy, purpose, fields).any?
      end

      # The requests in force, from the cheapest source the store has.
      def in_force_requests(store)
        store.respond_to?(:in_force_requests) ? store.in_force_requests : store.active
      end

      # The requests of +requests+ that could cover an access by (policy,
      # purpose) to +fields+, whoever their subject: an upheld objection
      # that blocks the purpose, or a restriction that covers the access and
      # that no exception of the purpose other than :consent admits.
      def applicable(requests, policy, purpose, fields)
        excepted = purpose.restriction_exceptions.any? { |exception| exception != :consent }
        requests.select do |request|
          if request.kind == :objection
            request.blocks?(policy.name, purpose)
          else
            !excepted && request.covers?(policy.name, purpose.name, fields)
          end
        end
      end

      # Why a purpose gives no right to object, in the words of the Regulation.
      def not_objectable_reason(purpose)
        if purpose.research_or_statistics?
          return "the purpose is research or statistics necessary for the performance of a task carried out " \
                 "for reasons of public interest (Art. 21(6))"
        end

        case purpose.legal_basis
        when :consent
          "the basis is consent (Art. 6(1)(a)), which the right to object does not cover: " \
            "the subject can withdraw consent instead (Art. 7(3))"
        when :contract then basis_reason("contract", "b")
        when :legal_obligation then basis_reason("legal obligation", "c")
        when :vital_interests then basis_reason("vital interests", "d")
        else "the purpose has no legal basis yet (the controller decides one)"
        end
      end

      # The recipients the registered policies declare for the purposes that
      # use these fields (all purposes when none are given): whom Art. 19 says
      # to tell of a restriction. PAM does not tell them.
      def recipients_for(fields)
        PamDsl.registry.all.flat_map do |policy|
          policy.purposes.values.select { |purpose|
            fields.empty? || fields.any? { |f| policy.allowed?(f, purpose.name) }
          }.flat_map(&:recipients)
        end.uniq
      end

      # The event that lifts a restriction (used by Ledger; public for stores
      # and tests).
      def lift_event(restriction, reason:, at:, by:)
        build_event("RestrictionLifted", restriction.id, restriction.subject_key, { reason: reason }, at: at, by: by)
      end

      # An event recorded now; +at+ (a Time, see time!) defaults to now.
      def build_event(type, request_id, subject_key, data, at:, by:)
        now = Time.now
        Event.new(type: type, request_id: request_id, subject_key: subject_key, data: data.freeze,
                  at: time!(at, "at", default: now), recorded_at: now, recorded_by: by)
      end

      private

      def apply(requests, event)
        data = event.data
        case event.type
        when "ProcessingRestricted"
          refuse_known!(requests, event)
          if data[:objection_id]
            objection = fetch(requests, event, Objection, id: data[:objection_id])
            illegal!(event, "its objection is #{objection.state}") unless objection.state == :pending
          end
          requests[event.request_id] = Restriction.new(
            id: event.request_id, subject_key: event.subject_key, ground: data[:ground]&.to_sym,
            fields: Array(data[:fields]).map(&:to_sym), policy: data[:policy], purpose: data[:purpose],
            objection_id: data[:objection_id], recipients: Array(data[:recipients]),
            requested_at: event.at, recorded_at: event.recorded_at, recorded_by: event.recorded_by,
            state: :active, history: []
          )
        when "RestrictionLiftNotified"
          fetch(requests, event, Restriction).tap do |r|
            illegal!(event, "the restriction is #{r.state}") unless r.state == :active
            if r.objection_id && requests[r.objection_id]&.state != :overridden
              illegal!(event, "an Art. 18(1)(d) restriction ends with the decision on its objection")
            end
            r.state = :lift_notified
            r.lift_notified_at = event.at
            r.lift_notified_by = event.recorded_by
          end
        when "RestrictionLifted"
          fetch(requests, event, Restriction).tap do |r|
            ended_by_decision = r.state == :active && r.objection_id &&
                                %i[upheld withdrawn].include?(requests[r.objection_id]&.state)
            unless r.state == :lift_notified || ended_by_decision
              illegal!(event, "the restriction is #{r.state}: the subject is told before it is lifted (Art. 18(3))")
            end
            r.state = :lifted
            r.lifted_at = event.at
            r.lifted_by = event.recorded_by
            r.lift_reason = data[:reason]
          end
        when "ObjectionReceived"
          refuse_known!(requests, event)
          requests[event.request_id] = Objection.new(
            id: event.request_id, subject_key: event.subject_key, policy: data[:policy], purpose: data[:purpose],
            article: data[:article], grounds: data[:grounds], restriction_id: data[:restriction_id],
            requested_at: event.at, recorded_at: event.recorded_at, recorded_by: event.recorded_by,
            state: :pending, history: []
          )
        when "ObjectionUpheld", "ObjectionOverridden"
          fetch(requests, event, Objection).tap do |o|
            illegal!(event, "the objection is #{o.state}") unless o.state == :pending
            refuse_without_restriction!(requests, event, o)
            o.state = event.type == "ObjectionUpheld" ? :upheld : :overridden
            o.decided_at = event.at
            o.decided_by = event.recorded_by
            o.decision_grounds = data[:grounds]
            o.reason = data[:reason]
            o.notified_at = data[:notified_at]
          end
        when "ObjectionRejected"
          fetch(requests, event, Objection).tap do |o|
            illegal!(event, "the objection is #{o.state}") unless o.state == :pending
            o.state = :rejected
            o.decided_at = event.at
            o.rejection_reason = data[:reason]
          end
        when "ObjectionWithdrawn"
          fetch(requests, event, Objection).tap do |o|
            illegal!(event, "the objection is #{o.state}") unless o.in_force?
            refuse_without_restriction!(requests, event, o)
            o.state = :withdrawn
            o.withdrawn_at = event.at
          end
        else
          illegal!(event, "it is not a rights event (#{EVENT_TYPES.join(', ')})")
        end
      end

      def fetch(requests, event, kind, id: event.request_id)
        request = requests[id]
        return request if request.is_a?(kind)

        illegal!(event, "no #{kind.name.split('::').last.downcase} #{id.inspect} precedes it")
      end

      # An objection received with an Art. 18(1)(d) restriction is decided or
      # withdrawn only once that restriction is recorded (the ledger appends
      # both at once; a store's direct append cannot skip it).
      def refuse_without_restriction!(requests, event, objection)
        return unless objection.restriction_id && !requests[objection.restriction_id]

        illegal!(event, "its Art. 18(1)(d) restriction #{objection.restriction_id} is not recorded")
      end

      def refuse_known!(requests, event)
        illegal!(event, "request #{event.request_id} is already recorded") if requests.key?(event.request_id)
      end

      def illegal!(event, why)
        raise RightsTransitionError, "#{event.type} for #{event.subject_key} cannot be recorded: #{why}"
      end

      # An Art. 18(2) exception the purpose declares, that this restriction admits.
      # :consent needs an active consent for (purpose, subject) granted
      # at or after the time the restriction was requested: a consent from before was
      # not given in view of it.
      # A consent store that cannot answer for this subject raises
      # ConsentRequiredError (Lyra's, for a record shared by several people):
      # the exception does not apply, and the refusal joins the violations.
      def excepted?(restriction, policy, purpose, subject, consent_refusals = [])
        purpose.restriction_exceptions.any? do |exception|
          next true unless exception == :consent

          begin
            record = policy.consent_policy.store.record_for(purpose.name, subject)
          rescue ConsentRequiredError => e
            consent_refusals << e
            next false
          end
          record&.granted? && record.granted_at && record.granted_at >= restriction.requested_at
        end
      end

      def restricted_error(restriction, purpose, fields)
        what = if restriction.objection_id
                 "for purpose '#{purpose.name}' while the subject's objection #{restriction.objection_id} is pending"
               elsif restriction.fields.empty?
                 "for all of the subject's data"
               else
                 "for fields #{(restriction.fields & fields).join(', ')}"
               end
        RestrictedProcessingError.new(
          "Processing of subject #{restriction.subject_key} is restricted #{what} " \
          "(#{restriction.article}, #{restriction.ground}; restriction #{restriction.id}), and purpose " \
          "'#{purpose.name}' declares no Art. 18(2) exception that applies"
        )
      end

      def objected_error(objection, policy, purpose)
        what = if objection.direct_marketing?
                 "to direct marketing (purpose '#{objection.purpose}' of policy '#{objection.policy}', Art. 21(2)), " \
                 "which stops every direct-marketing purpose, '#{purpose.name}' of policy '#{policy.name}' included " \
                 "(Art. 21(3))"
               else
                 "to purpose '#{purpose.name}' of policy '#{objection.policy}' (#{objection.article})"
               end
        ObjectedProcessingError.new(
          "Subject #{objection.subject_key} objected #{what}, and the objection was upheld (objection #{objection.id})"
        )
      end

      def basis_reason(name, letter)
        "the basis is #{name} (Art. 6(1)(#{letter})); the right to object covers Art. 6(1)(e) and (f), " \
          "direct marketing and research or statistics"
      end
    end

    # The rights API, PamDsl.rights. Every method records through
    # PamDsl.rights_store, so it works the same whichever store is installed.
    class Ledger
      # How often object! re-reads after another process recorded first.
      OBJECTION_ATTEMPTS = 3

      def store
        PamDsl.rights_store
      end

      # Restrict the processing of a subject's data (Art. 18(1)(a)-(c)), all
      # of it or only +fields+ (names a registered policy declares).
      # +requested_at+ is when the subject asked (a Time, not in the future;
      # default: now). Returns the Restriction.
      def restrict!(subject:, ground:, fields: nil, requested_at: nil, recorded_by: nil)
        ground = symbol!(ground, "ground")
        if ground == :objection_pending
          raise ArgumentError, "An Art. 18(1)(d) restriction is created by object!, not by restrict!"
        end
        unless RESTRICTION_GROUNDS.key?(ground)
          raise ArgumentError, "Invalid Art. 18(1) ground #{ground.inspect}. Must be one of " \
                               "#{(RESTRICTION_GROUNDS.keys - [:objection_pending]).join(', ')}"
        end

        key = Rights.subject_key!(subject)
        fields = declared_fields!(fields)
        requested_at = requested_at!(requested_at)
        event = Rights.build_event("ProcessingRestricted", SecureRandom.uuid, key,
                                   { ground: ground, fields: fields, recipients: Rights.recipients_for(fields) },
                                   at: requested_at, by: recorded_by)
        commit(key, store.events_for(key).size, [event])
        find_in(key, event.request_id)
      end

      # Record that the subject was told the restriction will be lifted
      # (Art. 18(3)). Processing stays restricted until lift!.
      def notify_lift!(id, at: nil, by: nil)
        key, version, restriction = load(id, Restriction)
        refuse_objection_restriction!(restriction)
        unless restriction.state == :active
          raise RightsTransitionError, "Restriction #{id} is #{restriction.state}: no notice to record"
        end

        at = not_before!(Rights.time!(at, "at", default: Time.now), restriction.requested_at, "the request")
        commit(key, version, [Rights.build_event("RestrictionLiftNotified", id, key, {}, at: at, by: by)])
        find_in(key, id)
      end

      # Lift a restriction. Refused unless the notice of Art. 18(3) is
      # recorded, and not dated before that notice.
      def lift!(id, reason:, at: nil, by: nil)
        key, version, restriction = load(id, Restriction)
        refuse_objection_restriction!(restriction)
        case restriction.state
        when :active
          raise RightsTransitionError, "Restriction #{id} cannot be lifted before the subject is told " \
                                       "(Art. 18(3)): record the notice with notify_lift! first"
        when :lifted
          raise RightsTransitionError, "Restriction #{id} is already lifted"
        end

        at = not_before!(Rights.time!(at, "at", default: Time.now), restriction.lift_notified_at, "the notice")
        commit(key, version, [Rights.lift_event(restriction, reason: reason, at: at, by: by)])
        find_in(key, id)
      end

      # Record an objection to one purpose of one policy (its name). Direct
      # marketing (Art. 21(2)) is upheld at once. An Art. 21(1) or 21(6)
      # objection is pending, and restricts that purpose only (Art. 18(1)(d))
      # until decide!. A purpose with no right to object records the
      # rejection and raises ObjectionNotApplicableError, whose message is
      # the reason to give.
      #
      # Idempotent while an objection is in force: objecting again to the
      # same purpose of the same policy (or, once direct marketing is
      # objected to, to any direct-marketing purpose) returns the objection
      # already recorded and records nothing, so a retry is safe.
      def object!(subject:, policy:, purpose:, grounds: nil, requested_at: nil, recorded_by: nil)
        if policy.is_a?(Policy)
          raise ArgumentError, "policy: is the policy's name (#{policy.name.inspect}), not the Policy object"
        end
        unless grounds.nil? || grounds.is_a?(String)
          raise ArgumentError, "grounds: are the subject's words, as text (or nil), not #{grounds.class}"
        end

        policy = PamDsl.policy(policy)
        purpose = policy.get_purpose(purpose)
        key = Rights.subject_key!(subject)
        requested_at = requested_at!(requested_at)
        attempts = 0
        begin
          events = store.events_for(key)
          existing = Rights.project(events).find { |r| r.kind == :objection && same_objection?(r, policy, purpose) }
          return existing if existing

          record_objection(key, events.size, policy, purpose, grounds, requested_at, recorded_by)
        rescue RightsConcurrencyError
          attempts += 1
          retry if attempts < OBJECTION_ATTEMPTS
          raise
        end
      end

      # Decide a pending objection: :upheld (the purpose stops for this
      # subject) or :overridden, with the controller's +grounds+ (see
      # OVERRIDING_GROUNDS), a +reason+ in text and +notified_at+, the Time
      # the subject was told (Art. 18(3): the 18(1)(d) restriction is lifted),
      # not after the decision (+at+, default now) and not before the request.
      def decide!(id, outcome:, grounds: nil, reason: nil, by: nil, at: nil, notified_at: nil)
        outcome = symbol!(outcome, "outcome")
        raise ArgumentError, "outcome: must be :upheld or :overridden" unless %i[upheld overridden].include?(outcome)

        key, version, objection = load(id, Objection)
        raise RightsTransitionError, "Objection #{id} is #{objection.state}: only a pending one is decided" unless objection.state == :pending

        at = not_before!(Rights.time!(at, "at", default: Time.now), objection.requested_at, "the request")
        restriction = find_in(key, objection.restriction_id)
        events = if outcome == :upheld
                   [Rights.build_event("ObjectionUpheld", id, key, { grounds: grounds, reason: reason }, at: at, by: by),
                    Rights.lift_event(restriction, reason: :objection_upheld, at: at, by: by)]
                 else
                   grounds, notified_at = validate_override!(objection, grounds, reason, notified_at, at)
                   [Rights.build_event("ObjectionOverridden", id, key,
                                       { grounds: grounds, reason: reason, notified_at: notified_at },
                                       at: at, by: by),
                    Rights.build_event("RestrictionLiftNotified", restriction.id, key, {}, at: notified_at, by: by),
                    Rights.lift_event(restriction, reason: :objection_overridden, at: at, by: by)]
                 end
        commit(key, version, events)
        find_in(key, id)
      end

      # The subject withdraws an objection, pending or upheld. A pending one's
      # 18(1)(d) restriction ends with it.
      def withdraw_objection!(id, at: nil, by: nil)
        key, version, objection = load(id, Objection)
        unless objection.in_force?
          raise RightsTransitionError, "Objection #{id} is #{objection.state}: there is nothing to withdraw"
        end

        at = not_before!(Rights.time!(at, "at", default: Time.now), objection.requested_at, "the request")
        events = [Rights.build_event("ObjectionWithdrawn", id, key, {}, at: at, by: by)]
        if objection.state == :pending
          events << Rights.lift_event(find_in(key, objection.restriction_id), reason: :objection_withdrawn, at: at, by: by)
        end
        commit(key, version, events)
        find_in(key, id)
      end

      # A request by id, or nil.
      def find(id)
        key = store.subject_key_for(id)
        key && find_in(key, id)
      end

      # A subject's restrictions and objections, with their histories.
      def state(subject)
        key = Rights.subject_key!(subject)
        events = store.events_for(key)
        requests = Rights.project(events)
        SubjectState.new(subject_key: key, restrictions: requests.select { |r| r.kind == :restriction },
                         objections: requests.select { |r| r.kind == :objection }, events: events)
      end

      # Restrictions not yet lifted and objections not yet decided, oldest
      # request first: each answers age (Art. 12(3) gives a month). A pending
      # objection is listed once; its 18(1)(d) restriction is its
      # restriction_id, not a request of its own.
      def open_requests
        store.active.select(&:open?)
             .reject { |r| r.kind == :restriction && r.objection_id }
             .sort_by(&:requested_at)
      end

      # The requests in force for these subject keys.
      def active_for(keys)
        store.active_for(Array(keys))
      end

      # The requests recorded under these subject keys, for the subject's
      # copy (Art. 15): { restrictions: [...], objections: [...] }, each
      # request a Hash of what the subject is told of it, oldest first. The
      # 18(1)(d) restriction of an objection is part of the objection, not a
      # request of its own. Who recorded or decided a request is left out:
      # those are the controller's staff, whom the copy names only when the
      # controller decides to. The reasons are the controller's words, as
      # recorded (they should hold no personal data).
      def export(keys)
        requests = Array(keys).map(&:to_s).uniq.flat_map { |key| Rights.project(store.events_for(key)) }
                              .sort_by(&:requested_at)
        restrictions = requests.select { |r| r.kind == :restriction && r.objection_id.nil? }
        objections = requests.select { |r| r.kind == :objection }
        { restrictions: restrictions.map { |r| restriction_entry(r) },
          objections: objections.map { |o| objection_entry(o) } }
      end

      private

      def restriction_entry(restriction)
        { id: restriction.id, subject: restriction.subject_key, ground: restriction.ground,
          article: restriction.article, fields: restriction.fields, state: restriction.state,
          requested_at: restriction.requested_at, lift_notified_at: restriction.lift_notified_at,
          lifted_at: restriction.lifted_at, lift_reason: restriction.lift_reason }
      end

      def objection_entry(objection)
        { id: objection.id, subject: objection.subject_key, policy: objection.policy, purpose: objection.purpose,
          article: objection.article, state: objection.state, grounds: objection.grounds,
          requested_at: objection.requested_at, decided_at: objection.decided_at,
          decision_grounds: objection.decision_grounds, reason: objection.reason || objection.rejection_reason,
          notified_at: objection.notified_at, withdrawn_at: objection.withdrawn_at }
      end

      def record_objection(key, version, policy, purpose, grounds, requested_at, recorded_by)
        id = SecureRandom.uuid
        article = purpose.objectable
        data = { policy: policy.name, purpose: purpose.name, article: article, grounds: grounds }
        received = ->(extra = {}) { Rights.build_event("ObjectionReceived", id, key, data.merge(extra), at: requested_at, by: recorded_by) }

        if article.nil?
          reason = Rights.not_objectable_reason(purpose)
          hook_errors = commit(key, version,
                               [received.(), Rights.build_event("ObjectionRejected", id, key, { reason: reason }, at: nil, by: recorded_by)],
                               raise_hook_errors: false)
          raise ObjectionNotApplicableError.new(
            "No right to object to purpose '#{purpose.name}' of policy '#{policy.name}': #{reason}"
          ), cause: hook_errors.first
        elsif article == "Art. 21(2)"
          commit(key, version, [received.(),
                                Rights.build_event("ObjectionUpheld", id, key, { grounds: :direct_marketing }, at: nil, by: recorded_by)])
        else
          restriction_id = SecureRandom.uuid
          commit(key, version, [
            received.(restriction_id: restriction_id),
            Rights.build_event("ProcessingRestricted", restriction_id, key,
                               { ground: :objection_pending, fields: [], policy: policy.name, purpose: purpose.name,
                                 objection_id: id, recipients: purpose.recipients },
                               at: requested_at, by: recorded_by)
          ])
        end
        find_in(key, id)
      end

      # The objection in force that a new one to (policy, purpose) would repeat.
      def same_objection?(objection, policy, purpose)
        return false unless objection.in_force?
        return true if objection.direct_marketing? && purpose.direct_marketing?

        objection.policy.to_s == policy.name.to_s && objection.purpose.to_s == purpose.name.to_s
      end

      def load(id, kind)
        key = store.subject_key_for(id)
        events = key ? store.events_for(key) : []
        request = Rights.project(events).find { |r| r.id == id }
        unless request.is_a?(kind)
          raise RightsTransitionError, "No #{kind.name.split('::').last.downcase} #{id.inspect} is recorded"
        end

        [key, events.size, request]
      end

      def find_in(key, id)
        Rights.project(store.events_for(key)).find { |r| r.id == id }
      end

      # Append, then hand every event to every handler. A handler that
      # raises does not stop the others: once all have run, the first error
      # is raised (the rest are logged), and the events stay recorded. With
      # raise_hook_errors: false the errors are returned instead.
      def commit(key, version, events, raise_hook_errors: true)
        refuse_unless_durable!
        store.append(events, expected_version: version)
        errors = deliver(events)
        return errors unless raise_hook_errors
        raise errors.first if errors.any?

        events
      end

      def deliver(events)
        errors = []
        events.each do |event|
          PamDsl.rights_event_handlers.each do |handler|
            handler.call(event)
          rescue StandardError => e
            errors << e
          end
        end
        errors.drop(1).each { |e| PamDsl.logger.warn("PAM rights event handler also failed: #{e.class}: #{e.message}") }
        errors
      end

      def refuse_unless_durable!
        return unless PamDsl.require_durable_rights_store && !store.durable?

        raise RightsStoreNotDurableError,
              "PamDsl.rights_store (#{store.class}) is not durable, and a durable store is required " \
              "(PamDsl.require_durable_rights_store): a restriction or objection recorded there would be lost " \
              "on restart or unseen by other processes. Install a durable store (Lyra installs its own)."
      end

      def refuse_objection_restriction!(restriction)
        return unless restriction.objection_id

        raise RightsTransitionError, "Restriction #{restriction.id} is the Art. 18(1)(d) restriction of objection " \
                                     "#{restriction.objection_id}: it ends with the decision on the objection (decide!)"
      end

      def requested_at!(requested_at)
        now = Time.now
        requested_at = Rights.time!(requested_at, "requested_at", default: now)
        raise ArgumentError, "requested_at (#{requested_at}) is in the future" if requested_at > now

        requested_at
      end

      def not_before!(time, earlier, what)
        raise ArgumentError, "#{time} is before #{what} (#{earlier})" if earlier && time < earlier

        time
      end

      def symbol!(value, name)
        return value.to_sym if value.is_a?(Symbol) || (value.is_a?(String) && !value.strip.empty?)

        raise ArgumentError, "#{name}: must be a symbol, not #{value.inspect}"
      end

      def declared_fields!(fields)
        fields = Array(fields).map { |f| symbol!(f, "fields") }.uniq
        declared = PamDsl.registry.all.flat_map { |policy| policy.fields.keys }
        unknown = fields - declared
        return fields if unknown.empty?

        raise ArgumentError, "No registered policy declares the field#{'s' if unknown.size > 1} #{unknown.join(', ')}"
      end

      def validate_override!(objection, grounds, reason, notified_at, at)
        allowed = OVERRIDING_GROUNDS.fetch(objection.article, [])
        if allowed.empty?
          raise ArgumentError, "An #{objection.article} objection cannot be overridden: its purpose is declared " \
                               "research not necessary for a task in the public interest " \
                               "(research_or_statistics! public_interest_task: false). Uphold it, or correct the declaration"
        end
        grounds = symbol!(grounds, "grounds") unless grounds.nil?
        unless allowed.include?(grounds)
          raise ArgumentError, "An #{objection.article} objection is overridden on #{allowed.join(' or ')}, " \
                               "not #{grounds.inspect}"
        end
        raise ArgumentError, "An override needs reason: in text" unless reason.is_a?(String) && !reason.strip.empty?
        if notified_at.nil?
          raise ArgumentError, "An override lifts the Art. 18(1)(d) restriction: record when the subject was told " \
                               "(notified_at:, Art. 18(3))"
        end

        notified_at = not_before!(Rights.time!(notified_at, "notified_at"), objection.requested_at, "the request")
        raise ArgumentError, "notified_at (#{notified_at}) is after the decision (#{at})" if notified_at > at

        [grounds, notified_at]
      end
    end
  end
end
