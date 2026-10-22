module TodoSync
  # Batched writes of the sync state of many items with one UPDATE ... FROM a
  # VALUES table, instead of one UPDATE per item. Like the rest of the sync it
  # skips callbacks. Versions never move backwards (`synced_version < version` or
  # MAX), so an edit made after the version was read leaves the item dirty.
  #
  # SQLite has no `AS v(columns)` alias for subqueries, hence the CTE.
  module BulkWriter
    BATCH_SIZE = 500

    MODES = {
      # Only advance the synced version (the remote already has these values).
      synced: {
        set: "remote_updated_at = v.remote_updated_at, synced_version = v.version",
        guard: "todo_items.synced_version < v.version"
      },
      # Store the remote id of an item that was never linked.
      link: {
        set: "external_id = v.external_id, remote_updated_at = v.remote_updated_at, synced_version = v.version",
        guard: "todo_items.external_id IS NULL AND todo_items.synced_version < v.version"
      },
      # Point an item to a new remote id after its list was recreated remotely.
      relink: {
        set: "external_id = v.external_id, remote_updated_at = v.remote_updated_at, " \
             "synced_version = MAX(todo_items.synced_version, v.version)",
        guard: "1 = 1"
      },
      # Point an item to another remote id without saying anything about its versions.
      retarget: {
        set: "external_id = v.external_id, remote_updated_at = v.remote_updated_at",
        guard: "1 = 1"
      }
    }.freeze

    module_function

    # rows: [[item_id, external_id, remote_updated_at, version], ...]
    def mark_items_synced(rows, mode: :synced)
      mode = MODES.fetch(mode)

      rows.each_slice(BATCH_SIZE) do |batch|
        values = batch.map do |id, external_id, remote_updated_at, version|
          ActiveRecord::Base.sanitize_sql_array(["(?, ?, ?, ?)", id, external_id, format_time(remote_updated_at), version])
        end

        TodoItem.connection.execute(<<~SQL.squish)
          WITH v(id, external_id, remote_updated_at, version) AS (VALUES #{values.join(', ')})
          UPDATE todo_items
          SET #{mode[:set]}
          FROM v
          WHERE todo_items.id = v.id AND #{mode[:guard]}
        SQL
      end
    end

    # Same format and precision Active Record stores datetimes with.
    def format_time(time)
      time&.utc&.strftime("%Y-%m-%d %H:%M:%S.%6N")
    end
  end
end
