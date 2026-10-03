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

    Result = Struct.new(:checked, :found, :repaired, :remaining, keyword_init: true) do
      def summary
        "checked #{checked} records: #{found.size} out of line, #{repaired.size} repaired, " \
          "#{remaining.size} still out of line"
      end
    end

    class << self
      # Find, and unless +dry_run+, repair every out-of-line record of
      # +models+. Returns a Result whose found, repaired and remaining hold
      # ModeTransition::Discrepancy values.
      def run(models: Lyra.config.monitored_models, dry_run: false)
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

        repaired = dry_run ? [] : found.filter_map { |model, problem| repair(model, problem.id) }
        remaining = found.filter_map { |model, problem| ModeTransition.discrepancy(model, problem.id) }
        Result.new(checked: checked, found: found.map(&:last), repaired: repaired, remaining: remaining)
      end

      # Repair one record. Returns the Discrepancy it repaired, or nil if the
      # record was (or had come) back in line.
      def repair(model, id)
        model.transaction do
          row = Lyra::PurposeBoundReads.internal { model.unscoped.lock.find_by(model.primary_key => id) }
          problem = ModeTransition.discrepancy(model, id)
          next nil unless problem

          case problem.problem
          when "row but no events", "row of a destroyed record"
            append(model, id, :imported, problem, attributes: row.attributes)
          when "row differs from its events"
            replayed = Lyra::DualView.new(model, id).event_sourced_state[:state] || {}
            changes = changed_columns(model, row, replayed)
            append(model, id, :updated, problem, attributes: changes.transform_values(&:last), changes: changes)
          when "events but no row"
            replayed = Lyra::DualView.new(model, id).event_sourced_state[:state] || {}
            append(model, id, :destroyed, problem, attributes: replayed)
          end
          problem
        end
      end

      private

      # Column => [replayed, row] for the columns DualView finds different.
      def changed_columns(model, row, replayed)
        differences = Lyra::DualView.new(model, row.id).compare[:differences]
        differences.keys.reject { _1 == :no_differences }.to_h do |column|
          [column.to_s, [replayed[column] || replayed[column.to_s], row.attributes[column.to_s]]]
        end
      end

      def append(model, id, operation, problem, attributes:, changes: {})
        data = {
          model_class: model.name,
          model_id: id,
          operation: operation,
          attributes: attributes,
          changes: changes,
          timestamp: Time.current
        }
        metadata = { source: SOURCE, repaired: problem.problem, correlation_id: Lyra::Correlation.current_id }.compact
        event = Lyra::BypassEvents.event_class_for(model, operation)
                                  .new(data: data, metadata: Lyra::Privacy.stamp(model, data, metadata))
        Lyra.append_events(event, stream_name: "#{model.name}$#{id}")
        Lyra::Projections::EventStoreReader.invalidate(model, id)
      end
    end
  end
end
