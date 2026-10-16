class AddMarkAllToTodoLists < ActiveRecord::Migration[7.0]
  def change
    add_column :todo_lists, :mark_all_heartbeat_at, :datetime
    add_index :todo_items, %i[todo_list_id completed]
  end
end
