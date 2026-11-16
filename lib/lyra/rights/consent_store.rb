# frozen_string_literal: true

module Lyra
  module Rights
    # PamDsl.consent_store, durable: consent (the CS of PAM's runtime context)
    # in Lyra's event store, shared by every policy and every process.
    #
    # Each request, grant and withdrawal is an event (ConsentRequested,
    # ConsentGranted, ConsentWithdrawn) in Lyra::Consent$<subject key>, linked
    # to the index stream Lyra::Consent, appended with the subject stream's
    # expected version, and lyra_consents (one row per subject key and
    # purpose: the record's state, its times and expires_at) is rewritten in
    # the same transaction. The transitions are PAM's (PamDsl::ConsentRecord):
    # a request while one is pending or granted is refused, a grant on a
    # pending record grants it and otherwise starts a fresh one (a grant that
    # repeats the granted record's times records nothing), a withdrawal of
    # anything but a granted record is refused, and of nothing is a no-op.
    # Expiry is not an event: the grant records expires_at (from the
    # requirement's expires_in), and the state is :expired once it has passed,
    # as in PAM (the guard of t2).
    #
    # Whose consent. A grant is recorded under the subject's first key (a
    # record's own key, or the subject as a string). A lookup (record_for:
    # Condition 4, and the :consent exception of Art. 18(2)) for a record
    # answers the record of the one person it names (Lyra::Rights::SubjectKeys),
    # or its own key's when it names no one. A record that names more than one
    # person raises SharedRecordConsentError: whose consent such a record needs
    # (all of them, or each for the fields about them) is not decided in 1.0.0,
    # so the access is refused rather than allowed on one person's consent.
    # Any other subject answers its key's record.
    #
    # Lookups are remembered per process for config.rights_refresh_interval
    # seconds, together with whether any consent at all is recorded for a
    # subject type and purpose (so a read of many records whose type has none
    # costs one query): a withdrawal made in another process applies here
    # within that interval. A transaction that records consent reads the keys
    # it wrote afresh until it ends, and nothing it reads is remembered for
    # other threads (see Rights::Pending).
    class ConsentStore
      include Pending

      # Consent is checked for a record that names several people.
      class SharedRecordConsentError < PamDsl::ConsentRequiredError; end

      COLUMNS = %w[subject_key subject_type subject_id purpose state requested_at granted_at expires_at
                   withdrawn_at stream_version updated_at].freeze
      CACHE_LIMIT = 10_000
      RETRIES = 3

      attr_reader :generation

      def initialize(event_store: nil)
        @event_store = event_store
        @mutex = Mutex.new
        @cache = {}
        @generation = 0
        @table_ready = false
        init_pending
      end

      def event_store
        @event_store || Lyra.config.event_store
      end

      def durable?
        true
      end

      # ── PAM's ConsentStore interface ──

      def request(purpose:, subject:)
        purpose = purpose.to_sym
        key = key_for!(subject)
        record!(key, purpose) do |current|
          if current && %i[pending granted].include?(current.state)
            raise PamDsl::Error,
                  "Cannot request consent: record for (#{purpose}, #{subject}) already in state '#{current.state}'"
          end
          ["ConsentRequested", { at: Time.current }]
        end
      end

      def grant(purpose:, subject:, granted_at: Time.current, expires_at: nil)
        purpose = purpose.to_sym
        key = key_for!(subject)
        record!(key, purpose) do |current|
          next nil if repeated_grant?(current, granted_at, expires_at)

          ["ConsentGranted", { at: Time.current, granted_at: granted_at, expires_at: expires_at }]
        end
      end

      def withdraw(purpose:, subject:)
        purpose = purpose.to_sym
        key = key_for!(subject)
        record!(key, purpose) do |current|
          next nil unless current

          unless current.state == :granted
            raise PamDsl::Error,
                  "Cannot withdraw: consent for (#{purpose}, #{subject}) is in state '#{current.state}'"
          end
          ["ConsentWithdrawn", { at: Time.current }]
        end
      end

      def record_for(purpose, subject)
        purpose = purpose.to_sym
        keys = PamDsl.subject_keys(subject)
        return nil if keys.empty?

        people = people_of(subject, keys)
        return lookup(purpose, keys.first) if people.empty?
        return lookup(purpose, people.first) if people.size == 1

        raise SharedRecordConsentError,
              "Consent for purpose '#{purpose}' cannot be checked for #{keys.first}: the record names several people " \
              "(#{people.join(', ')}), and consent for a record shared by several people is not supported yet"
      end

      def granted?(purpose, subject)
        record_for(purpose, subject)&.state == :granted
      end

      # ── For the consent audit ──

      # The consent records kept under +subject_key+, one per purpose, with
      # their histories: what GDPRCompliance#consent_audit lists.
      def consents_for(subject_key)
        events = events_for(subject_key)
        events.group_by { |event| event[:purpose] }.map do |purpose, list|
          record = fold(list, purpose, subject_key)
          {
            purpose: purpose, subject_key: subject_key, state: record&.state,
            requested_at: list.select { |e| e[:type] == "ConsentRequested" }.last&.dig(:at),
            granted_at: record&.granted_at, expires_at: record&.expires_at, withdrawn_at: record&.withdrawn_at,
            history: list.map { |e| e.slice(:type, :at, :granted_at, :expires_at) }
          }
        end
      end

      # The subject's consent events, oldest first, as hashes.
      def events_for(subject_key)
        PurposeBoundReads.internal(INTERNAL) do
          event_store.read.stream(Rights.consent_stream_for(subject_key)).to_a.map { |record| decode(record) }
        end
      end

      # Forget remembered lookups.
      def forget!
        @mutex.synchronize { @cache = {} }
      end

      # Rewrites lyra_consents from the index stream. Returns the rows written.
      def rebuild!
        ensure_table!
        written = 0
        keys = []
        ActiveRecord::Base.transaction(requires_new: true) do
          ActiveRecord::Base.with_connection { |c| Rights.lock_table(c, CONSENT_TABLE) }
          keys = event_store.read.stream(CONSENT_STREAM).to_a.map { |record| decode(record)[:subject_key] }.uniq
          ActiveRecord::Base.with_connection { |c| c.execute("DELETE FROM #{CONSENT_TABLE}") }
          keys.each do |key|
            events = events_for(key)
            events.map { |e| e[:purpose] }.uniq.each do |purpose|
              list = events.select { |e| e[:purpose] == purpose }
              write_row(key, purpose, fold(list, purpose, key), list, events.size)
              written += 1
            end
          end
        end
        changed!(keys.map { |key| [nil, key] })
        written
      end

      private

      def key_for!(subject)
        key = PamDsl.subject_keys(subject).first
        raise ArgumentError, "Consent is given by one data subject: #{subject.inspect} names none" unless key

        key
      end

      # The people a record names, when Lyra's resolver mapped it.
      def people_of(subject, keys)
        return [] unless PamDsl.subject_key_resolver.equal?(SubjectKeys) && subject.is_a?(ActiveRecord::Base)

        keys.drop(1)
      end

      def repeated_grant?(current, granted_at, expires_at)
        current&.state == :granted && same_time?(current.granted_at, granted_at) &&
          same_time?(current.expires_at, expires_at)
      end

      def same_time?(a, b)
        return a.nil? && b.nil? if a.nil? || b.nil?

        (a.to_r - b.to_r).abs < Rational(1, 1_000_000)
      end

      # Read the subject's stream, fold the purpose's record, ask the block for
      # the event to append ([type, data], or nil for none), append it with the
      # stream's expected version and rewrite the row. Retried when another
      # process appended to the subject's stream in between.
      def record!(key, purpose)
        attempts = 0
        begin
          events = events_for(key)
          current = fold(events.select { |e| e[:purpose] == purpose }, purpose, key)
          type, data = yield(current)
          return current unless type

          append(key, purpose, type, data, events)
        rescue PamDsl::RightsConcurrencyError
          attempts += 1
          retry if attempts < RETRIES
          raise
        end
      end

      def append(key, purpose, type, data, events)
        ensure_table!
        record = Events.const_get(type).new(
          data: {
            "subject_key" => key, "purpose" => purpose.to_s,
            "at" => Codec.encode(data[:at]),
            "granted_at" => Codec.encode(data[:granted_at]), "expires_at" => Codec.encode(data[:expires_at])
          },
          metadata: { source: "lyra_consent", correlation_id: Lyra::Correlation.current_id }.compact
        )
        all = events + [decode(record)]
        list = all.select { |e| e[:purpose] == purpose }
        folded = fold(list, purpose, key)
        ActiveRecord::Base.transaction(requires_new: true) do
          event_store.append([record], stream_name: Rights.consent_stream_for(key),
                                       expected_version: events.empty? ? :none : events.size - 1)
          event_store.link([record.event_id], stream_name: CONSENT_STREAM)
          write_row(key, purpose, folded, list, all.size)
        end
        changed!([[purpose, key]])
        folded
      rescue RubyEventStore::WrongExpectedEventVersion, ActiveRecord::RecordNotUnique
        raise PamDsl::RightsConcurrencyError, "The consent of #{key} changed while this request was handled"
      end

      # The purpose's current record from its events (PAM's transitions,
      # without re-checking them against the clock).
      def fold(events, purpose, key)
        events.reduce(nil) do |record, event|
          case event[:type]
          when "ConsentRequested"
            PamDsl::ConsentRecord.restore(purpose: purpose, subject: key, state: :pending)
          when "ConsentGranted"
            PamDsl::ConsentRecord.restore(purpose: purpose, subject: key, state: :granted,
                                          granted_at: event[:granted_at], expires_at: event[:expires_at])
          when "ConsentWithdrawn"
            next record unless record

            PamDsl::ConsentRecord.restore(purpose: purpose, subject: key, state: :withdrawn,
                                          granted_at: record.granted_at, expires_at: record.expires_at,
                                          withdrawn_at: event[:at])
          else record
          end
        end
      end

      def decode(record)
        data = record.data.to_h.transform_keys(&:to_s)
        {
          type: record.class.name.demodulize, subject_key: data["subject_key"], purpose: data["purpose"]&.to_sym,
          at: Codec.decode(data["at"]), granted_at: Codec.decode(data["granted_at"]),
          expires_at: Codec.decode(data["expires_at"]), event_id: record.event_id
        }
      end

      def restore(row)
        PamDsl::ConsentRecord.restore(
          purpose: row["purpose"], subject: row["subject_key"], state: row["state"],
          granted_at: time(row["granted_at"]), expires_at: time(row["expires_at"]),
          withdrawn_at: time(row["withdrawn_at"])
        )
      end

      def time(value)
        return nil if value.nil?
        return value.to_time if value.respond_to?(:to_time) && !value.is_a?(String)

        ActiveRecord::Type::DateTime.new.cast(value)&.to_time
      end

      # The record of (purpose, key): read afresh when this connection's open
      # transaction wrote it, else remembered for the refresh interval.
      def lookup(purpose, key)
        pending = pending_here
        if pending&.include?([purpose, key]) || pending&.include?([nil, key])
          row = fetch_row(purpose, key)
          return row && restore(row)
        end
        return nil unless any_for_type?(purpose, key, pending)

        row = remembered([purpose, key], pending) { fetch_row(purpose, key) }
        row && restore(row)
      end

      # Whether any consent for +purpose+ is recorded for the key's type (a
      # bare key, with no type, is always looked up).
      def any_for_type?(purpose, key, pending)
        type, _id = Rights.split_key(key)
        return true if type.nil?

        remembered([:type, purpose, type], pending) do
          next false unless table_ready?

          ActiveRecord::Base.with_connection do |c|
            !c.select_value("SELECT 1 FROM #{CONSENT_TABLE} WHERE purpose = #{c.quote(purpose.to_s)} " \
                            "AND subject_type = #{c.quote(type)} LIMIT 1").nil?
          end
        end
      rescue ActiveRecord::NoDatabaseError, ActiveRecord::ConnectionNotEstablished
        false
      end

      # The cached value for +cache_key+, or the block's, remembered unless
      # this connection's open transaction wrote consent (what it reads may
      # yet roll back).
      def remembered(cache_key, pending)
        entry = @cache[cache_key]
        return entry[0] if entry && Rights.current?(entry[1])

        value = yield
        return value if pending

        @mutex.synchronize do
          @cache = {} if @cache.size >= CACHE_LIMIT
          @cache[cache_key] = [value, Rights.now]
        end
        value
      end

      def fetch_row(purpose, key)
        return nil unless table_ready?

        ActiveRecord::Base.with_connection do |c|
          c.select_all("SELECT * FROM #{CONSENT_TABLE} WHERE subject_key = #{c.quote(key)} " \
                       "AND purpose = #{c.quote(purpose.to_s)}").to_a.first
        end
      rescue ActiveRecord::NoDatabaseError, ActiveRecord::ConnectionNotEstablished
        nil
      end

      def write_row(key, purpose, record, list, version)
        type, id = Rights.split_key(key)
        ActiveRecord::Base.with_connection do |c|
          c.execute("DELETE FROM #{CONSENT_TABLE} WHERE subject_key = #{c.quote(key)} AND purpose = #{c.quote(purpose.to_s)}")
          next unless record

          state = if record.withdrawn_at then :withdrawn elsif record.granted_at then :granted else :pending end
          requested_at = list.select { |e| e[:type] == "ConsentRequested" }.last&.dig(:at)
          values = [key, type, id, purpose.to_s, state.to_s, requested_at,
                    record.granted_at, record.expires_at, record.withdrawn_at, version, Time.current]
          c.execute("INSERT INTO #{CONSENT_TABLE} (#{COLUMNS.join(', ')}) VALUES " \
                    "(#{values.map { |v| Rights.quote(c, v) }.join(', ')})")
        end
      end

      # A change by this thread: its keys are read afresh through its
      # connection until its transaction ends; then nothing remembered stands.
      def changed!(pairs)
        @mutex.synchronize do
          @generation += 1
          @cache = {}
        end
        Rights.note_write!
        mark_pending(pairs)
      end

      def settled(_pairs)
        forget!
      end

      def table_ready?
        return true if @table_ready

        @table_ready = Rights.table_exists?(CONSENT_TABLE)
      end

      def ensure_table!
        return if @table_ready && table_ready?

        ready = Rights.with_table(CONSENT_TABLE) do |c|
          c.create_table(CONSENT_TABLE) do |t|
            t.string :subject_key, null: false
            t.string :subject_type
            t.string :subject_id
            t.string :purpose, null: false
            t.string :state, null: false
            t.datetime :requested_at, precision: 6
            t.datetime :granted_at, precision: 6
            t.datetime :expires_at, precision: 6
            t.datetime :withdrawn_at, precision: 6
            t.integer :stream_version, null: false
            t.datetime :updated_at, precision: 6, null: false
          end
          c.add_index CONSENT_TABLE, %i[subject_key purpose], unique: true
          c.add_index CONSENT_TABLE, %i[purpose subject_type]
        end
        raise ActiveRecord::ConnectionNotEstablished, "no database for #{CONSENT_TABLE}" unless ready

        @table_ready = true
      end
    end
  end
end
