# frozen_string_literal: true

module Lyra
  # Mode Transition Safety (thesis, architecture chapter): a mode switch that
  # changes which store is authoritative is allowed only when the two agree,
  # for every monitored record.
  #
  # Two kinds of switch are gated:
  # - Escalation, from Disabled or Monitor to Hijack or event sourcing: the
  #   events become authoritative, so they must reproduce every row. Rows
  #   that predate Lyra are imported first (Lyra::Genesis), or each would
  #   count as a discrepancy.
  # - Leaving a mode whose tables lag the log (ES-NoProj, ES-Lazy, ES-Async)
  #   for one that reads them: the tables must catch up first. ES-Lazy
  #   catches up on read; ES-NoProj needs a Rebuild (rebuild: true).
  # Every other switch (Monitor to Disabled, ES-Sync to ES-NoProj, ...) keeps
  # the authoritative store as it is and passes freely.
  #
  # A check compares every row with the state replayed from its stream, and
  # every stream with its row, in batches, reading the real table (never the
  # event-store read path). It notes the event store's position when it
  # starts, then re-checks the records whose streams moved or whose rows were
  # updated while it ran, so the answer holds at its end, not only at its
  # start. A clean check is stored as a certificate.
  #
  # The gate runs:
  # - in ModeTransition.to! and the config.enable_*! helpers, at runtime. A
  #   fresh certificate for the switch is accepted after re-checking only
  #   what changed since; otherwise a full check runs. Discrepancies refuse
  #   the switch (Refused, with the report);
  # - at boot, against the mode the application last ran in. Without a
  #   certificate for the switch the boot is refused
  #   (LYRA_FORCE_MODE_TRANSITION=1 overrides).
  # On large tables run `rake lyra:mode:check TO=...` beforehand: the
  # certificate it stores makes the switch itself fast.
  #
  # config.mode_transition_gate: nil (default) gates everywhere but the
  # test environment; true always; false never. config.mode = ... is the
  # raw, ungated setter used by tests and benchmark harnesses.
  class ModeTransition
    TABLE = "lyra_mode_transitions"
    LAGGING = ["event_sourcing/disabled", "event_sourcing/lazy", "event_sourcing/async"].freeze

    class Refused < StandardError
      attr_reader :report

      def initialize(message, report = nil)
        @report = report
        super(message)
      end
    end

    Discrepancy = Struct.new(:model, :id, :problem, :details, keyword_init: true) do
      def to_s = "#{model} #{id}: #{problem}#{" (#{details})" if details}"
    end

    Report = Struct.new(:from, :to, :checked, :rechecked, :imported, :rebuilt, :discrepancies,
                        :position, :started_at, :finished_at, keyword_init: true) do
      def clean? = discrepancies.empty?

      def summary
        "#{from} -> #{to}: #{checked} records checked, #{rechecked} re-checked, " \
          "#{imported} imported, #{discrepancies.size} discrepancies"
      end
    end

    class << self
      # The current configuration as "mode" or "event_sourcing/<projection>".
      def current
        label(Lyra.config.mode, Lyra.config.projection_mode)
      end

      def label(mode, projection_mode = nil)
        mode.to_sym == :event_sourcing ? "event_sourcing/#{(projection_mode || :sync)}" : mode.to_s
      end

      def gate_enabled?
        setting = Lyra.config.mode_transition_gate
        return setting unless setting.nil?

        !(defined?(Rails) && Rails.respond_to?(:env) && Rails.env.test?)
      end

      # Whether switching +from+ -> +to+ needs the stores to agree.
      def gate_required?(from, to)
        return false if from == to

        escalation = %w[disabled monitor].include?(from) && !%w[disabled monitor].include?(to)
        leaving_lag = LAGGING.include?(from) && !%w[event_sourcing/disabled event_sourcing/lazy].include?(to)
        escalation || leaving_lag
      end

      # Switch to +mode+ (and +projection_mode+ for event sourcing), gated.
      # Returns the report of the check that allowed it (nil if none was
      # needed).
      def to!(mode, projection_mode: nil, force: false, rebuild: false)
        projection_mode ||= Lyra.config.projection_mode if mode.to_sym == :event_sourcing
        from = current
        to = label(mode, projection_mode)
        report = nil

        if gate_enabled? && gate_required?(from, to) && !force
          report = certified_check(from, to) || check(to: to, from: from, rebuild: rebuild)
          unless report.clean?
            raise Refused.new("Lyra refuses #{from} -> #{to}: #{report.discrepancies.size} discrepancies, e.g. " +
                              report.discrepancies.first(3).map(&:to_s).join("; "), report)
          end
        end

        apply(mode, projection_mode)
        id = record_applied(to)
        ModeSync.seen!(id)
        announce(from, to)
        report
      end

      # Switch this process to a recorded label ("hijack",
      # "event_sourcing/lazy"), without the gate (ModeSync: the process that
      # recorded it passed the gate).
      def apply_label(label)
        mode, projection_mode = label.split("/")
        apply(mode, projection_mode)
      end

      # The application-wide mode: { id:, config: } of the latest applied row.
      def latest_applied
        return nil unless table_ready?

        row = connection.select_one("SELECT id, to_config FROM #{TABLE} WHERE kind = 'applied' ORDER BY id DESC LIMIT 1")
        row && { id: row["id"].to_i, config: row["to_config"] }
      end

      # Compare every monitored record's row with its events. Returns a
      # Report; stores a certificate when it is clean.
      def check(to:, from: current, models: Lyra.config.monitored_models, rebuild: false, batch_size: 1_000)
        started_at = Time.current
        position = event_position
        imported = 0
        rebuilt = 0

        if !%w[disabled monitor].include?(to) && %w[disabled monitor].include?(from)
          models.each { |model| imported += Lyra::Genesis.import_all(model) }
        end
        if LAGGING.include?(from)
          Lyra::Projections::LazyProjection.catch_up! if from == "event_sourcing/lazy"
          rebuilt = models.sum { |model| Lyra::Projections::Rebuild.rebuild(model)[:records] } if rebuild
        end

        discrepancies = []
        checked = 0
        models.each do |model|
          ids_to_check(model).each_slice(batch_size) do |ids|
            ids.each { |id| (problem = compare(model, id)) && discrepancies << problem }
            checked += ids.size
          end
        end

        changed = changed_since(models, position, started_at)
        changed.each do |model, ids|
          discrepancies.reject! { |d| d.model == model.name && ids.include?(d.id.to_s) }
          ids.each { |id| (problem = compare(model, id)) && discrepancies << problem }
        end

        report = Report.new(from: from, to: to, checked: checked, rechecked: changed.values.sum(&:size),
                            imported: imported, rebuilt: rebuilt, discrepancies: discrepancies,
                            position: event_position, started_at: started_at, finished_at: Time.current)
        certify(report) if report.clean?
        report
      end

      # At boot: refuse to start in a mode the application has not been
      # cleared to switch to from the one it last ran in.
      def boot_check!
        return unless gate_enabled?
        return unless table_ready?

        to = current
        last = last_applied
        if last.nil? || last == to || !gate_required?(last, to)
          ModeSync.seen!(last == to ? latest_applied&.dig(:id) : record_applied(to))
          return
        end

        report = certified_check(last, to)
        if report&.clean? || ENV["LYRA_FORCE_MODE_TRANSITION"].present?
          ModeSync.seen!(record_applied(to))
          return
        end

        raise Refused.new("Lyra will not start in #{to}: the application last ran in #{last}, and no clean check " \
                          "certifies that switch. Run `rake lyra:mode:check TO=#{to.sub('event_sourcing/', 'event_sourcing PROJECTION=')}`, " \
                          "or set LYRA_FORCE_MODE_TRANSITION=1.", report)
      end

      def last_applied
        return nil unless table_ready?

        connection.select_value("SELECT to_config FROM #{TABLE} WHERE kind = 'applied' ORDER BY id DESC LIMIT 1")
      end

      # Every id of +model+ with a row or a stream (Lyra::Repair).
      def record_ids(model) = ids_to_check(model)

      # nil if the record's row and events agree, else a Discrepancy
      # (Lyra::Repair).
      def discrepancy(model, id) = compare(model, id)

      private

      def apply(mode, projection_mode)
        Lyra.config.mode = mode.to_sym
        Lyra.config.hijack_enabled = mode.to_sym == :hijack
        Lyra.config.projection_mode = projection_mode.to_sym if projection_mode
      end

      # A fresh certificate for the switch, re-checked for what changed since.
      def certified_check(from, to)
        return nil unless table_ready?

        row = connection.select_one(
          "SELECT position, created_at FROM #{TABLE} WHERE kind = 'certificate' AND from_config = #{q(from)} " \
          "AND to_config = #{q(to)} ORDER BY id DESC LIMIT 1"
        )
        return nil unless row

        certified_at = row["created_at"].is_a?(String) ? Time.zone.parse(row["created_at"]) : row["created_at"]
        return nil if certified_at < Time.current - Lyra.config.mode_transition_certificate_ttl

        models = Lyra.config.monitored_models
        changed = changed_since(models, row["position"].to_i, certified_at)
        discrepancies = changed.flat_map { |model, ids| ids.filter_map { |id| compare(model, id) } }
        Report.new(from: from, to: to, checked: 0, rechecked: changed.values.sum(&:size), imported: 0, rebuilt: 0,
                   discrepancies: discrepancies, position: event_position, started_at: certified_at,
                   finished_at: Time.current)
      end

      # Every id that has a row or a stream.
      def ids_to_check(model)
        bypass do
          table_ids = model.unscoped.pluck(model.primary_key).map(&:to_s)
          (table_ids | stream_ids(model)).sort_by { |id| id.match?(/\A\d+\z/) ? [0, id.to_i] : [1, id] }
        end
      end

      def stream_ids(model)
        prefix = "#{model.name}$"
        connection.select_values(
          "SELECT DISTINCT stream FROM event_store_events_in_streams WHERE stream LIKE #{q(like_prefix(prefix))}"
        ).map { _1.delete_prefix(prefix) }
      end

      # nil if the record's row and events agree, else a Discrepancy.
      def compare(model, id)
        bypass do
          row = model.unscoped.find_by(model.primary_key => id)
          events = Lyra.config.event_store.read.stream("#{model.name}$#{id}").to_a
          replayed = events.select { Lyra::Event.operation_of(_1) }
          gone = replayed.empty? || Lyra::Event.operation_of(replayed.last) == :destroyed

          if row.nil?
            next nil if gone

            next Discrepancy.new(model: model.name, id: id, problem: "events but no row")
          end
          next Discrepancy.new(model: model.name, id: id, problem: "row but no events") if events.empty?
          next Discrepancy.new(model: model.name, id: id, problem: "row of a destroyed record") if gone

          differences = Lyra::DualView.new(model, id).compare[:differences]
          next nil if differences[:no_differences]

          Discrepancy.new(model: model.name, id: id, problem: "row differs from its events",
                          details: differences.keys.first(5).join(", "))
        end
      end

      # { model => [ids] } whose streams moved past +position+ or whose rows
      # were updated at or after +since+.
      def changed_since(models, position, since)
        models.each_with_object({}) do |model, acc|
          prefix = "#{model.name}$"
          moved = connection.select_values(
            "SELECT DISTINCT s.stream FROM event_store_events_in_streams s JOIN event_store_events e " \
            "ON e.event_id = s.event_id WHERE e.id > #{Integer(position)} AND s.stream LIKE #{q(like_prefix(prefix))}"
          ).map { _1.delete_prefix(prefix) }
          touched = if model.column_names.include?("updated_at")
                      bypass { model.unscoped.where("updated_at >= ?", since).pluck(model.primary_key).map(&:to_s) }
                    else
                      []
                    end
          ids = (moved | touched)
          acc[model] = ids if ids.any?
        end
      end

      def certify(report)
        return unless table_ready?

        connection.execute(
          "INSERT INTO #{TABLE} (kind, from_config, to_config, position, checked, created_at) VALUES " \
          "('certificate', #{q(report.from)}, #{q(report.to)}, #{Integer(report.position)}, #{Integer(report.checked)}, " \
          "#{q(report.finished_at.utc)})"
        )
      end

      # Record +to+ as the application-wide mode; returns the row's id.
      def record_applied(to)
        return nil unless table_ready?

        connection.select_value(
          "INSERT INTO #{TABLE} (kind, from_config, to_config, position, checked, created_at) VALUES " \
          "('applied', NULL, #{q(to)}, #{Integer(event_position)}, 0, #{q(Time.current.utc)}) RETURNING id"
        ).to_i
      end

      # Say what a switch reaches: with ModeSync, every process within its
      # interval; without it, this process only.
      def announce(from, to)
        message =
          if ModeSync.enabled?
            "Lyra: switched the application #{from} -> #{to}; other processes adopt it within " \
            "#{Lyra.config.mode_sync_interval}s (ModeSync)"
          else
            "Lyra: switched this process #{from} -> #{to}. ModeSync is off: other running processes keep " \
            "their mode until they restart with the new configuration"
          end
        Rails.logger.warn(message)
      end

      def event_position
        connection.select_value("SELECT COALESCE(MAX(id), 0) FROM event_store_events").to_i
      end

      # Created on first use, so the gate needs no migration. False when the
      # database cannot be reached (assets precompilation, a first setup).
      def table_ready?
        return true if @table_ready

        unless connection.table_exists?(TABLE)
          connection.create_table(TABLE) do |t|
            t.string :kind, null: false
            t.string :from_config
            t.string :to_config, null: false
            t.bigint :position, null: false, default: 0
            t.integer :checked, null: false, default: 0
            t.datetime :created_at, null: false
          end
        end
        @table_ready = true
      rescue ActiveRecord::NoDatabaseError, ActiveRecord::ConnectionNotEstablished
        false
      end

      def bypass
        previous = Thread.current[:lyra_bypass_read_override]
        Thread.current[:lyra_bypass_read_override] = true
        yield
      ensure
        Thread.current[:lyra_bypass_read_override] = previous
      end

      def connection = ActiveRecord::Base.connection

      def q(value) = connection.quote(value)

      def like_prefix(prefix) = "#{ActiveRecord::Base.sanitize_sql_like(prefix)}%"
    end
  end
end
