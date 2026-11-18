# frozen_string_literal: true

require "json"

module Lyra
  module Rights
    # PamDsl.rights_store, durable: the PamDsl::RightsStore protocol on Lyra's
    # event store.
    #
    # Events. A subject's rights events go to Lyra::Rights$<subject key>, in
    # the order appended, each linked to the index stream Lyra::Rights.
    # append(events, expected_version:) folds the subject's events with the
    # new ones first (PamDsl::Rights.project, which refuses an illegal
    # transition), so nothing is stored that does not replay; then it appends
    # with RubyEventStore's expected version on the subject's stream (the
    # stream's last position), links, and rewrites the subject's rows in
    # lyra_rights, in one transaction. Two processes that read the same
    # version and both try to record (lift, decide) cannot both succeed: the
    # second insert of the same stream position violates the stream's unique
    # index, after waiting for the first to commit, and gets
    # PamDsl::RightsConcurrencyError, with nothing stored.
    #
    # Projection. lyra_rights holds one row per restriction or objection: its
    # subject key (and type and id), kind, policy, purpose, fields, ground,
    # article, state, whether it is in force, its times, and the subject
    # stream's version and last event id after the append that wrote it.
    #
    # Snapshot. Condition 6 asks any_active? and active_for(keys) on every
    # access with a subject, so they answer from a snapshot of the committed
    # requests in force, shared by the process's threads: one indexed query
    # (the subject keys in force, with their stream version and last event id)
    # refreshes it, and only a subject whose last event changed is read again.
    # An event id is never reused, as a stream version is after a rollback.
    # The snapshot is refreshed when it is older than
    # config.rights_refresh_interval seconds (default 1), when it was read
    # before the current checking scope began (Lyra::Rights.scope: a purpose
    # block, a request, a job, a batch), and on Lyra::Rights.refresh!. A
    # transaction that recorded a right sees its own (the keys it wrote are
    # read afresh through its connection, see Rights::Pending) and never
    # refreshes the shared snapshot; when it commits or rolls back, its keys
    # leave the snapshot and the next check reads them again. A right recorded
    # in another process applies here from the next refresh, at the latest
    # from the next checking scope. When nothing is in force the check costs a
    # clock read, and a query at most once per interval and scope. active
    # (open requests, reports) always refreshes first.
    #
    # Rebuild (Lyra::Rights.rebuild!) locks lyra_rights against appends while
    # it rewrites it (on PostgreSQL), so a transition waits for it rather than
    # failing or losing its row.
    class Store
      include PamDsl::RightsStore::Base
      include Pending

      # Times are kept with microseconds, the resolution of the columns.
      COLUMNS = %w[request_id kind subject_key subject_type subject_id policy purpose fields ground article
                   decision_grounds objection_id restriction_id state in_force requested_at recorded_at
                   lift_notified_at lifted_at decided_at withdrawn_at stream_version last_event_id updated_at].freeze

      attr_reader :generation

      def initialize(event_store: nil)
        @event_store = event_store
        @mutex = Mutex.new
        @snapshot = {}.freeze
        @versions = {}.freeze
        @checked_at = nil
        @overlays = {}.freeze
        @overlays_generation = 0
        @generation = 0
        @table_ready = false
        init_pending
      end

      def event_store
        @event_store || Lyra.config.event_store
      end

      # Kept in the database, seen by every process.
      def durable?
        true
      end

      # ── The protocol ──

      def append(events, expected_version:)
        events = Array(events)
        raise ArgumentError, "append takes at least one event" if events.empty?

        key = single_subject_key(events)
        existing = events_for(key)
        refuse_stale!(key, expected_version, existing.size) unless existing.size == expected_version

        # Fold first: an illegal transition raises here, and nothing is stored.
        all = existing + events
        requests = PamDsl::Rights.project(all)
        ensure_table!

        ActiveRecord::Base.transaction(requires_new: true) do
          records = events.map { |event| to_record(event) }
          event_store.append(records, stream_name: Rights.stream_for(key),
                                      expected_version: expected_version.zero? ? :none : expected_version - 1)
          event_store.link(records.map(&:event_id), stream_name: STREAM)
          write_rows(key, requests, all.size, records.last.event_id)
        end
        changed!([key])
        events
      rescue RubyEventStore::WrongExpectedEventVersion, ActiveRecord::RecordNotUnique
        refuse_stale!(key, expected_version, nil)
      end

      def events_for(subject_key)
        read_stream(subject_key).map { |record| from_record(record) }
      end

      def subject_key_for(request_id)
        if table_ready?
          key = with_connection do |c|
            c.select_value("SELECT subject_key FROM #{TABLE} WHERE request_id = #{c.quote(request_id.to_s)}")
          end
          return key if key
        end
        # Not in the table (being rebuilt, or written before it): the index.
        event_store.read.stream(STREAM).to_a.reverse_each do |record|
          data = record_data(record)
          return data["subject_key"] if data["request_id"] == request_id.to_s
        end
        nil
      end

      # Every request in force, read afresh.
      def active
        refresh!
        pending = pending_here
        current = snapshot_here(pending)
        current = current.merge(pending.to_h { |key| [key, load_in_force(key)] }) if pending
        current.values.flatten
      end

      def active_for(keys)
        pending = refresh_if_due
        snapshot = snapshot_here(pending)
        Array(keys).flat_map do |key|
          key = key.to_s
          pending&.include?(key) ? load_in_force(key) : snapshot.fetch(key, [])
        end
      end

      def any_active?
        refresh_if_due
        !@snapshot.empty? || !pending_here.nil?
      end

      # Every request in force, from the snapshot (and, read afresh, those
      # this connection's open transaction wrote): what Condition 6 asks
      # before it resolves a subject's keys (PamDsl::Rights.could_apply?).
      def in_force_requests
        pending = refresh_if_due
        current = snapshot_here(pending)
        current = current.merge(pending.to_h { |key| [key, load_in_force(key)] }) if pending
        current.values.flatten
      end

      # An object that changes whenever the snapshot's content does, or nil
      # while this connection's transaction has rights of its own: callers
      # remember what they derived from the rights against it
      # (Rights::Queries).
      def snapshot_token
        refresh_if_due
        pending_here ? nil : @snapshot
      end

      # The subject keys with a request in force (the snapshot's, and those
      # this connection's open transaction wrote), for model-wide queries.
      def keys_in_force
        pending = refresh_if_due
        keys = snapshot_here(pending).keys
        return keys unless pending

        # A pending key is in force as this transaction left it, not as the
        # snapshot holds it (a restriction it lifted is not).
        (keys - pending.to_a) + pending.select { |key| load_in_force(key).any? }
      end

      # Which of +keys+ have any request recorded (in force or not): one
      # query, for the subject's copy.
      def keys_with_requests(keys)
        keys = Array(keys).map(&:to_s).uniq
        return [] if keys.empty? || !table_ready?

        with_connection do |c|
          keys.each_slice(1000).flat_map do |slice|
            c.select_values("SELECT DISTINCT subject_key FROM #{TABLE} WHERE subject_key IN " \
                            "(#{slice.map { |key| c.quote(key) }.join(', ')})")
          end
        end
      end

      # ── The snapshot ──

      # Read the committed requests in force again. From a connection whose
      # open transaction recorded rights, into a snapshot of that
      # connection's own (refresh_around): what it reads may be its own
      # uncommitted rights, or, under REPEATABLE READ or SERIALIZABLE, the
      # database as its transaction began, and neither may reach the
      # snapshot every thread reads.
      def refresh!
        pending = pending_here
        return refresh_around(pending) if pending

        @mutex.synchronize do
          # One row first: how many requests are in force and when the last
          # of them was written. Unchanged, the snapshot stands without
          # reading every subject's marker (hundreds of rows per scope).
          digest = in_force_digest
          if digest && digest == @digest
            @checked_at = Rights.now
            next
          end

          markers = in_force_markers
          @digest = digest
          if markers == @versions
            # Nothing changed: the same snapshot object, so what was derived
            # from it (snapshot_token) still holds.
            @checked_at = Rights.now
            next
          end

          snapshot = {}
          markers.each do |key, marker|
            cached = @snapshot[key]
            in_force = cached && @versions[key] == marker ? cached : load_in_force(key)
            snapshot[key] = in_force.freeze unless in_force.empty?
          end
          @snapshot = snapshot.freeze
          @versions = markers.freeze
          @checked_at = Rights.now
        end
        self
      end

      # The next check reads the table again.
      def invalidate!
        @checked_at = nil
        @mutex.synchronize do
          @overlays = {}.freeze
          @overlays_generation += 1
        end
      end

      # ── Rebuild ──

      # Rewrites lyra_rights from the index stream. Returns the rows written.
      def rebuild!
        ensure_table!
        written = 0
        keys = []
        ActiveRecord::Base.transaction(requires_new: true) do
          # The lock first, then the index: an append either committed before
          # it (and is read here) or writes its rows after the rebuild commits.
          with_connection { |c| Rights.lock_table(c, TABLE) }
          keys = event_store.read.stream(STREAM).to_a.map { |record| record_data(record)["subject_key"] }.uniq
          with_connection { |c| c.execute("DELETE FROM #{TABLE}") }
          keys.each do |key|
            records = read_stream(key)
            requests = PamDsl::Rights.project(records.map { |record| from_record(record) })
            write_rows(key, requests, records.size, records.last&.event_id)
            written += requests.size
          end
        end
        changed!(keys)
        written
      end

      private

      # Refreshes what this connection answers from when it is due, and
      # returns the keys its open transaction wrote (pending_here), or nil.
      # A connection without rights of its own refreshes the shared snapshot,
      # as before; one with them, its own (refresh_around), on the same
      # schedule.
      def refresh_if_due
        pending = pending_here
        if pending
          refresh_around(pending) if !Rights.current?(@overlays[current_connection]&.last)
        elsif !Rights.current?(@checked_at)
          refresh!
        end
        pending
      rescue ActiveRecord::NoDatabaseError, ActiveRecord::ConnectionNotEstablished
        pending
      end

      # What this connection answers from: the shared snapshot, or, while its
      # open transaction has rights of its own (+pending+), the snapshot
      # refresh_around read for it.
      def snapshot_here(pending)
        return @snapshot unless pending

        @overlays[current_connection]&.first || @snapshot
      end

      # refresh! from a connection whose open transaction recorded rights for
      # +pending+ keys: the requests in force of every other subject, as
      # this connection reads them, into a snapshot used by this connection
      # only (snapshot_here), until its transaction ends (settled clears it)
      # or it is due again. Its pending keys are read afresh by the readers.
      # The shared snapshot is not written: under READ COMMITTED this
      # connection reads what others committed, but under REPEATABLE READ or
      # SERIALIZABLE it reads the database as its transaction began, and
      # another thread must not lose a restriction committed since. It used
      # to return at once, and a snapshot another write had just left
      # without a subject (settled) stayed so until the transaction ended: a
      # restriction committed before it began was not in force inside it.
      #
      # The rows are read outside the mutex. A write settled meanwhile (by
      # another thread: invalidate! moves @overlays_generation) may be
      # missing from what was read, so the read is made again; a read that
      # still raced is used for this check only (no read time: the next
      # check reads again), never kept as fresh.
      def refresh_around(pending, attempts = OVERLAY_READS)
        generation = @overlays_generation
        shared = @snapshot
        versions = @versions
        overlay = {}
        in_force_markers.each do |key, marker|
          next if pending.include?(key)

          cached = shared[key]
          in_force = cached && versions[key] == marker ? cached : load_in_force(key)
          overlay[key] = in_force.freeze unless in_force.empty?
        end
        connection = current_connection
        stored = @mutex.synchronize do
          raced = @overlays_generation != generation
          next false if raced && attempts > 1

          @overlays = @overlays.merge(connection => [overlay.freeze, raced ? nil : Rights.now]).freeze
          true
        end
        stored ? self : refresh_around(pending, attempts - 1)
      end

      # How many times refresh_around reads before it settles for a read
      # that raced with a write.
      OVERLAY_READS = 3

      def load_in_force(key)
        PamDsl::Rights.project(events_for(key)).select(&:in_force?)
      end

      # Lyra's own read (not checked for a purpose: a check would ask this
      # store again, from inside its refresh).
      def read_stream(key)
        PurposeBoundReads.internal(INTERNAL) { event_store.read.stream(Rights.stream_for(key)).to_a }
      end

      # { subject key => [stream version, last event id] } for the keys with
      # a request in force.
      def in_force_digest
        return [0, nil] unless table_ready?

        with_connection do |c|
          c.select_rows("SELECT COUNT(*), MAX(updated_at), SUM(stream_version) FROM #{TABLE} " \
                        "WHERE in_force = #{c.quoted_true}").first&.then { |count, at, versions| [count.to_i, at.to_s, versions.to_i] }
        end
      end

      def in_force_markers
        return {} unless table_ready?

        with_connection do |c|
          c.select_rows("SELECT subject_key, MAX(stream_version), MAX(last_event_id) FROM #{TABLE} " \
                        "WHERE in_force = #{c.quoted_true} GROUP BY subject_key")
           .to_h { |key, version, event_id| [key, [version.to_i, event_id]] }
        end
      end

      # A change to +keys+ by this thread: read through its connection until
      # its transaction ends, then out of the shared snapshot.
      def changed!(keys)
        @mutex.synchronize { @generation += 1 }
        Rights.note_write!
        mark_pending(keys)
      end

      # +keys+ committed or rolled back: drop them from the shared snapshot,
      # so the next check reads them from the database.
      def settled(keys)
        @mutex.synchronize do
          @snapshot = @snapshot.except(*keys).freeze
          @versions = @versions.except(*keys).freeze
          @digest = nil
        end
        invalidate!
      end

      def refuse_stale!(key, expected, found)
        found_text = found.nil? ? "another process recorded first" : "found #{found}"
        raise PamDsl::RightsConcurrencyError,
              "The rights of #{key} changed while this request was handled (expected version #{expected}, " \
              "#{found_text}): read them again and retry"
      end

      def single_subject_key(events)
        keys = events.map(&:subject_key).uniq
        raise ArgumentError, "append takes events for exactly one subject key, got #{keys.inspect}" unless keys.size == 1

        keys.first.to_s
      end

      def to_record(event)
        Events.const_get(event.type).new(
          data: {
            "request_id" => event.request_id.to_s,
            "subject_key" => event.subject_key.to_s,
            "at" => Codec.encode(event.at),
            "recorded_at" => Codec.encode(event.recorded_at),
            "recorded_by" => event.recorded_by&.to_s,
            "data" => Codec.encode(event.data.to_h)
          },
          metadata: { source: "lyra_rights", correlation_id: Lyra::Correlation.current_id }.compact
        )
      end

      def from_record(record)
        data = record_data(record)
        PamDsl::Rights::Event.new(
          type: record.class.name.demodulize, request_id: data["request_id"], subject_key: data["subject_key"],
          data: (Codec.decode(data["data"]) || {}).freeze, at: Codec.decode(data["at"]),
          recorded_at: Codec.decode(data["recorded_at"]), recorded_by: data["recorded_by"]
        )
      end

      def record_data(record)
        record.data.to_h.transform_keys(&:to_s)
      end

      # Rewrite the subject's rows: few per subject, and serialised by the
      # append's lock on the subject's stream position.
      def write_rows(key, requests, version, last_event_id)
        type, id = Rights.split_key(key)
        now = Time.current
        with_connection do |c|
          c.execute("DELETE FROM #{TABLE} WHERE subject_key = #{c.quote(key)}")
          requests.each do |r|
            restriction = r.kind == :restriction
            values = [
              r.id, r.kind.to_s, key, type, id, r.policy&.to_s, r.purpose&.to_s,
              restriction ? JSON.generate(r.fields.map(&:to_s)) : nil,
              restriction ? r.ground&.to_s : nil, r.article, restriction ? nil : r.decision_grounds&.to_s,
              restriction ? r.objection_id : nil, restriction ? nil : r.restriction_id,
              r.state.to_s, r.in_force?, r.requested_at, r.recorded_at,
              restriction ? r.lift_notified_at : nil, restriction ? r.lifted_at : nil,
              restriction ? nil : r.decided_at, restriction ? nil : r.withdrawn_at, version, last_event_id, now
            ]
            c.execute("INSERT INTO #{TABLE} (#{COLUMNS.join(', ')}) VALUES (#{values.map { |v| Rights.quote(c, v) }.join(', ')})")
          end
        end
      end

      def with_connection(&block)
        ActiveRecord::Base.with_connection(&block)
      end

      def table_ready?
        return true if @table_ready

        @table_ready = Rights.table_exists?(TABLE)
      end

      def ensure_table!
        return if @table_ready && table_ready?

        ready = Rights.with_table(TABLE) do |c|
          c.create_table(TABLE) do |t|
            t.string :request_id, limit: 36, null: false
            t.string :kind, null: false
            t.string :subject_key, null: false
            t.string :subject_type
            t.string :subject_id
            t.string :policy
            t.string :purpose
            t.text :fields
            t.string :ground
            t.string :article
            t.string :decision_grounds
            t.string :objection_id, limit: 36
            t.string :restriction_id, limit: 36
            t.string :state, null: false
            t.boolean :in_force, null: false, default: false
            t.datetime :requested_at, precision: 6
            t.datetime :recorded_at, precision: 6
            t.datetime :lift_notified_at, precision: 6
            t.datetime :lifted_at, precision: 6
            t.datetime :decided_at, precision: 6
            t.datetime :withdrawn_at, precision: 6
            t.integer :stream_version, null: false
            t.string :last_event_id, limit: 36
            t.datetime :updated_at, precision: 6, null: false
          end
          c.add_index TABLE, :request_id, unique: true
          c.add_index TABLE, %i[in_force subject_key]
          c.add_index TABLE, :subject_key
        end
        raise ActiveRecord::ConnectionNotEstablished, "no database for #{TABLE}" unless ready

        @table_ready = true
      end
    end
  end
end
