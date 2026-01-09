# frozen_string_literal: true

module Lyra
  # Error raised when strict data access mode is enabled and a callback-bypassing
  # operation is attempted on a Lyra-monitored model.
  class StrictDataAccessViolation < StandardError
    attr_reader :method_name, :model_class, :alternative

    ALTERNATIVES = {
      update_columns: "update!",
      update_column: "update!",
      delete: "destroy",
      update_all: "find_each { |r| r.update!(...) }",
      delete_all: "find_each(&:destroy)",
      insert_all: "records.each { |attrs| create!(attrs) }",
      insert_all!: "records.each { |attrs| create!(attrs) }",
      upsert_all: "records.each { |attrs| find_or_create_by!(...).update!(attrs) }"
    }.freeze

    def initialize(method_name, model_class)
      @method_name = method_name
      @model_class = model_class
      @alternative = ALTERNATIVES[method_name.to_sym]

      super(build_message)
    end

    private

    def build_message
      msg = "#{method_name} bypasses ActiveRecord callbacks and won't be captured by Lyra."
      msg += " Use #{alternative} instead." if alternative
      msg += " Disable strict_data_access mode if this is intentional."
      msg
    end
  end

  # Module that overrides callback-bypassing instance methods to raise errors
  # when strict_data_access mode is enabled.
  # Uses prepend to properly intercept method calls.
  # When operations are allowed (strict mode off or bypassed), events are created
  # to ensure the event stream captures all state changes.
  module StrictDataAccess
    def update_columns(attributes)
      raise_strict_violation!(:update_columns)
      publish_bypass_update_event(attributes)
      super
    end

    def update_column(name, value)
      raise_strict_violation!(:update_column)
      publish_bypass_update_event({ name => value })
      super
    end

    def delete
      raise_strict_violation!(:delete)
      publish_bypass_destroy_event
      super
    end

    private

    def raise_strict_violation!(method_name)
      return unless Lyra.config.strict_data_access
      return if Thread.current[:lyra_bypass_strict_access]

      raise StrictDataAccessViolation.new(method_name, self.class)
    end

    # Check if this model should have bypass events published
    def should_publish_bypass_event?
      return false unless self.class.respond_to?(:lyra_monitored) && self.class.lyra_monitored
      return false if Lyra.config.mode == :disabled
      true
    end

    # Publish an "updated" event for bypass operations like update_columns
    def publish_bypass_update_event(attributes)
      return unless should_publish_bypass_event?

      # Build changes hash with old and new values
      changes = {}
      attributes.each do |key, new_value|
        key_str = key.to_s
        old_value = read_attribute(key_str)
        changes[key_str] = [old_value, new_value] if old_value != new_value
      end

      return if changes.empty?

      # Get event class
      config = self.class.lyra_config || Lyra.config.model_config(self.class)
      event_name = config.event_name_for(:updated)
      sanitized_name = event_name.to_s.gsub("::", "")

      event_class = if Lyra::Events.const_defined?(sanitized_name, false)
        Lyra::Events.const_get(sanitized_name, false)
      else
        Lyra::Events.const_set(sanitized_name, Class.new(Lyra::Event))
      end

      # Build metadata
      metadata = {
        correlation_id: Lyra::Correlation.current_id,
        causation_id: Lyra::Causation.current_id,
        bypass_source: "update_columns"
      }.compact

      # Build event data
      event_data = {
        model_class: self.class.name,
        model_id: id,
        operation: :updated,
        attributes: attributes.transform_keys(&:to_s),
        changes: changes,
        timestamp: Time.current
      }

      event = event_class.new(data: event_data, metadata: metadata)
      stream_name = "#{self.class.name}$#{id}"

      Lyra.config.event_store.publish(event, stream_name: stream_name)
    rescue => e
      Rails.logger.error("Lyra: Failed to publish bypass update event - #{e.message}")
    end

    # Publish a "destroyed" event for bypass operations like delete
    def publish_bypass_destroy_event
      return unless should_publish_bypass_event?

      # Get event class
      config = self.class.lyra_config || Lyra.config.model_config(self.class)
      event_name = config.event_name_for(:destroyed)
      sanitized_name = event_name.to_s.gsub("::", "")

      event_class = if Lyra::Events.const_defined?(sanitized_name, false)
        Lyra::Events.const_get(sanitized_name, false)
      else
        Lyra::Events.const_set(sanitized_name, Class.new(Lyra::Event))
      end

      # Build metadata
      metadata = {
        correlation_id: Lyra::Correlation.current_id,
        causation_id: Lyra::Causation.current_id,
        bypass_source: "delete"
      }.compact

      # Build event data
      event_data = {
        model_class: self.class.name,
        model_id: id,
        operation: :destroyed,
        attributes: attributes.except("created_at", "updated_at"),
        changes: {},
        timestamp: Time.current
      }

      event = event_class.new(data: event_data, metadata: metadata)
      stream_name = "#{self.class.name}$#{id}"

      Lyra.config.event_store.publish(event, stream_name: stream_name)
    rescue => e
      Rails.logger.error("Lyra: Failed to publish bypass destroy event - #{e.message}")
    end
  end

  # Class methods for bulk operations that bypass callbacks.
  # These are called directly on the model class (not on relations).
  module StrictDataAccessClassMethods
    def insert_all(attributes, **options)
      raise_strict_class_violation!(:insert_all)
      super
    end

    def insert_all!(attributes, **options)
      raise_strict_class_violation!(:insert_all!)
      super
    end

    def upsert_all(attributes, **options)
      raise_strict_class_violation!(:upsert_all)
      super
    end

    # Note: update_all and delete_all are handled via relation extension
    # because they're typically called on scopes (Model.where(...).update_all)

    private

    def raise_strict_class_violation!(method_name)
      return unless Lyra.config.strict_data_access
      return if Thread.current[:lyra_bypass_strict_access]

      raise StrictDataAccessViolation.new(method_name, self)
    end
  end

  # Extension for ActiveRecord::Relation to intercept update_all/delete_all
  # on scoped queries. This is needed because Model.where(...).update_all
  # is called on a Relation, not the model class.
  module StrictDataAccessRelation
    def update_all(updates)
      check_strict_mode!(:update_all, updates)
      super
    end

    def delete_all
      check_strict_mode!(:delete_all)
      super
    end

    private

    def check_strict_mode!(method_name, updates = nil)
      return unless Lyra.config.strict_data_access
      return unless klass.respond_to?(:lyra_monitored) && klass.lyra_monitored

      # Allow update_all when called from Rails association handling (dependent: :nullify)
      # These updates only set a foreign key to NULL and are internal Rails operations
      if method_name == :update_all && association_nullify_update?(updates)
        # Create events for affected records before the bulk update
        # This ensures the event stream captures the state change
        publish_nullify_events(updates) if Lyra.config.mode != :disabled
        return
      end

      # Allow operations when bypassed via Lyra.without_strict_access block
      return if Thread.current[:lyra_bypass_strict_access]

      raise StrictDataAccessViolation.new(method_name, klass)
    end

    # Detect if this is an association nullify operation (dependent: :nullify)
    # Rails sets a single foreign key column to NULL when destroying parent records
    def association_nullify_update?(updates)
      return false unless updates.is_a?(Hash)
      return false unless updates.size == 1

      # Check if it's a foreign key being set to nil
      key, value = updates.first
      value.nil? && key.to_s.end_with?("_id")
    end

    # Publish "updated" events for each record affected by dependent: :nullify
    # This captures the foreign key nullification in the event stream
    def publish_nullify_events(updates)
      column = updates.keys.first.to_s

      # Get the records being updated with their current values
      # In ES Disabled mode, records don't exist in DB, so we need to query
      # the event store via the model's read path (which uses CachedRelation)
      records_data = fetch_affected_records_for_nullify(column)
      return if records_data.empty?

      # Get the event class for updates
      config = klass.lyra_config || Lyra.config.model_config(klass)
      event_name = config.event_name_for(:updated)
      sanitized_name = event_name.to_s.gsub("::", "")

      event_class = if Lyra::Events.const_defined?(sanitized_name, false)
        Lyra::Events.const_get(sanitized_name, false)
      else
        Lyra::Events.const_set(sanitized_name, Class.new(Lyra::Event))
      end

      # Build metadata (only include non-nil values, use strings for RES compatibility)
      metadata = {
        correlation_id: Lyra::Correlation.current_id,
        causation_id: Lyra::Causation.current_id,
        nullify_source: "dependent_association"
      }.compact

      # Publish an event for each affected record
      records_data.each do |id, old_value|
        event_data = {
          model_class: klass.name,
          model_id: id,
          operation: :updated,
          attributes: { column => nil },
          changes: { column => [old_value, nil] },
          timestamp: Time.current
        }

        event = event_class.new(data: event_data, metadata: metadata)
        stream_name = "#{klass.name}$#{id}"

        Lyra.config.event_store.publish(event, stream_name: stream_name)
      end
    rescue => e
      # Don't fail the nullify operation if event publishing fails
      Rails.logger.error("Lyra: Failed to publish nullify events - #{e.message}")
    end

    # Fetch affected records for nullify operation
    # Handles both DB-backed mode and ES Disabled mode (event store only)
    def fetch_affected_records_for_nullify(column)
      # First, try to get records from DB (works in non-ES-Disabled modes)
      records_data = self.pluck(:id, column)
      return records_data unless records_data.empty?

      # In ES Disabled mode, records don't exist in DB
      # Extract the foreign key value from the where clause and query event store
      foreign_key_value = extract_foreign_key_from_where_clause(column)
      return [] unless foreign_key_value

      # Query the model using its normal read path (which uses EventStoreReader in ES mode)
      # This will return records from the event store cache
      if Lyra.event_sourcing_mode? && Lyra.config.projection_mode == :disabled
        cached_records = klass.where(column.to_sym => foreign_key_value)
        cached_records.map { |r| [r.id, r.send(column)] }
      else
        []
      end
    end

    # Extract the foreign key value from the relation's where clause
    # The relation is something like: Registration.where(group_id: 123)
    def extract_foreign_key_from_where_clause(column)
      return nil unless respond_to?(:where_clause)

      where_clause.send(:predicates).each do |predicate|
        next unless predicate.is_a?(Arel::Nodes::Equality)
        next unless predicate.left.respond_to?(:name)
        next unless predicate.left.name.to_s == column

        # Extract the value - Rails 7/8 uses QueryAttribute
        right = predicate.right
        case right
        when Arel::Nodes::Casted
          return right.value
        when Arel::Nodes::BindParam
          return right.value.value_before_type_cast
        when Integer, String
          return right
        else
          # Rails 7/8: ActiveRecord::Relation::QueryAttribute
          if right.respond_to?(:value)
            return right.value
          elsif right.respond_to?(:value_before_type_cast)
            return right.value_before_type_cast
          end
        end
      end

      nil
    rescue => e
      Rails.logger.debug("Lyra: Could not extract foreign key from where clause - #{e.message}")
      nil
    end
  end

  # Temporarily bypass strict data access checks
  # Use this for legitimate bulk operations in migrations, seeds, etc.
  def self.without_strict_access
    previous = Thread.current[:lyra_bypass_strict_access]
    Thread.current[:lyra_bypass_strict_access] = true
    yield
  ensure
    Thread.current[:lyra_bypass_strict_access] = previous
  end
end
