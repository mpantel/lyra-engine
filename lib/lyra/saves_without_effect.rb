# frozen_string_literal: true

module Lyra
  # The cause named by the writes a save's before_* callbacks made, when the
  # save then ended without an event of its own in the log.
  #
  # A write's id is fixed when its write scope opens (Causation::WriteScope),
  # and the writes its before_* callbacks make (a belongs_to autosave, a
  # dependent: :destroy, the model's own before_save) name it as their cause:
  # they are appended before the write's own event, and before anyone can
  # know whether there will be one. Some writes then leave nothing in their
  # stream: a save that changes nothing, an update or destroy whose row was
  # gone (Monitor's stale copy), a save that was aborted, refused by its
  # command or raised, one whose Monitor append failed. The cause would name
  # no event. In that case only, Lyra appends a SaveWithoutEffect with the
  # write's id, in the write's transaction, so the cause exists.
  #
  # The marker goes to one stream of Lyra's own, STREAM, never to the
  # record's: the record's stream stays as the write left it (nothing may
  # follow a Destroyed there), and nothing that reads a record's history sees
  # it. One stream for every model, as for Lyra::UnrecordedWrites: a marker is
  # looked up by its id, as a cause, never by record, and is rare. The name
  # has no "$", so no reader takes it for a record's stream (Model$id).
  #
  # The marker names the stream owner, the record's key, the operation
  # attempted and why it had no effect, and holds no attribute value. Its
  # data has no model_class or model_id and is marked replay: false, so
  # replay, the projections, ES-Lazy's catch-up, DualView and the subject
  # reports pass it over; Lyra::EventWindow (the dashboard, EventFlow) leaves
  # it out. A causation lookup (event_store.read.event(id),
  # Causation.integrity) finds it.
  module SavesWithoutEffect
    STREAM = "Lyra::SavesWithoutEffect"
    TYPE = "Lyra::Events::SaveWithoutEffect"
    SOURCE = "lyra_save_without_effect"
    # The operation config.metadata_proc is given, as for the write's own event.
    EVENT_OPERATIONS = { create: :created, update: :updated, destroy: :destroyed }.freeze

    module_function

    def marker?(event)
      event.respond_to?(:event_type) && event.event_type == TYPE
    end

    # Append the marker for +record+'s write scope +scope+: +operation+
    # (:create, :update, :destroy), +reason+ ("no change", "no row", "not
    # saved", "append failed"). Metadata as the write's own event would have
    # had (CrudInterceptor#lyra_event_metadata). A failed append fails the
    # write where events are required, and is logged in Monitor.
    def record(scope, record, operation:, reason:)
      event = Lyra::Events::SaveWithoutEffect.new(
        event_id: scope.event_id,
        data: { model: Lyra.stream_owner_name(record.class), record_id: record.id, operation: operation.to_s,
                reason: reason, replay: false },
        metadata: { source: SOURCE }.merge(record.lyra_event_metadata(EVENT_OPERATIONS.fetch(operation)).compact)
      )
      Lyra.append_events(event, stream_name: STREAM)
    rescue => e
      raise if Lyra.config.events_required?

      Rails.logger.error("Lyra: could not record a save without effect (#{record.class.name} #{record.id}) - #{e.message}")
    end
  end

  module Events
    # See Lyra::SavesWithoutEffect.
    class SaveWithoutEffect < Lyra::Event; end
  end
end
