module Lyra
  module Privacy
    # GDPR compliance tools for Lyra events
    #
    # This class provides a Lyra-specific wrapper around PamDsl::GDPRCompliance,
    # automatically configuring it to work with Lyra's event store and event format.
    #
    # @example Basic usage
    #   compliance = Lyra::Privacy::GDPRCompliance.new(subject_id: user.id)
    #   report = compliance.data_export
    #
    # @example With custom subject type
    #   compliance = Lyra::Privacy::GDPRCompliance.new(
    #     subject_id: student.id,
    #     subject_type: 'Student'
    #   )
    #
    class GDPRCompliance
      attr_reader :pam_compliance

      # Initialize GDPR compliance handler
      #
      # @param subject_id [Object] The data subject's identifier
      # @param subject_type [String] The type/class of the subject (default: 'User')
      # @param actor_label [Proc] ->(actor, subject) { label }: how the copy names who acted
      #   (default "you", "staff", "staff or you" or "system"; PamDsl::SubjectAccess::DEFAULT_ACTOR_LABEL)
      # @param access_log_subjects [Array] the keys the application passed as this subject to the
      #   access log besides its records (validate_access!(..., subject: 7) writes Lyra::DataAccess$7);
      #   default: the bare subject id. [] reads none, where bare ids of several types share the log.
      #
      def initialize(subject_id:, subject_type: 'User', actor_label: nil, access_log_subjects: nil)
        @subject_id = subject_id
        @subject_type = subject_type
        @access_log_subjects = access_log_subjects.nil? ? [subject_id.to_s] : Array(access_log_subjects).map(&:to_s)

        @pam_compliance = PamDsl::GDPRCompliance.new(
          subject_id: subject_id,
          subject_type: subject_type,
          record_reader: method(:read_subject_events),
          attribute_extractor: method(:extract_attributes),
          timestamp_extractor: method(:extract_timestamp),
          operation_extractor: method(:extract_operation),
          model_class_extractor: method(:extract_model_class),
          model_id_extractor: method(:extract_model_id),
          changes_extractor: method(:extract_changes),
          retention_policy: retention_policy,
          policy_resolver: method(:policy_for_model),
          records_reader: method(:read_subject_records),
          access_reader: method(:read_access_log),
          export_recorder: Lyra::AccessLog.method(:record_export),
          actor_label: actor_label,
          rights_keys: method(:rights_keys)
        )
      end

      # Delegate all GDPR methods to the PAM DSL implementation

      # Right to Access (Article 15): the subject's copy. Beside the event
      # summaries it always gave, +records+ (each of the subject's records
      # whole, with its history), +accesses+ (the access log; nil when
      # config.record_access_events is off), +processing_context+, +notice+
      # (the policy's access_notice) and +gaps+. See PamDsl::SubjectAccess
      # and Lyra::Privacy::SubjectRecords. From 1.0.0 +restrictions+ and
      # +objections+ list the subject's requests of Arts. 18 and 21: those
      # recorded under the subject's key (EnfAuthor$7), and under the key of
      # one of the subject's records that names no other person (a contested
      # invoice). A record shared with another person is left out: its
      # restriction may be the other person's request.
      #
      # An explicit call answers a request and is recorded, in the stream
      # Lyra::SubjectAccessExports$<Type>$<id> (Lyra::AccessLog.record_export),
      # unless config.record_subject_access_exports is false. record: false is
      # for a view of the data that answers no request: full_report and the
      # dashboard's subject and GDPR routes pass it, so a view is not on record
      # as an answered request.
      #
      # history: false and accesses: false are for a request the subject
      # has narrowed (recital 63); disclose_actors: true adds who acted (ids,
      # IP addresses) to the role labels, after the controller has weighed
      # the staff's rights; verified_by: names who verified the subject's
      # identity, for the record of the export.
      def data_export(history: true, accesses: true, disclose_actors: false, verified_by: nil, record: true)
        pam_compliance.data_export(history: history, accesses: accesses, disclose_actors: disclose_actors,
                                   verified_by: verified_by, record: record)
      end

      # Right to be Forgotten (Article 17)
      def right_to_be_forgotten_report
        pam_compliance.right_to_be_forgotten_report
      end

      # Right to Data Portability (Article 20)
      def portable_export(format: :json)
        pam_compliance.portable_export(format: format)
      end

      # Right to Rectification (Article 16)
      def rectification_history
        pam_compliance.rectification_history
      end

      # Processing Activities Record (Article 30)
      def processing_activities
        pam_compliance.processing_activities
      end

      # Data Retention Compliance Check
      def retention_compliance_check
        pam_compliance.retention_compliance_check
      end

      # Consent Audit
      def consent_audit
        pam_compliance.consent_audit
      end

      # Full GDPR Compliance Report. Its data_export is not recorded as an
      # answered request (see data_export).
      def full_report
        pam_compliance.full_report
      end

      private

      # The PAM policy that governs +model_name+'s model (its privacy_policy,
      # else config.privacy_policy), or nil. A subject's records span models
      # with different policies; before 1.0.0 the wrapper passed none, and the
      # register's legal basis read "Not specified".
      def policy_for_model(model_name)
        model = Lyra.config.monitored_model_named(model_name) || model_name.to_s.safe_constantize
        policy = model.is_a?(Class) ? Lyra::Privacy.policy_for(model) : Lyra::Privacy.policy(Lyra.config.privacy_policy)
        policy.respond_to?(:pam_policy) ? policy.pam_policy : nil
      rescue StandardError
        nil
      end

      # The keys the subject's rights are recorded under (see data_export):
      # the subject's own, and those of their records that have requests
      # (one lookup in lyra_rights) and name this subject alone.
      def rights_keys(records)
        model = Lyra.config.monitored_model_named(@subject_type.to_s) || @subject_type.to_s.safe_constantize
        person = active_record_model?(model) ? Lyra.stream_name(model, @subject_id) : "#{@subject_type}$#{@subject_id}"
        candidates = records.filter_map do |raw|
          record_model = Lyra.config.monitored_model_named(raw[:model].to_s) || raw[:model].to_s.safe_constantize
          next unless active_record_model?(record_model) && !raw[:id].nil?

          key = Lyra.stream_name(record_model, raw[:id])
          [key, record_model, raw[:id]] unless key == person
        end
        store = PamDsl.rights_store
        keys = candidates.map(&:first)
        with_requests = store.respond_to?(:keys_with_requests) ? store.keys_with_requests(keys) : keys
        own = candidates.select { |key, _, _| with_requests.include?(key) }.filter_map do |key, record_model, id|
          # Its row, or under ES-NoProj its state from its events.
          row = Lyra::Rights::SubjectKeys.find_record(record_model, id)
          key if row && Lyra::Rights::SubjectKeys.person_keys(row) == [person]
        end
        [person, *own]
      end

      def active_record_model?(model)
        model.is_a?(Class) && model < ActiveRecord::Base
      end

      def read_subject_records(subject_id, subject_type, events, history: true)
        SubjectRecords.new(subject_id, subject_type, events, history: history).call
      end

      ACCESS_LOG_OFF = "access log not enabled (accesses lists earlier exports only)"

      # The access log's entries, oldest first: for each of the subject's
      # records, those within the periods the record was the subject's (a
      # moved record's accesses while it was another person's are theirs);
      # for the subject's own key and the keys the application passed as the
      # subject (access_log_subjects:, the bare id by default); and the
      # subject's earlier exports, which have a stream of their own. With
      # the log off, only the exports, and the gap that says so.
      def read_access_log(subject_id, subject_type, records)
        subject = Lyra::AccessLog.subject_key_for(subject_type, subject_id)
        exports = Lyra::AccessLog.exports_for(subject).map { |event| access_entry(subject, event) }
        return { entries: exports, gap: ACCESS_LOG_OFF } unless Lyra.config.record_access_events

        periods = records.to_h { |record| ["#{record[:model]}$#{record[:id]}", record[:periods]] }
        ([subject] + @access_log_subjects).each { |key| periods[key] = nil unless periods.key?(key) }
        entries = periods.flat_map do |key, record_periods|
          Lyra::AccessLog.for(key).map { |event| access_entry(key, event) }
                         .select { |entry| within?(record_periods, entry[:at]) }
        end
        (entries + exports).sort_by { |entry| entry[:at] || Time.at(0) }
      end

      # Whether +at+ falls in one of +periods+ (nil: the whole record).
      def within?(periods, at)
        return true if periods.nil? || at.nil?

        periods.any? { |period| (period[:from].nil? || at >= period[:from]) && (period[:to].nil? || at <= period[:to]) }
      end

      def access_entry(key, event)
        data = event.data.to_h.transform_keys(&:to_sym)
        metadata = event.metadata.to_h.transform_keys(&:to_sym)
        exported = event.event_type.to_s.end_with?("SubjectAccessExported")
        {
          at: data[:accessed_at] || data[:exported_at] || metadata[:timestamp],
          record: key,
          policy: data[:policy],
          purpose: exported ? nil : data[:purpose],
          legal_basis: data[:legal_basis],
          fields: data[:fields],
          outcome: exported ? "exported" : data[:outcome],
          sections: data[:sections],
          actor: metadata.slice(:user_id, :ip_address, :user_type).compact
        }
      end

      # Read all events related to the subject from Lyra's event store
      # Every event of the subject's own record and of the records that refer
      # to them (SubjectLinks: a belongs_to to the subject's class, or
      # <type>_id), in log order. A related record is followed through its
      # stream: its links are tracked from event to event, and an event belongs
      # to the subject when the record named them before or after it. An event
      # carries only what it changed (Lyra::EventData, 1.0.0), so matching the
      # foreign key in each event alone kept a related record's create and lost
      # its later updates and its destroy.
      #
      # The event that moves a record between people is given with the
      # subject's side only: moving in, its new values; moving away, the
      # links' old values and nothing of the new owner's (from 1.0.0; the
      # reports built on these events gave both sides).
      def read_subject_events(subject_id, subject_type)
        links = SubjectLinks.new(subject_type)
        own = links.subject_model ? Lyra.stream_owner_name(links.subject_model) : subject_type.to_s
        values = {} # stream => the link columns' last known values
        matching = []
        each_event do |event|
          relates = event_relates_to_subject?(event, subject_id, subject_type)
          model_id = extract_model_id(event)
          model = linked_model(extract_model_class(event))
          name = model.is_a?(Class) ? Lyra.stream_owner_name(model) : model.to_s
          if model_id.nil? || (name == own && model_id.to_s == subject_id.to_s) || links.for(model).empty?
            matching << event if relates
            next
          end

          key = "#{name}$#{model_id}"
          classified, values[key] = SubjectRecords.classify([event], links: links, model: model, subject_id: subject_id,
                                                                     initial: values[key] || {})
          case classified.first.last
          when :inside then matching << event
          when :in, :away then matching << subject_side(event, classified.first.last, links.columns(model))
          else matching << event if relates
          end
        end
        matching
      end

      def linked_model(name)
        model = Lyra.config.monitored_model_named(name) || name.to_s.safe_constantize
        model.is_a?(Class) && model < ActiveRecord::Base ? model : name.to_s
      rescue StandardError
        name.to_s
      end

      # A transition event with the subject's side only: an update moving the
      # record in keeps its new values, one moving it away the links' old
      # values. A create or import moving it in is the subject's whole.
      def subject_side(event, kind, link_columns)
        data = event.data.to_h
        changes = data[:changes] || data["changes"]
        return event unless changes.is_a?(Hash) && Lyra::Event.operation_of(event) == :updated

        side =
          if kind == :in
            changes.to_h { |field, change| [field, [nil, change.is_a?(Array) ? change.last : change]] }
          else
            changes.select { |field, _| link_columns.include?(field.to_s) }
                   .to_h { |field, change| [field, [change.is_a?(Array) ? change.first : nil, nil]] }
          end
        event.class.new(event_id: event.event_id, metadata: event.metadata.to_h,
                        data: data.except(:changes, "changes").merge(changes: side))
      end

      EVENT_BATCH = 1_000

      # Every event in the log, read in batches: a report that must see all of it
      # (a subject's events, retention) holds a batch at a time, not the whole log.
      def each_event(batch_size = EVENT_BATCH, &block)
        Lyra.config.event_store.read.in_batches(batch_size).each(&block)
      end

      # Whether an event holds the subject's data: an event of the subject's
      # own record, or of a record that refers to the subject through its
      # foreign key (a Registration's user_id, for subject type User).
      #
      # Who *made* a change is not whose data it is: before 0.9.3 an event
      # whose metadata named the subject as its actor (metadata[:user_id])
      # was exported too, so a staff member's export held every record they
      # had edited, other people's data, while a subject's own records written
      # by staff could be missed.
      def event_relates_to_subject?(event, subject_id, subject_type)
        data = event.respond_to?(:data) ? event.data : {}
        id = subject_id.to_s
        return true if extract_model_class(event).to_s == subject_type.to_s && extract_model_id(event).to_s == id

        explicit = data[:subject_id] || data["subject_id"]
        if explicit
          type = data[:subject_type] || data["subject_type"]
          return explicit.to_s == id && (type.nil? || type.to_s == subject_type.to_s)
        end

        attributes = extract_attributes(event)
        value = attributes[subject_foreign_key(subject_type)] || attributes[subject_foreign_key(subject_type).to_sym]
        !value.nil? && value.to_s == id
      end

      # The foreign key a record uses to refer to a subject of +subject_type+.
      def subject_foreign_key(subject_type)
        "#{subject_type.to_s.demodulize.underscore}_id"
      end

      # Lyra-specific extractors

      # The fields the event gives or changes (Lyra::Event.fields_of): an
      # update holds its changes only, in every mode.
      # Encrypted attributes are opened (the log holds their ciphertext), so
      # the export's inventory and lineage give the values, as its records do.
      def extract_attributes(event)
        return opened(event, Lyra::Event.fields_of(event)) if event.respond_to?(:data)
        return event.attributes if event.respond_to?(:attributes) && !event.attributes.is_a?(Method)
        {}
      end

      # The model whose encrypted attributes +event+ may hold, or nil.
      def encrypted_model(event)
        model = linked_model(extract_model_class(event))
        model.is_a?(Class) && Lyra::EncryptedAttributes.names(model).any? ? model : nil
      end

      def opened(event, values)
        model = encrypted_model(event)
        model && values.is_a?(Hash) ? Lyra::EncryptedAttributes.open(model, values) : values
      end

      def opened_changes(event, changes)
        model = encrypted_model(event)
        return changes unless model && changes.is_a?(Hash)

        changes.to_h do |field, change|
          opened_change = Array(change).map { |value| Lyra::EncryptedAttributes.open(model, { field => value })[field] }
          [field, change.is_a?(Array) ? opened_change : opened_change.first]
        end
      end

      def extract_timestamp(event)
        return event.timestamp if event.respond_to?(:timestamp) && event.timestamp
        return event.data[:timestamp] || event.data["timestamp"] if event.respond_to?(:data)
        event.metadata[:timestamp] if event.respond_to?(:metadata)
      end

      def extract_operation(event)
        return event.operation if event.respond_to?(:operation)
        if event.respond_to?(:data)
          op = event.data[:operation] || event.data["operation"]
          op.is_a?(String) ? op.to_sym : op
        end
      end

      def extract_model_class(event)
        return event.model_class if event.respond_to?(:model_class)
        event.data[:model_class] || event.data["model_class"] if event.respond_to?(:data)
      end

      def extract_model_id(event)
        return event.model_id if event.respond_to?(:model_id)
        event.data[:model_id] || event.data["model_id"] if event.respond_to?(:data)
      end

      def extract_changes(event)
        if event.respond_to?(:changes) && !event.changes.is_a?(Method)
          begin
            return opened_changes(event, event.changes) unless event.method(:changes).owner.to_s.include?('ActiveRecord')
          rescue
            return event.changes
          end
        end
        return opened_changes(event, event.data[:changes] || event.data["changes"] || {}) if event.respond_to?(:data)
        {}
      end

      # The retention periods the compliance check applies, as PAM's check
      # expects them ({ "Model" => { duration: d }, default: { duration: d } }):
      # each monitored model's period from its privacy policy's retention block,
      # over config.retention_policy, which may be a single duration (7.years) or
      # such a hash.
      #
      # Before 0.9.3 the policies' retention blocks were ignored in favour of
      # hard-coded periods for models named Payment, Invoice, Student and
      # Enrollment, and a single duration in config.retention_policy raised
      # TypeError.
      def retention_policy
        configured = Lyra.config.retention_policy
        policy =
          case configured
          when nil then { default: { duration: 7.years } }
          when Hash then configured.transform_values { |v| v.is_a?(Hash) ? v : { duration: v } }
          else { default: { duration: configured } }
          end

        Lyra.config.monitored_models.each do |model|
          duration = Lyra::Privacy.policy_for(model).retention_for(model)
          # A Duration, or a plain number of seconds (Numeric; a Duration also
          # answers is_a?(Numeric) for its value).
          policy[model.name] = { duration: duration } if duration.is_a?(ActiveSupport::Duration) || duration.is_a?(Numeric)
        rescue StandardError
          next
        end
        policy
      end
    end

    # Extend GDPRCompliance with policy integration
    class GDPRCompliance
      # Use privacy policy for PII detection if available
      #
      # @param attributes [Hash] Attributes to check
      # @param policy_name [Symbol] Policy name
      # @param use_detector [Boolean] Fall back to PIIDetector (default: true)
      #
      def detect_pii_with_policy(attributes, policy_name, use_detector: true)
        integration = PolicyIntegration.new(policy_name, use_detector: use_detector)
        integration.detect_pii(attributes)
      end

      # Check retention compliance with policy
      # Returns nil for models without defined retention (infinite/manual)
      def retention_compliance_with_policy(policy_name)
        integration = PolicyIntegration.new(policy_name)
        now = Time.current
        totals = Hash.new(0)
        expired_ids = Hash.new { |hash, key| hash[key] = [] }
        durations = {}

        # One pass over the log, keeping counts and the ids of expired events, not the events.
        each_event do |event|
          model_class = extract_model_class(event)
          totals[model_class] += 1
          duration = durations.fetch(model_class) { durations[model_class] = integration.retention_duration(model_class) }
          next if duration.nil?

          timestamp = extract_timestamp(event)
          next unless timestamp && timestamp < (now - duration)

          expired_ids[model_class] << (event.respond_to?(:event_id) ? event.event_id : event.object_id)
        end

        totals.map do |model_class, total|
          retention_duration = durations[model_class]

          # nil means infinite/manual retention - always compliant
          if retention_duration.nil?
            { model_class: model_class, total_events: total, expired_events: 0, retention_period: nil,
              compliance_status: :manual, expired_event_ids: [] }
          else
            expired = expired_ids[model_class]
            { model_class: model_class, total_events: total, expired_events: expired.size,
              retention_period: retention_duration, compliance_status: expired.empty? ? :compliant : :requires_action,
              expired_event_ids: expired }
          end
        end
      end
    end
  end
end
