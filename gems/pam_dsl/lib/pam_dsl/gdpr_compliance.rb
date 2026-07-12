# frozen_string_literal: true

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
    #
    def initialize(subject_id:, subject_type: 'User', record_reader:, **options)
      @subject_id = subject_id
      @subject_type = subject_type
      @record_reader = record_reader
      @options = options
      @pam_policy = options[:policy_name] ? PamDsl.registry.get(options[:policy_name]) : nil

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
    # @return [Hash] Complete data export including events, PII inventory, and lineage
    #
    def data_export
      events = collect_all_records

      {
        subject: { id: subject_id, type: subject_type },
        generated_at: Time.now,
        events: events.map { |e| event_summary(e) },
        pii_inventory: collect_pii_inventory(events),
        data_lineage: trace_data_lineage(events),
        processing_activities: collect_processing_activities(events)
      }
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

      corrections = events.select do |event|
        extract_operation(event) == :updated && has_pii?(event)
      end

      corrections.map do |event|
        {
          timestamp: extract_timestamp(event),
          model: extract_model_class(event),
          record_id: extract_model_id(event),
          changes: extract_changes(event),
          corrected_fields: identify_pii_changes(extract_changes(event)),
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

      activities.map do |source, source_events|
        {
          source: source,
          purpose: infer_purpose(source, source_events),
          legal_basis: determine_legal_basis(source, source_events),
          data_categories: categorize_data(source_events),
          recipients: identify_recipients(source_events),
          retention_period: determine_retention_period(source_events),
          events_count: source_events.count
        }
      end
    end

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

      {
        current_consents: extract_current_consents(consent_events),
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
        data_export: data_export,
        erasure_report: right_to_be_forgotten_report,
        rectification_history: rectification_history,
        processing_activities: processing_activities,
        retention_compliance: retention_compliance_check,
        consent_audit: consent_audit
      }
    end

    private

    # Collect all events for the subject
    def collect_all_records
      @record_reader.call(subject_id, subject_type)
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
      PIIDetector.detect(extract_attributes(event)).any?
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

    def collect_pii_inventory(events)
      PIIDetector.extract_pii_from_records(
        events,
        attribute_extractor: ->(e) { extract_attributes(e) },
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
        pii_fields = PIIDetector.detect(extract_attributes(event))

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

    def collect_processing_activities(events)
      events.map do |event|
        metadata = event.respond_to?(:metadata) ? event.metadata : {}
        {
          timestamp: extract_timestamp(event),
          activity: extract_operation(event),
          model: extract_model_class(event),
          purpose: infer_purpose(metadata[:source], [event]),
          data_processed: PIIDetector.detect(extract_attributes(event)).keys
        }
      end
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
        attrs = extract_attributes(event)
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
      legitimate_interests: "Legitimate interests (Art. 6(1)(f))"
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
        PIIDetector.detect(extract_attributes(event)).values.map { |v| v[:type] }
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
