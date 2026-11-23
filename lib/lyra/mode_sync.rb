# frozen_string_literal: true

module Lyra
  # Keeps every process of an application in the mode last switched to.
  #
  # The mode a process runs in lives in its own memory (Lyra.config). The
  # application-wide mode is the latest 'applied' row in
  # ModeTransition::TABLE: written when a process boots in a new mode (after
  # the boot gate) and by every gated switch (ModeTransition.to!). Without
  # this, a switch made in one process (a console) changed that process only,
  # and the others kept writing in the old mode.
  #
  # Each process remembers the latest applied row it has seen. At most every
  # config.mode_sync_interval seconds (default 5) it looks for a newer one,
  # and adopts its mode: the process that recorded it already passed the
  # gate, so the gate is not run again; but a switch the gate checks (an
  # escalation, or leaving a lagging mode) is adopted only if the
  # row names the certificate of the clean check that cleared it (or the operator
  # overrode the gate, which the row says), so one INSERT cannot move every
  # process to a mode whose stores were never compared (0.9.3 adopted any row;
  # ModeTransition.adoption_refusal).
  # It looks:
  # - at the start of each web request (Middleware);
  # - before each background job (ActiveJob before_perform);
  # - before each write to a monitored model, which covers consoles and
  #   scripts;
  # never inside an open transaction, so a mode cannot change half-way
  # through a write.
  #
  # It reacts only to switches recorded after the process last looked: a
  # process's own in-process changes through the raw config.mode = setter
  # (tests, benchmark harnesses) are left alone.
  #
  # A process whose boot check did not run (a rake task; any process with the
  # gate off) has not looked when it boots, and may have booted in a stale
  # mode: at its first check it adopts the application's, unless it has set
  # its mode since boot (any mode, the one it booted in too) and the switch is
  # older than the boot (remember_boot!). The configuration applied again by a
  # code reload is not a set.
  #
  # config.mode_sync: nil (default) follows the Mode Transition Safety gate
  # (on everywhere but the test environment); true; false.
  module ModeSync
    @mutex = Mutex.new
    @last_seen_id = nil
    @checked_at = nil
    @boot = nil

    class << self
      attr_reader :last_seen_id

      def enabled?
        setting = Lyra.config.mode_sync
        setting.nil? ? ModeTransition.gate_enabled? : setting
      end

      # Adopt the application-wide mode if another process switched it.
      # Cheap when nothing is due: a clock read. Returns the label adopted, or
      # nil.
      def maybe_sync!
        # A process that leaves touches out keeps its registry entry fresh from
        # here, outside any transaction (nothing with config.record_touches true).
        if Lyra.config.record_touches == false && !ActiveRecord::Base.with_connection(&:transaction_open?)
          TouchRegistry.heartbeat_if_due
        end
        return nil unless enabled?
        return nil if due_in.positive?
        return nil if ActiveRecord::Base.with_connection(&:transaction_open?)

        sync!
      rescue ActiveRecord::NoDatabaseError, ActiveRecord::ConnectionNotEstablished
        nil
      end

      def sync!
        @mutex.synchronize do
          @checked_at = now
          row = ModeTransition.latest_applied
          return nil unless row
          return nil if @last_seen_id && row[:id] <= @last_seen_id

          if row[:config] == ModeTransition.current
            @last_seen_id = row[:id]
            return nil
          end

          # The row counts as seen once it is decided: adopted, or refused (logged
          # once). An error while deciding leaves it unseen, so the next check tries
          # again rather than leave this process in its mode for good.
          # The application runs in a mode whose log rebuilds rows, and this
          # process leaves touches out: it must not go on that way. It refuses
          # every touch it would leave out from now on (TouchRegistry.fence!),
          # and each check raises, until it runs with record_touches on.
          if Lyra.config.record_touches == false && TouchRegistry.authoritative?(row[:config])
            TouchRegistry.fence!(row[:config])
            message = TouchRegistry.process_refusal(row[:config])
            Rails.logger.error(message)
            raise ModeTransition::Refused, message
          end

          # Not while another process leaves touches out of the log: the row
          # stays unseen, and this process adopts it once that process's entry
          # has ended or expired (as a fenced process retries).
          if TouchRegistry.authoritative?(row[:config]) &&
             (touches = TouchRegistry.gate_refusal(ModeTransition.current, row[:config]))
            if @touch_refused_id != row[:id]
              @touch_refused_id = row[:id]
              Rails.logger.error("Lyra: did not adopt the application's mode #{row[:config]} yet; this process stays " \
                                 "in #{ModeTransition.current} and tries again: #{touches}")
            end
            return nil
          end

          # After the two touch checks, which must hold whatever set the mode.
          if set_since_boot?(row)
            @last_seen_id = row[:id]
            return nil
          end

          if (refusal = ModeTransition.adoption_refusal(row))
            @last_seen_id = row[:id]
            Rails.logger.error("Lyra: did not adopt the application's mode #{row[:config]}; this process stays in " \
                               "#{ModeTransition.current}: #{refusal}")
            return nil
          end

          previous = ModeTransition.current
          ModeTransition.apply_label(row[:config])
          @last_seen_id = row[:id]
          Rails.logger.warn("Lyra: adopted the application's mode #{row[:config]} (was #{previous}), switched elsewhere")
          row[:config]
        end
      end

      # Mark the application-wide record up to +id+ as seen (at boot, and
      # after this process's own switch).
      def seen!(id)
        @mutex.synchronize do
          @last_seen_id = id if id && (@last_seen_id.nil? || id > @last_seen_id)
          @checked_at = now
        end
      end

      # At the end of initialization (Engine), where the boot check marked
      # nothing seen: the latest applied id then, from which on the process's
      # own sets are its own (mode_set!). Not seen!: a process that merely
      # booted still adopts that row.
      # It creates no table and keeps no connection it opened (db:drop needs
      # the database free of sessions). When the database cannot be read,
      # nothing is remembered, and the first check adopts as it finds.
      def remember_boot! # :nodoc:
        @boot = nil
        return if @last_seen_id || !enabled?

        id = latest_id_at_boot
        # Assigned last: loading Active Record may run the application's
        # configuration, which is not a set.
        @boot = { id: id, set: false }
      rescue StandardError => e
        Rails.logger&.debug("Lyra: the applied mode not read at boot (#{e.class}: #{e.message})")
      end

      def forget_boot! # :nodoc:
        @boot = nil
      end

      # The process set its mode (Configuration's mode setters), unless the
      # code reload in progress on this thread applies the configuration again.
      def mode_set! # :nodoc:
        boot = @boot
        return if boot.nil? || boot[:set] || Thread.current[:lyra_reapplying_configuration]

        @boot = boot.merge(set: true)
      end

      # Around the reloader's prepare! (a code reload's to_prepare blocks).
      def reapplying_configuration # :nodoc:
        previous = Thread.current[:lyra_reapplying_configuration]
        Thread.current[:lyra_reapplying_configuration] = true
        yield
      ensure
        Thread.current[:lyra_reapplying_configuration] = previous
      end

      def reset!
        @mutex.synchronize do
          @last_seen_id = nil
          @checked_at = nil
          @boot = nil
        end
      end

      private

      # Whether this process set its mode after a boot that +row+ predates.
      def set_since_boot?(row)
        @boot && @boot[:set] && row[:id] <= @boot[:id]
      end

      # 0 without a table or a row.
      def latest_id_at_boot
        pool = ActiveRecord::Base.connection_pool
        connected = pool.connected?
        # SQLite creates the file on connecting, and db:create would find it.
        db = pool.db_config
        return 0 if !connected && db.adapter == "sqlite3" && !File.exist?(File.expand_path(db.database, Rails.root))

        pool.with_connection do |c|
          next 0 unless c.table_exists?(ModeTransition::TABLE)

          c.select_value("SELECT MAX(id) FROM #{ModeTransition::TABLE} WHERE kind = 'applied'").to_i
        end
      ensure
        pool.disconnect if connected == false
      end

      def due_in
        return 0 unless @checked_at

        Lyra.config.mode_sync_interval.to_f - (now - @checked_at)
      end

      def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # Prepended onto monitored models: adopt a switch made elsewhere before a
    # write, at the call the application makes (save, update, destroy), which
    # normally runs outside a transaction. (Lyra's write hooks run inside the
    # write's transaction, where a mode must not change.)
    module BeforeWrite
      %i[save save! update update! destroy destroy!].each do |method_name|
        define_method(method_name) do |*args, **kwargs, &block|
          ModeSync.maybe_sync!
          super(*args, **kwargs, &block)
        end
      end
    end

    # Prepended onto the application's reloader: a code reload applies the
    # configuration again, which is no set of the process's own.
    module Reloads
      def prepare!
        ModeSync.reapplying_configuration { super }
      end
    end

    # Rack middleware: adopt a switch made elsewhere before each request.
    class Middleware
      def initialize(app)
        @app = app
      end

      def call(env)
        ModeSync.maybe_sync!
        @app.call(env)
      end
    end
  end
end
