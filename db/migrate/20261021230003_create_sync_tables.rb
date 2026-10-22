class CreateSyncTables < ActiveRecord::Migration[7.0]
  def change
    create_table :sync_tombstones do |t|
      t.string :record_type, null: false
      t.string :external_id, null: false
      t.string :list_external_id
      t.datetime :remote_updated_at
      t.integer :attempts, null: false, default: 0
      t.datetime :next_attempt_at
      t.text :last_error
      t.timestamps
    end
    add_index :sync_tombstones, %i[record_type external_id], unique: true

    create_table :sync_runs do |t|
      t.string :trigger
      t.string :status, null: false, default: "running"
      t.datetime :started_at
      t.datetime :finished_at
      t.json :stats, null: false, default: {}
      t.text :error
      t.timestamps
    end

    create_table :sync_states do |t|
      t.datetime :scheduled_at
      t.datetime :lock_heartbeat_at
      t.datetime :last_succeeded_at
      t.timestamps
    end
  end
end
