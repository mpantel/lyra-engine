# frozen_string_literal: true

require "test_helper"

module Lyra
  module Projections
    # CachedProjection serves ES-NoProj reads from per-record cache entries,
    # each stamped with the id of the last event it was built from. These
    # tests check the rule that makes that safe: an entry is used only while
    # its stamp is still its stream's last event, so no write, rollback or
    # race can make a read return an out-of-date record.
    class CachedProjectionTest < Minitest::Test
      def setup
        skip "Requires Rails and database" unless defined?(ActiveRecord::Base) && ActiveRecord::Base.connection.table_exists?(:users)

        Object.send(:remove_const, :CacheUser) if defined?(CacheUser)
        Object.const_set(:CacheUser, Class.new(ActiveRecord::Base) do
          self.table_name = "users"
          include Lyra::Interceptors::CrudInterceptor
          monitor_with_lyra
        end)
        clean
        Rails.cache.clear
        Lyra.config.enable_event_sourcing!
        Lyra.config.projection_mode = :disabled
        Lyra.config.monitor_model(CacheUser)
      end

      def teardown
        return unless defined?(CacheUser)

        Lyra.config.projection_mode = :sync
        clean
        Rails.cache.clear
      end

      def test_a_write_made_elsewhere_is_seen_without_any_invalidation
        user = CacheUser.create!(name: "Ann", email: "ann@example.com")
        assert_equal "Ann", CachedProjection.find(CacheUser, user.id)["name"]

        # Another process appends an event; nothing here is invalidated.
        publish_update(user.id, "name" => ["Ann", "Anna"])

        assert_equal "Anna", CachedProjection.find(CacheUser, user.id)["name"]
        assert_equal ["Anna"], CachedProjection.all(CacheUser).map { _1["name"] }
      end

      def test_a_rolled_back_write_leaves_nothing_visible
        user = CacheUser.create!(name: "Ann", email: "ann@example.com")

        ActiveRecord::Base.transaction do
          user.update!(name: "Ghost") # warms the cache inside the transaction
          assert_equal "Ghost", CachedProjection.find(CacheUser, user.id)["name"]
          raise ActiveRecord::Rollback
        end

        assert_equal "Ann", CachedProjection.find(CacheUser, user.id)["name"]
        assert_equal ["Ann"], CachedProjection.all(CacheUser).map { _1["name"] }
      end

      def test_an_out_of_date_entry_is_never_used
        user = CacheUser.create!(name: "Ann", email: "ann@example.com")
        key = CachedProjection.send(:record_cache_key, CacheUser, user.id)
        Rails.cache.write(key, { "v" => "not-the-last-event", "a" => { "id" => user.id, "name" => "Stale" } })

        assert_equal "Ann", CachedProjection.find(CacheUser, user.id)["name"]
        assert_equal ["Ann"], CachedProjection.all(CacheUser).map { _1["name"] }
      end

      def test_after_one_write_a_collection_read_replays_one_stream
        users = 3.times.map { |i| CacheUser.create!(name: "U#{i}", email: "u#{i}@example.com") }
        CachedProjection.all(CacheUser) # warm

        publish_update(users[1].id, "name" => ["U1", "U1b"])
        replayed = count_replays { CachedProjection.all(CacheUser) }

        assert_equal 1, replayed
        assert_equal %w[U0 U1b U2], CachedProjection.all(CacheUser).map { _1["name"] }
        assert_equal 0, count_replays { CachedProjection.all(CacheUser) }, "warm again"
      end

      def test_destroyed_records_are_absent
        kept = CacheUser.create!(name: "Kept", email: "k@example.com")
        gone = CacheUser.create!(name: "Gone", email: "g@example.com")
        gone.destroy!

        assert_nil CachedProjection.find(CacheUser, gone.id)
        refute CachedProjection.exists?(CacheUser, gone.id)
        assert_equal [kept.id], CachedProjection.all(CacheUser).map { _1["id"] }
        assert_equal 1, CachedProjection.count(CacheUser)
      end

      def test_lookups_by_attribute_see_an_update_at_once
        user = CacheUser.create!(name: "Ann", email: "ann@example.com")
        assert CachedProjection.find_by(CacheUser, { name: "Ann" })
        assert_equal 1, CachedProjection.count(CacheUser, { name: "Ann" })

        user.update!(name: "Bea")

        assert_nil CachedProjection.find_by(CacheUser, { name: "Ann" }), "no five-minute stale answer"
        assert_equal 1, CachedProjection.where(CacheUser, { name: "Bea" }).size
        assert_equal 0, CachedProjection.count(CacheUser, { name: "Ann" })
      end

      def test_a_stale_entry_is_updated_from_the_events_after_its_stamp
        user = CacheUser.create!(name: "Ann", email: "ann@example.com")
        3.times { |i| publish_update(user.id, "name" => ["n#{i}", "n#{i + 1}"]) }
        assert_equal "n3", CachedProjection.find(CacheUser, user.id)["name"] # warm

        publish_update(user.id, "name" => ["n3", "Bea"])
        publish_update(user.id, "email" => ["ann@example.com", "bea@example.com"])

        full = nil
        found = nil
        full = full_replays_in { found = CachedProjection.find(CacheUser, user.id) }

        assert_equal 0, full, "the stream is not replayed from its first event"
        assert_equal "Bea", found["name"]
        assert_equal "bea@example.com", found["email"]
        assert_equal user.id, found["id"]
      end

      def test_replaying_after_a_stamp_reaches_the_state_of_a_full_replay
        user = CacheUser.create!(name: "Ann", email: "ann@example.com")
        other = CacheUser.create!(name: "Cy", email: "cy@example.com")
        names = %w[A B C D E F]
        names.each_cons(2) do |from, to|
          publish_update(user.id, "name" => [from, to], "email" => ["#{from}@x", "#{to}@x"])
          # alternate: read between writes (incremental) and every second write
          CachedProjection.find(CacheUser, user.id) if from.ord.odd?
          CachedProjection.all(CacheUser) if from.ord.even?
        end

        incremental = CachedProjection.find(CacheUser, user.id)
        full = CachedProjection.find(CacheUser, user.id, force: true)

        assert_equal full, incremental
        assert_equal "F", incremental["name"]
        assert_equal %w[F Cy], CachedProjection.all(CacheUser).map { _1["name"] }
        assert_equal "Cy", CachedProjection.find(CacheUser, other.id)["name"]
      end

      def test_a_destroy_after_the_stamp_removes_the_record
        user = CacheUser.create!(name: "Ann", email: "ann@example.com")
        assert CachedProjection.find(CacheUser, user.id)

        user.destroy!

        assert_nil CachedProjection.find(CacheUser, user.id)
        assert_empty CachedProjection.all(CacheUser)
      end

      def test_a_stamp_that_rolled_back_is_replayed_in_full
        user = CacheUser.create!(name: "Ann", email: "ann@example.com")
        ActiveRecord::Base.transaction do
          user.update!(name: "Ghost")
          assert_equal "Ghost", CachedProjection.find(CacheUser, user.id)["name"] # entry stamped with a doomed event
          raise ActiveRecord::Rollback
        end
        publish_update(user.id, "email" => ["ann@example.com", "ann@work.example"])

        found = CachedProjection.find(CacheUser, user.id)

        assert_equal "Ann", found["name"], "nothing of the rolled-back write survives in the entry"
        assert_equal "ann@work.example", found["email"]
      end

      def test_find_many_answers_like_find_from_one_query
        users = 4.times.map { |i| CacheUser.create!(name: "U#{i}", email: "u#{i}@example.com") }
        users.last.destroy!
        CachedProjection.find(CacheUser, users[0].id) # one entry warm, the rest not
        publish_update(users[1].id, "name" => ["U1", "U1b"])

        ids = [users[2].id, users[0].id, users[1].id, users[3].id, 999_999]
        many = CachedProjection.find_many(CacheUser, ids)

        assert_equal ids.filter_map { |id| CachedProjection.find(CacheUser, id) }.sort_by { _1["id"] },
                     many.sort_by { _1["id"] }
        assert_equal %w[U0 U1b U2], many.map { _1["name"] }.sort
        assert_empty CachedProjection.find_many(CacheUser, [])
      end

      def test_a_warm_entry_is_read_from_this_process_not_the_shared_cache
        user = CacheUser.create!(name: "Ann", email: "ann@example.com")
        CachedProjection.find(CacheUser, user.id) # warm both levels

        reads = 0
        original = Rails.cache.method(:read)
        Rails.cache.define_singleton_method(:read) { |*args, **kw| reads += 1; original.call(*args, **kw) }
        begin
          assert_equal "Ann", CachedProjection.find(CacheUser, user.id)["name"]
        ensure
          Rails.cache.singleton_class.send(:remove_method, :read)
        end

        assert_equal 0, reads
        # The copy never outlives its stamp: a write made elsewhere is seen.
        publish_update(user.id, "name" => ["Ann", "Anna"])
        assert_equal "Anna", CachedProjection.find(CacheUser, user.id)["name"]
      end

      def test_a_model_name_with_like_wildcards_matches_only_its_own_streams
        user = CacheUser.create!(name: "Ann", email: "ann@example.com")
        other = Lyra::Events.const_defined?(:CacheXUserUpdated) ? Lyra::Events::CacheXUserUpdated : Lyra::Events.const_set(:CacheXUserUpdated, Class.new(Lyra::Event))
        # "CacheUser$" must not match a stream such as "CacheXUser$...":
        # the prefix is escaped before it is used in LIKE.
        Lyra.config.event_store.publish(other.new(data: { model_class: "CacheXUser", model_id: 1, operation: :updated, changes: {} }),
                                        stream_name: "CacheXUser$#{user.id}")

        assert_equal [user.id], CachedProjection.all(CacheUser).map { _1["id"] }
      end

      private

      def publish_update(id, changes)
        name = Lyra.config.model_config(CacheUser).event_name_for(:updated).to_s.gsub("::", "")
        event_class = Lyra::Events.const_defined?(name, false) ? Lyra::Events.const_get(name, false) : Lyra::Events.const_set(name, Class.new(Lyra::Event))
        Lyra.config.event_store.publish(
          event_class.new(data: { model_class: "CacheUser", model_id: id, operation: :updated,
                                  attributes: changes.transform_values(&:last), changes: changes }),
          stream_name: "CacheUser$#{id}"
        )
      end

      # Counts stream replays by wrapping load_events in a prepended module,
      # switched on only inside the block.
      # replay_count counts every stream read, from the first event or after a
      # stamp; full_count only those from the first event.
      module ReplayCounter
        attr_accessor :replay_count, :full_count

        def load_events(*args)
          if replay_count
            self.replay_count += 1
            self.full_count += 1
          end
          super
        end

        def load_events_after(*args)
          self.replay_count += 1 if replay_count
          super
        end
      end

      def count_replays
        CachedProjection.singleton_class.prepend(ReplayCounter) unless CachedProjection.singleton_class.include?(ReplayCounter)
        CachedProjection.replay_count = 0
        CachedProjection.full_count = 0
        yield
        CachedProjection.replay_count
      ensure
        CachedProjection.replay_count = nil
      end

      def full_replays_in
        count_replays { yield }
        CachedProjection.full_count
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
