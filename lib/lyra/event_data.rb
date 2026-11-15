# frozen_string_literal: true

module Lyra
  # The data payload of the event a write produces: one shape, in every mode
  # and for every writer of CRUD events (Monitor's callbacks, the command
  # handler of Hijack and event sourcing, bypass writes, Genesis and repair).
  #
  #   operation        attributes                changes
  #   created, imported the record's attributes   {}
  #   updated           {}                        the delta, [old, new] pairs
  #   destroyed         {}                        {}
  #
  # Replay reads only a create's attributes and an update's changes, so state is
  # derived the same way whichever mode wrote the event. The record is not
  # repeated on an update, nor kept on a destroy: its state is in the events
  # before, and every copy of personal data in the log is a copy the erasure
  # executor must rewrite.
  #
  # Logs written before 1.0.0, in the earlier per-mode shapes, are not
  # supported (CHANGELOG, 1.0.0, Breaking).
  module EventData
    CREATES = %i[created imported].freeze

    module_function

    def build(model_class, model_id, operation, attributes: {}, changes: {}, timestamp: Time.current)
      kind = operation.to_sym
      {
        model_class: model_class.respond_to?(:name) ? model_class.name : model_class.to_s,
        model_id: model_id,
        operation: operation,
        attributes: CREATES.include?(kind) ? attributes : {},
        changes: kind == :updated ? changes : {},
        timestamp: timestamp
      }
    end
  end
end
