# frozen_string_literal: true

module Lyra
  module Projections
    # Per stream, the last event ES-Async's projection has applied to the row
    # (AsyncProjectionJob). Kept in a table of Lyra's own, created on first
    # use, so the mode needs no migration.
    #
    # A checkpoint only saves work. Applying an event the row already reflects
    # is harmless (Rebuild.project_events), so an old checkpoint costs a few
    # redundant writes, never a wrong row; a missing one, or one whose event
    # is no longer in the stream, means a full replay.
    module AsyncCheckpoint
      TABLE = "lyra_async_checkpoints"

      class << self
        # The id of the last event applied to +stream+'s row, or nil.
        def read(connection, stream)
          ensure_table!(connection)
          connection.select_value("SELECT event_id FROM #{TABLE} WHERE stream = #{connection.quote(stream)}")
        end

        def write(connection, stream, event_id)
          ensure_table!(connection)
          connection.execute(<<~SQL.squish)
            INSERT INTO #{TABLE} (stream, event_id, updated_at)
            VALUES (#{connection.quote(stream)}, #{connection.quote(event_id)}, CURRENT_TIMESTAMP)
            ON CONFLICT (stream) DO UPDATE SET event_id = EXCLUDED.event_id, updated_at = EXCLUDED.updated_at
          SQL
        end

        # Forget every checkpoint (tests; after the tables were truncated).
        def reset!(connection = ActiveRecord::Base.connection)
          connection.execute("DELETE FROM #{TABLE}") if connection.table_exists?(TABLE)
        end

        private

        def ensure_table!(connection)
          return if @table_ready

          Lyra.create_own_table(connection, TABLE) do |conn|
            conn.create_table(TABLE, id: false) do |t|
              t.string :stream, null: false
              t.string :event_id, null: false
              t.datetime :updated_at
            end
            conn.add_index(TABLE, :stream, unique: true)
          end
          @table_ready = true
        end
      end
    end
  end
end
