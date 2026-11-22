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
  # Who accessed goes in the metadata: user_id (Current.user) and
  # ip_address (Current.ip_address) when the application keeps them in
  # Current, request and correlation ids, the cause from outside every write
  # scope (a write in scope may roll back; the entry stays), and whatever
  # config.access_metadata_proc returns for the access (a console, a job,
  # an API token: anything Current does not know). Without either, an
  # access carries no user: set one.
  #
  # Every access is recorded, with no sampling, on a connection of its own
  # (Lyra::OwnConnection), so that it stays recorded when the reader's
  # transaction rolls back: the read has already returned its value by then.
  # Inside a transaction that costs a thread and a second connection per
  # access, so size the pool for it: with every thread of the application
  # (Puma's, Sidekiq's) inside a transaction, a read that finds no free
  # connection waits the pool's checkout_timeout (5 s by default) and is
  # then recorded inline, in the reader's transaction, and lost if that rolls
  # back. A pool of twice the threads avoids the wait.
  # An access that cannot be recorded does not go ahead: the store's error
  # propagates from validate_access!. Off by default, and nothing is recorded in disabled
  # mode: reads can outnumber writes by orders of magnitude, so its cost is
  # measured separately (LYRA_RECORD_ACCESS=1 in the Aegean testbed).
  #
  # The Article 30 record of processing does not depend on it: PAM's
  # reporter generates that from the declared policy. The access log is
  # the evidence of what was actually accessed.
  #
  # Erasure (from 1.0.0). A subject's log can be deleted: with the record
  # (Lyra::Erasure.erase!, config.erase_access_log or access_log: true), or
  # on its own with AccessLog.erase!, which also takes the bare ids an
  # application passes as subjects. Its events are deleted from every stream
  # they are in and from the events table, and an AccessLogErased event in
  # Lyra::AccessLogErasures records which subject, how many entries, why and
  # who. A model-wide entry (Lyra::DataAccess$<Model>$*, written by a pluck)
  # names no subject: it is the record of a read of everyone's data, and no
  # one person's erasure removes it.
  module AccessLog
    STREAM = "Lyra::DataAccess"
    ERASURES = "Lyra::AccessLogErasures"
    # Each Art. 15 export, per subject (record_export); not part of the
    # access log, so erasing the log leaves it.
    EXPORTS = "Lyra::SubjectAccessExports"
    DELETE_BATCH = 1000

    class ModelWideSubject < ArgumentError; end

    class << self
      # PamDsl.access_recorder protocol.
      def record?(_policy)
        Lyra.config.record_access_events && !Lyra.config.disabled_mode?
      end

      def call(access)
        event_class = access.outcome == :denied ? Lyra::Events::DataAccessDenied : Lyra::Events::DataAccessed
        subject = subject_key(access.subject)
        event = event_class.new(data: data_for(access, subject), metadata: metadata(access))
        # Outside a transaction this just runs; inside one it runs on a second
        # connection, so a rollback of the reader's transaction keeps the entry.
        Lyra::OwnConnection.run { Lyra.append_events(event, stream_name: stream_for(subject)) }
      end

      # A read through the dashboard (a flow or privacy route): who, which route, the
      # ids it was scoped to and how much came back. Written when
      # config.record_access_events is on, to Lyra::DataAccess$Dashboard.
      def dashboard_read(route:, scope: {}, returned: nil, truncated: nil)
        return unless record?(nil)

        data = { route: route.to_s, scope: scope.transform_values(&:to_s), returned: returned, truncated: truncated,
                 accessed_at: Time.current }.compact
        event = Lyra::Events::DashboardRead.new(data: data, metadata: metadata_for_dashboard)
        # On its own connection, as every access entry (call).
        Lyra::OwnConnection.run { Lyra.append_events(event, stream_name: stream_for("Dashboard")) }
      end

      # Records that a data subject's Art. 15 copy was made
      # (GDPRCompliance#data_export, an explicit call): a SubjectAccessExported
      # event with which sections it gave, how many records, who verified the
      # subject and who exported (the metadata, as for any access). Never a
      # value. On unless config.record_subject_access_exports is false;
      # nothing in disabled mode. Written on its own connection, as every
      # access entry.
      #
      # It goes to a stream of its own, Lyra::SubjectAccessExports$<subject>,
      # not to the subject's access stream: erasing the access log (erase!,
      # Lyra::Erasure with access_log:) deletes that stream, and the evidence
      # that a request was answered must outlive it, as the record of an
      # erasure does (Lyra::AccessLogErasures).
      def record_export(export)
        return if !Lyra.config.record_subject_access_exports || Lyra.config.disabled_mode?

        subject = subject_key_for(export[:subject_type], export[:subject_id])
        data = {
          subject: subject,
          sections: Array(export[:sections]).map(&:to_s),
          records: export[:records],
          gaps: export[:gaps],
          disclose_actors: export[:disclose_actors] ? true : false,
          verified_by: export[:verified_by]&.to_s,
          exported_at: export[:generated_at] || Time.current
        }.compact
        event = Lyra::Events::SubjectAccessExported.new(data: data, metadata: metadata_for_export)
        Lyra::OwnConnection.run { Lyra.append_events(event, stream_name: exports_stream_for(subject)) }
      end

      # The recorded exports of +subject+ (a key such as "Registration$5"),
      # oldest first.
      def exports_for(subject)
        Lyra.config.event_store.read.stream(exports_stream_for(subject)).to_a
      end

      def exports_stream_for(subject)
        "#{EXPORTS}$#{subject}"
      end

      # The access-log key of a subject given by type and id: the record's
      # ("Registration$5", the STI base class's name) when the type is a
      # model, "<type>$<id>" otherwise.
      def subject_key_for(subject_type, subject_id)
        model = subject_type.to_s.safe_constantize
        if model.is_a?(Class) && model < ActiveRecord::Base
          Lyra.stream_name(model, subject_id)
        else
          "#{subject_type}$#{subject_id}"
        end
      end

      def stream_for(subject)
        subject ? "#{STREAM}$#{subject}" : STREAM
      end

      # "Registration$5" for a record, the value itself for an id.
      def subject_key(subject)
        case subject
        when nil then nil
        when ActiveRecord::Base then Lyra.stream_name(subject.class, subject.id)
        else subject.to_s
        end
      end

      # The accesses recorded for +subject+ (a record or an id), oldest first.
      def for(subject)
        Lyra.config.event_store.read.stream(stream_for(subject_key(subject))).to_a
      end

      # Deletes +subject+'s access log (a record, or an id the application
      # passed as the subject) and records that it did, with the reason and
      # who. Returns how many entries it deleted. Refuses a model-wide key.
      def erase!(subject, reason:, erased_by: nil)
        key = erasable_key(subject)
        Lyra::PurposeBoundReads.internal(INTERNAL) do
          ActiveRecord::Base.transaction do
            entries = delete_stream!(stream_for(key))
            # Beside the claimed label, what the operating system says
            # (Lyra::Attribution), as for an ErasureApplied.
            who = { os_user: Lyra::Attribution.os_user, host: Lyra::Attribution.host, pid: Process.pid }
            erasure = Lyra::Events::AccessLogErased.new(
              data: { subject: key, entries: entries, reason: reason.to_s, erased_at: Time.current },
              metadata: { source: "lyra_access_log", erased_by: erased_by&.to_s, os_user: who[:os_user],
                          host: who[:host], pid: who[:pid], correlation_id: Lyra::Correlation.current_id }.compact
            )
            Lyra.append_events(erasure, stream_name: ERASURES)
            entries
          end
        end
      end

      # The subject key for +subject+, refusing nil and model-wide keys.
      def erasable_key(subject)
        key = subject_key(subject)
        raise ArgumentError, "no subject" if key.nil? || key.empty?
        if key.end_with?("$*")
          raise ModelWideSubject, "#{key} is a model-wide entry (a pluck): it names no subject, and erasing it " \
                                  "would erase the record of reads of everyone's data"
        end

        key
      end

      # How many entries +stream+ holds.
      def count_stream(stream)
        ActiveRecord::Base.with_connection do |conn|
          conn.select_value("SELECT count(*) FROM event_store_events_in_streams WHERE stream = #{conn.quote(stream)}").to_i
        end
      end

      # Deletes +stream+'s events from every stream they are in and from the
      # events table (RES's delete_stream only unlinks). Returns how many.
      def delete_stream!(stream)
        ActiveRecord::Base.with_connection do |conn|
          ids = conn.select_values(
            "SELECT event_id FROM event_store_events_in_streams WHERE stream = #{conn.quote(stream)}"
          ).uniq
          ids.each_slice(DELETE_BATCH) do |slice|
            list = slice.map { |event_id| conn.quote(event_id) }.join(", ")
            conn.execute("DELETE FROM event_store_events_in_streams WHERE event_id IN (#{list})")
            conn.execute("DELETE FROM event_store_events WHERE event_id IN (#{list})")
          end
          ids.size
        end
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

      def metadata(access)
        {
          user_id: current(:user)&.id,
          user_type: Lyra::Attribution.actor_type(current(:user)),
          ip_address: current(:ip_address),
          request_id: current(:request_id),
          correlation_id: Lyra::Correlation.current_id,
          # Not a write in scope: the entry commits on its own connection and
          # stays when that write rolls back, so it would name no event. The
          # correlation still ties the read to the writes around it.
          causation_id: Lyra::Causation.outside_write_scopes
        }.merge(custom_metadata(access)).merge(source: "lyra_access_log").compact
      end

      def metadata_for_export
        {
          user_id: current(:user)&.id,
          user_type: Lyra::Attribution.actor_type(current(:user)),
          ip_address: current(:ip_address),
          request_id: current(:request_id),
          correlation_id: Lyra::Correlation.current_id,
          source: "lyra_subject_access"
        }.compact
      end

      def metadata_for_dashboard
        {
          user_id: current(:user)&.id,
          user_type: Lyra::Attribution.actor_type(current(:user)),
          ip_address: current(:ip_address),
          request_id: current(:request_id),
          correlation_id: Lyra::Correlation.current_id,
          source: "lyra_dashboard"
        }.compact
      end

      def current(attribute)
        defined?(::Current) && ::Current.respond_to?(attribute) ? ::Current.public_send(attribute) : nil
      end

      # config.access_metadata_proc's hash, with symbol keys. A failing proc
      # is logged and skipped: the access is still recorded, without it.
      def custom_metadata(access)
        proc = Lyra.config.access_metadata_proc
        return {} unless proc

        result = proc.call(access)
        result.is_a?(Hash) ? result.transform_keys(&:to_sym) : {}
      rescue => e
        Rails.logger.warn("Lyra: access_metadata_proc failed - #{e.message}")
        {}
      end
    end
  end

  module Events
    class DataAccessed < Lyra::Event; end
    class DataAccessDenied < Lyra::Event; end
    class DashboardRead < Lyra::Event; end
    # A data subject's Art. 15 copy was made (AccessLog.record_export).
    class SubjectAccessExported < Lyra::Event; end
    # A subject's access log was deleted (AccessLog.erase!).
    class AccessLogErased < Lyra::Event; end
  end
end

PamDsl.access_recorder = Lyra::AccessLog if defined?(PamDsl) && PamDsl.respond_to?(:access_recorder=)
