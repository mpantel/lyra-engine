# frozen_string_literal: true

module Lyra
  # Records every access the privacy policy validates (PAM's
  # validate_access!) as an event, when config.record_access_events is on:
  # who accessed which declared attributes of which subject, for which
  # purpose under which legal basis, and whether it was granted.
  #
  # - DataAccessed: the access went ahead, outcome "granted", or "audited"
  #   when audit mode let it through despite violations (listed).
  # - DataAccessDenied: strict mode refused it (violations listed).
  #
  # Each goes to the subject's access stream, Lyra::DataAccess$<subject>
  # (Lyra::DataAccess$Registration$5 for a record), never to the record's
  # own stream, so replay, DualView and mode transitions do not see it.
  # Field names only, never values.
  #
  # Every access is recorded, with no sampling. An access that cannot be
  # recorded does not go ahead: the store's error propagates from
  # validate_access!. Off by default, and nothing is recorded in disabled
  # mode: reads can outnumber writes by orders of magnitude, so its cost is
  # measured separately (LYRA_RECORD_ACCESS=1 in the Aegean testbed).
  #
  # The Article 30 record of processing does not depend on it: PAM's
  # reporter generates that from the declared policy. The access log is
  # the evidence of what was actually accessed.
  module AccessLog
    STREAM = "Lyra::DataAccess"

    class << self
      # PamDsl.access_recorder protocol.
      def record?(_policy)
        Lyra.config.record_access_events && !Lyra.config.disabled_mode?
      end

      def call(access)
        event_class = access.outcome == :denied ? Lyra::Events::DataAccessDenied : Lyra::Events::DataAccessed
        subject = subject_key(access.subject)
        event = event_class.new(data: data_for(access, subject), metadata: metadata)
        Lyra.config.event_store.publish(event, stream_name: stream_for(subject))
      end

      def stream_for(subject)
        subject ? "#{STREAM}$#{subject}" : STREAM
      end

      # "Registration$5" for a record, the value itself for an id.
      def subject_key(subject)
        case subject
        when nil then nil
        when ActiveRecord::Base then "#{subject.class.name}$#{subject.id}"
        else subject.to_s
        end
      end

      # The accesses recorded for +subject+ (a record or an id), oldest first.
      def for(subject)
        Lyra.config.event_store.read.stream(stream_for(subject_key(subject))).to_a
      end

      private

      def data_for(access, subject)
        data = {
          policy: access.policy.to_s,
          purpose: access.purpose.to_s,
          legal_basis: access.legal_basis&.to_s,
          fields: access.fields.map(&:to_s),
          subject: subject,
          outcome: access.outcome.to_s,
          accessed_at: access.at
        }
        if access.violations.any?
          data[:violations] = access.violations.map { |error| { error: error.class.name, message: error.message } }
        end
        data
      end

      def metadata
        {
          user_id: defined?(Current) && Current.respond_to?(:user) ? Current.user&.id : nil,
          request_id: defined?(Current) && Current.respond_to?(:request_id) ? Current.request_id : nil,
          correlation_id: Lyra::Correlation.current_id,
          causation_id: Lyra::Causation.current_id,
          source: "lyra_access_log"
        }.compact
      end
    end
  end

  module Events
    class DataAccessed < Lyra::Event; end
    class DataAccessDenied < Lyra::Event; end
  end
end

PamDsl.access_recorder = Lyra::AccessLog if defined?(PamDsl) && PamDsl.respond_to?(:access_recorder=)
