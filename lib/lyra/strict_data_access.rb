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
      msg = "#{method_name} bypasses ActiveRecord callbacks: validations and the Lyra " \
            "interceptor don't run, and Lyra can only record it as a bypass event."
      msg += " Use #{alternative} instead." if alternative
      msg += " Disable strict_data_access mode if this is intentional."
      msg
    end
  end

  # Guards callback-bypassing writes on monitored models.
  #
  # With strict_data_access on, each one raises unless it runs inside
  # Lyra.without_strict_access. Whenever one is allowed to run, it publishes
  # a bypass event per affected record (see BypassEvents), so the event
  # stream records the change whatever the strict setting. Lyra's own
  # read-model writes run inside Lyra.projection_write and publish nothing.
  #
  # Instance methods, prepended onto each monitored model. The bulk methods
  # are on StrictDataAccessRelation below.
  module StrictDataAccess
    # The event is built from the record after the write: the old value is
    # what was last persisted (attribute_in_database), the new value is what
    # the record holds once Rails has written it. Taking the old value from
    # the in-memory attribute instead missed the common idiom "assign, then
    # update_columns": the attribute already held the new value, no change
    # was seen, and no event was published (Solidus's
    # Shipment#persist_amounts). Building after the write also covers the
    # timestamps that touch: true sets.
    def update_columns(attributes)
      raise_strict_violation!(:update_columns)
      with_bypass_event(bypass_column_names(attributes), "update_columns") { super }
    end

    # Rails implements update_column(name, value, touch:) as update_columns,
    # which publishes the event; publishing here as well produced it twice.
    # The touch: keyword is passed through.
    def update_column(name, value, touch: nil)
      raise_strict_violation!(:update_column)
      super
    end

    # touch skips save callbacks too (Solidus records order completion with
    # touch(:completed_at)). It is not a strict-mode violation: Rails itself
    # calls it for belongs_to ... touch: true.
    def touch(*names, time: nil)
      columns = (timestamp_attributes_for_update_in_model | names.map(&:to_s)).map do |name|
        self.class.attribute_aliases[name] || name
      end
      with_bypass_event(columns, "touch") { super }
    end

    def delete
      raise_strict_violation!(:delete)
      if Lyra::BypassEvents.enabled_for?(self.class)
        safely_publish("delete") do
          Lyra::BypassEvents.publish(self.class, id, :destroyed,
                                     attributes: attributes.except(*Lyra::BypassEvents::TIMESTAMP_COLUMNS),
                                     source: "delete")
        end
      end
      super
    end

    private

    def raise_strict_violation!(method_name)
      return unless Lyra.config.strict_data_access
      return if Thread.current[:lyra_bypass_strict_access]

      raise StrictDataAccessViolation.new(method_name, self.class)
    end

    # Columns an update_columns call writes, including the timestamps that
    # its touch: option adds.
    def bypass_column_names(attributes)
      touch = attributes[:touch] || attributes["touch"]
      names = attributes.keys.map(&:to_s).reject { |k| k == "touch" }
      names = names.map { |k| self.class.attribute_aliases[k] || k }
      return names unless touch

      names | timestamp_attributes_for_update_in_model | (touch == true ? [] : Array.wrap(touch).map(&:to_s))
    end

    # In an events-only store (ES-NoProj) there is no row: the UPDATE matches
    # nothing and returns false, and the event is the write. Publishing only
    # on a matched row lost every update_columns and touch there.
    def with_bypass_event(columns, source)
      Lyra::BypassEvents.atomically(self.class) do
        events_only = Lyra.event_sourcing_mode? && Lyra.config.projection_mode == :disabled
        before = columns.to_h { |c| [c, attribute_in_database(c)] }
        result = yield
        written = result || events_only
        changes = columns.each_with_object({}) do |c, h|
          now = read_attribute(c)
          h[c] = [before[c], now] unless before[c] == now
        end
        publish_bypass_update_event(changes, source) if written && changes.any?
        events_only ? written : result
      end
    end

    # Publish an "updated" event for a write that bypassed callbacks.
    # +changes+ maps column => [old, new].
    def publish_bypass_update_event(changes, source)
      return unless Lyra::BypassEvents.enabled_for?(self.class)

      safely_publish(source) do
        Lyra::BypassEvents.publish(self.class, id, :updated,
                                   attributes: changes.transform_values(&:last), changes: changes,
                                   source: source)
      end
    end

    # A failed publish fails the write in Hijack and the event-sourcing
    # modes, and is logged in Monitor (BypassEvents.required?).
    def safely_publish(source)
      yield
    rescue => e
      Lyra::BypassEvents.publish_failed!(e, source)
    end
  end

  # Relation extension for the bulk methods. Model.insert_all, Model.upsert,
  # author.articles.insert_all and Model.where(...).update_all all end up
  # here: ActiveRecord delegates the class-level forms to the relation.
  module StrictDataAccessRelation
    def update_all(updates)
      return super unless lyra_guarded?

      # dependent: :nullify is Rails' own bookkeeping when a parent is
      # destroyed through callbacks. It is always allowed, but the children
      # it rewrites still get events.
      if association_nullify_update?(updates)
        publish_nullify_events(updates) if Lyra::BypassEvents.enabled_for?(klass)
        return super
      end

      check_strict_mode!(:update_all)
      return super unless Lyra::BypassEvents.enabled_for?(klass)

      Lyra::BypassEvents.atomically(klass) do
        before = Lyra::BypassEvents.snapshot(klass, self)
        result = super
        safely_publish_bulk("update_all") { Lyra::BypassEvents.publish_updates(klass, before, source: "update_all") }
        result
      end
    end

    def delete_all
      return super unless lyra_guarded?

      check_strict_mode!(:delete_all)
      return super unless Lyra::BypassEvents.enabled_for?(klass)

      Lyra::BypassEvents.atomically(klass) do
        before = Lyra::BypassEvents.snapshot(klass, self)
        result = super
        safely_publish_bulk("delete_all") { Lyra::BypassEvents.publish_destroys(klass, before, source: "delete_all") }
        result
      end
    end

    def insert_all(attributes, returning: nil, **options)
      return super unless lyra_guarded?

      check_strict_mode!(:insert_all)
      return super unless Lyra::BypassEvents.enabled_for?(klass)

      Lyra::BypassEvents.atomically(klass) do
        result, ids = with_primary_keys(returning) { |ret| super(attributes, returning: ret, **options) }
        safely_publish_bulk("insert_all") { Lyra::BypassEvents.publish_upserts(klass, {}, ids, source: "insert_all") }
        result
      end
    end

    def insert_all!(attributes, returning: nil, **options)
      return super unless lyra_guarded?

      check_strict_mode!(:insert_all!)
      return super unless Lyra::BypassEvents.enabled_for?(klass)

      Lyra::BypassEvents.atomically(klass) do
        result, ids = with_primary_keys(returning) { |ret| super(attributes, returning: ret, **options) }
        safely_publish_bulk("insert_all!") { Lyra::BypassEvents.publish_upserts(klass, {}, ids, source: "insert_all!") }
        result
      end
    end

    # One statement inserts some rows and updates others. The rows that
    # already existed are found by the conflict key before the write; after
    # it, those are "updated" (with their changes) and the rest "created".
    def upsert_all(attributes, returning: nil, unique_by: nil, **options)
      return super unless lyra_guarded?

      check_strict_mode!(:upsert_all)
      return super unless Lyra::BypassEvents.enabled_for?(klass)

      if Lyra.event_sourcing_mode? && Lyra.config.projection_mode == :disabled
        raise ArgumentError, "upsert_all can't be used in event sourcing mode with projections disabled: " \
                             "its ON CONFLICT check runs against the table, not the event stream. " \
                             "Use find_or_initialize_by(...).update!(...) per record."
      end

      rows = Array(attributes).map { |row| row.to_h.transform_keys(&:to_s) }
      keys = conflict_columns(unique_by)
      Lyra::BypassEvents.atomically(klass) do
        before = Lyra::BypassEvents.snapshot_by_keys(klass, rows, keys)
        result, ids = with_primary_keys(returning) do |ret|
          super(attributes, returning: ret, unique_by: unique_by, **options)
        end
        ids ||= Lyra::BypassEvents.snapshot_by_keys(klass, rows, keys).keys
        safely_publish_bulk("upsert_all") { Lyra::BypassEvents.publish_upserts(klass, before, ids, source: "upsert_all") }
        result
      end
    end

    private

    def lyra_guarded?
      klass.respond_to?(:lyra_monitored) && klass.lyra_monitored
    end

    # Run the write with the primary key in RETURNING, so the inserted and
    # updated rows can be identified, and hand the caller the result they
    # asked for. Returns [caller_result, ids]; ids is nil only when the
    # caller passed raw SQL for returning without the primary key.
    def with_primary_keys(returning)
      pk = klass.primary_key
      request, strip = case returning
                       when nil then [nil, nil]
                       when false then [[pk], :all]
                       when Arel::Nodes::SqlLiteral then [returning, nil]
                       else
                         columns = Array(returning).map(&:to_s)
                         columns.include?(pk) ? [returning, nil] : [columns + [pk], :pk]
                       end

      result = yield(request)
      index = result.columns.index(pk)
      ids = index && result.rows.map { |row| row[index] }

      caller_result = case strip
                      when :all then ActiveRecord::Result.empty
                      when :pk
                        ActiveRecord::Result.new(result.columns.reject.with_index { |_, i| i == index },
                                                 result.rows.map { |row| row.reject.with_index { |_, i| i == index } })
                      else result
                      end
      [caller_result, ids]
    end

    # The columns upsert_all's ON CONFLICT uses: unique_by as columns, or as
    # an index name, or the primary key by default.
    def conflict_columns(unique_by)
      return [klass.primary_key] if unique_by.nil?

      columns = Array(unique_by).map(&:to_s)
      return columns unless columns.size == 1 && !klass.column_names.include?(columns.first)

      index = klass.connection.indexes(klass.table_name).find { |i| i.name == columns.first }
      Array(index&.columns).map(&:to_s)
    end

    def check_strict_mode!(method_name)
      return unless Lyra.config.strict_data_access
      return if Thread.current[:lyra_bypass_strict_access]

      raise StrictDataAccessViolation.new(method_name, klass)
    end

    def safely_publish_bulk(source)
      yield
    rescue => e
      Lyra::BypassEvents.publish_failed!(e, source)
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

      records_data.each do |id, old_value|
        Lyra::BypassEvents.publish(klass, id, :updated,
                                   attributes: { column => nil },
                                   changes: { column => [old_value, nil] },
                                   source: "dependent_association")
      end
    rescue => e
      # Fails the parent's destroy in Hijack and the event-sourcing modes
      # (it runs inside its transaction); logged in Monitor.
      Lyra::BypassEvents.publish_failed!(e, "dependent_association")
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

  # Temporarily bypass strict data access checks, for legitimate bulk
  # operations in migrations, seeds, etc. The writes still publish bypass
  # events; Lyra's own read-model writes use Lyra.projection_write instead.
  def self.without_strict_access
    previous = Thread.current[:lyra_bypass_strict_access]
    Thread.current[:lyra_bypass_strict_access] = true
    yield
  ensure
    Thread.current[:lyra_bypass_strict_access] = previous
  end
end
