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
  # gate, so the gate is not run again. It looks:
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
  # config.mode_sync: nil (default) follows the Mode Transition Safety gate
  # (on everywhere but the test environment); true; false.
  module ModeSync
    @mutex = Mutex.new
    @last_seen_id = nil
    @checked_at = nil

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
        return nil unless enabled?
        return nil if due_in.positive?
        return nil if ActiveRecord::Base.connection.transaction_open?

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

          @last_seen_id = row[:id]
          return nil if row[:config] == ModeTransition.current

          previous = ModeTransition.current
          ModeTransition.apply_label(row[:config])
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

      def reset!
        @mutex.synchronize do
          @last_seen_id = nil
          @checked_at = nil
        end
      end

      private

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
