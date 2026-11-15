# frozen_string_literal: true

module Lyra
  # The newest events of the log, for a reader that must not read all of it:
  # the dashboard's routes and Lyra::EventFlow. At most +limit+ events, newest
  # first, and a window that says what was read.
  #
  # The access log's own entries are skipped (ACCESS_LOG_TYPES).
  # With config.record_access_events on, every read adds one, so they would
  # fill the window and push out the events it is for. Skipping them costs a
  # scan, so the scan stops after SCAN_FACTOR x limit events: a log that is
  # mostly access entries still bounds the work, and the window then says it
  # stopped early.
  module EventWindow
    SCAN_FACTOR = 10
    # Lyra::AccessLog's event types, named here because the access log loads
    # only with PAM DSL.
    ACCESS_LOG_TYPES = %w[
      Lyra::Events::DataAccessed Lyra::Events::DataAccessDenied
      Lyra::Events::DashboardRead Lyra::Events::AccessLogErased
    ].freeze
    BATCH = 1_000

    module_function

    # [events, window]. window: limit, returned, truncated (older events may
    # exist that were not read) and skipped (access-log entries passed over).
    def recent(limit)
      cap = limit * SCAN_FACTOR
      events = []
      scanned = 0
      skipped = 0
      truncated = false

      Lyra.config.event_store.read.backward.limit(cap + 1).in_batches([limit + 1, BATCH].min).each do |event|
        scanned += 1
        if scanned > cap
          truncated = true
          break
        end
        if ACCESS_LOG_TYPES.include?(event.event_type)
          skipped += 1
          next
        end
        if events.size == limit
          truncated = true
          break
        end
        events << event
      end

      [events, { limit: limit, returned: events.size, truncated: truncated, skipped: skipped }]
    end
  end
end
