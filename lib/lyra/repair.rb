# frozen_string_literal: true

module Lyra
  # Brings the event log back in line with the tables after events were lost.
  #
  # Monitor's failure policy is log-and-continue: when an event cannot be
  # stored the write stands and its stream falls behind its row
  # (EventStoreUnavailableError). DualViewSampler and the mode-transition
  # check find such records; this repairs them, durably, from the table:
  #
  # - a row with no events, or the row of a record its stream says was
  #   destroyed: an Imported event with the row's state, as Genesis writes;
  # - a row that differs from its events: an Updated event carrying the
  #   differing columns, from the replayed value to the row's;
  # - events but no row: a Destroyed event.
  #
  # The stream then replays to the row. What is lost is the detail of the
  # missing changes (each record jumps to its current state), which a retry
  # queue would also lose with its process. Each repair event carries
  # metadata source "lyra_repair" and the problem it repaired.
  #
  # Only where the table is authoritative: Monitor or Disabled. In Hijack and
  # event sourcing the events are, and a table that disagrees is rebuilt from
  # them instead (bin/rails lyra:mode:check ... REBUILD=1).
  #
  # Each record is repaired under a lock on its row, re-checked first, so a
  # write running at the same time is not overwritten with older values.
  module Repair
    SOURCE = "lyra_repair"

    class Refused < StandardError; end

    # Records whose repair event would hold a value their model cannot
    # represent (Lyra::Genesis's check): nothing was repaired. +rows+: how many
    # records; +values+: the first Genesis::LISTED Lyra::Genesis::Unrepresentable
    # of the +found+ in all.
    class Unrepresentable < Refused
      attr_reader :rows, :values, :found

      def initialize(rows:, values:, found:)
        @rows = rows
        @values = values
        @found = found
        super("lyra:repair will not write events for #{rows} record(s) whose rows hold values their model cannot " \
              "represent, so the events would not match them; nothing was repaired. Fix the rows or the models; or " \
              "skip those records (config.genesis_unrepresentable = :skip, or UNREPRESENTABLE=skip for lyra:repair). " \
              "#{values.map(&:to_s).join('; ')}#{" (and #{found - values.size} more)" if found > values.size}")
      end
    end

    # +unrepresentable+: the first Genesis::LISTED values the model cannot
    # represent, of the +skipped+ records left out of line (with :skip) or
    # that would be (a dry run).
    Result = Struct.new(:checked, :found, :repaired, :remaining, :skipped, :unrepresentable, keyword_init: true) do
      def summary
        "checked #{checked} records: #{found.size} out of line, #{repaired.size} repaired, " \
          "#{remaining.size} still out of line" \
          "#{", #{skipped} with values their model cannot represent (not repaired)" if skipped.to_i.positive?}"
      end
    end

    class << self
      # Find, and unless +dry_run+, repair every out-of-line record of
      # +models+. Returns a Result whose found, repaired and remaining hold
      # ModeTransition::Discrepancy values.
      #
      # A repair writes the row as its model reads it. A record whose event
      # would hold a value the model cannot represent (an enum value outside
      # the mapping, read as nil; Lyra::Genesis's check, on the whole row for
      # an Imported event, on the changed columns for an Updated one) follows
      # +unrepresentable+, config.genesis_unrepresentable by default, as
      # Genesis does: :refuse raises Unrepresentable before anything is
      # written; :skip leaves those records out of line and repairs the rest.
      # Either way the Result lists them (a dry run never raises).
      def run(models: Lyra.config.monitored_models, dry_run: false, operator: nil,
              unrepresentable: Lyra.config.genesis_unrepresentable)
        skip = Lyra::Genesis.unrepresentable_choice(unrepresentable) == :skip
        unless Lyra.config.monitor_mode? || Lyra.config.disabled_mode?
          raise Refused, "lyra:repair writes the tables' state into the event log, so it runs only where the " \
                         "tables are authoritative (monitor or disabled). In #{ModeTransition.current} the events " \
                         "are: rebuild the tables from them (bin/rails lyra:mode:check TO=... REBUILD=1)."
        end

        found = []
        checked = 0
        models.each do |model|
          ids = ModeTransition.record_ids(model)
          checked += ids.size
          ids.each { |id| (problem = ModeTransition.discrepancy(model, id)) && found << [model, problem] }
        end

        # Refusing (or a dry run): every record is checked before anything is
        # written. Skipping: each repair checks its record, under its lock.
        held = []
        unless skip && !dry_run
          found.each do |model, problem|
            values = unrepresentable_values(model, problem, load_row(model, problem.id))
            held << values if values.any?
          end
          if held.any? && !skip && !dry_run
            values = held.flatten
            raise Unrepresentable.new(rows: held.size, values: values.first(Lyra::Genesis::LISTED), found: values.size)
          end
        end

        repaired = if dry_run
                     []
                   else
                     found.filter_map { |model, problem| repair_record(model, problem.id, operator: operator, skip: true, held: held) }
                   end
        remaining = found.filter_map { |model, problem| ModeTransition.discrepancy(model, problem.id) }
        Result.new(checked: checked, found: found.map(&:last), repaired: repaired, remaining: remaining,
                   skipped: held.size, unrepresentable: held.flatten.first(Lyra::Genesis::LISTED))
      end

      # Repair one record. Returns the Discrepancy it repaired, or nil if the
      # record was (or had come) back in line, or holds a value its model
      # cannot represent and +unrepresentable+ is :skip (:refuse raises
      # Unrepresentable; see run).
      def repair(model, id, operator: nil, unrepresentable: Lyra.config.genesis_unrepresentable)
        repair_record(model, id, operator: operator, skip: Lyra::Genesis.unrepresentable_choice(unrepresentable) == :skip)
      end

      private

      # repair; a record skipped for its values adds them to +held+ (run checks
      # first only when refusing, so a record is never held twice).
      def repair_record(model, id, operator:, skip:, held: nil)
        model.transaction do
          row = load_row(model, id, lock: true)
          problem = ModeTransition.discrepancy(model, id)
          next nil unless problem

          # DualView's differences, computed once for the check and the event.
          differs = problem.problem == "row differs from its events"
          diffs = differences(model, row) if differs
          values = unrepresentable_values(model, problem, row, diffs)
          if values.any?
            raise Unrepresentable.new(rows: 1, values: values.first(Lyra::Genesis::LISTED), found: values.size) unless skip

            held&.push(values)
            next nil
          end

          case problem.problem
          when "row but no events", "row of a destroyed record"
            append(model, id, :imported, problem, attributes: row.attributes, operator: operator)
          when "row differs from its events"
            replayed = Lyra::DualView.new(model, id).event_sourced_state[:state] || {}
            changes = changed_columns(row, replayed, diffs)
            append(model, id, :updated, problem, attributes: changes.transform_values(&:last), changes: changes, operator: operator)
          when "events but no row"
            replayed = Lyra::DualView.new(model, id).event_sourced_state[:state] || {}
            append(model, id, :destroyed, problem, attributes: replayed, operator: operator)
          end
          problem
        end
      end

      def load_row(model, id, lock: false)
        scope = lock ? model.unscoped.lock : model.unscoped
        # Lyra's own locking read: the row as it is, not first brought up to date.
        read = -> { scope.find_by(model.primary_key => id) }
        Lyra::PurposeBoundReads.internal(INTERNAL) { lock ? Lyra::Projections::LazyProjection.own_locking_read(&read) : read.call }
      end

      # The values of +row+ the repair of +problem+ would write that the model
      # cannot represent: the whole row for an Imported event, the changed
      # columns (+diffs+, DualView's differences, computed if not given) for an
      # Updated one (Lyra::Genesis.unrepresentable).
      def unrepresentable_values(model, problem, row, diffs = nil)
        return [] if row.nil?

        case problem.problem
        when "row but no events", "row of a destroyed record" then Lyra::Genesis.unrepresentable(row)
        when "row differs from its events"
          Lyra::Genesis.unrepresentable(row, columns: (diffs || differences(model, row)).keys)
        else []
        end
      end

      def differences(model, row)
        Lyra::PurposeBoundReads.internal(INTERNAL) { Lyra::DualView.new(model, row.id).compare[:differences] }
      end

      # Column => [replayed, row] for the columns DualView found different.
      def changed_columns(row, replayed, diffs)
        diffs.keys.to_h do |column|
          [column.to_s, [replayed.fetch(column.to_s) { replayed[column.to_sym] }, row.attributes[column.to_s]]]
        end
      end

      def append(model, id, operation, problem, attributes:, changes: {}, operator: nil)
        data = Lyra::EventData.build(model, id, operation, attributes: attributes, changes: changes)
        # Who ran the repair: the label (OPERATOR, Current.user, ...), which nobody checks,
        # and the operating system's user and host beside it (Lyra::Attribution).
        who = Lyra::Attribution.of(operator)
        metadata = { source: SOURCE, repaired: problem.problem, repaired_by: who[:actor], os_user: who[:os_user],
                     host: who[:host], pid: who[:pid], correlation_id: Lyra::Correlation.current_id }.compact
        event = Lyra::BypassEvents.event_class_for(model, operation)
                                  .new(data: data, metadata: Lyra::Privacy.stamp(model, data, metadata))
        Lyra.append_events(event, stream_name: Lyra.stream_name(model, id))
        Lyra::Projections::EventStoreReader.invalidate(model, id)
      end
    end
  end
end
