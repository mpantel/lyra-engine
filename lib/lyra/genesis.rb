# frozen_string_literal: true

module Lyra
  # Genesis: event streams for rows that existed before Lyra recorded them.
  #
  # A table row written before Lyra was enabled has no stream. Its first
  # Updated event would then start a stream with no head, and everything that
  # rebuilds state from events -- DualView, Rebuild, ES-NoProj reads and their
  # aggregates (count, sum, average, minimum, maximum) -- would see the record
  # wrongly or not at all.
  #
  # Genesis gives each such row one Imported event, carrying the row exactly as
  # it is (timestamps included). Imported is replayed like Created, but says
  # what happened: the record was adopted, not created at that moment.
  #
  # It runs on a model's first use in a process, not ahead of time:
  # - the first write to the model (any event-producing mode), before the
  #   write's own event, so the Imported event holds the row as it was;
  # - in ES-NoProj, the first read of the model (find, where, all, count, sum,
  #   ...), before the record set is assembled, so that every answer, the SQL
  #   aggregates included, is computed from streams alone.
  # The first use imports every row of the model that has no stream; each later
  # use costs nothing. For a large table, run `rake lyra:genesis` before
  # enabling a mode, so the first request does not pay for it.
  #
  # Concurrency: the import runs under a per-model PostgreSQL advisory lock
  # and selects only rows whose stream is still empty, so two processes never
  # import a row twice. When the caller is inside a transaction, the import
  # runs on a connection of its own and commits there: the lock is held only
  # while importing, not until the caller commits (a long transaction would
  # otherwise block every other first use of the model), and the Imported
  # events stand whether the caller commits or rolls back -- they record rows
  # that already existed, not the caller's write. Where no second connection
  # can be had (Rails' transactional tests pin one; a pool may have none
  # free), the import runs in the caller's transaction and the model counts as
  # imported only once it commits (Lyra::OwnConnection).
  #
  # Enabled with config.genesis: :auto (the default) runs it in event-sourcing
  # mode, where the event log is the only source of truth; true also runs it in
  # Monitor and Hijack modes (for DualView and Rebuild); false never runs it.
  module Genesis
    BATCH = 1_000
    OPERATION = :imported

    @imported = {}
    @mutex = Mutex.new

    class << self
      def enabled?
        case Lyra.config.genesis
        when true then !Lyra.disabled_mode?
        when false, nil then false
        else Lyra.event_sourcing_mode?
        end
      end

      # Import +model_class+'s rows without a stream, once per process.
      # Returns the number of rows imported by this call.
      def first_use(model_class)
        return 0 unless enabled?
        return 0 if imported?(model_class)
        return 0 if Thread.current[:lyra_genesis_running]

        # Usually every row already has a stream: then nothing is written and
        # no lock is needed. The model counts as done once the caller's
        # transaction, if any, commits: the streams it sees may be an inline
        # import's, uncommitted in that transaction (see below).
        if model_class.with_connection { |c| rows_without_stream(c, model_class, nil, limit: 1) }.empty?
          Lyra::OwnConnection.after_commit(model_class) { mark_imported(model_class) }
          return 0
        end

        # On a connection of its own when the caller is in a transaction; in
        # the caller's transaction where none can be had (a pinned test
        # connection, a pool with none free), and then done only at commit.
        inline = false
        count = Lyra::OwnConnection.run(model_class) do |in_caller_transaction|
          inline = in_caller_transaction
          import_all(model_class)
        end
        mark = -> { mark_imported(model_class) }
        inline ? Lyra::OwnConnection.after_commit(model_class, &mark) : mark.call
        count
      end

      # Import every row of +model_class+ that has no stream, now, whatever the
      # mode. Returns the number of rows imported.
      def import_all(model_class)
        Thread.current[:lyra_genesis_running] = true
        imported = []

        model_class.with_connection do |connection|
          model_class.transaction do
            lock!(connection, model_class)
            after = nil
            loop do
              rows = rows_without_stream(connection, model_class, after)
              break if rows.empty?

              rows.each { |row| (id = import_row(model_class, row)) && imported << id }
              after = rows.last[model_class.primary_key]
            end
          end
        end

        forget_cached(model_class, imported)
        imported.size
      ensure
        Thread.current[:lyra_genesis_running] = nil
      end

      def imported?(model_class)
        @mutex.synchronize { @imported.key?(model_class.name) }
      end

      # Forget which models were imported (tests, or after the event store or
      # the tables were reset).
      def reset!
        @mutex.synchronize { @imported.clear }
      end

      private

      def mark_imported(model_class)
        @mutex.synchronize { @imported[model_class.name] = true }
      end

      def rows_without_stream(connection, model_class, after, limit: BATCH)
        table = connection.quote_table_name(model_class.table_name)
        pk = connection.quote_column_name(model_class.primary_key)
        prefix = connection.quote(Lyra.stream_prefix(model_class))
        keyset = after.nil? ? "" : "AND t.#{pk} > #{connection.quote(after)}"

        connection.select_all(<<~SQL.squish).to_a
          SELECT t.* FROM #{table} t
          WHERE NOT EXISTS (
            SELECT 1 FROM event_store_events_in_streams s
            WHERE s.stream = #{prefix} || CAST(t.#{pk} AS VARCHAR)
          ) #{keyset}
          ORDER BY t.#{pk} LIMIT #{Integer(limit)}
        SQL
      end

      def import_row(model_class, row)
        record = Lyra::PurposeBoundReads.internal { model_class.instantiate(row) }
        return nil if record.id.nil?

        data = {
          model_class: model_class.name,
          model_id: record.id,
          operation: OPERATION,
          attributes: record.attributes,
          changes: {},
          timestamp: Time.current
        }
        event = event_class(model_class).new(data: data, metadata: Lyra::Privacy.stamp(model_class, data, { genesis: true }))
        # The lock and the NOT EXISTS above make the stream empty here.
        stream_name = Lyra.stream_name(model_class, record.id)
        Lyra.append_events(event, stream_name: stream_name)
        # The has_and_belongs_to_many links the row already has.
        Associations::HabtmLinks.import(model_class, record.id, stream_name)
        record.id
      end

      # An ES-NoProj lookup made before the import (in an earlier process, or
      # before the event store was reset) may have cached "not found" for these
      # records. invalidate_all cannot drop per-record entries on every store
      # (Solid Cache cannot delete by prefix), so such a record stayed missing
      # until the entry expired, up to an hour. Drop each one by id.
      def forget_cached(model_class, ids)
        return if ids.empty?

        ids.each { |id| Projections::CachedProjection.invalidate(model_class, id) }
      end

      def event_class(model_class)
        config = model_class.respond_to?(:lyra_config) && model_class.lyra_config || Lyra.config.model_config(model_class)
        name = config.event_name_for(OPERATION).to_s.gsub("::", "")
        return Lyra::Events.const_get(name, false) if Lyra::Events.const_defined?(name, false)

        Lyra::Events.const_set(name, Class.new(Lyra::Event))
      end

      def lock!(connection, model_class)
        Lyra::AdvisoryLock.xact_lock(connection, "lyra_genesis/#{model_class.name}", purpose: "Genesis")
      end
    end
  end
end
