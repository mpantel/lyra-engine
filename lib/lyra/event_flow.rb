module Lyra
  # Visualizes event flows and chains
  class EventFlow
    attr_reader :subject_id, :subject_type, :time_range

    def initialize(subject_id: nil, subject_type: nil, time_range: nil)
      @subject_id = subject_id
      @subject_type = subject_type
      @time_range = time_range || (30.days.ago..Time.current)
    end

    # Get complete event flow for visualization
    def flow_data
      events = load_events
      grouped = group_by_correlation(events)

      {
        timeline: build_timeline(events),
        flows: build_flows(grouped),
        statistics: calculate_statistics(events),
        privacy_impact: analyze_privacy_impact(events)
      }
    end

    # Build timeline view showing CRUD operations and their events
    def build_timeline(events)
      events.sort_by { |e| event_timestamp(e) }.map do |event|
        {
          event_id: event.event_id,
          timestamp: event_timestamp(event),
          operation: event_operation(event),
          model_class: event_model_class(event),
          model_id: event_model_id(event),
          correlation_id: event.metadata[:correlation_id],
          action_id: event.metadata[:action_id],
          user_action: event.metadata[:user_action],
          changes: event_changes(event),
          pii_fields: detect_pii(event),
          grouped_with: find_grouped_events(event, events)
        }
      end
    end

    # Build event flows showing cause and effect
    def build_flows(grouped_events)
      grouped_events.map do |correlation_id, events|
        {
          correlation_id: correlation_id,
          started_at: event_timestamp(events.min_by { |e| event_timestamp(e) }),
          completed_at: event_timestamp(events.max_by { |e| event_timestamp(e) }),
          duration: calculate_duration(events),
          user_action: events.first.metadata[:user_action],
          user_id: events.first.metadata[:user_id],
          events_chain: build_event_chain(events),
          crud_operations: extract_crud_operations(events),
          privacy_impact: calculate_flow_privacy_impact(events)
        }
      end
    end

    # Show how a single CRUD operation maps to events
    # +model_class+ may be a class or its name; +operation+ a symbol or
    # string; +model_id+ an id or its string form (as a request passes it).
    def crud_to_event_mapping(model_class, operation, model_id = nil)
      model_name = model_name_of(model_class)
      operation = operation&.to_sym
      events = load_events.select do |event|
        matches = event_model_class(event).to_s == model_name && event_operation(event) == operation
        matches &&= event_model_id(event).to_s == model_id.to_s if model_id
        matches
      end

      {
        crud_operation: {
          model: model_name,
          operation: operation,
          record_id: model_id
        },
        generated_events: events.map { |e| event_summary(e) },
        count: events.count,
        timeline: events.sort_by { |e| event_timestamp(e) }.map do |e|
          {
            timestamp: event_timestamp(e),
            event_type: e.class.name,
            event_id: e.event_id,
            data: e.data
          }
        end
      }
    end

    # Reconstruct state from event chain
    def reconstruct_state_chain(model_class, model_id)
      stream_name = "#{model_class}$#{model_id}"
      events = Lyra.config.event_store.read.stream(stream_name).to_a

      chain = []
      state = {}

      events.sort_by { |e| event_timestamp(e) }.each do |event|
        previous_state = state.dup

        case event_operation(event)
        when :created, :imported
          state = event_attributes(event).dup
        when :updated
          event_changes(event).each { |k, (old, new)| state[k] = new }
        when :destroyed
          state[:_deleted] = true
          state[:_deleted_at] = event_timestamp(event)
        end

        chain << {
          event_id: event.event_id,
          timestamp: event_timestamp(event),
          operation: event_operation(event),
          previous_state: previous_state,
          changes: event_changes(event),
          new_state: state.dup,
          pii_changed: identify_pii_changes(previous_state, state),
          user_action: event.metadata[:user_action]
        }
      end

      {
        model: { class: model_class, id: model_id },
        initial_state: {},
        final_state: state,
        events_count: events.count,
        state_evolution: chain
      }
    end

    # Visualize data lineage for GDPR compliance
    def data_lineage(field_name, model_class = nil)
      events = load_events

      if model_class
        model_name = model_name_of(model_class)
        events = events.select { |e| event_model_class(e).to_s == model_name }
      end

      lineage = []

      events.each do |event|
        attrs = event_attributes(event)
        changes = event_changes(event)
        if attrs.key?(field_name) || attrs.key?(field_name.to_s) || changes.key?(field_name) || changes.key?(field_name.to_s)
          lineage << {
            timestamp: event_timestamp(event),
            event_id: event.event_id,
            model: event_model_class(event),
            record_id: event_model_id(event),
            operation: event_operation(event),
            old_value: changes.dig(field_name, 0) || changes.dig(field_name.to_s, 0),
            new_value: changes.dig(field_name, 1) || changes.dig(field_name.to_s, 1) || attrs[field_name] || attrs[field_name.to_s],
            source: event.metadata[:source],
            user_id: event.metadata[:user_id],
            action: event.metadata[:user_action]
          }
        end
      end

      {
        field: field_name,
        model_class: model_class && model_name_of(model_class),
        total_modifications: lineage.count,
        first_seen: lineage.min_by { |l| l[:timestamp] }&.dig(:timestamp),
        last_modified: lineage.max_by { |l| l[:timestamp] }&.dig(:timestamp),
        lineage: lineage.sort_by { |l| l[:timestamp] }
      }
    end

    # Analyze privacy impact of event chains
    def privacy_impact_analysis
      events = load_events
      pii_inventory = extract_pii_from_events(events)

      {
        total_events: events.count,
        events_with_pii: events.count { |e| has_pii?(e) },
        pii_categories: pii_inventory.keys,
        pii_fields_count: pii_inventory.values.sum(&:count),
        sensitive_operations: identify_sensitive_operations(events),
        data_flows: trace_data_flows(events),
        risk_assessment: assess_privacy_risk(events, pii_inventory)
      }
    end

    private

    # Helper methods to extract data from events (works with both Lyra::Event and RubyEventStore::Event)
    def event_operation(event)
      return event.operation if event.respond_to?(:operation)
      op = event.data[:operation] || event.data["operation"]
      op.is_a?(String) ? op.to_sym : op
    end

    # A model class or its name, as the name events record.
    def model_name_of(model_class)
      model_class.is_a?(Module) ? model_class.name : model_class.to_s
    end

    def event_model_class(event)
      return event.model_class if event.respond_to?(:model_class)
      event.data[:model_class] || event.data["model_class"]
    end

    def event_model_id(event)
      return event.model_id if event.respond_to?(:model_id)
      event.data[:model_id] || event.data["model_id"]
    end

    def event_timestamp(event)
      return event.timestamp if event.respond_to?(:timestamp) && event.timestamp
      event.data[:timestamp] || event.data["timestamp"] || event.metadata[:timestamp]
    end

    def event_attributes(event)
      return event.attributes if event.respond_to?(:attributes) && !event.attributes.is_a?(Hash)
      event.data[:attributes] || event.data["attributes"] || {}
    end

    def event_changes(event)
      return event.changes if event.respond_to?(:changes) && event.method(:changes).owner != ActiveRecord::AttributeMethods::Dirty
      event.data[:changes] || event.data["changes"] || {}
    end

    def load_events
      events = Lyra.config.event_store.read.to_a

      # Filter by subject if specified
      if subject_id && subject_type
        events = events.select { |e| event_relates_to_subject?(e) }
      end

      # Filter by time range
      events = events.select { |e| time_range.cover?(parse_timestamp(event_timestamp(e))) }

      events
    end

    def event_relates_to_subject?(event)
      event.metadata[:user_id] == subject_id ||
      event.data[:user_id] == subject_id ||
      (event_model_class(event) == subject_type && event_model_id(event) == subject_id)
    end

    def group_by_correlation(events)
      events.group_by { |e| e.metadata[:correlation_id] || e.event_id }
    end

    def build_event_chain(events)
      events.sort_by { |e| event_timestamp(e) }.map do |event|
        {
          event_id: event.event_id,
          timestamp: event_timestamp(event),
          event_type: event.class.name,
          operation: event_operation(event),
          model: "#{event_model_class(event)}##{event_model_id(event)}",
          changes: event_changes(event),
          pii_affected: detect_pii(event).any?
        }
      end
    end

    def extract_crud_operations(events)
      events.map do |event|
        {
          operation: event_operation(event),
          model: event_model_class(event),
          record_id: event_model_id(event),
          timestamp: event_timestamp(event)
        }
      end
    end

    def calculate_duration(events)
      return 0 if events.empty?
      max_time = parse_timestamp(event_timestamp(events.max_by { |e| event_timestamp(e) }))
      min_time = parse_timestamp(event_timestamp(events.min_by { |e| event_timestamp(e) }))
      (max_time - min_time).to_f
    end

    def parse_timestamp(timestamp)
      return timestamp if timestamp.is_a?(Time) || timestamp.is_a?(DateTime)
      return timestamp.to_time if timestamp.respond_to?(:to_time)
      Time.parse(timestamp.to_s)
    end

    def calculate_statistics(events)
      {
        total_events: events.count,
        operations: events.group_by { |e| event_operation(e) }.transform_values(&:count),
        models: events.group_by { |e| event_model_class(e) }.transform_values(&:count),
        hourly_distribution: hourly_distribution(events),
        users: events.map { |e| e.metadata[:user_id] }.compact.uniq.count
      }
    end

    def hourly_distribution(events)
      events.group_by { |e| parse_timestamp(event_timestamp(e)).hour }.transform_values(&:count)
    end

    def detect_pii(event)
      return {} unless Lyra.privacy_features_available?

      Lyra::Privacy::PIIDetector.detect(event_attributes(event))
    end

    def has_pii?(event)
      detect_pii(event).any?
    end

    def find_grouped_events(event, all_events)
      correlation_id = event.metadata[:correlation_id]
      return [] unless correlation_id

      all_events.select do |e|
        e.metadata[:correlation_id] == correlation_id && e.event_id != event.event_id
      end.map(&:event_id)
    end

    def calculate_flow_privacy_impact(events)
      pii_count = events.count { |e| has_pii?(e) }
      {
        events_with_pii: pii_count,
        percentage: events.empty? ? 0 : (pii_count.to_f / events.count * 100).round(2),
        pii_types: events.flat_map { |e| detect_pii(e).values.map { |v| v[:type] } }.uniq
      }
    end

    def identify_pii_changes(old_state, new_state)
      return {} unless Lyra.privacy_features_available?

      changes = {}

      new_state.each do |key, new_value|
        old_value = old_state[key]
        if old_value != new_value && Lyra::Privacy::PIIDetector.contains_pii?(key)
          changes[key] = { from: old_value, to: new_value }
        end
      end

      changes
    end

    def event_summary(event)
      {
        event_id: event.event_id,
        timestamp: event_timestamp(event),
        operation: event_operation(event),
        has_pii: has_pii?(event)
      }
    end

    def analyze_privacy_impact(events)
      pii_inventory = extract_pii_from_events(events)

      {
        pii_categories: pii_inventory.keys,
        total_pii_fields: pii_inventory.values.sum(&:count),
        sensitive_data_present: pii_inventory.keys.any? { |k|
          [:ssn, :credit_card, :health, :biometric].include?(k)
        }
      }
    end

    def extract_pii_from_events(events)
      # Custom implementation that uses event_attributes helper
      inventory = Hash.new { |h, k| h[k] = [] }
      events.each do |event|
        pii = detect_pii(event)
        pii.each do |field, info|
          inventory[info[:type]] << { field: field, model: event_model_class(event) }
        end
      end
      inventory
    end

    def identify_sensitive_operations(events)
      events.select { |e| has_pii?(e) && [:destroyed, :updated].include?(event_operation(e)) }
             .map { |e| event_summary(e) }
    end

    def trace_data_flows(events)
      # Identify how data flows between models
      flows = Hash.new { |h, k| h[k] = [] }

      events.each do |event|
        pii = detect_pii(event)
        next if pii.empty?

        source = event_model_class(event)
        pii.each do |field, info|
          flows[info[:type]] << {
            source_model: source,
            field: field,
            timestamp: event_timestamp(event),
            operation: event_operation(event)
          }
        end
      end

      flows
    end

    def assess_privacy_risk(events, pii_inventory)
      risk_factors = []

      # Check for sensitive PII
      if pii_inventory.keys.any? { |k| [:ssn, :credit_card, :health].include?(k) }
        risk_factors << { level: :high, reason: "Contains highly sensitive PII" }
      end

      # Check for many PII fields
      if pii_inventory.values.sum(&:count) > 10
        risk_factors << { level: :medium, reason: "Large number of PII fields" }
      end

      # Check for frequent modifications
      update_events = events.count { |e| event_operation(e) == :updated && has_pii?(e) }
      if update_events > 50
        risk_factors << { level: :medium, reason: "Frequent PII modifications" }
      end

      {
        overall_risk: calculate_overall_risk(risk_factors),
        factors: risk_factors,
        recommendations: generate_recommendations(risk_factors)
      }
    end

    def calculate_overall_risk(risk_factors)
      return :low if risk_factors.empty?
      return :high if risk_factors.any? { |f| f[:level] == :high }
      return :medium if risk_factors.any? { |f| f[:level] == :medium }
      :low
    end

    def generate_recommendations(risk_factors)
      recommendations = []

      if risk_factors.any? { |f| f[:reason].include?("sensitive") }
        recommendations << "Implement field-level encryption for sensitive PII"
        recommendations << "Enable audit logging for all sensitive data access"
      end

      if risk_factors.any? { |f| f[:reason].include?("modifications") }
        recommendations << "Review data retention policies"
        recommendations << "Implement change approval workflows"
      end

      recommendations << "Regular GDPR compliance audits recommended" if risk_factors.any?

      recommendations
    end
  end
end
