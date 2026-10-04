# Lyra in Monitor mode: the tables stay authoritative, and every write through
# ActiveRecord to a monitored model (see monitor_with_lyra in app/models)
# appends an event to that record's stream, "Model$id".
#
# Switching config.mode to :hijack or :event_sourcing here is gated outside
# the test environment: see docs/MIGRATION_GUIDE.md in the Lyra repository.
Lyra.configure do |config|
  config.mode = :monitor

  # Lyra::EventSerializer stores events as JSON and keeps the microseconds of
  # times, which serializer: JSON would drop. Without config.event_store the
  # engine uses RailsEventStore::Client.new (YAML).
  config.event_store = RailsEventStore::Client.new(
    repository: RubyEventStore::ActiveRecord::EventRepository.new(serializer: Lyra::EventSerializer)
  )

  # Who made each change; stored in every event's metadata.
  config.metadata_proc = ->(_record, _operation) { { source: "blog_app" } }
end
