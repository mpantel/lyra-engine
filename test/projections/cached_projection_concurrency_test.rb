# frozen_string_literal: true

require "test_helper"

module Lyra
  module Projections
    # CachedProjection under many threads: the shared cache (Solid Cache here),
    # the process-local copy in front of it, and records rebuilt from the
    # events after a stale entry's stamp. Readers and writers of one record run
    # at once under ES-NoProj. Every read must be a state the record's stream
    # actually had, a reader must never see the record go back to an older
    # state, and once the writers stop every reader sees the last one.
    class CachedProjectionConcurrencyTest < Minitest::Test
      READERS = 8
      WRITERS = 2
      UPDATES = 25

      def setup
        skip "Requires Rails and database" unless defined?(ActiveRecord::Base) && ActiveRecord::Base.connection.table_exists?(:users)

        Object.send(:remove_const, :ConcurrentCacheUser) if defined?(ConcurrentCacheUser)
        Object.const_set(:ConcurrentCacheUser, Class.new(ActiveRecord::Base) do
          self.table_name = "users"
          include Lyra::Interceptors::CrudInterceptor
          monitor_with_lyra
        end)
        # A connection per thread, as an application sizes its pool to its
        # threads; the test database's own pool (5) is restored afterwards.
        @db_config = ActiveRecord::Base.connection_db_config.configuration_hash
        ActiveRecord::Base.establish_connection(@db_config.merge(pool: READERS + WRITERS + 2))
        clean
        Rails.cache.clear
        Lyra.config.enable_event_sourcing!
        Lyra.config.projection_mode = :disabled
        Lyra.config.monitor_model(ConcurrentCacheUser)
      end

      def teardown
        return unless defined?(ConcurrentCacheUser)

        ActiveRecord::Base.establish_connection(@db_config) if @db_config
        Lyra.config.projection_mode = :sync
        clean
        Rails.cache.clear
      end

      def test_readers_see_only_states_the_stream_had_in_order_and_converge
        id = ConcurrentCacheUser.create!(name: "w0-0", email: "c@example.com").id
        CachedProjection.find(ConcurrentCacheUser, id) # warm both levels
        written = (0...WRITERS).flat_map { |w| (1..UPDATES).map { |i| "w#{w}-#{i}" } }

        stop = false
        errors = Queue.new
        writers = WRITERS.times.map do |w|
          Thread.new do
            (1..UPDATES).each do |i|
              with_connection { ConcurrentCacheUser.find(id).update!(name: "w#{w}-#{i}") }
            end
          rescue StandardError => e
            errors << e
          end
        end
        readers = READERS.times.map do
          Thread.new do
            seen = []
            until stop
              with_connection { seen << CachedProjection.find(ConcurrentCacheUser, id)&.fetch("name") }
              Thread.pass
            end
            seen
          rescue StandardError => e
            errors << e
            []
          end
        end

        writers.each { |t| assert t.join(60), "a writer hung" }
        stop = true
        observations = readers.map { |t| assert(t.join(60), "a reader hung") && t.value }

        unless errors.empty?
          first = errors.pop
          trace = first.backtrace.grep(%r{/lib/lyra/}).first(8).join("\n  ")
          flunk "#{errors.size + 1} errors, first: #{first.class}: #{first.message}\n  #{trace}"
        end
        order = stream_names(id)
        assert_equal ["w0-0", *written].sort, order.sort, "every update was recorded once"

        position = order.each_with_index.to_h
        observations.each_with_index do |seen, reader|
          refute_empty seen, "reader #{reader} read nothing"
          unknown = seen.uniq - order
          assert_empty unknown, "reader #{reader} read states the stream never had: #{unknown.first(3)}"
          positions = seen.map { position.fetch(_1) }
          assert_equal positions.sort, positions, "reader #{reader} saw the record go back to an older state"
        end

        final = order.last
        READERS.times.map do
          Thread.new { with_connection { CachedProjection.find(ConcurrentCacheUser, id)["name"] } }
        end.each { |t| assert_equal final, t.value, "a reader did not converge on the last write" }
      end

      private

      def with_connection(&) = ActiveRecord::Base.connection_pool.with_connection(&)

      # The names the record's stream sets, in its order.
      def stream_names(id)
        Lyra.config.event_store.read.stream("ConcurrentCacheUser$#{id}").to_a.filter_map do |event|
          data = event.data
          # A created event carries its attributes (and an empty changes hash).
          attrs = (data[:changes].presence || data["changes"].presence ||
                   data[:attributes] || data["attributes"] || {}).with_indifferent_access
          next unless attrs.key?(:name)

          value = attrs[:name]
          value.is_a?(Array) ? value.last : value
        end
      end

      def clean
        conn = ActiveRecord::Base.connection
        conn.execute("DELETE FROM users")
        conn.execute("DELETE FROM event_store_events_in_streams")
        conn.execute("DELETE FROM event_store_events")
      end
    end
  end
end
