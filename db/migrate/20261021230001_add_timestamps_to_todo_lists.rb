# SQLite can't add a column with a non-constant default (CURRENT_TIMESTAMP), so
# add nullable columns, backfill them and only then make them NOT NULL.
class AddTimestampsToTodoLists < ActiveRecord::Migration[7.0]
  def up
    add_column :todo_lists, :created_at, :datetime
    add_column :todo_lists, :updated_at, :datetime

    now = connection.quote(Time.current.utc.to_fs(:db))
    execute "UPDATE todo_lists SET created_at = #{now}, updated_at = #{now}"

    change_column_null :todo_lists, :created_at, false
    change_column_null :todo_lists, :updated_at, false
  end

  def down
    remove_column :todo_lists, :created_at
    remove_column :todo_lists, :updated_at
  end
end
