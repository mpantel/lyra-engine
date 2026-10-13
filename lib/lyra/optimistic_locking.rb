# frozen_string_literal: true

module Lyra
  # Optimistic locking (a lock_version column) where Lyra takes a write over.
  #
  # Active Record checks the version in the statement that writes the row: the
  # UPDATE or DELETE matches the row only if its lock_version is still the one
  # the record was loaded with, and the UPDATE adds one to it. A record that
  # matches nothing is stale (another writer got there first) and the write
  # raises ActiveRecord::StaleObjectError.
  #
  # In the event-sourcing modes that statement never runs: the row is written
  # from the event (ES-Sync, ES-Async, ES-Lazy) or not at all (ES-NoProj). A
  # stale update used to overwrite the newer one silently (a lost update), and
  # since no event carried the increment, the log replayed to a lock_version
  # the row did not have. So, in every mode that takes the write over:
  # - the write's event records the increment, [old, old + 1], as a change of
  #   the column (Hijack included, where Active Record still writes the row);
  # - before the event is appended, the event-sourcing modes check the version
  #   against the log: the newest event that records the column gives the
  #   version, and a record that expects an older one raises StaleObjectError.
  #   The check runs under the lock on the aggregate (the row's own in ES-Sync,
  #   an advisory lock on the stream otherwise), so no other writer of the
  #   record can append in between.
  #
  # The check is against the log, not the row: in ES-Async and ES-Lazy the row
  # can trail the log, and in ES-NoProj there is none. A record is stale when
  # it expects a version older than the log's; one newer than the log's passes,
  # since events written before this check existed did not record increments
  # their rows made (a Hijack table switched to event sourcing), and such a
  # record could otherwise never be updated again.
  module OptimisticLocking
    module_function

    def enabled?(model_class)
      model_class.respond_to?(:locking_enabled?) && model_class.locking_enabled? ? true : false
    end

    # The version the write expects: the one the record was loaded with or,
    # if the application assigned one (a form submitting the version it was
    # rendered with), that one, as Active Record's own check takes it.
    def expected_version(record)
      column = record.class.locking_column
      value = record.will_save_change_to_attribute?(column) ? record[column] : record.attribute_in_database(column)
      value.to_i
    end

    # The change the write makes to the version: Active Record adds one to the
    # version the record holds.
    def increment(record)
      column = record.class.locking_column
      { column => [record.attribute_in_database(column).to_i, record[column].to_i + 1] }
    end

    # The version the log last recorded for +record+, or nil when no event of
    # its stream records one.
    def recorded_version(record)
      column = record.class.locking_column.to_s
      Lyra.config.event_store.read.stream(Lyra.stream_name(record.class, record.id)).backward.each do |event|
        value = version_in(event.data, column)
        return value unless value.nil?
      end
      nil
    end

    # Raise ActiveRecord::StaleObjectError, as Active Record would, when the
    # log has moved past the version +record+ expects. The caller holds the
    # lock on the aggregate.
    def check!(record, attempted_action)
      return unless enabled?(record.class)

      recorded = recorded_version(record)
      return if recorded.nil? || expected_version(record) >= recorded

      raise ActiveRecord::StaleObjectError.new(record, attempted_action)
    end

    def version_in(data, column)
      changes = data[:changes] || data["changes"]
      change = changes[column] || changes[column.to_sym] if changes.is_a?(Hash)
      return (change.is_a?(Array) ? change.last : change).to_i unless change.nil?

      attributes = data[:attributes] || data["attributes"]
      value = attributes[column] || attributes[column.to_sym] if attributes.is_a?(Hash)
      value&.to_i
    end
  end
end
