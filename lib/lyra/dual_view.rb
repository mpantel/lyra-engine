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

    # CRUD view - current database state. Read as the caller reads: under
    # reads_without_purpose :deny it needs a purpose that allows the declared
    # fields, as any read does. Lyra's own comparisons (the mode gate, the
    # sampler, repair) read as Lyra. The row is looked up by the model's
    # primary key, whatever its column is called, and without the model's
    # default scope (from 1.0.1): the comparison is of the two stores, and a
    # soft-deleted row (default_scope { where(deleted_at: nil) }) is still in
    # the table, as its events say.
    def crud_state
      record = model_class.unscoped { model_class.find_by(Lyra.key_column(model_class) => model_id) }

      return { exists: false } unless record

      {
        exists: true,
        attributes: record.attributes,
        timestamps: timestamps_of(record)
      }
    end

    # Event-sourced view - state rebuilt from events
    def event_sourced_state
      stream_name = Lyra.stream_name(model_class, model_id)

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

      # Encrypted attributes are ciphertext in the log, plaintext in the
      # record's attributes: compare like with like.
      state = EncryptedAttributes.open(model_class, StateProjection.new.rebuild_from_events(events))

      # A stream whose last replayed event destroys the record describes a
      # record that no longer exists, as Lyra::ModeTransition.compare reads
      # it: a destroyed record whose row is gone compares clean, and one
      # whose row survives is an existence mismatch. state keeps the last
      # state the events gave the record. A stream with no replayed event at
      # all (only replay: false domain events) describes no record either.
      replayed = events.select { |e| Lyra::Event.operation_of(e) }
      destroyed = replayed.any? && Lyra::Event.operation_of(replayed.last) == :destroyed

      {
        exists: replayed.any? && !destroyed,
        destroyed: destroyed,
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
    # Each attribute whose value differs, keyed by its column name as a
    # string (as Active Record keys attributes), => { crud:, event_sourced: };
    # {} when the row and its replayed state agree (both absent counts as
    # agreeing). When only one of them has the record, one entry in the same
    # shape under the symbol :exists, exists: { crud:, event_sourced: } (true or
    # false each), which no column name (a string) can collide with: never
    # empty, so a caller that checks for {} cannot take it for agreement.
    # Before 1.0.0 agreement was { no_differences: true } and a missing record
    # { exists_mismatch: true }.
    def calculate_differences
      crud = crud_state
      es = event_sourced_state

      return { exists: { crud: crud[:exists], event_sourced: es[:exists] } } if crud[:exists] != es[:exists]
      return {} if !crud[:exists] && !es[:exists]

      crud_attrs = crud[:attributes] || {}
      es_attrs = es[:state] || {}

      differences = {}

      # Build lookup tables with both string and symbol keys
      crud_lookup = build_key_lookup(crud_attrs)
      es_lookup = build_key_lookup(es_attrs)

      # Compare the union of both sources' keys. created_at and updated_at are
      # compared like any other attribute: every event carries them (1.0.0).
      all_keys = (crud_lookup.keys + es_lookup.keys).uniq

      all_keys.each do |key|
        crud_val = crud_lookup[key]
        es_val = es_lookup[key]

        unless values_equal?(crud_val, es_val)
          differences[key.to_s] = {
            crud: crud_val,
            event_sourced: es_val
          }
        end
      end

      # With config.record_touches false (Monitor only), a touch that changed
      # only the update timestamps left no event, so a row whose only
      # difference is in those columns agrees with its events. A difference in
      # any other column is reported with the timestamps beside it.
      differences = {} if !Lyra.config.record_touches && touch_only?(differences)

      # has_and_belongs_to_many links: the join table against the link
      # events (Lyra::Associations::HabtmLinks), by association name.
      differences.merge!(Associations::HabtmLinks.differences(model_class, model_id))

      differences
    end

    # Get audit trail from events
    def audit_trail
      AuditProjection.audit_trail(model_class, model_id)
    end

    private

    # The record's timestamp columns, by name: those the model has
    # (created_at, updated_at, updated_on, ...), none for a model without.
    # Before 1.0.0 created_at and updated_at were read whatever the model had,
    # and a model without one raised NoMethodError.
    def timestamps_of(record)
      klass = record.class
      return {} unless klass.respond_to?(:timestamp_attributes_for_update_in_model)

      names = klass.timestamp_attributes_for_create_in_model | klass.timestamp_attributes_for_update_in_model
      names.to_h { |name| [name.to_sym, record.read_attribute(name)] }
    end

    # Whether every difference is in the model's update timestamps
    # (updated_at, updated_on).
    def touch_only?(differences)
      return false if differences.empty? || !model_class.respond_to?(:timestamp_attributes_for_update_in_model)

      stamps = model_class.timestamp_attributes_for_update_in_model
      differences.each_key.all? { |key| stamps.include?(key.to_s) }
    end

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
          comparison[:differences].any?
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

      if comparison[:differences].key?(:exists)
        recommendations << "State existence mismatch - investigate data consistency"
      end

      if comparison[:differences].any? && !comparison[:differences].key?(:exists)
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
