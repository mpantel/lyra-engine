# frozen_string_literal: true

module Lyra
  # The processes that leave touches out of the log (config.record_touches =
  # false), recorded where every process's mode gate reads them: rows of kind
  # 'touch_skipping' in Lyra::ModeTransition::TABLE.
  #
  # Such a process changes rows in a way its events do not show (updated_at
  # moves, the stream does not). That is acceptable in Monitor, where the table
  # is authoritative, and only there: no process may switch the application
  # into Hijack or event sourcing while one runs this way, or use a
  # certificate that a check issued before or during such a period. The
  # registry is how the gate knows:
  #
  # - a process registers when its option is off: at boot, or when the option
  #   is set false after boot, and in any case before its first touch is left
  #   out (live!). A touch is left out only once the entry is committed; when
  #   it cannot be (no connection of its own to be had, the database refuses),
  #   the touch is recorded;
  # - every registry write commits on its own, never in the caller's
  #   transaction: on this thread's connection when no transaction is open on
  #   it, else on a second connection checked out for at most
  #   CHECKOUT_TIMEOUT seconds. Each runs under the registry's advisory lock
  #   (PostgreSQL), with a short lock_timeout, and re-reads the application's
  #   mode under it: a switch into Hijack or event sourcing takes the same lock
  #   for its last look at the registry and its record (serialize), so either
  #   the switch sees the entry and is refused, or the entry sees the switch,
  #   is ended at once, and the touch is recorded (and the process fenced);
  # - it refreshes the entry at most every HEARTBEAT seconds: from the touch
  #   path, and from ModeSync's check before requests, jobs and writes. No
  #   thread. Times are the database's clock (clock_timestamp() on
  #   PostgreSQL), so hosts' clocks do not matter;
  # - it ends the entry when the option is set back to true and at exit, best
  #   effort. An entry not refreshed for EXPIRY seconds is no longer live;
  # - each refresh notes the table's latest id (position), and a certificate
  #   is taken only if it was issued after every entry's latest refresh or end
  #   (ModeTransition.certified_check).
  #
  # With the option true (the default) no write path reads or writes the
  # registry. Each to! or check into Hijack or event sourcing, each ModeSync
  # adoption of such a mode and each Rebuild.rebuild runs one registry SELECT;
  # to! and check also take the advisory lock in a short transaction.
  #
  # The advisory lock is PostgreSQL's: on other adapters AdvisoryLock takes no
  # lock (and warns once, except on SQLite), so the race between a registration and a switch is
  # closed only on PostgreSQL.
  module TouchRegistry
    KIND = "touch_skipping"
    TABLE = ModeTransition::TABLE
    HEARTBEAT = 60
    EXPIRY = 3 * HEARTBEAT
    # How long a registry write waits for a connection of its own while the
    # caller's transaction is open, and for a row lock.
    CHECKOUT_TIMEOUT = 1
    LOCK_TIMEOUT = "2s"
    LOCK_KEY = "lyra:touch_registry"

    STEPS = "To escalate: restart every process with record_touches on, run `rake lyra:repair` in Monitor, then switch."
    WARNING = "Lyra: record_touches is off — touches that change only update timestamps are not recorded; escalation " \
              "to Hijack or event sourcing is refused while any process runs this way. #{STEPS}"

    @mutex = Mutex.new
    @beat_mutex = Mutex.new
    @row_id = nil
    @pid = nil
    @beat_at = nil
    @started_at = nil
    @warned_pid = nil
    @exit_hook = false
    @fence = nil

    class << self
      # At boot (Lyra::Engine), every process: with the option off, refuse to
      # run in an application whose latest applied mode rebuilds rows from the
      # log (it must not leave touches out there), otherwise register.
      def boot!
        register_or_refuse! if Lyra.config.record_touches == false
      end

      # config.record_touches set to false after boot: as at boot.
      def option_off!
        register_or_refuse! if Lyra.booted?
      end

      # config.record_touches set back to true: end this process's entry.
      def option_on!
        @fence = nil
        deregister!
      end

      # Whether +label+ ("hijack", "event_sourcing/lazy") is a mode whose log
      # rebuilds rows.
      def authoritative?(label)
        !label.nil? && !%w[disabled monitor].include?(label.to_s.split("/").first)
      end

      # Before a touch is left out: true once this process's entry is live.
      # False when it cannot be written, or the application turns out to run in
      # a mode whose log rebuilds rows: the touch is then recorded. Raises once
      # this process has been fenced (fence!).
      def live!
        raise ModeTransition::Refused, @fence if @fence
        return true if fresh?

        beat!
      end

      # From ModeSync's check, outside any transaction: refresh the entry when
      # due. Costs nothing with the option on.
      def heartbeat_if_due
        return unless Lyra.config.record_touches == false
        return if @fence || fresh?

        beat!
      end

      # The application runs in +label+, which this process cannot run with the
      # option off: it refuses to go on leaving touches out. Every touch it
      # would leave out raises from now on, and with it the write that cascades
      # it (a child's save under belongs_to ... touch: true), until the option
      # is set true or the process restarts with it.
      def fence!(label)
        @fence = process_refusal(label)
      end

      def fenced? = !@fence.nil?

      # A switch into +to+'s last look at the registry and its record, under
      # the registry's lock (PostgreSQL), in a transaction: a registration
      # waits for it, and then sees the switch. Other targets run unlocked.
      def serialize(to, &block)
        return yield unless authoritative?(to)

        ActiveRecord::Base.transaction do
          ActiveRecord::Base.with_connection do |c|
            Lyra::AdvisoryLock.xact_lock(c, LOCK_KEY, purpose: "touch registry")
          end
          block.call
        end
      end

      # The live entries, each { id:, host:, pid:, since:, last_seen:, version:,
      # actor: }; [] when there are none (or no table).
      def live_processes
        return [] unless ModeTransition.table_available?

        rows = ActiveRecord::Base.with_connection do |c|
          c.select_all(
            "SELECT id, host, pid, os_user, actor, from_config, started_at, created_at, seen_at FROM #{TABLE} " \
            "WHERE kind = #{c.quote(KIND)} AND ended_at IS NULL AND seen_at > #{expiry_boundary(c)} ORDER BY id"
          ).to_a
        end
        rows.map do |row|
          { id: row["id"].to_i, host: row["host"], pid: row["pid"]&.to_i, version: row["from_config"],
            actor: row["actor"], since: time(row["started_at"] || row["created_at"]), last_seen: time(row["seen_at"]) }
        end
      end

      # The table's id up to which certificates are not to be taken: the
      # latest refresh or end of any entry. 0 when there is none.
      def certificate_floor_sql
        "COALESCE((SELECT MAX(position) FROM #{TABLE} WHERE kind = '#{KIND}'), 0)"
      end

      # A gate refusal naming the live entries, or nil when there are none.
      def gate_refusal(from, to)
        live = live_processes
        return nil if live.empty?

        "Lyra refuses #{from} -> #{to}: #{live.size} process#{'es' if live.size > 1} leave#{'s' if live.size == 1} " \
          "touches out of the log (config.record_touches = false): #{describe(live)}. #{STEPS}"
      end

      def describe(live)
        live.map do |p|
          "#{p[:host]} pid #{p[:pid]} (since #{p[:since]&.utc&.iso8601}, last seen #{p[:last_seen]&.utc&.iso8601})"
        end.join("; ")
      end

      # The refusal for a process with the option off in an application whose
      # mode is +label+.
      def process_refusal(label)
        "Lyra refuses to run with config.record_touches = false: the application runs in #{label}, whose log " \
          "rebuilds rows, and a touch left out of it would rebuild a stale updated_at. #{STEPS}"
      end

      # Testing and maintenance: forget this process's entry (the row stays).
      def reset!
        @mutex.synchronize do
          @row_id = nil
          @pid = nil
          @beat_at = nil
          @fence = nil
          @warned_pid = nil
        end
      end

      private

      def fresh?
        @row_id && @pid == Process.pid && (monotonic - @beat_at) < HEARTBEAT
      end

      # Register, or raise (leaving this process unfenced and unregistered)
      # when the application runs in a mode whose log rebuilds rows.
      def register_or_refuse!
        label = ModeTransition.last_applied
        raise ModeTransition::Refused, process_refusal(label) if authoritative?(label)

        beat!
        return unless @fence

        message = @fence
        @fence = nil
        raise ModeTransition::Refused, message
      end

      # Write or refresh the entry (see the module's notes). Returns whether
      # it is live.
      def beat!
        return false unless ModeTransition.table_available?

        @beat_mutex.synchronize do
          return true if fresh?

          outcome = in_registry_transaction do |c|
            id = refresh(c, @row_id) if @row_id && @pid == Process.pid
            id ||= insert(c)
            applied = last_applied(c)
            if authoritative?(applied)
              end_entry(c, id)
              [:authoritative, applied]
            else
              [:live, id]
            end
          end

          unless outcome
            Rails.logger.warn("Lyra: no connection of its own for the registry of processes that leave touches out; " \
                              "this touch is recorded")
            return false
          end

          status, value = outcome
          if status == :authoritative
            forget
            fence!(value)
            Rails.logger.error(@fence)
            return false
          end

          remember(value)
          warn_once
          true
        end
      rescue StandardError => e
        Rails.logger.error("Lyra: could not record that this process leaves touches out; it records them instead - " \
                           "#{e.class}: #{e.message}")
        false
      end

      # Run the block with a connection in a transaction of its own, never the
      # caller's: this thread's connection when no transaction is open on it,
      # else a second one, checked out for at most CHECKOUT_TIMEOUT seconds
      # (none when the connection is pinned, as in transactional tests).
      # Under the registry's advisory lock, with LOCK_TIMEOUT. Returns the
      # block's value, or nil when no such connection could be had.
      def in_registry_transaction(&block)
        where = ActiveRecord::Base.with_connection do |c|
          next :here unless c.transaction_open?

          c.pinned ? :none : :second
        end
        return nil if where == :none
        return ActiveRecord::Base.with_connection { |c| locked_transaction(c, &block) } if where == :here

        pool = ActiveRecord::Base.connection_pool
        Thread.new do
          Thread.current.report_on_exception = false # its error is raised to the caller by #value
          connection = pool.checkout(CHECKOUT_TIMEOUT)
          begin
            locked_transaction(connection, &block)
          ensure
            pool.checkin(connection)
          end
        end.value
      rescue ActiveRecord::ConnectionTimeoutError
        nil
      end

      def locked_transaction(connection)
        connection.transaction do
          if postgres?(connection)
            connection.execute("SET LOCAL lock_timeout = '#{LOCK_TIMEOUT}'")
            Lyra::AdvisoryLock.xact_lock(connection, LOCK_KEY, purpose: "touch registry")
          end
          yield connection
        end
      end

      def remember(id)
        @mutex.synchronize do
          @row_id = id
          @pid = Process.pid
          @beat_at = monotonic
        end
        return if @exit_hook

        @exit_hook = true
        at_exit { deregister! }
      end

      def forget
        @mutex.synchronize do
          @row_id = nil
          @beat_at = nil
        end
      end

      def insert(c)
        @started_at = Time.current if @pid != Process.pid || @started_at.nil?
        who = Lyra::Attribution.of
        now = now_sql(c)
        c.select_value(
          "INSERT INTO #{TABLE} (kind, from_config, to_config, position, checked, created_at, seen_at, started_at, " \
          "actor, os_user, host, pid) SELECT #{c.quote(KIND)}, #{c.quote(Lyra::VERSION)}, 'touches', " \
          "COALESCE(MAX(id), 0), 0, #{now}, #{now}, #{c.quote(@started_at.utc)}, " \
          "#{c.quote(who[:actor])}, #{c.quote(who[:os_user])}, #{c.quote(who[:host])}, #{Integer(who[:pid])} " \
          "FROM #{TABLE} RETURNING id"
        ).to_i
      end

      # The refreshed entry's id, or nil when it has ended or gone.
      def refresh(c, id)
        c.select_value(
          "UPDATE #{TABLE} SET seen_at = #{now_sql(c)}, position = (SELECT COALESCE(MAX(id), 0) FROM #{TABLE}) " \
          "WHERE id = #{Integer(id)} AND kind = #{c.quote(KIND)} AND ended_at IS NULL RETURNING id"
        )&.to_i
      end

      def end_entry(c, id)
        now = now_sql(c)
        c.execute("UPDATE #{TABLE} SET ended_at = #{now}, seen_at = #{now}, " \
                  "position = (SELECT COALESCE(MAX(id), 0) FROM #{TABLE}) WHERE id = #{Integer(id)}")
      end

      def last_applied(c)
        c.select_value("SELECT to_config FROM #{TABLE} WHERE kind = 'applied' ORDER BY id DESC LIMIT 1")
      end

      def deregister!
        id = @mutex.synchronize do
          next nil unless @row_id && @pid == Process.pid

          found = @row_id
          @row_id = nil
          @beat_at = nil
          found
        end
        return unless id

        done = in_registry_transaction { |c| end_entry(c, id) || true }
        return if done

        Rails.logger&.warn("Lyra: no connection to end this process's entry among those that leave touches out; it " \
                           "expires in #{EXPIRY}s")
      rescue StandardError => e
        Rails.logger&.warn("Lyra: could not end this process's entry among those that leave touches out; it expires " \
                           "in #{EXPIRY}s - #{e.class}: #{e.message}")
      end

      def warn_once
        return if @warned_pid == Process.pid

        @warned_pid = Process.pid
        Rails.logger.warn(WARNING)
      end

      def postgres?(connection) = connection.adapter_name.match?(/postgres/i)

      # The database's current time, at the statement (not the transaction's
      # start).
      def now_sql(connection)
        postgres?(connection) ? "clock_timestamp()" : "CURRENT_TIMESTAMP"
      end

      def expiry_boundary(connection)
        if connection.adapter_name.match?(/sqlite/i)
          "datetime('now', '-#{EXPIRY} seconds')"
        else
          "#{now_sql(connection)} - INTERVAL '#{EXPIRY}' SECOND"
        end
      end

      def time(value)
        return nil if value.nil?

        value.is_a?(String) ? Time.zone.parse(value) : value
      end

      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
