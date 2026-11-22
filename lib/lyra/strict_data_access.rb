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
    #
    # A has_one's dependent: :nullify clears its record's key with
    # update_columns: Rails' association code (Lyra::Associations::Maintenance),
    # allowed in strict mode as a has_many's nullify is (a polymorphic key's
    # two columns included). It was refused, and the owner could not be
    # destroyed. Its event is update_columns', as before.
    def update_columns(attributes)
      raise_strict_violation!(:update_columns) unless Lyra::Associations::Maintenance.claim(:nullify, self)
      with_bypass_event(bypass_column_names(attributes), "update_columns", unique: attributes) { super }
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
    # calls it for belongs_to ... touch: true. With optimistic locking it
    # also increments lock_version, which the event records.
    def touch(*names, time: nil)
      columns = (timestamp_attributes_for_update_in_model | names.map(&:to_s)).map do |name|
        self.class.attribute_aliases[name] || name
      end
      columns |= [self.class.locking_column] if Lyra::OptimisticLocking.enabled?(self.class)
      deferred, @lyra_deferred_touch_before = @lyra_deferred_touch_before, nil
      with_bypass_event(columns, "touch", before: deferred) { super }
    end

    # A copy of a record destroyed since it was read (its stream ends in a
    # destroy, read under the aggregate lock: Lyra::BypassEvents
    # .checks_streams?) records nothing and deletes nothing, as Active
    # Record's delete of a row already gone: it appended a second Destroyed,
    # a stream no replay can apply. The record is frozen, as Active Record
    # leaves it; a row still in the table (ES-Async, before the destroy's
    # job runs) is left to the job (Lyra::BypassEvents.unwritten).
    def delete
      raise_strict_violation!(:delete)
      if persisted? && Lyra::BypassEvents.enabled_for?(self.class) && Lyra::BypassEvents.checks_streams?
        return self.class.transaction do
          if Lyra::BypassEvents.destroyed_ids(self.class, [id], write: "delete").any?
            Lyra::BypassEvents.unwritten(self.class) { super }
            self
          else
            safely_publish("delete") do
              Lyra::BypassEvents.publish(self.class, id, :destroyed, attributes: attributes, source: "delete")
            end
            super
          end
        end
      end
      if persisted? && Lyra::BypassEvents.enabled_for?(self.class) && Lyra::BypassEvents.locks_rows?
        # Where the rows are the store: the row locked first; a copy whose
        # row another write deleted records nothing (it appended a second
        # Destroyed), as Active Record's delete reaches no row.
        return Lyra::BypassEvents.atomically(self.class) do
          if lyra_lock_row_for_delete
            safely_publish("delete") do
              Lyra::BypassEvents.publish(self.class, id, :destroyed, attributes: attributes, source: "delete")
            end
          end
          super
        end
      end
      if Lyra::BypassEvents.enabled_for?(self.class)
        safely_publish("delete") do
          Lyra::BypassEvents.publish(self.class, id, :destroyed,
                                     attributes: attributes,
                                     source: "delete")
        end
      end
      super
    end

    private

    # belongs_to ... touch: true runs through Rails' touch_later: it writes
    # the timestamps into the record at once and clears their change
    # (surreptitiously_touch), and calls touch when the transaction commits.
    # By then attribute_in_database holds the new value, so touch saw no change
    # and the cascade published nothing: the parent's row moved and its stream
    # did not. The value the row held before the first deferred touch is kept
    # here, and the next touch takes it as the old value.
    def surreptitiously_touch(attr_names)
      @lyra_deferred_touch_before ||= {}
      attr_names.each do |name|
        name = name.to_s
        @lyra_deferred_touch_before[name] = attribute_in_database(name) unless @lyra_deferred_touch_before.key?(name)
      end
      super
    end

    # Whether the record's row is there, locked (FOR UPDATE) until the
    # transaction ends.
    def lyra_lock_row_for_delete
      klass = self.class
      key = respond_to?(:id_in_database) ? id_in_database : id
      klass.with_connection do |connection|
        sql = "SELECT 1 FROM #{connection.quote_table_name(klass.table_name)} " \
              "WHERE #{connection.quote_column_name(klass.primary_key)} = #{connection.quote(key)} FOR UPDATE"
        connection.uncached { connection.select_value(sql, "Lyra delete row lock") }.present?
      end
    end

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
    # +before+: old values known from elsewhere (a deferred touch's), which
    # attribute_in_database no longer holds.
    #
    # A copy of a record destroyed since it was read (its stream ends in a
    # destroy, read under the aggregate lock where the store can hold a
    # destroy whose row is not gone: Lyra::BypassEvents.checks_streams?)
    # records nothing, writes no row, and returns false, as Active Record's
    # update_columns and touch of a row already gone write nothing and
    # return false (the attributes are set in memory, as there). It
    # appended an update after the destroy and brought the record back.
    #
    # +unique+: the attributes update_columns writes. In ES-NoProj, after the
    # stream check (under the record's aggregate lock, where streams are
    # checked) and before anything is written or recorded: where a value
    # given is the one the copy holds, the record is read from its stream (a
    # copy read before another writer changed it held another value, which
    # its UPDATE in the table modes overwrites: the write recorded nothing);
    # and the values it claims in the table's unique indexes are locked (after
    # the aggregate lock, as Monitor's UPDATE takes the row, then the index
    # entries) and checked against the event store (Lyra::Projections
    # ::UniqueIndexes): a value a live record holds raises
    # ActiveRecord::RecordNotUnique, as the table's UPDATE raises it in the
    # other modes. Before, the duplicate was recorded.
    def with_bypass_event(columns, source, before: nil, unique: nil)
      Lyra::BypassEvents.atomically(self.class) do
        enabled = persisted? && Lyra::BypassEvents.enabled_for?(self.class)
        Lyra::BypassEvents.admit(self.class, [id]) if enabled
        if enabled && Lyra::BypassEvents.checks_streams? &&
           Lyra::BypassEvents.destroyed_ids(self.class, [id], write: source).any?
          Lyra::BypassEvents.unwritten(self.class) { yield }
          next false
        end
        events_only = Lyra.event_sourcing_mode? && Lyra.config.projection_mode == :disabled
        stored = lyra_events_only_columns(unique) if enabled && events_only && unique
        # ES-Lazy: the row as the stream has it, under the lock just taken.
        Lyra::Projections::LazyProjection.refresh_records(self.class, [id]) if enabled && Lyra::BypassEvents.checks_streams?
        lyra_projected_unique_columns(unique) if enabled && unique && !events_only && Lyra.event_sourcing_mode?
        known = before || {}
        before = columns.to_h do |c|
          [c, if known.key?(c) then known[c]
              elsif stored&.key?(c) then stored[c]
              else attribute_in_database(c)
              end]
        end
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

    # ES-NoProj's update_columns(+attributes+), before its write (see
    # with_bypass_event): the record's values as its stream has them, when a
    # value given is the copy's own ({ column => value }, else nil), and the
    # unique values it claims locked and checked.
    def lyra_events_only_columns(attributes)
      klass = self.class
      given = lyra_given_columns(attributes)
      stored = nil
      if given.any? { |column, value| value == attribute_in_database(column) }
        record = Lyra::PurposeBoundReads.internal(INTERNAL) { Lyra::Projections::EventStoreReader.find(klass, id) }
        stored = record && klass.column_names.to_h { |column| [column, record.read_attribute(column)] }
      end
      claims = lyra_unique_column_claims(given, stored)
      if claims.present?
        Lyra::Projections::UniqueIndexes.lock!(klass, claims)
        Lyra::Projections::UniqueIndexes.refuse_taken!(klass, claims, except: id)
      end
      stored
    end

    # { column => value as the record will hold it } of update_columns'
    # +attributes+ (aliases resolved; touch: and unknown names left out).
    def lyra_given_columns(attributes)
      klass = self.class
      attributes.to_h.each_with_object({}) do |(name, value), acc|
        column = klass.attribute_aliases.fetch(name.to_s, name.to_s)
        next if column == "touch" || !klass.column_names.include?(column)

        acc[column] = klass.type_for_attribute(column).cast(value)
      end
    end

    # update_columns(+attributes+) in ES-Sync, ES-Async and ES-Lazy, before
    # its table write (with_bypass_event): the values it sets in the table's
    # unique indexes (Lyra::Projections::UniqueIndexes) are locked, so a
    # write through callbacks checking the value waits for this one, as this
    # one waits for it. Where the table lags the event store (ES-Async: a
    # record created or moved there whose job has not run; ES-Lazy: one
    # written after the write's catch-up) they are then checked against the
    # event store, under the record's aggregate lock: the table's UPDATE
    # missed such a holder and recorded the duplicate, which the holder's
    # projection then met (ES-Async also brings up to date, where it waits
    # for no one, the rows of records that gave the value up, which the
    # UPDATE would meet). ES-Sync's table is current: its UPDATE checks, and
    # its row is locked first (FOR NO KEY UPDATE, as the UPDATE and a save
    # through callbacks lock it), then the values, as Monitor's UPDATE takes
    # the row, then the index entries.
    def lyra_projected_unique_columns(attributes)
      klass = self.class
      indexes = Lyra::Projections::UniqueIndexes
      return unless indexes.enforced?(klass) && indexes.of(klass).any?

      written = lyra_given_columns(attributes).slice(*indexes.columns(klass))
      return if written.empty?

      in_table = indexes.in_table?(klass)
      lyra_lock_own_row(:update) if in_table && respond_to?(:lyra_lock_own_row, true)
      claims = indexes.update_claims(klass, id, written)
      return if claims.empty?

      indexes.lock!(klass, claims)
      indexes.refuse_taken!(klass, claims, except: id) unless in_table
    end

    # The values update_columns claims in the table's unique indexes, in
    # ES-NoProj (Lyra::Projections::UniqueIndexes): for each index with a
    # column whose value it changes (from the record's stream, +stored+, if
    # read), the tuple the record will hold (the values given, the others as
    # the stream has them). nil for a model without such an index.
    def lyra_unique_column_claims(given, stored)
      klass = self.class
      indexes = Lyra::Projections::UniqueIndexes
      return nil unless indexes.enforced?(klass) && indexes.of(klass).any?

      written = given.slice(*indexes.columns(klass)).reject do |column, value|
        held = stored ? stored[column] : attribute_in_database(column)
        indexes.key(klass, column, value) == indexes.key(klass, column, held)
      end
      return nil if written.empty?

      indexes.update_claims(klass, id, written, current: stored)
    end

    # Publish an "updated" event for a write that bypassed callbacks.
    # +changes+ maps column => [old, new].
    def publish_bypass_update_event(changes, source)
      return unless Lyra::BypassEvents.enabled_for?(self.class)
      # A touch (instance, or belongs_to ... touch: true) that changed only the
      # update timestamps, with config.record_touches false in Monitor.
      return if source == "touch" && Lyra::BypassEvents.skip_touch?(self.class, changes)

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

      # Rails' own nullify (a has_many's dependent: :nullify, and children
      # removed from the collection; a has_many :through's
      # dependent: :nullify of its through records), the relation it writes
      # marked by its association code (Lyra::Associations::Maintenance). It
      # is always allowed, but the records it rewrites still get events. The
      # events and the write are one transaction where events are required:
      # a write that fails after its events were published takes them back.
      # The same write made by the application is an update_all like any
      # other, below.
      if Lyra::Associations::Maintenance.claim(:nullify, self) && updates.is_a?(Hash)
        return super unless Lyra::BypassEvents.enabled_for?(klass)

        return Lyra::BypassEvents.atomically(klass) do
          skipped = publish_nullify_events(updates)
          # A child whose stream ends in a destroy (ES-Async, before its
          # job deletes the row) is left as it is, as its event was.
          next super if skipped.blank?

          Lyra.projection_write(INTERNAL) { where.not(klass.primary_key => skipped).update_all(updates) }
        end
      end

      check_strict_mode!(:update_all)
      return super unless Lyra::BypassEvents.enabled_for?(klass)
      # ES-NoProj: an Active Record relation of the model (one built past
      # Lyra's reads) clearing a foreign key writes the records the event
      # store holds that it selects, as it did when it was taken for a
      # nullify, now as an update_all (CachedRelation#update_all: strict
      # mode, the stream checks, the lock limit, an event per record).
      return events_only_relation("update_all(#{updates.keys.first}: nil)").update_all(updates) if events_only_nullify?(updates)

      Lyra::BypassEvents.atomically(klass) do
        lock = Lyra::BypassEvents.locks_rows?
        before = lock ? Lyra::BypassEvents.locked_snapshot(klass, self, write: "update_all") : Lyra::BypassEvents.snapshot(klass, self)
        projected_unique_update(before, updates) if lock
        result = lock ? write_snapshotted(before) { |rows| rows.update_all(updates) } : super
        safely_publish_bulk("update_all") { Lyra::BypassEvents.publish_updates(klass, before, source: "update_all") }
        result
      end
    end

    # Rails's touch_all is update_all of the timestamp columns, recorded as
    # update_all. With config.record_touches false (Monitor), the rows whose
    # only change is the update timestamp are left out of the log
    # (BypassEvents.skip_touch?).
    def touch_all(*names, time: nil)
      return super unless Lyra.config.skip_touches? && lyra_guarded?

      Lyra::BypassEvents.touching_all { super }
    end

    def delete_all
      # Deleting has_and_belongs_to_many join rows unlinks their owners:
      # always allowed when Rails' association code deletes them (delete,
      # clear, assigning, destroying the owner: Lyra::Associations::Maintenance),
      # refused in strict mode when the application does, through the join
      # model or a model of its own on the join table.
      join_model = Lyra::Associations::HabtmLinks.join_model_of(klass)
      if join_model
        association = Lyra::Associations::Maintenance.claim(:unlink, self)
        check_strict_mode!(:delete_all) unless association || !Lyra::Associations::HabtmLinks.guarded?(join_model)
        # A join model's rows unlink its owners; an application model's
        # rows of a join table, every monitored owner they name (several
        # has_and_belongs_to_many can share the table).
        return Lyra::Associations::HabtmLinks.delete_all(self) { super } if join_model.equal?(klass)

        return Lyra::Associations::HabtmLinks.delete_all_on_table(self) { super }
      end
      return super unless lyra_guarded?

      # A has_many :through's through records, deleted when records are
      # removed from it (Lyra::Associations::Maintenance): allowed, and
      # recorded as any delete_all.
      check_strict_mode!(:delete_all) unless Lyra::Associations::Maintenance.claim(:unlink, self)
      return super unless Lyra::BypassEvents.enabled_for?(klass)

      Lyra::BypassEvents.atomically(klass) do
        lock = Lyra::BypassEvents.locks_rows?
        before = lock ? Lyra::BypassEvents.locked_snapshot(klass, self, write: "delete_all") : Lyra::BypassEvents.snapshot(klass, self)
        result = lock ? write_snapshotted(before) { |rows| rows.delete_all } : super
        safely_publish_bulk("delete_all") { Lyra::BypassEvents.publish_destroys(klass, before, source: "delete_all") }
        result
      end
    end

    # In ES-NoProj a row's primary key conflicts as the event store has it
    # (events_only_inserts): a record it holds is skipped, as the table's
    # ON CONFLICT DO NOTHING skips a row already there in Monitor; a key
    # whose record was destroyed is inserted again, its stream going on with
    # a Created after the Destroyed, as Monitor's log does. In ES-Async the
    # rows of the keys given are brought up to date with their streams
    # first (project_pending_inserts), so the insert conflicts as Monitor's
    # does there too.
    #
    # On a join table (Lyra::Associations::HabtmLinks.join_model_of): guarded
    # as the application's delete_all of join rows is, and recorded as the
    # links the rows written make (join_insert).
    def insert_all(attributes, returning: nil, **options)
      if (join_model = Lyra::Associations::HabtmLinks.join_model_of(klass))
        return join_insert(:insert_all, join_model, attributes, returning) { |ret| super(attributes, returning: ret, **options) }
      end
      return super unless lyra_guarded?

      check_strict_mode!(:insert_all)
      return super unless Lyra::BypassEvents.enabled_for?(klass)

      refuse_composite_key!(:insert_all)
      Lyra::BypassEvents.atomically(klass) do
        skip = options[:unique_by].nil? ? :any : conflict_columns(options[:unique_by])
        attributes = events_only_inserts(attributes, "insert_all", skip: skip)
        locked = project_pending_inserts(attributes, "insert_all")
        attributes, = projected_unique_rows(attributes, "insert_all", skip: skip, keys: locked)
        result, ids = with_primary_keys(returning) { |ret| super(attributes, returning: ret, **options) }
        published = safely_publish_bulk("insert_all") { Lyra::BypassEvents.publish_upserts(klass, {}, ids, source: "insert_all") }
        advance_checkpoints(published, locked)
        result
      end
    end

    def insert_all!(attributes, returning: nil, **options)
      if (join_model = Lyra::Associations::HabtmLinks.join_model_of(klass))
        return join_insert(:insert_all!, join_model, attributes, returning) { |ret| super(attributes, returning: ret, **options) }
      end
      return super unless lyra_guarded?

      check_strict_mode!(:insert_all!)
      return super unless Lyra::BypassEvents.enabled_for?(klass)

      refuse_composite_key!(:insert_all!)
      Lyra::BypassEvents.atomically(klass) do
        attributes = events_only_inserts(attributes, "insert_all!", skip: nil)
        locked = project_pending_inserts(attributes, "insert_all!")
        attributes, = projected_unique_rows(attributes, "insert_all!", skip: nil, keys: locked)
        result, ids = with_primary_keys(returning) { |ret| super(attributes, returning: ret, **options) }
        published = safely_publish_bulk("insert_all!") { Lyra::BypassEvents.publish_upserts(klass, {}, ids, source: "insert_all!") }
        advance_checkpoints(published, locked)
        result
      end
    end

    # One statement inserts some rows and updates others. The rows that
    # already existed are found by the conflict key before the write; after
    # it, those are "updated" (with their changes) and the rest "created".
    def upsert_all(attributes, returning: nil, unique_by: nil, **options)
      if (join_model = Lyra::Associations::HabtmLinks.join_model_of(klass))
        return join_insert(:upsert_all, join_model, attributes, returning, unique_by: unique_by) do |ret|
          super(attributes, returning: ret, unique_by: unique_by, **options)
        end
      end
      return super unless lyra_guarded?

      check_strict_mode!(:upsert_all)
      return super unless Lyra::BypassEvents.enabled_for?(klass)

      refuse_composite_key!(:upsert_all)
      if Lyra.event_sourcing_mode? && Lyra.config.projection_mode == :disabled
        raise Lyra::Projections::UnsupportedQuery.new(
          klass,
          "upsert_all (its ON CONFLICT check runs against the table, not the event stream; " \
          "use find_or_initialize_by(...).update!(...) per record)"
        )
      end

      rows = Array(attributes).map { |row| row.to_h.transform_keys(&:to_s) }
      keys = conflict_columns(unique_by)
      Lyra::BypassEvents.atomically(klass) do
        before = Lyra::BypassEvents.snapshot_by_keys(klass, rows, keys)
        before, locked = lock_upserted_rows(before, rows, keys) if Lyra::BypassEvents.checks_streams?
        _, brought = projected_unique_rows(attributes, "upsert_all", upsert: keys, keys: Array(locked))
        # A record whose row the check brought up to date (ES-Async: its
        # create's job had not run) is updated by the upsert, not created.
        before = Lyra::BypassEvents.snapshot_by_keys(klass, rows, keys) if brought.any?
        result, ids = with_primary_keys(returning) do |ret|
          super(attributes, returning: ret, unique_by: unique_by, **options)
        end
        ids ||= Lyra::BypassEvents.snapshot_by_keys(klass, rows, keys).keys
        published = safely_publish_bulk("upsert_all") { Lyra::BypassEvents.publish_upserts(klass, before, ids, source: "upsert_all") }
        advance_checkpoints(published, locked)
        result
      end
    end

    private

    # Where the table can hold the row of a record whose stream ends in a
    # destroy (Lyra::BypassEvents.checks_streams?: ES-Async before the
    # destroy's projection job runs, ES-Lazy before its next catch-up; in
    # ES-NoProj upsert_all is refused above), the records whose rows the
    # upsert conflicts with have their aggregate locks taken (all or none,
    # within config.bulk_write_lock_limit) and their streams read. ON CONFLICT
    # updated such a row and appended an Updated after the Destroyed,
    # bringing the record back (and the destroy's job then deleted the row,
    # leaving the log and the table apart). Active Record, whose row is
    # gone, inserts a new row there: with the column defaults for what the
    # upsert does not name, under unique_by another key perhaps.
    #
    # In ES-Async (Lyra::BypassEvents.projects_pending?) the records of the
    # keys the rows give are locked too, and every locked record's row is
    # brought up to date with its stream
    # (Lyra::Projections::AsyncProjectionJob.project_pending), then the rows
    # are read again: a destroyed record's row is gone, and the upsert
    # inserts it again, as Active Record does (a Created after the
    # Destroyed); a record whose create was pending has its row, and is
    # updated; one with an update pending is updated from the row its stream
    # has, which the update's job no longer overwrites. Before, a destroy
    # still to be projected refused the upsert (Lyra::RecordDestroyedError).
    #
    # In ES-Lazy the upsert is refused there (Lyra::RecordDestroyedError)
    # before anything is written, as an update of a destroyed record is
    # (BypassEvents.projects_pending? says why it is not projected there).
    # Once the destroy is in the table (the next catch-up), the upsert
    # inserts. The locked rows are then brought up to date with their
    # streams and read again, so the events carry the values the stream has.
    #
    # The rows are read again once the locks are held, whatever was brought
    # up to date: the first read takes no lock, and a projection job (or an
    # ES-Lazy catch-up) that committed between it and the locks changed the
    # rows it read (a destroyed record's row gone, a created one's there).
    # From the stale read the upsert's row was recorded as an update of the
    # destroyed record, or as a second create. Returns [rows read, the keys
    # locked].
    def lock_upserted_rows(before, rows, keys)
      if Lyra::BypassEvents.projects_pending?
        ids = before.keys | explicit_keys(rows)
        return [before, []] if ids.empty?

        Lyra::BypassEvents.lock_streams!(klass, ids, write: "upsert_all")
        Lyra::Projections::AsyncProjectionJob.project_pending(klass, ids)
        return [Lyra::BypassEvents.snapshot_by_keys(klass, rows, keys), ids]
      end
      return [before, []] if before.empty?

      dead = Lyra::BypassEvents.destroyed_ids(klass, before.keys, write: "upsert_all")
      if dead.any?
        raise Lyra::RecordDestroyedError,
              "#{klass.name} #{dead.join(', ')} #{dead.one? ? 'was' : 'were'} destroyed and #{dead.one? ? 'its row is' : 'their rows are'} " \
              "not yet gone from the table (a projection still to run); upsert_all would update #{dead.one? ? 'it' : 'them'} " \
              "and bring #{dead.one? ? 'it' : 'them'} back, so it is refused. Retry once the destroy is projected, " \
              "or create the records again."
      end
      Lyra::Projections::LazyProjection.refresh_records(klass, before.keys)
      [Lyra::BypassEvents.snapshot_by_keys(klass, rows, keys), before.keys]
    end

    def lyra_guarded?
      klass.respond_to?(:lyra_monitored) && klass.lyra_monitored
    end

    # update_all(+updates+) in ES-Sync, ES-Async and ES-Lazy, once the rows
    # it writes (+before+, the snapshot) and their aggregate locks are held
    # (BypassEvents.locked_snapshot): the tuples the records will hold in the
    # table's unique indexes (Lyra::Projections::UniqueIndexes::BulkUpdate)
    # are locked, after the rows, as Monitor's UPDATE takes the rows and then
    # the index entries, so a write through callbacks checking a value waits
    # for this one. Where the table lags the event store (ES-Async, ES-Lazy)
    # they are checked against each other and the event store before the
    # write, as for update_columns (StrictDataAccess
    # #lyra_projected_unique_columns); ES-Sync's UPDATE checks them.
    def projected_unique_update(before, updates)
      return if before.empty? || !Lyra.event_sourcing_mode?

      unique = Lyra::Projections::UniqueIndexes.bulk_update(klass, updates)
      unique&.check!(before.values, check: !Lyra::Projections::UniqueIndexes.in_table?(klass))
    end

    # insert_all, insert_all! (+skip+: the conflicts insert_all's ON
    # CONFLICT DO NOTHING skips: :any, or its unique_by's columns; nil for
    # insert_all!) and upsert_all (+upsert+: its conflict columns) in
    # ES-Sync, ES-Async and ES-Lazy, after the keys the rows give are locked
    # (+keys+): the values each row claims in the table's unique indexes
    # (Lyra::Projections::UniqueIndexes; the primary key is the keys'), as
    # the record would hold them (the column defaults and the relation's
    # scope for what the row does not give), are locked, together counted
    # against config.bulk_write_lock_limit with the keys, so a write through
    # callbacks checking a value waits for the insert, as it waits for that
    # write. ES-Sync's table is current, and its INSERT checks them.
    #
    # Where the table lags the event store (ES-Async: a record whose create
    # or update waits for its job; ES-Lazy: one written after the catch-up
    # the write began with), each value is then looked up in the event store
    # (its value stream, under its lock): the table missed such a holder and
    # inserted the duplicate, which the holder's projection then met. A row
    # whose value a live record other than the row's own key holds is left
    # out of insert_all (as ON CONFLICT DO NOTHING leaves it, on any index,
    # or on its unique_by), and raises ActiveRecord::RecordNotUnique,
    # before anything is written, for insert_all!, a conflict on an index
    # other than insert_all's unique_by, and an upsert's conflict on an
    # index other than its conflict columns (the record the row updates
    # excepted). An upsert's conflict on its conflict columns updates the
    # holder's row: in ES-Async that row is brought up to date first where
    # it waits for its job (UniqueIndexes.bring_rows_up_to_date, which waits
    # for no one), and where it is still not in the table (taken, or in
    # ES-Lazy written after the catch-up) the upsert raises
    # ActiveRecord::RecordNotUnique rather than insert a second record with
    # the value. In ES-Async the rows of records that gave a value up and
    # whose jobs have not run are brought up to date too, so the table does
    # not skip or refuse a row for a value no record holds.
    #
    # Returns [the rows to write, the ids of the records whose rows were
    # brought up to date].
    def projected_unique_rows(attributes, write, skip: nil, upsert: nil, keys: [])
      unique = Lyra::Projections::UniqueIndexes
      return [attributes, []] if Lyra.config.projection_mode == :disabled || !unique.enforced?(klass)

      indexes = unique.of(klass)
      rows = attributes.is_a?(Hash) ? [attributes] : Array(attributes)
      return [attributes, []] if indexes.empty? || rows.empty?

      scope = scope_for_create.transform_keys(&:to_s)
      defaults = klass.column_defaults
      columns = indexes.flat_map(&:columns).uniq
      claims = rows.map do |row|
        values = defaults.merge(scope.merge(row.to_h.to_h { |k, v| [klass.attribute_aliases.fetch(k.to_s, k.to_s), v] }))
        given = columns.to_h { |column| [column, klass.type_for_attribute(column).cast(values[column])] }
        unique.claims(klass) { given[_1] }
      end
      all = claims.flatten
      return [attributes, []] if all.empty?

      Lyra::BypassEvents.check_lock_limit!(klass, all.map { [_1.index.columns.first, _1.values.first] }.uniq.size + keys.size, write)
      unique.lock!(klass, all)
      return [attributes, []] if unique.in_table?(klass)

      pk = klass.primary_key
      type = pk.is_a?(String) ? klass.type_for_attribute(pk) : nil
      brought = []
      seen = {}
      holders = lambda do |claim|
        seen[[claim.index.name, claim.keys]] ||= begin
          held, gave_up = unique.scan(klass, claim)
          brought.concat(unique.bring_rows_up_to_date(klass, gave_up))
          held
        end
      end
      target = upsert&.sort
      kept = rows.each_index.select do |r|
        own = type && explicit_key(rows[r], pk, type)&.to_s
        if upsert
          updated = target == [pk] ? own : nil
          aim = claims[r].find { _1.index.columns.sort == target }
          if aim && (held = holders.(aim) - [own].compact).any?
            updated = held.first
            unless upserted_row_present?(updated, brought)
              raise unique.not_unique(aim)
            end
          end
          refused = claims[r].find { |claim| claim != aim && (holders.(claim) - [own, updated].compact).any? }
          raise unique.not_unique(refused) if refused

          next true
        end
        taken = claims[r].select { |claim| (holders.(claim) - [own].compact).any? }
        next true if taken.empty?

        refused = taken.find { |claim| !(skip == :any || (skip && skip.sort == claim.index.columns.sort)) }
        raise unique.not_unique(refused) if refused

        false
      end
      return [attributes, brought] if kept.size == rows.size

      [kept.map { rows[_1] }, brought]
    end

    # Whether the row of the live record +id+, which an upsert updates by its
    # conflict columns, is in the table: in ES-Async brought up to date
    # first, where its job has not run and nothing has to be waited for.
    def upserted_row_present?(id, brought)
      brought.concat(Lyra::Projections::UniqueIndexes.bring_rows_up_to_date(klass, [id]))
      Lyra::PurposeBoundReads.internal(INTERNAL) do
        klass.uncached { klass.unscoped.where(klass.primary_key => id).exists? }
      end
    end

    # The rows of an insert_all or insert_all! in the events-only store
    # (ES-NoProj), where the event store, not the table, says which records
    # exist. +skip+: the conflicts ON CONFLICT DO NOTHING skips, as Monitor's
    # does: :any (insert_all), the columns of its unique_by, or nil
    # (insert_all!: every conflict raises ActiveRecord::RecordNotUnique).
    #
    # The model's other unique indexes first (events_only_unique_rows),
    # then its primary key. ON CONFLICT DO NOTHING covers a primary key
    # conflict with no unique_by or unique_by the primary key; otherwise
    # (+unique+ below: insert_all!, or an insert_all whose unique_by is
    # another index) a key taken raises ActiveRecord::RecordNotUnique, as
    # Monitor's insert raises it. The records whose keys the rows give are
    # locked (aggregate locks, under config.bulk_write_lock_limit) and read
    # from the store. A row whose record it holds is left out of the insert,
    # as Monitor's ON CONFLICT DO NOTHING leaves it (when +unique+,
    # ActiveRecord::RecordNotUnique is raised, as Monitor's insert raises it,
    # before anything is written). The table's row of any other key whose
    # stream ends in a destroy is deleted (Lyra's own write), so the row is
    # inserted and recorded as Monitor inserts it; one with no stream (a row
    # Genesis skipped) is a record the table holds, and conflicts
    # (events_only_dead_keys).
    # Before, the table answered: a record the store held but the table
    # did not (every record created through callbacks there) was inserted
    # again, a second Created on its live stream, and its attributes
    # overwritten; a key whose record had been inserted with insert_all and
    # then destroyed met that record's row and was skipped, with no event,
    # where Monitor creates the record again. Rows that give no key take
    # the table's sequence, as before. Elsewhere, the rows as given.
    def events_only_inserts(attributes, write, skip:)
      return attributes unless Lyra.event_sourcing_mode? && Lyra.config.projection_mode == :disabled

      rows = attributes.is_a?(Hash) ? [attributes] : Array(attributes)
      # The keys' aggregate locks before the values' (events_only_unique_rows),
      # as an update through callbacks takes them: the record, then the
      # index entry, as Monitor's writes take the row, then the entry.
      given = explicit_keys(rows)
      lock_keys = -> { Lyra::BypassEvents.lock_streams!(klass, given, write: write) if given.any? }
      rows = events_only_unique_rows(rows, write, skip, keys: given.size, before_locks: lock_keys)
      pk = klass.primary_key
      return rows unless pk.is_a?(String)

      unique = !(skip == :any || skip == [pk])
      type = klass.type_for_attribute(pk)
      keyed = rows.map { |row| [row, explicit_key(row, pk, type)] }
      ids = keyed.filter_map(&:last).uniq
      return rows if ids.empty?

      Lyra::BypassEvents.lock_streams!(klass, ids, write: write)
      held = Lyra::PurposeBoundReads.internal(INTERNAL) { Lyra::Projections::EventStoreReader.find_many(klass, ids) }
      taken = held.to_set { _1.read_attribute(pk) }
      dead = events_only_dead_keys(ids.reject { taken.include?(_1) }, taken)
      if unique && taken.any?
        raise ActiveRecord::RecordNotUnique,
              "Lyra: #{klass.name} #{pk} #{taken.first.inspect} is already taken (#{write})"
      end

      Lyra.projection_write(INTERNAL) { klass.unscoped.where(pk => dead).delete_all } if dead.any?
      keyed.reject { |_, id| taken.include?(id) }.map(&:first)
    end

    # Of +ids+ (keys the event store does not hold), those whose table row
    # (left by a destroyed record) is to be deleted for the insert: the
    # streams that end in a destroy. A row with no stream (from before Lyra,
    # which Genesis left without one: config.genesis_unrepresentable :skip)
    # is a record Monitor's table holds, and its key is added to +taken+;
    # it was deleted as a destroyed record's, and its data lost.
    def events_only_dead_keys(ids, taken)
      return [] if ids.empty?

      pk = klass.primary_key
      present = Lyra::PurposeBoundReads.internal(INTERNAL) { klass.unscoped.where(pk => ids).pluck(pk) }
      return [] if present.empty?

      streams = present.to_h { [Lyra.stream_name(klass, _1), _1] }
      dead = Lyra::StreamTail.destroyed_streams(streams.keys).map { streams[_1] }
      taken.merge(present - dead)
      dead
    end

    # The model's unique indexes other than its primary key, checked from
    # the event store as Monitor's table checks them (events_only_inserts).
    # Before, ES-NoProj checked them against its table, which holds no row
    # of a record created through callbacks: a duplicate (an email taken,
    # with no key given) was inserted, a second record with the value, where
    # Monitor's insert_all skips it and insert_all! raises; and the row a
    # destroyed record left there was taken for a live one, skipping (or
    # refusing) a value that is free.
    #
    # Each row's values for each index (the relation's scope and the column
    # defaults filling what it does not give; a row with a NULL among them
    # conflicts with nothing, unless the index is NULLS NOT DISTINCT) are
    # locked as a uniqueness validation of the value locks them
    # (Lyra::Projections::Uniqueness.lock_all!: a multi-column index by its
    # first column's value, coarser, never finer), so a concurrent insert or
    # validated create of the value waits. Those locks and the aggregate
    # locks of the keys the rows give (+keys+) count together against
    # config.bulk_write_lock_limit, PostgreSQL's lock table being what they
    # share: a model with several unique indexes reaches the limit at fewer
    # rows. The keys' locks (+before_locks+) are taken once the limit is
    # checked and before the values', as an update takes its record's lock
    # and then its values'. Then the records that may hold the values are read: those whose
    # events are in the values' streams (Lyra::Projections::UniqueIndexes
    # .candidate_records: one query for the streams, one for their events,
    # one for the records, whatever the model's size), and the table's rows
    # that hold the values (one query per index), each index's values
    # compared as UniqueIndexes.key compares them (as the column holds
    # them; a citext column's by the database's LOWER). Every record was
    # read before (Uniqueness::Snapshot), at a cost that grew with the
    # model: 52.8 s at 10,000 records, cold.
    #
    # A row conflicts with a value a record the store holds has, and with a
    # value a table row holds whose record the store neither holds nor has
    # destroyed (a row from before Lyra that Genesis left without a stream,
    # config.genesis_unrepresentable :skip): skipped where +skip+ covers that
    # index, else ActiveRecord::RecordNotUnique before anything is written.
    # The table's rows whose streams end in a destroy are deleted (Lyra's own
    # write), and the rows of live records that hold a value their records
    # no longer have (written by an insert, updated since through callbacks,
    # which write no row) are brought up to the values the store has, so
    # the insert meets the table as Monitor's does. Rows of the same insert
    # that conflict with each other meet in the table, as in Monitor. Partial
    # and expression indexes are left to the table.
    def events_only_unique_rows(rows, write, skip, keys: 0, before_locks: nil)
      pk = klass.primary_key
      unique = Lyra::Projections::UniqueIndexes
      indexes = unique.of(klass)
      return rows if indexes.empty? || rows.empty?

      scope = scope_for_create.transform_keys(&:to_s)
      defaults = klass.column_defaults
      columns = indexes.flat_map(&:columns).uniq
      # Each row's values, as the record would hold them.
      given = rows.map do |row|
        values = defaults.merge(scope.merge(row.to_h.to_h { |k, v| [klass.attribute_aliases.fetch(k.to_s, k.to_s), v] }))
        columns.to_h { |column| [column, klass.type_for_attribute(column).cast(values[column])] }
      end
      key_tuple = lambda do |index, values|
        compared = index.columns.map { |column| unique.key(klass, column, values[column]) }
        compared.any?(&:nil?) && !index.nulls_not_distinct ? nil : compared
      end
      tuples = given.map { |values| indexes.map { |index| key_tuple.(index, values) } }

      claims = given.each_index.flat_map do |r|
        indexes.each_index.filter_map { |i| tuples[r][i] && [indexes[i].columns.first, given[r][indexes[i].columns.first]] }
      end.uniq
      return rows if claims.empty?

      Lyra::BypassEvents.check_lock_limit!(klass, claims.size + keys, write)
      Lyra::Projections::ReferenceLinks.catch_up(klass) if Lyra::Projections::ReferenceLinks.enabled?
      before_locks&.call
      Lyra::Projections::Uniqueness.lock_all!(klass, claims)
      table = table_rows_holding(indexes, tuples, given, key_tuple)
      wanted = tuples.flat_map { |row| row.each_with_index.filter_map { |tuple, i| tuple && [indexes[i], tuple] } }.uniq
      records = Lyra::PurposeBoundReads.internal(INTERNAL) do
        Lyra::Genesis.first_use(klass)
        unique.candidate_records(klass, wanted, ids: table.map { _2 })
      end
      reader = Lyra::Projections::TypedValues::EventReader.new(klass.base_class)
      entry_tuple = ->(index, attrs) { key_tuple.(index, index.columns.to_h { [_1, reader.read(attrs, _1)] }) }
      live = records.to_h { [_1[pk], _1] }
      held = indexes.map { |index| records.filter_map { |attrs| entry_tuple.(index, attrs) }.to_set }
      dead, outdated = sort_table_rows(indexes, table, live, held, entry_tuple)

      kept = rows.each_index.reject do |r|
        taken = indexes.each_index.select { |i| tuples[r][i] && held[i].include?(tuples[r][i]) }
        next false if taken.empty?

        refused = taken.find { |i| !(skip == :any || (skip && skip.sort == indexes[i].columns.sort)) }
        if refused
          index = indexes[refused]
          raise unique.not_unique(unique::Claim.new(index, tuples[r][refused], index.columns.map { given[r][_1] }))
        end
        true
      end
      Lyra.projection_write(INTERNAL) do
        klass.unscoped.where(pk => dead).delete_all if dead.any?
        outdated.each { |id| klass.unscoped.where(pk => id).update_all(columns.to_h { [_1, live[id][_1]] }) }
      end
      kept.map { rows[_1] }
    end

    # The table's rows that hold any of +tuples+' values (comparison keys;
    # +given+: the rows' values), per index, as [index position, primary
    # key, tuple], one query per index.
    def table_rows_holding(indexes, tuples, given, key_tuple)
      pk = klass.primary_key
      indexes.each_with_index.flat_map do |index, i|
        wanted = tuples.filter_map { _1[i] }.to_set
        next [] if wanted.empty?

        first = index.columns.first
        values = given.each_index.filter_map { |r| given[r][first] if tuples[r][i] }.uniq
        found = Lyra::PurposeBoundReads.internal(INTERNAL) do
          klass.unscoped.where(first => values).pluck(pk, *index.columns)
        end
        found.filter_map do |id, *held|
          tuple = key_tuple.(index, index.columns.zip(held).to_h)
          [i, id, tuple] if wanted.include?(tuple)
        end
      end
    end

    # Sort the table's rows that hold a value being inserted (+table+): a
    # live record's row holding a value its record no longer has is
    # +outdated+; a row whose record the store does not hold is +dead+ when
    # its stream ends in a destroy, and otherwise (no stream: a row Genesis
    # skipped) its value is taken, added to +held+. Returns [dead, outdated].
    def sort_table_rows(indexes, table, live, held, entry_tuple)
      outdated = table.filter_map { |i, id, tuple| id if live[id] && entry_tuple.(indexes[i], live[id]) != tuple }.uniq
      unknown = table.reject { |_, id, _| live[id] }
      return [[], outdated] if unknown.empty?

      streams = unknown.map { |_, id, _| id }.uniq.to_h { [Lyra.stream_name(klass, _1), _1] }
      dead = Lyra::StreamTail.destroyed_streams(streams.keys).map { streams[_1] }.to_set
      unknown.each { |i, id, tuple| held[i] << tuple unless dead.include?(id) }
      [dead.to_a, outdated]
    end

    # ES-Async (Lyra::BypassEvents.projects_pending?): the records whose
    # keys the rows of an insert_all or insert_all! give are locked
    # (aggregate locks, within config.bulk_write_lock_limit) and their rows
    # brought up to date with their streams
    # (Lyra::Projections::AsyncProjectionJob.project_pending), before the
    # insert. Its ON CONFLICT then meets the rows Monitor's would: a record
    # whose destroy was waiting for its job has no row, and is inserted
    # again, a Created after the Destroyed, with the values given and the
    # column defaults; a record whose create was waiting has its row, which
    # insert_all skips and insert_all! raises ActiveRecord::RecordNotUnique
    # on. Before, the first was skipped (no event; the destroy's job then
    # deleted its row), the second inserted with a second Created on its
    # stream. Rows that give no key take the table's sequence. A conflict on
    # another unique index is looked up in the event store
    # (projected_unique_rows), as a record whose create waits for its job
    # holds its value with no row.
    #
    # Returns the keys locked.
    def project_pending_inserts(attributes, write)
      return [] unless Lyra::BypassEvents.projects_pending?

      ids = explicit_keys(attributes)
      return [] if ids.empty?

      Lyra::BypassEvents.lock_streams!(klass, ids, write: write)
      Lyra::Projections::AsyncProjectionJob.project_pending(klass, ids)
      ids
    end

    # ES-Async (Lyra::BypassEvents.projects_pending?): the write wrote the
    # rows and their events (+published+: publish_upserts) in one
    # transaction, so a row whose stream was up to date before it is up to
    # date with its new event, and its projection checkpoint is moved there,
    # in one statement (AsyncProjectionJob.advance): the records it locked
    # and brought up to date (+locked+), and every record it created, whose
    # row it inserted with the very attributes of its Created. Others (a
    # record an upsert matched by another unique index, not locked) keep
    # their checkpoints. Before, a bypass write never moved a checkpoint:
    # the next insert or upsert of the same keys found every stream behind
    # and replayed the previous write's events onto rows that already had
    # them, as each record's next projection job did.
    def advance_checkpoints(published, locked)
      return unless Lyra::BypassEvents.projects_pending? && published.present?

      locked = locked.to_set
      moves = published.filter_map { |id, (operation, event_id)| [id, event_id] if operation == :created || locked.include?(id) }
      Lyra::Projections::AsyncProjectionJob.advance(klass, moves)
    end

    # insert_all, insert_all! and upsert_all of a model whose primary key
    # has several columns (one its table declares, enrolled before Active
    # Record read it; Lyra::ModelSelection refuses one it knows) are refused
    # in the event-sourcing modes, before anything is written: their
    # Created events name the record by an array no projection, catch-up or
    # rebuild can apply (ES-Lazy's catch-up then failed on every read and
    # write of every monitored model, and a rebuild failed), and an update
    # of such a record failed in Genesis. Monitor and Hijack, which replay
    # nothing, write them and record their events.
    def refuse_composite_key!(write)
      key = klass.primary_key
      return unless key.is_a?(Array) && Lyra.event_sourcing_mode?

      raise ArgumentError,
            "#{klass.name} has a composite primary key (#{key.join(', ')}), which Lyra does not support: in the " \
            "event-sourcing modes #{write} would record events that no projection or rebuild can apply, so it is " \
            "refused before anything is written. A monitored model needs a single-column primary key."
    end

    # The primary keys the rows of an insert give, cast, each once.
    def explicit_keys(attributes)
      pk = klass.primary_key
      return [] unless pk.is_a?(String)

      type = klass.type_for_attribute(pk)
      rows = attributes.is_a?(Hash) ? [attributes] : Array(attributes)
      rows.filter_map { explicit_key(_1, pk, type) }.uniq
    end

    # The primary key a row of an insert gives, cast, or nil.
    def explicit_key(row, pk, type)
      row = row.to_h.transform_keys(&:to_s)
      name = row.key?(pk) ? pk : klass.attribute_aliases.key(pk)
      name && row.key?(name) ? type.cast(row[name]) : nil
    end

    # Run the write with the primary key in RETURNING, so the inserted and
    # updated rows can be identified, and hand the caller the result they
    # asked for (Lyra::BypassEvents.with_returning: raw SQL for returning
    # gets the key under an alias of Lyra's own; the caller's result keeps
    # its column types). Returns [caller_result, ids]; ids nil where no key
    # can be returned (an adapter without RETURNING), as before. A primary
    # key of several columns (a model whose table declares one, enrolled
    # before Active Record read it: Lyra::ModelSelection refuses one it
    # knows) has each column returned, and each id is the array of their
    # values, as record.id gives it. Its key was asked for as one quoted
    # name, and an explicit returning: raised PG::UndefinedColumn; without
    # one, no key was found in the result and nothing was recorded.
    def with_primary_keys(returning)
      pk = klass.primary_key
      return [yield(returning), nil] if pk.blank?

      keys = Array(pk)
      result, rows = Lyra::BypassEvents.with_returning(klass, returning, keys) { |ret| yield ret }
      [result, rows&.map { |row| pk.is_a?(Array) ? row.values_at(*keys) : row[pk] }]
    end

    # The application's insert_all, insert_all! or upsert_all (+write+) on a
    # join table: the join model of a has_and_belongs_to_many, or a model it
    # declared on the table (+join_model+: HabtmLinks.join_model_of). Refused
    # in strict mode, unless inside Lyra.without_strict_access, where either
    # side's model is monitored (HabtmLinks.guarded?), as its delete_all of
    # join rows is; Rails' own links are inserted one by one, through the
    # join model's callbacks (HabtmLinks.create), and never come here.
    # Where it runs, the rows it wrote are recorded as the links they make
    # (HabtmLinks.insert_all). Before, it was neither refused nor recorded.
    def join_insert(write, join_model, attributes, returning, unique_by: nil, &block)
      check_strict_mode!(write) if Lyra::Associations::HabtmLinks.guarded?(join_model)
      conflict = write == :upsert_all ? conflict_columns(unique_by) : nil
      Lyra::Associations::HabtmLinks.insert_all(self, attributes, returning: returning, conflict: conflict, &block)
    end

    # The columns upsert_all's ON CONFLICT uses: unique_by as columns, or as
    # an index name, or the primary key by default.
    def conflict_columns(unique_by)
      return Array(klass.primary_key) if unique_by.nil?

      columns = Array(unique_by).map(&:to_s)
      return columns unless columns.size == 1 && !klass.column_names.include?(columns.first)

      index = klass.with_connection { |c| c.indexes(klass.table_name) }.find { |i| i.name == columns.first }
      Array(index&.columns).map(&:to_s)
    end

    def check_strict_mode!(method_name)
      return unless Lyra.config.strict_data_access
      return if Thread.current[:lyra_bypass_strict_access]

      raise StrictDataAccessViolation.new(method_name, klass)
    end

    # The bulk write, on exactly the rows the locked snapshot holds: no row
    # another transaction inserted since is written without its event. Runs as
    # Lyra's own write, so it is not intercepted a second time. The snapshot
    # already took the relation's limit and offset: the write by key keeps
    # neither (an offset applied again to the snapshot's rows wrote none).
    def write_snapshotted(before)
      return 0 if before.empty?

      Lyra.projection_write(INTERNAL) { yield unscope(:limit, :offset).where(klass.primary_key => before.keys) }
    end
    
    def safely_publish_bulk(source)
      yield
    rescue => e
      Lyra::BypassEvents.publish_failed!(e, source)
    end

    # The shape of the write a has_many's nullify makes: one foreign key
    # column set to NULL. Rails' association code marks its own
    # (Lyra::Associations::Maintenance); the shape alone does not make a
    # write a nullify.
    def association_nullify_update?(updates)
      StrictDataAccessRelation.nullify_update?(updates)
    end

    # In the events-only store, with events recorded: whether this is an
    # Active Record relation's update_all clearing a foreign key, which the
    # table cannot answer (it is empty or stale there).
    def events_only_nullify?(updates)
      Lyra.event_sourcing_mode? && Lyra.config.projection_mode == :disabled && association_nullify_update?(updates)
    end

    # The records the event store holds that this relation selects, all of
    # it (CachedRelation#narrowed_by: its conditions on the model's columns,
    # order and limit; anything else raises UnsupportedQuery, naming +what+).
    def events_only_relation(what)
      Lyra::PurposeBoundReads.internal(INTERNAL) do
        Lyra::Projections::EventStoreReader.relation(klass).narrowed_by(self, what)
      end
    end

    # The same test for the events-only store, where the association writes
    # through the event-backed relation (AssociationInterceptor).
    def self.nullify_update?(updates)
      return false unless updates.is_a?(Hash)
      return false unless updates.size == 1

      # Check if it's a foreign key being set to nil
      key, value = updates.first
      value.nil? && key.to_s.end_with?("_id")
    end

    # Publish "updated" events for each record affected by dependent: :nullify
    # This captures the foreign key nullification in the event stream
    def publish_nullify_events(updates)
      updates = updates.to_h { |key, value| [klass.attribute_aliases[key.to_s] || key.to_s, value] }
      columns = updates.keys

      # Get the records being updated with their current values
      # In ES Disabled mode, records don't exist in DB, so we need to query
      # the event store via the model's read path (which uses CachedRelation)
      # Lyra's own read, for the events: the write itself is checked
      # (Lyra::PurposeBoundReads::RelationCheck).
      records_data = Lyra::PurposeBoundReads.internal(INTERNAL) { fetch_affected_records_for_nullify(columns) }

      # Where events are required, a row Genesis skipped refuses the whole
      # destroy before any event (Lyra::Genesis.admit_all!). In Monitor each
      # row's failure is logged on its own: one skipped child does not cost
      # the others their events.
      Lyra::Genesis.admit_all!(klass, records_data.map(&:first)) if Lyra::BypassEvents.required?
      # Where the store can hold a destroy whose row is not gone
      # (Lyra::BypassEvents.checks_streams?), a destroyed child gets no event:
      # it would bring the child back. Its key is returned, for the write to
      # leave its row as well.
      skipped = []
      if Lyra::BypassEvents.checks_streams? && records_data.any?
        skipped = Lyra::BypassEvents.destroyed_ids(klass, records_data.map(&:first), write: "dependent: :nullify")
        records_data = records_data.reject { |id, _| skipped.include?(id) } if skipped.any?
      end
      # The columns it changes: the foreign key, and for a polymorphic
      # association its type, whatever they are called.
      records_data.each do |id, old_values|
        changes = columns.zip(old_values).each_with_object({}) do |(column, old_value), acc|
          acc[column] = [old_value, updates[column]] unless old_value == updates[column]
        end
        next if changes.empty?

        Lyra::BypassEvents.publish(klass, id, :updated,
                                   attributes: changes.transform_values(&:last),
                                   changes: changes,
                                   source: "dependent_association")
      rescue => e
        Lyra::BypassEvents.publish_failed!(e, "dependent_association")
      end
      skipped
    rescue => e
      # Fails the parent's destroy in Hijack and the event-sourcing modes
      # (it runs inside its transaction); logged in Monitor.
      Lyra::BypassEvents.publish_failed!(e, "dependent_association")
      []
    end

    # The records the nullify rewrites, as [id, [old values of +columns+]]: the table's rows
    # the relation selects, or, in the events-only store (ES-NoProj), where
    # the table is empty or stale, the records the event store holds that
    # the relation's where clause selects, all of it (CachedRelation's
    # narrowed_by: its conditions on the model's columns, order and limit;
    # anything else it holds is refused with UnsupportedQuery, which fails
    # the write). A parent's dependent: :nullify is written by
    # AssociationInterceptor there; this is reached when Rails' association
    # code writes a table relation (Lyra's own projection writes aside). It
    # used to read the foreign key's equality alone, skipping any other
    # condition (where(author_id: 1, status: "published") nullified the
    # author's drafts too in the log, and matched no row in the table), and
    # to read the table first.
    def fetch_affected_records_for_nullify(columns)
      pk = klass.primary_key
      unless Lyra.event_sourcing_mode? && Lyra.config.projection_mode == :disabled
        return pluck(pk, *columns).map { |id, *values| [id, values] }
      end

      selected = Lyra::Projections::EventStoreReader.relation(klass).narrowed_by(self, "update_all(#{columns.join(', ')}: nil)")
      selected.map { |record| [record.read_attribute(pk), columns.map { record.read_attribute(_1) }] }
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
