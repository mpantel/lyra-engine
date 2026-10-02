module Lyra
  # Provides dual view comparison between CRUD state and Event-sourced state
  class DualView
    TIME_PRECISION = 6

    attr_reader :model_class, :model_id

    def initialize(model_class, model_id)
      @model_class = model_class
      @model_id = model_id
    end

    # Get both CRUD and Event-sourced views
    def compare
      {
        crud_view: crud_state,
        event_sourced_view: event_sourced_state,
        differences: calculate_differences,
        metadata: {
          model_class: model_class.name,
          model_id: model_id,
          timestamp: Time.current,
          mode: Lyra.config.mode
        }
      }
    end

    # CRUD view - current database state
    def crud_state
      record = model_class.find_by(id: model_id)

      return { exists: false } unless record

      {
        exists: true,
        attributes: record.attributes,
        timestamps: {
          created_at: record.created_at,
          updated_at: record.updated_at
        }
      }
    end

    # Event-sourced view - state rebuilt from events
    def event_sourced_state
      stream_name = "#{model_class.name}$#{model_id}"

      begin
        events = Lyra.config.event_store.read.stream(stream_name).to_a
      rescue => e
        return {
          exists: false,
          error: e.message,
          events_count: 0
        }
      end

      return { exists: false, events_count: 0 } if events.empty?

      state = StateProjection.new.rebuild_from_events(events)

      {
        exists: true,
        state: state,
        events_count: events.count,
        first_event_at: event_timestamp(events.first),
        last_event_at: event_timestamp(events.last),
        events_summary: events.map { |e| { type: e.class.name, operation: event_operation(e), timestamp: event_timestamp(e) } }
      }
    end

    # Helper methods to extract data from events (works with both Lyra::Event and RubyEventStore::Event)
    def event_timestamp(event)
      return event.timestamp if event.respond_to?(:timestamp) && event.timestamp
      event.data[:timestamp] || event.data["timestamp"] || event.metadata[:timestamp]
    end

    def event_operation(event)
      return event.operation if event.respond_to?(:operation)
      op = event.data[:operation] || event.data["operation"]
      op.is_a?(String) ? op.to_sym : op
    end

    # Calculate differences between CRUD and Event-sourced states
    def calculate_differences
      crud = crud_state
      es = event_sourced_state

      return { exists_mismatch: true } if crud[:exists] != es[:exists]
      return { no_differences: true } if !crud[:exists] && !es[:exists]

      crud_attrs = crud[:attributes] || {}
      es_attrs = es[:state] || {}

      differences = {}

      # Build lookup tables with both string and symbol keys
      crud_lookup = build_key_lookup(crud_attrs)
      es_lookup = build_key_lookup(es_attrs)

      # Compare union of all keys from both sources, excluding DB-managed timestamps
      ignored_keys = %i[created_at updated_at]
      all_keys = (crud_lookup.keys + es_lookup.keys).uniq - ignored_keys

      all_keys.each do |key|
        crud_val = crud_lookup[key]
        es_val = es_lookup[key]

        unless values_equal?(crud_val, es_val)
          differences[key] = {
            crud: crud_val,
            event_sourced: es_val
          }
        end
      end

      differences.empty? ? { no_differences: true } : differences
    end

    # Get audit trail from events
    def audit_trail
      AuditProjection.audit_trail(model_class, model_id)
    end

    private

    # Build a normalized lookup table from attributes hash
    # Converts all keys to symbols for consistent access
    def build_key_lookup(attrs)
      result = {}
      attrs.each do |key, val|
        result[key.to_sym] = val
      end
      result
    end

    # Compare values with type coercion for common mismatches
    def values_equal?(crud_val, es_val)
      return true if crud_val == es_val
      return true if crud_val.nil? && es_val.nil?
      return false if crud_val.nil? || es_val.nil?

      # Normalize for comparison
      normalized_crud = normalize_value(crud_val)
      normalized_es = normalize_value(es_val)

      normalized_crud == normalized_es
    end

    def normalize_value(val)
      case val
      # Times compare at microseconds, the resolution of a PostgreSQL timestamp.
      # Comparing at whole seconds (iso8601 with no fraction) hid an event log
      # that had dropped sub-second time: 15:49:11.420 and 15:49:11 compared equal.
      when Time, DateTime, ActiveSupport::TimeWithZone
        val.utc.iso8601(TIME_PRECISION)
      when Date
        val.iso8601
      when BigDecimal
        val.to_f.round(6)
      when Float
        val.round(6)
      when Integer
        val.to_f
      when String
        # Try to parse as time if it looks like a timestamp
        if val =~ /^\d{4}-\d{2}-\d{2}(T|\s)/
          begin
            Time.parse(val).utc.iso8601(TIME_PRECISION)
          rescue
            val
          end
        # Try to parse as number if it looks numeric
        elsif val =~ /^-?\d+\.?\d*$/
          val.to_f.round(6)
        else
          val
        end
      when TrueClass, FalseClass
        val
      when NilClass
        nil
      else
        val.to_s
      end
    end

    # Class methods for batch comparison
    class << self
      def compare_all(model_class)
        model_class.find_each.map do |record|
          new(model_class, record.id).compare
        end
      end

      def find_discrepancies(model_class)
        compare_all(model_class).select do |comparison|
          comparison[:differences] != { no_differences: true }
        end
      end
    end
  end

  # Analysis tools
  class StateAnalyzer
    def self.analyze(model_class, model_id)
      view = DualView.new(model_class, model_id)

      {
        comparison: view.compare,
        audit_trail: view.audit_trail,
        recommendations: generate_recommendations(view)
      }
    end

    def self.generate_recommendations(view)
      comparison = view.compare
      recommendations = []

      if comparison[:differences][:exists_mismatch]
        recommendations << "State existence mismatch - investigate data consistency"
      end

      if comparison[:differences] != { no_differences: true } && !comparison[:differences][:exists_mismatch]
        recommendations << "Attribute differences detected - consider which source is authoritative"
        recommendations << "Differences: #{comparison[:differences].keys.join(', ')}"
      end

      if comparison[:event_sourced_view][:events_count] == 0 && comparison[:crud_view][:exists]
        recommendations << "CRUD record exists but no events found - may have been created before Lyra was enabled"
      end

      recommendations
    end
  end
end
