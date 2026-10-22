# Per-record retry state and the last sync error (dead letters), used by the
# item creation strategies and the resilience work.
class AddSyncErrorColumns < ActiveRecord::Migration[7.0]
  def change
    %i[todo_lists todo_items].each do |table|
      change_table table do |t|
        t.integer :sync_attempts, null: false, default: 0
        t.datetime :next_sync_at
        t.text :sync_error
      end
    end
  end
end
