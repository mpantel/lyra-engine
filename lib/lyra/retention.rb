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

      private

      def apply_model(model, dry_run, now)
        policy = Lyra::Privacy.policy_for(model)
        rule = policy.retention_rule(model)
        return [] unless rule

        anchor = anchor_for(model)
        personal = policy.declared_fields.map(&:to_s) & model.column_names
        shortest = ([rule.duration] + rule.field_durations.values).compact.min
        return [] unless shortest

        PurposeBoundReads.internal do
          candidates(model, anchor, now - shortest).filter_map do |record|
            next unless rule.applies.call(record)

            act(model, record, rule, personal, anchor, dry_run, now)
          end
        end
      end

      def anchor_for(model)
        (Lyra.config.retention_anchors[model.name] || :created_at).to_s
      end

      def candidates(model, anchor, cutoff)
        if events_only?
          # ES-NoProj: no table to query; every record, rebuilt from its events.
          return ModeTransition.record_ids(model)
                               .filter_map { |id| model.unscoped.find_by(model.primary_key => id) }
                               .select { |record| (started = record.public_send(anchor)) && started < cutoff }
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
        return action(model, record, strategy, fields, :would_erase) if dry_run

        Lyra::Erasure.erase!(model, record.id, fields: fields, reason: reason(model, strategy, now), erased_by: SOURCE)
        action(model, record, strategy, fields, :erased)
      end

      def hard_delete(model, record, personal, dry_run, now)
        fields = personal - erased_fields(model, record.id)
        return action(model, record, :hard_delete, fields, :would_delete) if dry_run

        if fields.any?
          Lyra::Erasure.erase!(model, record.id, fields: fields, reason: reason(model, :hard_delete, now),
                                                 erased_by: SOURCE)
        end
        model.unscoped.find(record.id).destroy!
        action(model, record, :hard_delete, fields, :deleted)
      end

      def soft_delete(model, record, dry_run, now)
        column = (SOFT_DELETE_COLUMNS & model.column_names).first
        return action(model, record, :soft_delete, [], :skipped, "no deleted_at or discarded_at column") unless column
        return nil if record.public_send(column)
        return action(model, record, :soft_delete, [], :would_soft_delete) if dry_run

        model.unscoped.find(record.id).update!(column => now)
        action(model, record, :soft_delete, [], :soft_deleted)
      end

      # Attributes an earlier erasure of this record already covered.
      def erased_fields(model, id)
        Lyra.config.event_store.read.stream("#{model.name}$#{id}").to_a
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
