# frozen_string_literal: true

require "test_helper"

module Lyra
  module Projections
    # Integration tests for Lyra::Projections::Rebuild.
    #
    # Verifies the load-bearing event-sourcing invariant: the read-model table
    # can be discarded and reconstructed from the event log alone. We drive a
    # full create/update/destroy lifecycle, wipe the projected rows directly
    # (simulating projection loss/corruption), rebuild from the log, and assert
    # the table matches the event-derived state.
    class RebuildTest < Minitest::Test
      def self.runnable_methods
        return [] unless defined?(ActiveRecord::Base) && defined?(Rails)

        super
      end

      def setup
        return unless defined?(ActiveRecord::Base)

        Lyra.reset_config!
        Lyra.configure do |config|
          config.mode = :event_sourcing
          config.projection_mode = :sync
          config.event_store = RailsEventStore::Client.new(
            repository: RubyEventStore::ActiveRecord::EventRepository.new(
              serializer: RubyEventStore::Serializers::YAML
            )
          )
        end

        @user_class = create_test_model_class
        Lyra.config.monitor_model(@user_class, event_prefix: "RebuildUser")

        Lyra.projection_write { @user_class.delete_all }
        clear_event_store

        @full_integration_available = check_full_integration_available
      end

      def teardown
        return unless defined?(ActiveRecord::Base)

        Lyra.projection_write { @user_class&.delete_all } rescue nil
        clear_event_store
        Lyra.reset_config!
      end

      # =========================================================================
      # Rebuild reconstructs surviving records
      # =========================================================================

      def test_rebuild_reconstructs_table_from_event_log
        skip_unless_full_integration

        alice = @user_class.new(name: "Alice", email: "alice@example.com")
        alice.save
        alice.name = "Alice Cooper"
        alice.save

        bob = @user_class.new(name: "Bob", email: "bob@example.com")
        bob.save

        # Simulate projection loss: wipe the read model, keep the event log.
        Lyra.projection_write { @user_class.delete_all }
        assert_equal 0, @user_class.count, "precondition: read model wiped"

        stats = Lyra::Projections::Rebuild.rebuild(@user_class)

        assert_equal 2, @user_class.count, "both live records reconstructed"

        rebuilt_alice = @user_class.find(alice.id)
        assert_equal "Alice Cooper", rebuilt_alice.name, "latest update applied on rebuild"
        assert_equal "alice@example.com", rebuilt_alice.email

        rebuilt_bob = @user_class.find(bob.id)
        assert_equal "Bob", rebuilt_bob.name

        assert_equal 2, stats[:records]
        assert_equal 0, stats[:destroyed]
        assert_equal 2, stats[:streams]
        assert stats[:events] >= 3, "replayed create+update+create events"
      end

      # =========================================================================
      # Rebuild honors destroyed records
      # =========================================================================

      def test_rebuild_omits_destroyed_records
        skip_unless_full_integration

        keep = @user_class.new(name: "Keep", email: "keep@example.com")
        keep.save

        gone = @user_class.new(name: "Gone", email: "gone@example.com")
        gone.save
        gone_id = gone.id
        gone.destroy

        Lyra.projection_write { @user_class.delete_all }

        stats = Lyra::Projections::Rebuild.rebuild(@user_class)

        assert_equal 1, @user_class.count, "only the surviving record is rebuilt"
        assert @user_class.exists?(keep.id), "kept record present"
        assert_nil @user_class.find_by(id: gone_id), "destroyed record stays absent"
        assert_equal 1, stats[:records]
        assert_equal 1, stats[:destroyed]
      end

      # Projection must write the table even while reads come from the event
      # store (projection_mode :disabled, ES-NoProj). Its update and destroy go
      # through model_class.where(...), which that mode answers from events: a
      # destroyed record is absent there, so its row was never deleted.
      def test_rebuild_in_place_while_reads_come_from_events
        skip_unless_full_integration

        keep = @user_class.new(name: "Keep", email: "keep@example.com")
        keep.save
        keep.name = "Keep Updated"
        keep.save
        gone = @user_class.new(name: "Gone", email: "gone@example.com")
        gone.save
        gone_id = gone.id
        gone.destroy

        # Corrupt the table: undo the update, resurrect the destroyed row.
        conn = ActiveRecord::Base.connection
        table = @user_class.table_name
        conn.execute("UPDATE #{table} SET name = 'Keep' WHERE id = #{Integer(keep.id)}")
        conn.execute("INSERT INTO #{table} (id, name, email, created_at, updated_at) " \
                     "VALUES (#{Integer(gone_id)}, 'Gone', 'gone@example.com', now(), now())")

        Lyra.config.projection_mode = :disabled
        Lyra::Projections::Rebuild.rebuild(@user_class, truncate: false)

        assert_equal "Keep Updated", conn.select_value("SELECT name FROM #{table} WHERE id = #{Integer(keep.id)}")
        assert_nil conn.select_value("SELECT id FROM #{table} WHERE id = #{Integer(gone_id)}"),
                   "the destroyed record's row must be deleted"
      ensure
        Lyra.config.projection_mode = :sync
      end

      # =========================================================================
      # Rebuilt state is dual-view consistent
      # =========================================================================

      def test_rebuilt_state_is_dual_view_consistent
        skip_unless_full_integration

        user = @user_class.new(name: "Dana", email: "dana@example.com")
        user.save
        user.name = "Dana Scully"
        user.save

        Lyra.projection_write { @user_class.delete_all }
        Lyra::Projections::Rebuild.rebuild(@user_class)

        comparison = Lyra::DualView.new(@user_class, user.id).compare
        assert_equal({ no_differences: true }, comparison[:differences],
                     "rebuilt ORM row matches event-sourced view: #{comparison[:differences].inspect}")
      end

      # =========================================================================
      # rebuild_all covers monitored models
      # =========================================================================

      def test_rebuild_all_defaults_to_monitored_models
        skip_unless_full_integration

        user = @user_class.new(name: "Mona", email: "mona@example.com")
        user.save
        Lyra.projection_write { @user_class.delete_all }

        results = Lyra::Projections::Rebuild.rebuild_all

        assert_kind_of Array, results
        assert results.any? { |s| s[:model] == @user_class.name }
        assert_equal 1, @user_class.count
      end

      private

      def create_test_model_class
        Class.new(ActiveRecord::Base) do
          self.table_name = "users"

          include Lyra::Interceptors::CrudInterceptor
          monitor_with_lyra

          def self.name
            "RebuildUser"
          end
        end
      end

      def check_full_integration_available
        test_user = @user_class.new(name: "probe", email: "probe@test.com")
        test_user.save
        has_id = test_user.id.present?
        Lyra.projection_write { @user_class.delete_all } rescue nil
        clear_event_store
        has_id
      rescue StandardError
        false
      end

      def skip_unless_full_integration
        skip "Full integration not available (model callbacks not firing)" unless @full_integration_available
      end

      def clear_event_store
        ActiveRecord::Base.connection.execute("DELETE FROM event_store_events_in_streams")
        ActiveRecord::Base.connection.execute("DELETE FROM event_store_events")
      rescue StandardError
        nil
      end
    end
  end
end
