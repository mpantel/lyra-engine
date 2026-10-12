# frozen_string_literal: true

require "test_helper"

module Lyra
  module Projections
    # ES-Async's projection job applies only the events after its stream's
    # checkpoint (AsyncCheckpoint), so a record's jobs cost what its history is
    # long, not its square. These tests check that it does, that it falls back
    # to the whole stream whenever the checkpoint cannot be trusted, and that
    # the row ends where the log does in every case.
    class AsyncCheckpointTest < Minitest::Test
      TABLE = "lyra_ckpt_items"

      # Counts the events the job projects, switched on inside the block.
      module Counter
        attr_accessor :projected

        def project_events(model_class, events)
          self.projected += events.size if projected
          super
        end
      end
      Rebuild.singleton_class.prepend(Counter)

      def setup
        skip "Requires Rails and PostgreSQL" unless defined?(ActiveRecord::Base) && connection.adapter_name.match?(/postgres/i)

        connection.create_table(TABLE, force: true) do |t|
          t.string :label
          t.timestamps
        end
        Object.send(:remove_const, :CkptItem) if defined?(CkptItem)
        Object.const_set(:CkptItem, Class.new(ActiveRecord::Base) do
          self.table_name = TABLE
          include Lyra::Interceptors::CrudInterceptor
          monitor_with_lyra
        end)
        CkptItem.reset_column_information
        clean
        Lyra.config.monitor_model(CkptItem)
        Lyra.config.enable_event_sourcing!
        Lyra.config.projection_mode = :async
        Lyra.config.async_projections_inline = true
      end

      def teardown
        return unless defined?(CkptItem)

        clean
        connection.drop_table(TABLE, if_exists: true)
      end

      def test_each_write_projects_only_the_events_after_the_checkpoint
        item = CkptItem.create!(label: "v0")

        counts = (1..5).map { |i| projected { item.update!(label: "v#{i}") } }

        assert_equal [1, 1, 1, 1, 1], counts, "one event per write, not the whole stream"
        assert_equal "v5", row_label(item.id)
      end

      def test_a_job_with_nothing_new_projects_nothing
        item = CkptItem.create!(label: "v0")
        item.update!(label: "v1")

        assert_equal 0, projected { run_job_for_last_event(item.id) }
        assert_equal "v1", row_label(item.id)
      end

      def test_a_checkpoint_whose_event_is_gone_means_a_full_replay
        item = CkptItem.create!(label: "v0")
        item.update!(label: "v1")
        AsyncCheckpoint.write(connection, stream(item.id), SecureRandom.uuid)

        assert_equal 2, projected { run_job_for_last_event(item.id) }
        assert_equal "v1", row_label(item.id)
      end

      def test_without_the_lock_on_the_aggregate_every_job_replays_the_whole_stream
        Lyra.config.lock_aggregate_before_append = false
        item = CkptItem.create!(label: "v0")
        item.update!(label: "v1")

        assert_equal 3, projected { item.update!(label: "v2") }
        assert_equal "v2", row_label(item.id)
      end

      # A checkpoint older than the row (events projected some other way since,
      # e.g. in ES-Sync before a switch back to ES-Async) only re-applies events
      # the row already has; the row still ends where the log does.
      def test_an_old_checkpoint_re_applies_harmlessly
        item = CkptItem.create!(label: "v0")
        item.update!(label: "v1")
        old = AsyncCheckpoint.read(connection, stream(item.id))
        item.update!(label: "v2")
        item.update!(label: "v3")
        AsyncCheckpoint.write(connection, stream(item.id), old)

        run_job_for_last_event(item.id)

        assert_equal "v3", row_label(item.id)
      end

      def test_a_destroy_after_the_checkpoint_removes_the_row
        item = CkptItem.create!(label: "v0")
        item.update!(label: "v1")

        item.destroy!

        assert_nil row_label(item.id)
      end

      private

      def projected
        Rebuild.projected = 0
        yield
        Rebuild.projected
      ensure
        Rebuild.projected = nil
      end

      def run_job_for_last_event(id)
        last = Lyra.config.event_store.read.stream(stream(id)).last
        AsyncProjectionJob.new.perform(last.event_id, "CkptItem")
      end

      def stream(id) = "CkptItem$#{id}"

      def row_label(id)
        connection.select_value("SELECT label FROM #{TABLE} WHERE id = #{Integer(id)}")
      end

      def connection = ActiveRecord::Base.connection

      def clean
        connection.execute("DELETE FROM event_store_events_in_streams")
        connection.execute("DELETE FROM event_store_events")
        AsyncCheckpoint.reset!(connection)
      end
    end
  end
end
