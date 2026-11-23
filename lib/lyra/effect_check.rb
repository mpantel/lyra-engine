# frozen_string_literal: true

module Lyra
  # A write whose row, as the database left it, differs from what its record's
  # events replay to (Lyra::EffectCheck). Raised in the write's transaction,
  # which rolls back with its event.
  class EffectMismatchError < ActiveRecord::ActiveRecordError
    attr_reader :discrepancy

    def initialize(discrepancy)
      @discrepancy = discrepancy
      super("Lyra: the write's effect differs from its events: #{discrepancy}")
    end
  end

  # The effect clause of Hypothesis H (H2), checked at the write, opt-in
  # (config.check_effects, from 1.0.1; off by default). In Hijack and ES-Sync
  # the row is written in the same transaction as the event: after a create,
  # update or destroy through callbacks, the record's row is compared with the
  # replay of its stream, as the mode gate and DualView compare them
  # (ModeTransition.discrepancy), and a difference (a trigger, a default the
  # database computes, a type that does not round-trip) raises
  # EffectMismatchError before the transaction commits. Monitor's event is
  # taken from what its table did, and the other modes write the row later or
  # never, so the check does not apply there. Writes that skip callbacks
  # (update_columns, update_all, insert_all) are not checked. The cost is a
  # read of the row and of the record's stream, and a replay, per write.
  module EffectCheck
    module_function

    def applies?
      return false unless Lyra.config.check_effects

      Lyra.hijack_mode? || (Lyra.event_sourcing_mode? && Lyra.config.projection_mode == :sync)
    end

    # Not checked: a model on another database than the event store's (the
    # comparison reads the log through ActiveRecord::Base). A soft delete
    # needs no exception: it is recorded as the update it is. A record of
    # an STI subclass is compared as its stream names it, by its base class,
    # so a change of its type is not taken for a missing row.
    def verify!(record)
      model = record.class
      return unless model.connection_db_config == ActiveRecord::Base.connection_db_config

      owner = Lyra.stream_owner_name(model).safe_constantize
      model = owner if owner.is_a?(Class) && model <= owner
      problem = Lyra::ModeTransition.discrepancy(model, record.id)
      raise EffectMismatchError, problem if problem
    end
  end
end
