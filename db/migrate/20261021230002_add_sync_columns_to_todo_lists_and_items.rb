class AddSyncColumnsToTodoListsAndItems < ActiveRecord::Migration[7.0]
  TABLES = %i[todo_lists todo_items].freeze

  def change
    TABLES.each do |table|
      change_table table do |t|
        t.string :external_id
        t.integer :local_version, null: false, default: 1
        t.integer :synced_version, null: false, default: 0
        t.datetime :remote_updated_at
      end

      add_index table, :external_id, unique: true
      # Dirty = changed locally since the last successful sync.
      add_index table, :id, where: "local_version > synced_version", name: "index_#{table}_on_dirty"
    end
  end
end
