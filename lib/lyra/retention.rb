# frozen_string_literal: true

module Lyra
  # Applies the privacy policy's retention rules (opt-in:
  # config.retention_executor). For each monitored model the policy has a
  # retention rule for, a record whose retention period has passed gets the
  # rule's on_expiry strategy:
  #
  # - :anonymize   its personal attributes are erased from the row and from
  #                every event (Lyra::Erasure), recorded as ErasureApplied;
  # - :hard_delete the same, then the record is destroyed through the normal
  #                write path (so the destroy is an event too);
  # - :soft_delete deleted_at (or discarded_at) is set through the normal
  #                write path; the data itself is kept, as the strategy says;
  # - :archive     reported as skipped: the policy names no archive.
  #
  # An attribute with its own, shorter retention (field :email, duration:)
  # is erased when that period passes, before the record's own.
  #
  # The period runs from the record's created_at, or the column
  # config.retention_anchors names for the model ({ "Registration" =>
  # :registered_at }). Rule conditions (when { ... }) are given the record.
  # Already-erased attributes are not erased again, so a run is idempotent.
  # In ES-NoProj the records, and their anchor, are read from the event store
  # (no default scope applied, as in every mode: a soft-deleted record is
  # still due), and a deletion or soft deletion is written as an event.
  #
  # A record under a restriction of processing (Art. 18, with PAM DSL's
  # rights and Lyra::Rights) is skipped and reported (outcome :restricted,
  # the restrictions in +detail+; Result#restricted lists them): the subject
  # asked for it to be kept (18(1)(b), (c)), and erasing it is processing
  # beyond storage. It is acted on at the first run after the restriction is
  # lifted. An objection's 18(1)(d) restriction, which covers one purpose,
  # does not hold it.
  #
  # Only a model with a retention rule of its own (for_model) is acted on:
  # the policy's default period is not executed.
  #
  # :soft_delete is the strategy of a rule that names none (PAM DSL's
  # default), and it needs a deleted_at or discarded_at column: on a table
  # without one, every record past its period is skipped and kept. Lyra
  # warns about such a rule (Rails.logger, else Kernel#warn) at boot, for
  # the models enrolled by then (check_rules!), and again in each run that
  # skips records for it, once per model, not once per record.
  #
  # Run it on a schedule: bin/rails lyra:retention:apply (DRY_RUN=1 lists
  # what would happen, and works with the executor off), or enqueue
  # Lyra::RetentionJob. Off by default: deleting data on a timer is a
  # decision a deployment makes, not one a library makes for it.
  module Retention
    SOURCE = "lyra_retention"
    SOFT_DELETE_COLUMNS = %w[deleted_at discarded_at].freeze

    class Disabled < StandardError; end

    Action = Struct.new(:model, :id, :strategy, :fields, :outcome, :detail, keyword_init: true) do
      def to_s = "#{model} #{id}: #{strategy} #{Array(fields).join(', ')} -> #{outcome}#{" (#{detail})" if detail}"
    end

    Result = Struct.new(:actions, :dry_run, keyword_init: true) do
      # The records skipped because a restriction of processing holds them.
      def restricted = actions.select { |a| a.outcome == :restricted }

      def summary
        counts = actions.group_by(&:outcome).transform_values(&:size)
        "#{dry_run ? 'would act on' : 'acted on'} #{actions.size} records: " +
          (counts.empty? ? "nothing due" : counts.map { |outcome, n| "#{n} #{outcome}" }.join(", "))
      end
    end

    class << self
      def apply!(models: Lyra.config.monitored_models, dry_run: false, now: Time.current)
        unless dry_run || Lyra.config.retention_executor
          raise Disabled, "the retention executor is off (config.retention_executor); DRY_RUN lists what it would do"
        end

        actions = models.flat_map { |model| apply_model(model, dry_run, now) }
        Result.new(actions: actions, dry_run: dry_run)
      end

      # Warns about each of +models+ whose retention rule is :soft_delete
      # while its table has neither deleted_at nor discarded_at, so the rule
      # can never act; returns their names. Lyra calls it at boot for the
      # models enrolled by then. A model whose table does not exist, or
      # whose policy cannot be read, is passed over.
      def check_rules!(models: Lyra.config.monitored_models)
        models.filter_map do |model|
          policy = Lyra::Privacy.policy_for(model)
          rule = policy.retention_rule(model)
          next unless rule && rule.strategy == :soft_delete && model.table_exists?
          next if soft_delete_column(model)

          warn_soft_delete(model, policy, rule)
          model.name
        rescue StandardError => e
          raise unless e.is_a?(ActiveRecord::ActiveRecordError) || e.class.name.start_with?("PamDsl::")

          nil
        end
      end

      private

      def apply_model(model, dry_run, now)
        policy = Lyra::Privacy.policy_for(model)
        rule = policy.retention_rule(model)
        return [] unless rule

        anchor = anchor_for(model)
        personal = policy.declared_fields.map(&:to_s) & model.column_names
        shortest = ([rule.duration] + rule.field_durations.values).compact.min
        return [] unless shortest

        actions = PurposeBoundReads.internal(INTERNAL) do
          candidates(model, anchor, now - shortest).filter_map do |record|
            next unless rule.applies.call(record)

            act(model, record, rule, personal, anchor, dry_run, now)
          end
        end
        skipped = actions.count { |a| a.strategy == :soft_delete && a.outcome == :skipped }
        warn_soft_delete(model, policy, rule, skipped: skipped) if skipped.positive?
        actions
      end

      def soft_delete_column(model)
        (SOFT_DELETE_COLUMNS & model.column_names).first
      end

      # Once per model per call: the model, its policy and rule, what
      # happens to its records, and the two ways to fix it.
      def warn_soft_delete(model, policy, rule, skipped: nil)
        period = rule.duration ? "keep_for #{rule.duration.inspect}, " : ""
        kept = if skipped
                 "#{skipped} #{skipped == 1 ? 'record past the period was' : 'records past the period were'} " \
                   "skipped and kept"
               else
                 "records past the period will be skipped and kept"
               end
        message = "Lyra: the retention rule for #{model.name} (policy :#{policy.name}, #{period}" \
                  "on_expiry :soft_delete, also what a rule that names no strategy gets) cannot act: " \
                  "#{model.table_name} has no deleted_at or discarded_at column, so #{kept}. " \
                  "Add a deleted_at (or discarded_at) column, or give the rule another strategy " \
                  "(on_expiry :anonymize or :hard_delete)."
        logger = defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
        logger ? logger.warn(message) : Kernel.warn(message)
      end

      def anchor_for(model)
        (Lyra.config.retention_anchors[model.name] || :created_at).to_s
      end

      def candidates(model, anchor, cutoff)
        if events_only?
          # ES-NoProj: the events are the only store (the table is empty or
          # stale). Every live record, rebuilt from its stream with no default
          # scope applied (as unscoped: a soft-deleted record is still due),
          # its anchor read from that state.
          return Lyra::Projections::EventStoreReader.all(model).to_a.select do |record|
            (started = record.public_send(anchor)) && started < cutoff
          end
        end

        Lyra::Projections::LazyProjection.catch_up! if lazy?
        model.unscoped.where(model.arel_table[anchor].lt(cutoff)).order(model.primary_key).to_a
      end

      def events_only?
        Lyra.config.event_sourcing_mode? && Lyra.config.projection_mode == :disabled
      end

      def lazy?
        Lyra.config.event_sourcing_mode? && Lyra.config.projection_mode == :lazy
      end

      def act(model, record, rule, personal, anchor, dry_run, now)
        started = record.public_send(anchor)
        return nil unless started

        if started < now - rule.duration
          case rule.strategy
          when :anonymize then erase(model, record, personal, rule.strategy, dry_run, now)
          when :hard_delete then hard_delete(model, record, personal, dry_run, now)
          when :soft_delete then soft_delete(model, record, dry_run, now)
          else action(model, record, rule.strategy, [], :skipped, "the policy names no archive")
          end
        else
          expired = rule.field_durations.select { |field, duration| personal.include?(field) && started < now - duration }
          expired.any? ? erase(model, record, expired.keys, :field_retention, dry_run, now) : nil
        end
      end

      def erase(model, record, fields, strategy, dry_run, now)
        fields -= erased_fields(model, record.id)
        return nil if fields.empty?
        held = restricted(record, fields)
        return action(model, record, strategy, fields, :restricted, held) if held
        return action(model, record, strategy, fields, :would_erase) if dry_run

        Lyra::Erasure.erase!(model, record.id, fields: fields, reason: reason(model, strategy, now), erased_by: SOURCE)
        action(model, record, strategy, fields, :erased)
      end

      def hard_delete(model, record, personal, dry_run, now)
        fields = personal - erased_fields(model, record.id)
        held = restricted(record, nil)
        return action(model, record, :hard_delete, fields, :restricted, held) if held
        return action(model, record, :hard_delete, fields, :would_delete) if dry_run

        if fields.any?
          Lyra::Erasure.erase!(model, record.id, fields: fields, reason: reason(model, :hard_delete, now),
                                                 erased_by: SOURCE)
        elsif Lyra.config.erase_access_log
          # Erased before, with its access log kept then: the record goes now, and its log with it.
          Lyra::Erasure.erase_access_log!(model, record.id, reason: reason(model, :hard_delete, now), erased_by: SOURCE)
        end
        current(model, record.id).destroy!
        action(model, record, :hard_delete, fields, :deleted)
      end

      def soft_delete(model, record, dry_run, now)
        column = soft_delete_column(model)
        return action(model, record, :soft_delete, [], :skipped, "no deleted_at or discarded_at column") unless column
        return nil if record.public_send(column)
        held = restricted(record, nil)
        return action(model, record, :soft_delete, [], :restricted, held) if held
        return action(model, record, :soft_delete, [], :would_soft_delete) if dry_run

        current(model, record.id).update!(column => now)
        action(model, record, :soft_delete, [], :soft_deleted)
      end

      # The record +id+ as it is now (after an erasure), to write through:
      # its row, or in ES-NoProj its state rebuilt from its events, whose
      # destroy! or update! the interceptor records as an event (there is no
      # row to read or write). No default scope either way.
      def current(model, id)
        return model.unscoped.find(id) unless events_only?

        Lyra::Projections::EventStoreReader.find(model, id) ||
          raise(ActiveRecord::RecordNotFound.new("#{Lyra.stream_name(model, id)} has no live record in its events",
                                                 model.name, model.primary_key, id))
      end

      # The restrictions holding +record+ (for +fields+; nil: all), as the
      # action's detail, or nil.
      def restricted(record, fields)
        return nil unless defined?(Lyra::Rights::ErasureGuard)

        held = Lyra::Rights::ErasureGuard.covering_record(record, fields: fields)
        return nil if held.empty?

        "restricted: #{held.map { |r| Lyra::Rights::ErasureGuard.describe(r) }.join('; ')}"
      end

      # Attributes an earlier erasure of this record already covered.
      def erased_fields(model, id)
        Lyra.config.event_store.read.stream(Lyra.stream_name(model, id)).to_a
            .select { |event| event.is_a?(Lyra::Events::ErasureApplied) }
            .flat_map { |event| Array(event.data[:fields] || event.data["fields"]).map(&:to_s) }
      end

      def reason(model, strategy, now)
        "retention: #{model.name} past its retention period (#{strategy}), #{now.to_date.iso8601}"
      end

      def action(model, record, strategy, fields, outcome, detail = nil)
        Action.new(model: model.name, id: record.id, strategy: strategy, fields: fields, outcome: outcome,
                   detail: detail)
      end
    end
  end
end

if defined?(ActiveJob::Base)
  module Lyra
    # Enqueue on a schedule to apply retention (config.retention_executor).
    class RetentionJob < ActiveJob::Base
      queue_as :default

      def perform
        Lyra::Retention.apply!
      end
    end
  end
end
