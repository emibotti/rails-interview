module TodoSync
  # Batched writes of the sync state of many items with one UPDATE ... FROM a
  # VALUES table, instead of one UPDATE per item. Like the rest of the sync it
  # skips callbacks, and `synced_version < version` keeps it from ever moving
  # backwards, so an edit made after the version was read leaves the item dirty.
  #
  # SQLite has no `AS v(columns)` alias for subqueries, hence the CTE.
  module BulkWriter
    BATCH_SIZE = 500

    module_function

    # rows: [[item_id, external_id, remote_updated_at, version], ...]
    # link: also store external_id (only on items that don't have one yet).
    def mark_items_synced(rows, link: false)
      rows.each_slice(BATCH_SIZE) do |batch|
        values = batch.map do |id, external_id, remote_updated_at, version|
          ActiveRecord::Base.sanitize_sql_array(["(?, ?, ?, ?)", id, external_id, format_time(remote_updated_at), version])
        end
        set_external_id = link ? "external_id = v.external_id," : ""
        unlinked_only = link ? "AND todo_items.external_id IS NULL" : ""

        TodoItem.connection.execute(<<~SQL.squish)
          WITH v(id, external_id, remote_updated_at, version) AS (VALUES #{values.join(', ')})
          UPDATE todo_items
          SET #{set_external_id} remote_updated_at = v.remote_updated_at, synced_version = v.version
          FROM v
          WHERE todo_items.id = v.id #{unlinked_only} AND todo_items.synced_version < v.version
        SQL
      end
    end

    # Same format and precision Active Record stores datetimes with.
    def format_time(time)
      time&.utc&.strftime("%Y-%m-%d %H:%M:%S.%6N")
    end
  end
end
