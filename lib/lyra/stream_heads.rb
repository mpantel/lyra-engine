# frozen_string_literal: true

module Lyra
  # The history clauses of Hypothesis H, enforced where a record's events are
  # appended (from 1.0.1).
  #
  # H asks that a record's operations be valid for the ORM: no second create
  # of a live record, no update or destroy of one that has none, nothing after
  # its destroy. Lyra 1.0.0 did not check it: a create with a live record's
  # key appended a second Created in every event-sourcing mode, and an upsert
  # that met a live row recorded it as created, in Monitor and Hijack too.
  #
  # A head is one row per record stream, in lyra_stream_heads: whether the
  # stream's record is live or gone, and the event that last moved it. Every
  # replayed CRUD event Lyra appends (Lyra.append_events) first moves its
  # stream's head, in the append's transaction:
  # - a create or an import needs no live record, and makes it live;
  # - an update needs a live record;
  # - a destroy needs a live record, and makes it gone.
  # Events that are not replayed (domain events added with also:, erasures,
  # links) leave the head alone.
  #
  # The head's row is the lock. An update or a destroy moves its live head in
  # one UPDATE, which locks it; a creator inserts the head, so two creators of
  # one key meet on its primary key: the second waits for the first's
  # transaction, as on the table's own primary key, and is refused if that
  # committed. Row locks take no entries in PostgreSQL's lock table, so a
  # transaction may create any number of records. The head is taken last,
  # just before the append, after the aggregate lock and the unique-index
  # locks, so writers take their locks in one order.
  #
  # The log is the authority and the head its summary. A head whose event is
  # no longer in the store (events deleted by hand, a test database cleaned of
  # them) is not trusted: the stream's events decide, as they do for a stream
  # that has no head yet (written before 1.0.1, or by an older process). The
  # same holds before anything is refused: the events are read again.
  #
  # What a mismatch does depends on who owns the truth:
  # - Hijack and event sourcing, where the log is authoritative, refuse the
  #   write before its event is stored: LiveKeyError (an
  #   ActiveRecord::RecordNotUnique, as Monitor's INSERT raises), or
  #   RecordDestroyedError / MissingRecordError (ActiveRecord::RecordNotFound).
  # - Monitor only observes writes the table has already taken, and never
  #   refuses: it records the event, moves the head to what the table says,
  #   and reports the mismatch (the log, and the lyra.stream_head_mismatch
  #   notification) for DualView and lyra:repair.
  #
  # Not enforced here: that the row receives exactly the event's change, and
  # writes that bypass Lyra (raw SQL, triggers, other programs). Those stay
  # assumptions, which DualView looks for. Nor does a head exclude a lost
  # update, which is a valid write of a value computed from an old read.
  #
  # config.stream_heads = false switches it off (1.0.0's behaviour).
  module StreamHeads
    TABLE = "lyra_stream_heads"
    LIVE = "live"
    GONE = "gone"
    ABSENT = "absent"
    OPERATIONS = %i[created imported updated destroyed].freeze

    # A create of a key whose record is live.
    class LiveKeyError < ActiveRecord::RecordNotUnique; end

    # An update or destroy of a key that has no record.
    class MissingRecordError < ActiveRecord::RecordNotFound; end

    # A change of a persisted record's primary key, which names its stream:
    # refused in Hijack and event sourcing (Monitor records it as the destroy
    # of the old key and the create of the new one).
    class KeyChangeError < ActiveRecord::ActiveRecordError; end

    # Refuse a change of +record+'s primary key in Hijack and event sourcing.
    def self.refuse_key_change!(model_class, from, to)
      return unless enabled? && from != to && !from.nil?

      raise KeyChangeError, "Lyra: #{model_class.name} #{from}: its primary key cannot change (to #{to}) " \
                            "in #{Lyra.config.mode}; the key names the record's event stream"
    end

    @ready = {}
    @mutex = Mutex.new

    class << self
      def enabled?
        Lyra.config.respond_to?(:stream_heads) ? Lyra.config.stream_heads != false : true
      end

      # Move +stream_name+'s head for one event about to be appended.
      # +operation+ is its replayed operation (Lyra::Event.operation_of),
      # +event_id+ its id. Raises in Hijack and event sourcing when H excludes
      # the event; in Monitor records the mismatch and goes on. Returns the
      # head's new status, or nil when it does not apply.
      def advance!(stream_name, operation, event_id, connection: nil)
        return unless enabled? && OPERATIONS.include?(operation)
        # with_connection, never ActiveRecord::Base.connection, which leases the
        # connection to the thread for good (Rails 7.2+) and starves the pool.
        return ActiveRecord::Base.with_connection { advance!(stream_name, operation, event_id, connection: _1) } unless connection

        return unless supported?(connection)

        ensure_table!(connection)
        q = Quoted.new(connection, stream_name, event_id)
        creating = %i[created imported].include?(operation)
        # The common cases, in one statement each: a live head moved by an
        # update or destroy; a new head inserted by a create.
        unless creating
          target = operation == :destroyed ? GONE : LIVE
          return target if move_live(q, target)
        end

        if creating && insert_new(q)
          # A new head. Its stream may hold events from before 1.0.1.
          status = from_events(q)
          return LIVE if status != LIVE

          decide(q, operation, status, stored: LIVE)
        else
          stored, trusted = locked_head(q)
          status = trusted ? stored : from_events(q)
          decide(q, operation, status, stored: stored)
        end
      end

      # The head of +stream_name+ as the events say it, without a lock:
      # :live, :gone or :absent.
      def status(stream_name, connection: nil)
        return ActiveRecord::Base.with_connection { status(stream_name, connection: _1) } unless connection

        from_events(Quoted.new(connection, stream_name, nil)).to_sym
      end

      # Of +stream_names+, those whose record is live, as the events say: one
      # query for the heads, then the events of those the heads call live.
      def live_streams(stream_names, connection: nil)
        return Set.new if stream_names.empty? || !enabled?
        return ActiveRecord::Base.with_connection { live_streams(stream_names, connection: _1) } unless connection

        return Set.new unless supported?(connection)

        ensure_table!(connection)
        listed = stream_names.map { connection.quote(_1) }.join(", ")
        candidates = connection.select_values(
          "SELECT stream FROM #{TABLE} WHERE stream IN (#{listed}) AND status = '#{LIVE}'", "Lyra stream head"
        )
        candidates.to_set { _1 }.select { from_events(Quoted.new(connection, _1, nil)) == LIVE }.to_set
      end

      # PostgreSQL only in 1.0.1: the heads rely on its row locks (FOR UPDATE)
      # and INSERT ... ON CONFLICT. On other databases (SQLite) they are not
      # kept, and the history clauses of H are not enforced, as in 1.0.0.
      def supported?(connection) = connection.adapter_name.match?(/postg/i)

      # Lock the heads of +stream_names+ (FOR UPDATE, to the end of the
      # transaction), in a fixed order, creating from its events a head that
      # is missing: a reader that holds them excludes every writer of those
      # records until it commits (ES-Lazy's locking reads,
      # LazyProjection.bring_locked_up_to_date).
      def lock_streams!(stream_names, connection:)
        return unless enabled? && supported?(connection) && stream_names.any?

        ensure_table!(connection)
        stream_names.uniq.sort.each do |stream_name|
          q = Quoted.new(connection, stream_name, nil)
          next if lock_row(q)

          connection.exec_insert(<<~SQL.squish, "Lyra stream head")
            INSERT INTO #{TABLE} (stream, status, event_id, updated_at)
            VALUES (#{q.stream}, #{connection.quote(from_events(q))}, NULL, CURRENT_TIMESTAMP)
            ON CONFLICT (stream) DO NOTHING
          SQL
          lock_row(q)
        end
      end

      # Forget that the table was seen (tests that drop it).
      def reset!
        @mutex.synchronize { @ready.clear }
        @event_match = nil
      end

      def ensure_table!(connection)
        key = connection.pool.db_config.name
        return if @ready[key]

        Lyra.create_own_table(connection, TABLE) do |c|
          c.create_table(TABLE, id: false) do |t|
            t.string :stream, null: false
            t.string :status, null: false
            t.string :event_id
            t.datetime :updated_at, null: false
          end
          c.add_index(TABLE, :stream, unique: true, name: "index_#{TABLE}_on_stream")
        end
        @mutex.synchronize { @ready[key] = true }
      end

      private

      # The head's event in the store, by the store's own unique index:
      # event_id is a string column in Rails Event Store's default schema, a
      # uuid in some.
      def event_match(connection)
        @event_match ||= begin
          column = connection.columns("event_store_events").find { _1.name == "event_id" }
          column&.type == :uuid ? "e.event_id = h.event_id::uuid" : "e.event_id = h.event_id"
        end
      end

      Quoted = Struct.new(:db, :stream_name, :event_id) do
        def stream = db.quote(stream_name)
        def event = db.quote(event_id)
      end

      # A live head whose event is still stored, moved to +status+ and the new
      # event; locks the head. False when the head is not live, not trusted or
      # missing: the slow path decides.
      def move_live(q, status)
        q.db.exec_update(<<~SQL.squish, "Lyra stream head").positive?
          UPDATE #{TABLE} h SET status = #{q.db.quote(status)}, event_id = #{q.event}, updated_at = CURRENT_TIMESTAMP
          WHERE h.stream = #{q.stream} AND h.status = '#{LIVE}'
            AND EXISTS (SELECT 1 FROM event_store_events e WHERE #{event_match(q.db)})
        SQL
      end

      # A head inserted as live for a create; false when one exists (after
      # waiting for a concurrent creator's transaction to end).
      def insert_new(q)
        !q.db.select_value(<<~SQL.squish, "Lyra stream head").nil?
          INSERT INTO #{TABLE} (stream, status, event_id, updated_at)
          VALUES (#{q.stream}, '#{LIVE}', #{q.event}, CURRENT_TIMESTAMP)
          ON CONFLICT (stream) DO NOTHING RETURNING 1
        SQL
      end

      # The existing head, locked, and whether its event is still stored.
      # Inserts one from the events first where there is none.
      def locked_head(q)
        row = lock_row(q)
        unless row
          q.db.exec_insert(<<~SQL.squish, "Lyra stream head")
            INSERT INTO #{TABLE} (stream, status, event_id, updated_at)
            VALUES (#{q.stream}, #{q.db.quote(from_events(q))}, NULL, CURRENT_TIMESTAMP)
            ON CONFLICT (stream) DO NOTHING
          SQL
          row = lock_row(q)
          return [row[0], true] if row && row[1].nil? # just derived from the events
        end
        [row[0], !row[1].nil? && row[2]]
      end

      def lock_row(q)
        q.db.uncached do
          q.db.select_rows(<<~SQL.squish, "Lyra stream head").first
            SELECT h.status, h.event_id, EXISTS (SELECT 1 FROM event_store_events e WHERE #{event_match(q.db)})
            FROM #{TABLE} h WHERE h.stream = #{q.stream} FOR UPDATE OF h
          SQL
        end
      end

      def decide(q, operation, status, stored:)
        wanted = %i[created imported].include?(operation) ? [ABSENT, GONE] : [LIVE]
        # Before refusing, the events decide (the log is the authority).
        status = from_events(q) unless wanted.include?(status)
        unless wanted.include?(status)
          raise error_for(operation, status, q.stream_name) unless Lyra.config.mode == :monitor

          mismatch!(q.stream_name, operation, status)
        end
        target = operation == :destroyed ? GONE : LIVE
        q.db.exec_update(<<~SQL.squish, "Lyra stream head")
          UPDATE #{TABLE} SET status = #{q.db.quote(target)}, event_id = #{q.event}, updated_at = CURRENT_TIMESTAMP
          WHERE stream = #{q.stream}
        SQL
        target
      end

      # What a stream's events say: absent with none, gone after a destroy,
      # live otherwise.
      def from_events(q)
        any = q.db.select_value(
          "SELECT 1 FROM event_store_events_in_streams WHERE stream = #{q.stream} LIMIT 1", "Lyra stream head"
        )
        return ABSENT unless any

        Lyra::StreamTail.destroyed?(q.stream_name) ? GONE : LIVE
      end

      def error_for(operation, status, stream_name)
        if %i[created imported].include?(operation)
          return LiveKeyError.new("Lyra: #{stream_name} is a live record; a second create is refused")
        end

        verb = operation == :updated ? "update" : "destroy"
        if status == GONE
          Lyra::RecordDestroyedError.new("Lyra: #{stream_name} was destroyed; its #{verb} is refused")
        else
          MissingRecordError.new("Lyra: #{stream_name} has no record; its #{verb} is refused")
        end
      end

      def mismatch!(stream_name, operation, status)
        message = "Lyra: #{operation} of #{stream_name}, whose head was #{status}; recorded as the table has it"
        Rails.logger.warn(message) if defined?(Rails) && Rails.logger
        ActiveSupport::Notifications.instrument("lyra.stream_head_mismatch",
                                                stream: stream_name, operation: operation, head: status)
      end
    end
  end
end
