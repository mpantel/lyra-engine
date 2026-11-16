# frozen_string_literal: true

module Lyra
  # Lyra's durable store for the data subject's rights of Arts. 18 and 21
  # (PamDsl.rights, PAM DSL's Rights::Ledger) and for consent (from 1.0.0).
  #
  # PAM DSL records and checks the rights; it keeps them, by default, in
  # memory, per process, which a production application cannot rely on (its
  # in-memory store refuses to record where a durable one is required). When
  # Lyra and PAM DSL are both loaded, Lyra installs:
  #
  # - Rights::Store as PamDsl.rights_store: each request, notice, decision and
  #   lift as an event in the subject's stream Lyra::Rights$<subject key>
  #   (Lyra::Rights$Payer$7), linked to the index stream Lyra::Rights, with the
  #   lyra_rights table as its projection (one row per restriction or
  #   objection), written in the same transaction;
  # - Rights::ConsentStore as PamDsl.consent_store: each consent request,
  #   grant and withdrawal as an event in Lyra::Consent$<subject key>, linked to
  #   Lyra::Consent, with the lyra_consents table as its projection (one row
  #   per subject key and purpose). Every policy and every process sees the
  #   same consent;
  # - Rights::SubjectKeys as PamDsl.subject_key_resolver: a record maps to its
  #   own key (Registration$42) and to the keys of the people it names, by the
  #   selection rule of the subject-access copy (Lyra::Privacy::SubjectLinks).
  #
  # Both tables are Lyra's own, created on first use (Lyra.create_own_table).
  # The streams are never erased: not with the access log
  # (Lyra::AccessLog.erase!, which deletes Lyra::DataAccess$<subject> only),
  # nor by Lyra::Erasure. They hold names, grounds and the controller's
  # reasons, never values, and they are the evidence that a right was handled
  # (Art. 5(2)). Keep personal data out of the free-text reasons.
  #
  # Lyra::Rights.rebuild! (bin/rails lyra:rights:rebuild) rebuilds both tables
  # from the index streams.
  module Rights
    STREAM = "Lyra::Rights"
    CONSENT_STREAM = "Lyra::Consent"
    TABLE = "lyra_rights"
    CONSENT_TABLE = "lyra_consents"

    # The events, one class per PAM rights event type, and three for consent.
    module Events
      class RightsEvent < Lyra::Event; end
      class ConsentEvent < Lyra::Event; end

      PamDsl::Rights::EVENT_TYPES.each { |type| const_set(type, Class.new(RightsEvent)) }
      CONSENT_TYPES = %w[ConsentRequested ConsentGranted ConsentWithdrawn].freeze
      CONSENT_TYPES.each { |type| const_set(type, Class.new(ConsentEvent)) }
    end

    # Values in the events: names, symbols, times, arrays of them. Encoded so
    # that they come back as they went in whatever serializer the event store
    # uses (YAML keeps symbols and times; JSON does not).
    module Codec
      module_function

      def encode(value)
        case value
        when Symbol then { "symbol" => value.to_s }
        when Time, DateTime then { "time" => value.to_time.utc.iso8601(6) }
        when ActiveSupport::TimeWithZone then { "time" => value.utc.iso8601(6) }
        when Date then { "date" => value.iso8601 }
        when Array then value.map { |v| encode(v) }
        when Hash then { "hash" => value.to_h { |k, v| [k.to_s, encode(v)] } }
        when String, Integer, Float, true, false, nil then value
        else value.to_s
        end
      end

      def decode(value)
        case value
        when Array then value.map { |v| decode(v) }
        when Hash
          tag, inner = value.first
          case tag.to_s
          when "symbol" then inner.to_sym
          when "time" then Time.iso8601(inner)
          when "date" then Date.iso8601(inner)
          when "hash" then inner.to_h { |k, v| [k.to_sym, decode(v)] }
          else value.to_h { |k, v| [k.to_sym, decode(v)] }
          end
        else value
        end
      end
    end

    class << self
      def store
        @store ||= Store.new
      end

      def consent_store
        @consent_store ||= ConsentStore.new
      end

      # Install the stores and the resolver into PAM DSL: when Lyra loads with
      # PAM DSL, and again by the engine at boot with +only_unset+, which
      # leaves in place a store or resolver the application installed in an
      # initializer (PamDsl.rights_store = ..., PamDsl.consent_store = ...,
      # PamDsl.subject_key_resolver = ...). That is how an application opts
      # out: install its own (PamDsl::RightsStore::Memory.new keeps PAM DSL's).
      def install!(only_unset: false)
        PamDsl.rights_store = store unless only_unset && host_rights_store?
        PamDsl.consent_store = consent_store unless only_unset && PamDsl.consent_store
        PamDsl.subject_key_resolver = SubjectKeys unless only_unset && PamDsl.subject_key_resolver
      end

      # Every write by any store of this process (for tests: whether any
      # rights or consent were recorded).
      def writes
        @writes || 0
      end

      def note_write!
        WRITES_MUTEX.synchronize { @writes = writes + 1 }
      end

      # Seconds a process answers from what it last read.
      def refresh_interval
        interval = Lyra.config.respond_to?(:rights_refresh_interval) ? Lyra.config.rights_refresh_interval : nil
        interval.nil? ? 1.0 : interval.to_f
      end

      # Hold +table+ against other writers until the transaction ends
      # (PostgreSQL; other databases serialise their writers anyway).
      def lock_table(connection, table)
        return unless connection.adapter_name.match?(/postg/i)

        connection.execute("LOCK TABLE #{connection.quote_table_name(table)} IN EXCLUSIVE MODE")
      end

      def quote(connection, value)
        case value
        when Time, DateTime, ActiveSupport::TimeWithZone then connection.quote(value.to_time.utc)
        else connection.quote(value)
        end
      end

      # Drop what this process remembers: the next check reads the tables
      # again. For the start of a checking scope (a request, a job, a batch).
      def refresh!
        store.refresh!
        consent_store.forget!
      end

      def stream_for(subject_key)
        "#{STREAM}$#{subject_key}"
      end

      def consent_stream_for(subject_key)
        "#{CONSENT_STREAM}$#{subject_key}"
      end

      # "Payer$7" => ["Payer", "7"]; a bare id ("user-7") has no type.
      def split_key(subject_key)
        type, id = subject_key.to_s.split("$", 2)
        id.nil? ? [nil, type] : [type, id]
      end

      # Rebuild lyra_rights and lyra_consents from the index streams. Returns
      # [requests, consents] written.
      def rebuild!
        [store.rebuild!, consent_store.rebuild!]
      end

      # Run +block+ with an own table ready; false when the database cannot be
      # reached (assets precompilation, a first setup).
      def with_table(name, &definition)
        ActiveRecord::Base.with_connection { |connection| Lyra.create_own_table(connection, name, &definition) }
        true
      rescue ActiveRecord::NoDatabaseError, ActiveRecord::ConnectionNotEstablished
        false
      end

      def table_exists?(name)
        ActiveRecord::Base.with_connection { |connection| connection.table_exists?(name) }
      rescue ActiveRecord::NoDatabaseError, ActiveRecord::ConnectionNotEstablished
        false
      end

      def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      # ── Checking scopes ──
      #
      # The stores answer from what the process last read for at most
      # config.rights_refresh_interval seconds, and never from what they read
      # before the current checking scope began: the first check in a scope
      # reads the rights afresh (one indexed query), so a right recorded in
      # another process applies from that process's next scope. A scope is a
      # Lyra.with_purpose block, a web request (Rights::Middleware), an
      # Active Job (Rights::Job), and each batch of in_batches, find_each
      # and find_in_batches. Opening one costs a clock read; nothing is read
      # unless a check is made in it, so code that checks nothing (no
      # purpose, reads_without_purpose :allow) never queries the rights.

      # Run +block+ as a checking scope.
      def scope(&block)
        PurposeBoundReads::Context.with(:lyra_rights_scope, now, &block)
      end

      # When the current checking scope began (a monotonic clock reading), or
      # nil outside one.
      def scope_started_at
        PurposeBoundReads::Context[:lyra_rights_scope]
      end

      # Whether a value read at +read_at+ may still answer: within the
      # refresh interval, and, under config.rights_refresh :scope (the
      # default), not read before the current scope began.
      def current?(read_at)
        return false unless read_at && now - read_at < refresh_interval
        return true unless refresh_per_scope?

        started = scope_started_at
        started.nil? || read_at >= started
      end

      # config.rights_refresh: :scope (default) or :interval.
      def refresh_per_scope?
        mode = Lyra.config.respond_to?(:rights_refresh) ? Lyra.config.rights_refresh : nil
        mode.nil? || mode == :scope
      end

      # A batch loop: the block gets a callable that ends one batch's scope
      # and begins the next one's; the loop's first batch begins a scope too.
      def batches
        scope { yield -> { PurposeBoundReads::Context[:lyra_rights_scope] = now } }
      end

      # The subject keys with a request in force, from the snapshot (Lyra's
      # store), or from any store's +active+.
      def keys_in_force(store = PamDsl.rights_store)
        return store.keys_in_force if store.respond_to?(:keys_in_force)

        store.active.map(&:subject_key).uniq
      end

      private

      # A rights store other than PAM DSL's own default: Lyra's, or one the
      # application set (PamDsl.rights_store = nil returns to the default).
      def host_rights_store?
        current = PamDsl.instance_variable_get(:@rights_store)
        !current.nil? && !PamDsl.instance_variable_get(:@rights_store_is_default)
      end
    end

    WRITES_MUTEX = Mutex.new

    # Rack middleware: each web request is a checking scope.
    class Middleware
      def initialize(app)
        @app = app
      end

      def call(env)
        Rights.scope { @app.call(env) }
      end
    end

    # Active Job: each job is a checking scope (the engine includes it).
    module Job
      def self.included(base)
        base.around_perform { |_job, block| Rights.scope(&block) }
      end
    end
  end
end

require "lyra/rights/pending"
require "lyra/rights/subject_keys"
require "lyra/rights/store"
require "lyra/rights/consent_store"
require "lyra/rights/queries"
require "lyra/rights/erasure_guard"

Lyra::Rights.install! if defined?(PamDsl) && PamDsl.respond_to?(:rights_store=) && PamDsl.respond_to?(:consent_store=)

# Each Active Job is a checking scope (the web request's is the engine's
# middleware, Lyra::Rights::Middleware).
ActiveSupport.on_load(:active_job) { include Lyra::Rights::Job } if defined?(ActiveSupport)
