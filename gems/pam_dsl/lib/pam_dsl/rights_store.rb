# frozen_string_literal: true

module PamDsl
  # Where the rights of Arts. 18 and 21 are kept: PamDsl.rights_store.
  #
  # == The protocol
  #
  # A rights store keeps the events of PamDsl::Rights (Rights::Event), one
  # stream per subject key, append-only. PAM computes every request's state
  # from its events (Rights.project), so a store keeps events, not state. It
  # answers four methods:
  #
  # append(events, expected_version:)::
  #   Append one or more events, all for one subject key, atomically, if that
  #   subject's stream holds exactly +expected_version+ events; otherwise raise
  #   PamDsl::RightsConcurrencyError and append nothing. This is what keeps two
  #   processes from both lifting, or both deciding, one request. Before
  #   storing, a store should check the events with Rights.project(existing +
  #   new), which raises PamDsl::RightsTransitionError for a step the rights
  #   do not allow (a lift without the Art. 18(3) notice, say), and store
  #   nothing if it raises. Returns the events. (PamDsl.rights, not the store,
  #   refuses to record when PamDsl.require_durable_rights_store is on and the
  #   store's durable? is false.)
  # events_for(subject_key)::
  #   The subject's events, in the order appended ([] for none), as
  #   Rights::Event values: +at+ and +recorded_at+ are Time objects (a store
  #   that serialises events returns Times), +data+ has symbol keys and keeps
  #   symbol values as symbols (grounds, reasons, field, policy and purpose
  #   names).
  # subject_key_for(request_id)::
  #   The subject key of the stream that holds a request, or nil.
  # active::
  #   Every request in force: each restriction not yet lifted and each
  #   objection pending or upheld (Rights::Restriction, Rights::Objection).
  #
  # Including RightsStore::Base adds active_for(keys) and any_active?, which
  # Condition 6 calls on every access with a subject, computed from +active+,
  # and durable? (false). A store should override active_for and any_active?
  # when it can answer them more cheaply, and must override durable? to return
  # true when its records outlive the process and are shared by every process.
  #
  # PAM DSL ships one store, Memory. A durable store comes from the host: Lyra
  # installs one that keeps the events in its event store.
  module RightsStore
    module Base
      # The requests in force for any of these subject keys.
      def active_for(keys)
        keys = keys.map(&:to_s)
        active.select { |request| keys.include?(request.subject_key) }
      end

      # Is any request in force? False lets Condition 6 skip resolving the subject.
      def any_active?
        !active.empty?
      end

      # Do the records outlive the process, and are they shared by every process?
      def durable?
        false
      end
    end

    # The default store: in memory, per process. A restart loses every
    # record, and a request recorded in one process is not seen by another.
    # For tests, development and scripts. While PamDsl.require_durable_rights_store
    # is on (under Rails, outside development and test), PamDsl.rights refuses
    # to record in it, so that a right a subject exercised cannot be lost
    # silently. Each append is checked with Rights.project first. Reading an
    # empty store finds nothing, so an application that records no rights is
    # unaffected either way.
    class Memory
      include Base

      def initialize
        @streams = {}
        @request_index = {}
        @active = {}
        @mutex = Mutex.new
      end

      def append(events, expected_version:)
        events = Array(events)
        key = single_subject_key(events)

        @mutex.synchronize do
          stream = @streams.fetch(key, [])
          unless stream.size == expected_version
            raise RightsConcurrencyError,
                  "The rights of #{key} changed while this request was handled (expected version " \
                  "#{expected_version}, found #{stream.size}): read them again and retry"
          end

          # Project first: an illegal transition raises here, and nothing is stored.
          appended = (stream + events).freeze
          in_force = Rights.project(appended).select(&:in_force?)
          @streams[key] = appended
          events.each { |event| @request_index[event.request_id] ||= key }
          in_force.empty? ? @active.delete(key) : @active[key] = in_force
        end
        events
      end

      def events_for(subject_key)
        @streams.fetch(subject_key.to_s, [])
      end

      def subject_key_for(request_id)
        @request_index[request_id]
      end

      def active
        @active.values.flatten
      end

      def active_for(keys)
        keys.flat_map { |key| @active.fetch(key.to_s, []) }
      end

      def any_active?
        !@active.empty?
      end

      private

      def single_subject_key(events)
        keys = events.map(&:subject_key).uniq
        raise ArgumentError, "append takes events for exactly one subject key, got #{keys.inspect}" unless keys.size == 1

        keys.first
      end
    end
  end
end
