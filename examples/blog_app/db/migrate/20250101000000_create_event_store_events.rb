# Migration for RailsEventStore tables
class CreateEventStoreEvents < ActiveRecord::Migration[7.1]
  def change
    create_table(:event_store_events, force: false) do |t|
      t.references :event, null: false, type: :string, limit: 36, index: { unique: true }
      t.string :event_type, null: false, index: true
      t.binary :metadata
      t.binary :data, null: false
      t.datetime :created_at, null: false, index: true
      t.datetime :valid_at, null: true, index: true
    end

    create_table(:event_store_events_in_streams, force: false) do |t|
      t.string :stream, null: false, index: true
      t.integer :position, null: true
      t.references :event, null: false, type: :string, limit: 36, index: true
      t.datetime :created_at, null: false, index: true
    end

    add_index :event_store_events_in_streams, [:stream, :position], unique: true
    add_index :event_store_events_in_streams, [:stream, :event_id], unique: true
  end
end
