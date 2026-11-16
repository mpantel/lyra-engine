# frozen_string_literal: true

module Lyra
  module Rights
    # Lyra::Erasure.erase! for a restricted subject (Art. 18 with Art. 17).
    #
    # A restriction asks the controller to keep the data and to process it
    # only for storage (Art. 18(2)): under Art. 18(1)(b) the subject opposed
    # erasure and asked for restriction instead, under 18(1)(c) the subject
    # needs the data for legal claims. Erasing it is processing, so erase!
    # refuses a record that a restriction in force covers: a restriction of
    # the record itself, or of a person it names (Rights::SubjectKeys), or of
    # a key passed as access_log_subjects:; for all of the subject's data, or
    # for a field being erased (+fields:+, or every personal field when none
    # are given). An objection's 18(1)(d) restriction covers one purpose and
    # does not refuse an erasure (Art. 17(1)(c) may be why the data goes).
    #
    # The refusal is a RestrictedProcessingError naming each restriction.
    # When the controller has decided to erase all the same (a later Art. 17
    # request that prevails, the claims settled), it records the Art. 18(3)
    # notice (PamDsl.rights.notify_lift!) and calls erase! with +lifting:+
    # the restriction's id, or ids: each is lifted (reason :erased, by
    # +erased_by+) and the record erased in one transaction, so a failed
    # erasure leaves the restriction in force. Lifting needs the notice, as
    # lift! does (RightsTransitionError), and names restrictions of this
    # record: any other covering restriction still refuses.
    #
    # Lyra::Erasure.erase! asks check! at its entry (with PAM DSL loaded); with
    # nothing in force that costs the store's any_active?. Lifting runs in the
    # erasure's own transaction (lift!).
    module ErasureGuard
      class << self
        # The restrictions to lift before erasing (+lifting+ among those
        # covering the record); raises RestrictedProcessingError when one
        # that covers it is not lifted, RightsTransitionError when one to lift
        # has no notice recorded.
        def check!(model, id, fields:, subjects:, lifting:)
          lifting = Array(lifting).map(&:to_s)
          return [] if lifting.empty? && !PamDsl.rights_store.any_active?

          lifted = Thread.current[:lyra_erasure_lifted] || []
          covering = covering(model, id, fields, subjects).reject { |r| lifted.include?(r.id) }
          lifts = covering.select { |r| lifting.include?(r.id) }
          refused = covering - lifts
          unless refused.empty?
            raise PamDsl::RestrictedProcessingError,
                  "#{model.name} #{id} cannot be erased: its processing is restricted " \
                  "(#{refused.map { |r| describe(r) }.join('; ')}). Erasure is processing beyond storage " \
                  "(Art. 18(2)). To erase all the same, record the Art. 18(3) notice " \
                  "(PamDsl.rights.notify_lift!) and pass lifting: the restriction's id"
          end
          unknown = lifting - lifts.map(&:id)
          if unknown.any?
            raise PamDsl::RestrictedProcessingError,
                  "lifting: #{unknown.join(', ')} is not a restriction in force on #{model.name} #{id}"
          end
          own = Lyra.stream_name(model, id)
          wider = lifts.reject { |r| r.subject_key == own }
          if wider.any?
            raise PamDsl::RestrictedProcessingError,
                  "lifting: #{wider.map(&:id).join(', ')} restricts #{wider.map(&:subject_key).uniq.join(', ')}, not only " \
                  "#{own}: erasing #{own} lifts only a restriction of that record. To make all of that subject's data " \
                  "processable again, lift it explicitly (PamDsl.rights.lift!), or erase that subject's own record " \
                  "with lifting:"
          end
          lifts.each do |r|
            next if r.state == :lift_notified

            raise PamDsl::RightsTransitionError,
                  "Restriction #{r.id} cannot be lifted for the erasure before the subject is told (Art. 18(3)): " \
                  "record the notice with PamDsl.rights.notify_lift! first"
          end
          lifts
        end

        # Lift +restrictions+ for an erasure (reason :erased), in the caller's
        # transaction.
        def lift!(restrictions, by: nil)
          restrictions.each { |restriction| PamDsl.rights.lift!(restriction.id, reason: :erased, by: by) }
        end

        # Run the erasure with +restrictions+ taken as lifted (lifted already
        # in this transaction, or, for a dry run, to be lifted): check! does
        # not refuse it for them again.
        def lifted(restrictions)
          previous = Thread.current[:lyra_erasure_lifted]
          Thread.current[:lyra_erasure_lifted] = (previous || []) + restrictions.map(&:id)
          yield
        ensure
          Thread.current[:lyra_erasure_lifted] = previous
        end

        # The restrictions in force that keep +record+ (or its +fields+;
        # nil: all of them) from being erased: Lyra::Retention skips it.
        def covering_record(record, fields: nil)
          return [] unless PamDsl.rights_store.any_active?

          select_covering(SubjectKeys.keys_for(record), fields)
        end

        def describe(restriction)
          what = restriction.fields.empty? ? "all data" : restriction.fields.join(", ")
          "#{restriction.id}: #{restriction.subject_key}, #{what}, #{restriction.article} #{restriction.ground}, " \
            "#{restriction.state}"
        end

        private

        def covering(model, id, fields, subjects)
          select_covering(keys_of(model, id) + Array(subjects).map(&:to_s), fields)
        end

        def select_covering(keys, fields)
          fields = fields && Array(fields).map(&:to_sym)
          PamDsl.rights_store.active_for(keys.uniq).select do |request|
            request.kind == :restriction && request.objection_id.nil? &&
              (request.fields.empty? || fields.nil? || request.fields.intersect?(fields))
          end
        end

        # The record's keys, from its row or its replayed state; when it has
        # neither, its people cannot be known, so the erasure is refused
        # (fail closed: a right is in force, or check! would not ask).
        def keys_of(model, id)
          record = SubjectKeys.find_record(model, id)
          return SubjectKeys.keys_for(record) if record

          raise UnresolvedSubjectError,
                "#{Lyra.stream_name(model, id)} has no row and no events to read the people it names from, so " \
                "whether a restriction covers it cannot be told; erasure refused"
        end
      end
    end
  end
end
