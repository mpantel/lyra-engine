# frozen_string_literal: true

require "json" # stdlib; ActiveSupport also loads it, the polyfill does not

module PamDsl
  # GDPR compliance tools for data subject rights
  #
  # This class provides generic GDPR compliance functionality that works with
  # any event store or data source through configurable extractors.
  #
  # @example With Lyra events
  #   compliance = PamDsl::GDPRCompliance.new(
  #     subject_id: user.id,
  #     subject_type: 'User',
  #     record_reader: ->(sid, stype) {
  #       Lyra.config.event_store.read.to_a.select { |e| relates_to_subject?(e, sid, stype) }
  #     }
  #   )
  #   report = compliance.data_export
  #
  # @example With RubyEventStore
  #   compliance = PamDsl::GDPRCompliance.new(
  #     subject_id: user.id,
  #     record_reader: ->(sid, stype) {
  #       event_store.read.stream("User$#{sid}").to_a
  #     },
  #     attribute_extractor: ->(e) { e.data[:attributes] || {} },
  #     timestamp_extractor: ->(e) { e.metadata[:timestamp] }
  #   )
  #
  class GDPRCompliance
    attr_reader :subject_id, :subject_type, :options

    # Initialize GDPR compliance handler
    #
    # @param subject_id [Object] The data subject's identifier
    # @param subject_type [String] The type/class of the subject (default: 'User')
    # @param record_reader [Proc] Block that returns records for a subject: ->(subject_id, subject_type) { [...] }
    # @param attribute_extractor [Proc] Block to extract attributes from event: ->(event) { hash }
    # @param timestamp_extractor [Proc] Block to extract timestamp from event: ->(event) { time }
    # @param operation_extractor [Proc] Block to extract operation from event: ->(event) { :created/:updated/:destroyed }
    # @param model_class_extractor [Proc] Block to extract model class from event: ->(event) { string }
    # @param model_id_extractor [Proc] Block to extract model id from event: ->(event) { id }
    # @param changes_extractor [Proc] Block to extract changes from event: ->(event) { hash }
    # @param retention_policy [Hash] Retention periods by model class
    # @param policy_name [Symbol] The policy that governs every model (the single-policy case)
    # @param policy_resolver [Proc] The policy that governs a model, for subjects whose records
    #   span models with different policies: ->(model_name) { PamDsl::Policy or nil }. Falls back
    #   to policy_name's policy.
    # @param records_reader [Proc] The subject's records for the Art. 15 copy, from the store:
    #   ->(subject_id, subject_type, events, history:) { [record] } (see PamDsl::SubjectAccess#record).
    #   Without it, the records are rebuilt from the subject's events.
    # @param access_reader [Proc] The access log's entries for the records:
    #   ->(subject_id, subject_type, records) { [entry] }, or nil when the store keeps no access log.
    # @param export_recorder [Proc] Called with what each data_export gave (sections, counts, who
    #   verified the subject; never values), to record that the request was answered.
    # @param actor_label [Proc] ->(actor, subject) { label } for who acted in history and accesses
    #   (PamDsl::SubjectAccess::DEFAULT_ACTOR_LABEL: "you", "staff", "system").
    # @param rights_keys [Proc] The keys the subject's restrictions and objections (PamDsl.rights) are
    #   recorded under: ->(records) { [key] }, given the subject's records. Default: "<type>$<id>".
    #   A host whose records can be restricted one by one adds those records' keys (Lyra does).
    #
    def initialize(subject_id:, subject_type: 'User', record_reader:, **options)
      @subject_id = subject_id
      @subject_type = subject_type
      @record_reader = record_reader
      @options = options
      @pam_policy = options[:policy_name] ? PamDsl.registry.get(options[:policy_name]) : nil
      @policy_resolver = options[:policy_resolver]
      @records_reader = options[:records_reader]
      @access_reader = options[:access_reader]
      @export_recorder = options[:export_recorder]
      @actor_label = options[:actor_label]
      @rights_keys = options[:rights_keys]

      # Set up extractors with sensible defaults
      @attribute_extractor = options[:attribute_extractor] || method(:default_attribute_extractor)
      @timestamp_extractor = options[:timestamp_extractor] || method(:default_timestamp_extractor)
      @operation_extractor = options[:operation_extractor] || method(:default_operation_extractor)
      @model_class_extractor = options[:model_class_extractor] || method(:default_model_class_extractor)
      @model_id_extractor = options[:model_id_extractor] || method(:default_model_id_extractor)
      @changes_extractor = options[:changes_extractor] || method(:default_changes_extractor)
      @source_extractor = options[:source_extractor] || method(:default_source_extractor)
      @retention_policy = options[:retention_policy] || default_retention_policy
    end

    # Right to Access (GDPR Article 15)
    # Export all data about the subject
    #
    # The event summaries, PII inventory and lineage are the keys it has
    # always returned. Beside them, the copy of the data (PamDsl::SubjectAccess):
    #
    # - records: each of the subject's records whole, every attribute, with
    #   its history (from/to per change). A field the policy declares
    #   withheld_from_access: is named under +withheld+ with that basis; a
    #   field about another person (about:) goes to +review+.
    # - accesses: the access log's entries for those records, or nil when no
    #   access log is kept.
    # - processing_context: per purpose that admits the records' declared
    #   fields, its basis, recipients, transfers, retention and sources.
    # - notice: the controller's notice, from the policy's access_notice.
    # - gaps: what the policy does not declare, as [purpose or nil, item].
    # - restrictions and objections (from 1.0.0): the subject's own requests of
    #   Arts. 18 and 21 (PamDsl::Rights::Ledger#export): grounds, fields,
    #   states, dates and the controller's decisions; never another person's,
    #   nor who on the controller's staff recorded them.
    #
    # @param history [Boolean] false only for a request the subject narrowed
    # @param accesses [Boolean] false only for a request the subject narrowed
    # @param disclose_actors [Boolean] add who acted (ids, IP addresses) beside the role labels
    # @param verified_by [String] who verified the subject's identity, for the record of the export
    # @param actor_label [Proc] overrides the actor_label option for this export
    # @param record [Boolean] whether this export answers a request and is recorded (export_recorder).
    #   An explicit call does (the default); full_report and views of the data, such as a
    #   dashboard, pass false, so that only answered requests are on record.
    # @return [Hash] Complete data export including events, PII inventory, and lineage
    #
    def data_export(history: true, accesses: true, disclose_actors: false, verified_by: nil, actor_label: nil,
                    record: true)
      events = collect_all_records
      generated_at = Time.now
      subject = { id: subject_id, type: subject_type }

      export = {
        subject: subject,
        generated_at: generated_at,
        events: events.map { |e| event_summary(e) },
        pii_inventory: collect_pii_inventory(events),
        data_lineage: trace_data_lineage(events)
      }

      access = SubjectAccess.new(subject: subject, policy_for: method(:policy_for),
                                 actor_label: actor_label || @actor_label, disclose_actors: disclose_actors)
      raw = subject_records(events, history)
      log = accesses ? read_accesses(raw) : nil
      # A reader may give a partial log with the gap it leaves ({ entries:, gap: }).
      log_gap = log.is_a?(Hash) ? log[:gap] : nil
      log = log[:entries] if log.is_a?(Hash)
      contexts = access.processing_context(raw)
      notice = access.notice(subject_policies(raw))
      gaps = access.gaps(raw, contexts, notice)
      gaps << [nil, "history not included (request narrowed)"] unless history
      gaps << [nil, accesses ? "access log not enabled" : "access log not included (request narrowed)"] if log.nil?
      gaps << [nil, log_gap] if log_gap

      export.merge!(
        records: raw.map { |record| access.record(record) },
        accesses: log&.map { |entry| access.access(entry) },
        processing_context: contexts,
        notice: notice,
        gaps: gaps
      )
      export.merge!(PamDsl.rights.export(rights_keys(raw)))
      return export unless record

      record_export(export, history: history, accesses: !log.nil? && log_gap.nil?, disclose_actors: disclose_actors,
                            verified_by: verified_by)
      export
    end

    # Right to be Forgotten (GDPR Article 17)
    # Identify all events containing subject's data for deletion planning
    #
    # @return [Hash] Report on affected data and recommended deletion strategy
    #
    def right_to_be_forgotten_report
      events = collect_all_records

      {
        subject: { id: subject_id, type: subject_type },
        total_events: events.count,
        events_with_pii: events.count { |e| has_pii?(e) },
        affected_streams: affected_streams(events),
        affected_models: affected_models(events),
        deletion_strategy: recommend_deletion_strategy(events),
        dependencies: find_dependencies(events)
      }
    end

    # Right to Data Portability (GDPR Article 20)
    # Export data in machine-readable format
    #
    # @param format [Symbol] Export format (:json, :csv, :xml, :hash)
    # @return [String, Hash] Exported data in requested format
    #
    def portable_export(format: :json)
      events = collect_all_records

      data = {
        version: "1.0",
        subject: { id: subject_id, type: subject_type },
        exported_at: Time.now.iso8601,
        data: collect_portable_data(events)
      }

      case format
      when :json
        data.to_json
      when :csv
        to_csv(data)
      when :xml
        to_xml(data)
      else
        data
      end
    end

    # Right to Rectification (GDPR Article 16)
    # Track all corrections made to subject's data
    #
    # @return [Array<Hash>] History of all data corrections
    #
    def rectification_history
      events = collect_all_records

      # An update is a correction of personal data when it changed a field the
      # model's policy declares, or one the detector flags (undeclared data).
      # Before 1.0.0 the detector alone decided, on the whole event: a declared
      # field it did not recognise was never listed.
      corrections = events.select do |event|
        extract_operation(event) == :updated && personal_changes(event).any?
      end

      corrections.map do |event|
        {
          timestamp: extract_timestamp(event),
          model: extract_model_class(event),
          record_id: extract_model_id(event),
          changes: extract_changes(event),
          corrected_fields: personal_changes(event),
          metadata: event.respond_to?(:metadata) ? event.metadata : {}
        }
      end
    end

    # Processing Activities Record (GDPR Article 30)
    # Document all processing activities for the subject
    #
    # @return [Array<Hash>] Processing activities grouped by source
    #
    def processing_activities
      events = collect_all_records

      activities = events.group_by { |record| @source_extractor.call(record) }

      # Where a policy governs the events' model, purpose, basis, categories,
      # recipients and retention are the declared ones: the purpose the
      # source names, else the purposes that admit the declared fields the
      # events carry. Only without a policy are they guessed.
      activities.map do |source, source_events|
        declared = declared_purposes(source, source_events)
        {
          source: source,
          purpose: declared.any? ? declared.map { |p| p.description.to_s.empty? ? p.name.to_s : p.description }.join(", ") : infer_purpose(source, source_events),
          legal_basis: declared.any? ? declared.map { |p| SubjectAccess.legal_basis_label(p.legal_basis) }.uniq.join("; ") : determine_legal_basis(source, source_events),
          data_categories: (categorize_data(source_events) | declared_categories(source_events)),
          recipients: (identify_recipients(source_events) | declared.flat_map(&:recipients)),
          retention_period: determine_retention_period(source_events),
          events_count: source_events.count
        }.merge(rights_declarations(declared))
      end
    end

    # Arts. 18 and 21 for the activity's declared purposes (the purpose the
    # source names, else those that admit the fields its events carry, each
    # read from the policy of the events' model): +rights_by_purpose+ gives
    # each purpose's right to object (nil: none) and Art. 18(2) exceptions;
    # +objectable+ and +allowed_when_restricted+ give the one purpose's, when
    # there is exactly one (before 1.0.0's rights work they read only the
    # policy_name policy, so a host that resolves policies per model, as Lyra
    # does, always got none).
    def rights_declarations(declared)
      single = declared.size == 1 ? declared.first : nil
      {
        objectable: single&.objectable,
        allowed_when_restricted: single ? single.restriction_exceptions : [],
        rights_by_purpose: declared.to_h do |purpose|
          [purpose.name, { objectable: purpose.objectable, allowed_when_restricted: purpose.restriction_exceptions }]
        end
      }
    end
    private :rights_declarations

    # The keys the subject's rights are recorded under (rights_keys option).
    def rights_keys(records)
      keys = @rights_keys&.call(records)
      keys.nil? ? ["#{subject_type}$#{subject_id}"] : Array(keys)
    end
    private :rights_keys

    # Data Retention Compliance Check
    # Verify that data retention policies are being followed
    #
    # @return [Array<Hash>] Compliance status per model class
    #
    def retention_compliance_check
      events = collect_all_records

      events.group_by { |e| extract_model_class(e) }.map do |model_class, model_events|
        policy = @retention_policy[model_class] || @retention_policy[:default] || { duration: 7.years }
        expired = model_events.select do |event|
          timestamp = extract_timestamp(event)
          timestamp && timestamp < (Time.now - policy[:duration])
        end

        {
          model_class: model_class,
          total_events: model_events.count,
          expired_events: expired.count,
          retention_period: policy[:duration],
          compliance_status: expired.empty? ? :compliant : :requires_action,
          expired_event_ids: expired.map { |e| e.respond_to?(:event_id) ? e.event_id : e.object_id }
        }
      end
    end

    # Consent Audit
    # Track and verify consent for data processing
    #
    # @return [Hash] Current consents, history, and processing legitimacy
    #
    def consent_audit
      events = collect_all_records

      consent_events = events.select do |event|
        data = event.respond_to?(:data) ? event.data : {}
        metadata = event.respond_to?(:metadata) ? event.metadata : {}

        data[:consent] ||
        metadata[:consent_id] ||
        extract_model_class(event).to_s.match?(/consent/i)
      end

      recorded = recorded_consents
      current = extract_current_consents(consent_events)
      recorded.each do |entry|
        current[entry[:purpose]] = { granted: entry[:state] == :granted, timestamp: entry[:granted_at],
                                     expires_at: entry[:expires_at], state: entry[:state], source: :consent_store }
      end

      {
        current_consents: current,
        # The consent store's own records for the subject (PamDsl.consent_store,
        # when the host installed a shared one that can list them: Lyra's), with
        # their histories. They are what Condition 4 checks, so they take
        # precedence in current_consents over consent found in the events.
        recorded_consents: recorded,
        consent_history: consent_events.map do |event|
          data = event.respond_to?(:data) ? event.data : {}
          {
            timestamp: extract_timestamp(event),
            consent_type: data[:consent_type],
            granted: data[:granted],
            purpose: data[:purpose],
            event_id: event.respond_to?(:event_id) ? event.event_id : nil
          }
        end,
        processing_legitimacy: verify_processing_legitimacy(events, consent_events)
      }
    end

    # Generate a complete GDPR compliance report
    #
    # @return [Hash] Comprehensive compliance report
    #
    def full_report
      {
        subject: { id: subject_id, type: subject_type },
        generated_at: Time.now,
        data_export: data_export(record: false), # a report, not an answered request
        erasure_report: right_to_be_forgotten_report,
        rectification_history: rectification_history,
        processing_activities: processing_activities,
        retention_compliance: retention_compliance_check,
        consent_audit: consent_audit
      }
    end

    private

    # The shared consent store's records for "<subject_type>$<subject_id>", or
    # [] when no store that lists them is installed.
    def recorded_consents
      store = PamDsl.consent_store
      return [] unless store.respond_to?(:consents_for)

      store.consents_for("#{subject_type}$#{subject_id}")
    end

    # Collect all events for the subject
    def collect_all_records
      @record_reader.call(subject_id, subject_type)
    end

    # The policy that governs +model+: the resolver's, else policy_name's.
    def policy_for(model)
      return @pam_policy if model.nil?

      (@policy_resolver && @policy_resolver.call(model.to_s)) || @pam_policy
    end

    # The policies of the subject's records, or the subject type's when it
    # has none (whose notice the copy still carries).
    def subject_policies(records)
      policies = records.filter_map { |record| policy_for(record[:model]) }.uniq
      policies.empty? ? [policy_for(subject_type)].compact : policies
    end

    # The subject's records as the store gives them (records_reader), or
    # rebuilt from the subject's events.
    def subject_records(events, history)
      return @records_reader.call(subject_id, subject_type, events, history: history) if @records_reader

      records_from_events(events, history)
    end

    def read_accesses(records)
      @access_reader&.call(subject_id, subject_type, records)
    end

    # Records that the copy was made: which sections, how many records, who
    # verified the subject. Never values.
    def record_export(export, history:, accesses:, disclose_actors:, verified_by:)
      return unless @export_recorder

      sections = [:records, (:history if history), (:accesses if accesses), :processing_context, :notice].compact
      @export_recorder.call(
        subject_id: subject_id, subject_type: subject_type, generated_at: export[:generated_at],
        sections: sections, records: export[:records].size, disclose_actors: disclose_actors,
        verified_by: verified_by, gaps: export[:gaps].size
      )
    end

    # Each record the events touch, its state replayed from them: what a
    # store without a records_reader can give.
    def records_from_events(events, history)
      events.group_by { |e| [extract_model_class(e).to_s, extract_model_id(e)] }.filter_map do |(model, id), record_events|
        next if id.nil?

        sorted = record_events.sort_by { |e| extract_timestamp(e) || Time.at(0) }
        state = {}
        destroyed = false
        entries = []
        sorted.each do |event|
          operation = extract_operation(event)
          at = extract_timestamp(event)
          actor = event_actor(event)
          case operation
          when :created, :imported
            state = extract_attributes(event).to_h.transform_keys(&:to_s)
            state.each { |field, value| entries << history_entry(at, operation, field, nil, value, actor) }
          when :updated
            changes = extract_changes(event).to_h
            changes = extract_attributes(event).to_h.transform_values { |v| [nil, v] } if changes.empty?
            changes.each do |field, change|
              from, to = change.is_a?(Array) ? change : [nil, change]
              state[field.to_s] = to
              entries << history_entry(at, operation, field.to_s, from, to, actor)
            end
          when :destroyed
            destroyed = true
            entries << history_entry(at, operation, nil, nil, nil, actor)
          end
        end

        { model: model, id: id, state: destroyed ? :destroyed : :replayed, as_of: extract_timestamp(sorted.last),
          attributes: state, history_from: extract_timestamp(sorted.first), periods: nil,
          history: history ? entries : nil }
      end
    end

    def history_entry(at, operation, field, from, to, actor)
      { at: at, operation: operation, field: field, from: from, to: to, actor: actor }
    end

    # Who wrote an event, from its metadata.
    def event_actor(event)
      metadata = event.respond_to?(:metadata) ? event.metadata.to_h : {}
      %i[user_id ip_address user_type].to_h { |key| [key, metadata[key] || metadata[key.to_s]] }.compact
    end

    # The purposes this activity is, from the policy of each model its events
    # touch: the one its source names, else those that admit the declared
    # fields the events carry. [] when no policy governs the events' models.
    def declared_purposes(source, events)
      events.group_by { |e| extract_model_class(e) }.flat_map do |model, model_events|
        policy = policy_for(model)
        next [] unless policy

        named = policy.purposes.values.find { |p| source_matches_purpose?(source, p) }
        next [named] if named

        fields = declared_fields_in(model_events, policy)
        policy.purposes.values.select { |p| fields.any? { |f| policy.allowed?(f, p.name) } }
      end.uniq
    end

    # The declared fields the events carry, by name.
    def declared_fields_in(events, policy)
      events.flat_map { |e| extract_fields(e).keys.map(&:to_s) }.uniq.select { |f| policy.fields.key?(f.to_sym) }
    end

    def declared_categories(events)
      events.group_by { |e| extract_model_class(e) }.flat_map do |model, model_events|
        policy = policy_for(model)
        next [] unless policy

        declared_fields_in(model_events, policy).map { |f| policy.fields[f.to_sym].type.to_s.split('_').map(&:capitalize).join(' ') }
      end.uniq
    end

    # The changed fields of an update that are personal data: declared by the
    # model's policy, or flagged by the detector.
    def personal_changes(event)
      policy = policy_for(extract_model_class(event))
      extract_changes(event).to_h.select do |field, _|
        (policy && policy.fields.key?(field.to_sym)) || PIIDetector.contains_pii?(field)
      end
    end

    # Default extractors that work with common record/event structures
    def default_source_extractor(record)
      if record.respond_to?(:metadata)
        record.metadata[:source] || 'unknown'
      elsif record.is_a?(Hash)
        (record[:source] || record["source"] || 'unknown').to_s
      else
        'unknown'
      end
    end

    def default_attribute_extractor(event)
      return event.attributes if event.respond_to?(:attributes) && !event.attributes.is_a?(Method)
      return event.data[:attributes] || event.data["attributes"] || {} if event.respond_to?(:data)
      {}
    end

    def default_timestamp_extractor(event)
      return event.timestamp if event.respond_to?(:timestamp) && event.timestamp
      if event.respond_to?(:data)
        event.data[:timestamp] || event.data["timestamp"]
      elsif event.respond_to?(:metadata)
        event.metadata[:timestamp]
      end
    end

    def default_operation_extractor(event)
      return event.operation if event.respond_to?(:operation)
      if event.respond_to?(:data)
        op = event.data[:operation] || event.data["operation"]
        op.is_a?(String) ? op.to_sym : op
      end
    end

    def default_model_class_extractor(event)
      return event.model_class if event.respond_to?(:model_class)
      event.data[:model_class] || event.data["model_class"] if event.respond_to?(:data)
    end

    def default_model_id_extractor(event)
      return event.model_id if event.respond_to?(:model_id)
      event.data[:model_id] || event.data["model_id"] if event.respond_to?(:data)
    end

    def default_changes_extractor(event)
      if event.respond_to?(:changes) && !event.changes.is_a?(Method)
        begin
          return event.changes unless event.method(:changes).owner.to_s.include?('ActiveRecord')
        rescue
          return event.changes
        end
      end
      return event.data[:changes] || event.data["changes"] || {} if event.respond_to?(:data)
      {}
    end

    # Extraction helpers using configured extractors
    def extract_attributes(event)
      @attribute_extractor.respond_to?(:call) ? @attribute_extractor.call(event) : @attribute_extractor.send(:call, event)
    end

    # What an event gives or changes: its attributes or, when it holds none (an
    # update carries its changes only, in every mode), the new values of its
    # changes. Personal data is detected in these, and subjects are matched on them.
    def extract_fields(event)
      attributes = extract_attributes(event)
      return attributes unless attributes.respond_to?(:empty?) && attributes.empty?

      extract_changes(event).to_h { |field, change| [field, change.is_a?(Array) ? change.last : change] }
    end

    def extract_timestamp(event)
      @timestamp_extractor.respond_to?(:call) ? @timestamp_extractor.call(event) : @timestamp_extractor.send(:call, event)
    end

    def extract_operation(event)
      @operation_extractor.respond_to?(:call) ? @operation_extractor.call(event) : @operation_extractor.send(:call, event)
    end

    def extract_model_class(event)
      @model_class_extractor.respond_to?(:call) ? @model_class_extractor.call(event) : @model_class_extractor.send(:call, event)
    end

    def extract_model_id(event)
      @model_id_extractor.respond_to?(:call) ? @model_id_extractor.call(event) : @model_id_extractor.send(:call, event)
    end

    def extract_changes(event)
      @changes_extractor.respond_to?(:call) ? @changes_extractor.call(event) : @changes_extractor.send(:call, event)
    end

    def has_pii?(event)
      PIIDetector.detect(extract_fields(event)).any?
    end

    def event_summary(event)
      {
        event_id: event.respond_to?(:event_id) ? event.event_id : nil,
        timestamp: extract_timestamp(event),
        operation: extract_operation(event),
        model: extract_model_class(event),
        record_id: extract_model_id(event),
        has_pii: has_pii?(event)
      }
    end

    # The fields of an event that may go into the subject's copy: those its
    # model's policy neither withholds (withheld_from_access:) nor marks as
    # another person's (about:). The copy's +withheld+ and +review+ name
    # them; the inventory and the lineage, part of the same export, must not
    # give their values (before 1.0.0 they did).
    def copy_fields(event)
      fields = extract_fields(event)
      policy = policy_for(extract_model_class(event))
      return fields unless policy

      fields.reject do |name, _|
        field = policy.fields[name.to_sym]
        field && (field.withheld_from_access? || field.about_another_person?)
      end
    end

    def collect_pii_inventory(events)
      PIIDetector.extract_pii_from_records(
        events,
        attribute_extractor: ->(e) { copy_fields(e) },
        metadata_extractor: ->(e) {
          {
            event_id: e.respond_to?(:event_id) ? e.event_id : nil,
            timestamp: extract_timestamp(e),
            model_class: extract_model_class(e),
            model_id: extract_model_id(e)
          }
        }
      )
    end

    def trace_data_lineage(events)
      sorted_events = events.sort_by { |e| extract_timestamp(e) || Time.at(0) }
      lineage = {}

      sorted_events.each do |event|
        pii_fields = PIIDetector.detect(copy_fields(event))

        pii_fields.each do |field, info|
          lineage[field] ||= []
          lineage[field] << {
            event_id: event.respond_to?(:event_id) ? event.event_id : nil,
            timestamp: extract_timestamp(event),
            operation: extract_operation(event),
            value: info[:value],
            source: event.respond_to?(:metadata) ? event.metadata[:source] : nil
          }
        end
      end

      lineage
    end

    def affected_streams(events)
      events.map { |e| "#{extract_model_class(e)}-#{extract_model_id(e)}" }.uniq
    end

    def affected_models(events)
      events.map { |e| extract_model_class(e) }.uniq
    end

    def recommend_deletion_strategy(events)
      events.count < 100 ? :direct_deletion : :batch_deletion
    end

    def find_dependencies(events)
      events.flat_map do |event|
        attrs = extract_fields(event)
        attrs.select { |k, v| k.to_s.end_with?('_id') && v == subject_id }
      end.uniq
    end

    def collect_portable_data(events)
      events.group_by { |e| extract_model_class(e) }.transform_values do |model_events|
        aggregate_state(model_events)
      end
    end

    def aggregate_state(events)
      sorted = events.sort_by { |e| extract_timestamp(e) || Time.at(0) }
      sorted.each_with_object({}) do |event, state|
        case extract_operation(event)
        when :created
          state.merge!(extract_attributes(event))
        when :updated
          changes = extract_changes(event)
          changes.each { |k, (old, new)| state[k] = new }
        when :destroyed
          state[:_deleted] = true
          state[:_deleted_at] = extract_timestamp(event)
        end
      end
    end

    def identify_pii_changes(changes)
      changes.select { |field, _| PIIDetector.contains_pii?(field) }
    end

    def infer_purpose(source, events)
      case source.to_s
      when /registration/i then "Account creation and management"
      when /payment/i then "Payment processing"
      when /email/i then "Communication"
      when /analytics/i then "Analytics and improvements"
      else "Application functionality"
      end
    end

    LEGAL_BASIS_LABELS = {
      consent:              "Consent (Art. 6(1)(a))",
      contract:             "Contract (Art. 6(1)(b))",
      legal_obligation:     "Legal obligation (Art. 6(1)(c))",
      vital_interests:      "Vital interests (Art. 6(1)(d))",
      public_task:          "Public task (Art. 6(1)(e))",
      legitimate_interests: "Legitimate interests (Art. 6(1)(f))",
      undetermined:         "Undetermined: the controller decides"
    }.freeze

    def determine_legal_basis(source, _events)
      return "Not specified" unless @pam_policy

      purpose = @pam_policy.purposes.values.find { |p| source_matches_purpose?(source, p) }
      LEGAL_BASIS_LABELS[purpose&.legal_basis] || "Not specified"
    end

    def source_matches_purpose?(source, purpose)
      source.to_s.downcase.include?(purpose.name.to_s.downcase.tr('_', ' ').split.first)
    end

    def categorize_data(events)
      pii_types = events.flat_map do |event|
        PIIDetector.detect(extract_fields(event)).values.map { |v| v[:type] }
      end.uniq

      pii_types.map { |t| t.to_s.split('_').map(&:capitalize).join(' ') }
    end

    def identify_recipients(events)
      events.flat_map do |event|
        metadata = event.respond_to?(:metadata) ? event.metadata : {}
        metadata[:recipients] || []
      end.uniq
    end

    def determine_retention_period(events)
      return "Not specified" if events.empty?
      model_class = extract_model_class(events.first)
      declared = policy_for(model_class)&.retention_for(model_class.to_s)
      return declared if declared
      policy = @retention_policy[model_class]
      policy&.dig(:duration) || @retention_policy[:default]&.dig(:duration) || "Not specified"
    end

    def default_retention_policy
      {
        default: { duration: 7.years },
        'Payment' => { duration: 10.years },
        'Invoice' => { duration: 10.years },
        'Student' => { duration: 10.years },
        'Enrollment' => { duration: 10.years }
      }
    end

    def extract_current_consents(consent_events)
      consent_events.group_by { |e| e.respond_to?(:data) ? e.data[:purpose] : nil }.transform_values do |events|
        latest = events.max_by { |e| extract_timestamp(e) || Time.at(0) }
        data = latest.respond_to?(:data) ? latest.data : {}
        {
          granted: data[:granted],
          timestamp: extract_timestamp(latest),
          expires_at: data[:expires_at]
        }
      end
    end

    def verify_processing_legitimacy(all_events, consent_events)
      all_events.map do |event|
        metadata = event.respond_to?(:metadata) ? event.metadata : {}
        purpose = infer_purpose(metadata[:source], [event])
        consent = find_applicable_consent(consent_events, purpose, extract_timestamp(event))
        consent_data = consent&.respond_to?(:data) ? consent.data : {}

        {
          event_id: event.respond_to?(:event_id) ? event.event_id : nil,
          timestamp: extract_timestamp(event),
          purpose: purpose,
          has_consent: consent.present? && consent_data[:granted],
          legitimate: consent.present? && consent_data[:granted]
        }
      end
    end

    def find_applicable_consent(consent_events, purpose, timestamp)
      return nil unless timestamp

      consent_events.find do |consent|
        data = consent.respond_to?(:data) ? consent.data : {}
        consent_time = extract_timestamp(consent)

        data[:purpose] == purpose &&
        consent_time && consent_time <= timestamp &&
        (data[:expires_at].nil? || data[:expires_at] > timestamp)
      end
    end

    def to_csv(data)
      require 'csv'

      CSV.generate do |csv|
        csv << ["Field", "Value"]
        flatten_hash(data).each { |k, v| csv << [k, v] }
      end
    end

    def to_xml(data)
      "<?xml version=\"1.0\"?>\n<data_export>\n#{hash_to_xml(data, 1)}</data_export>"
    end

    def flatten_hash(hash, prefix = "")
      hash.flat_map do |k, v|
        key = prefix.empty? ? k.to_s : "#{prefix}.#{k}"
        v.is_a?(Hash) ? flatten_hash(v, key) : [[key, v]]
      end
    end

    def hash_to_xml(hash, indent = 0)
      hash.map do |k, v|
        spaces = "  " * indent
        if v.is_a?(Hash)
          "#{spaces}<#{k}>\n#{hash_to_xml(v, indent + 1)}#{spaces}</#{k}>\n"
        elsif v.is_a?(Array)
          "#{spaces}<#{k}>#{v.join(', ')}</#{k}>\n"
        else
          "#{spaces}<#{k}>#{v}</#{k}>\n"
        end
      end.join
    end
  end
end
