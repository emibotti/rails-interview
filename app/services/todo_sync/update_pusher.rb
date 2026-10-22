module TodoSync
  # Pushes local changes of linked records (dirty = local_version > synced_version).
  #
  # Each record is compared with the snapshot first: if the remote already has
  # the same values it is marked as synced without any API call. Otherwise only
  # the fields that differ are sent. This is what keeps a mark all of N items,
  # M of them already completed remotely, down to N - M requests.
  #
  # Conflicts were already decided by the Puller: a record still dirty here either changed only locally or
  # won the last-write-wins comparison, so its values are the ones to send.
  #
  # synced_version is set to the version that was read before the call, never the
  # current one, so an edit made during the PATCH leaves the record dirty.
  class UpdatePusher
    HEARTBEAT_EVERY = 100 # records between Thread.pass calls

    def self.call(snapshot, run, client:)
      new(snapshot, run, client).call
    end

    def initialize(snapshot, run, client)
      @snapshot = snapshot
      @run = run
      @client = client
      @processed = 0
    end

    def call
      push_lists
      push_items
    end

    private

    def push_lists
      TodoList.dirty.linked.ready_to_sync.select(:id, :name, :external_id, :local_version).find_each do |list|
        remote = @snapshot.lists_by_external_id[list.external_id]
        # Missing from the snapshot: deleted remotely. The Puller deals with it (step 6).
        next tick if remote.nil?

        if remote.name == list.name
          mark_synced(TodoList, list, remote.updated_at)
          @run.increment_stat(:skipped_noop)
        else
          patch(list, "list") do
            @client.update_todo_list(list.external_id, name: list.name)
          end
        end
        tick
      end
    end

    def push_items
      noop_rows = []

      dirty_items.find_each(batch_size: 1000) do |item|
        remote = @snapshot.items_by_external_id[item.external_id]
        next tick if remote.nil? # same as lists: deleted remotely

        changes = changes_for(item, remote)
        if changes.empty?
          noop_rows << [item.id, item.external_id, remote.updated_at, item.local_version]
          flush_noops(noop_rows) if noop_rows.size >= BulkWriter::BATCH_SIZE
        else
          patch(item, "item") { @client.update_todo_item(item.list_external_id, item.external_id, **changes) }
        end
        tick
      end
      flush_noops(noop_rows)
    end

    def dirty_items
      TodoItem.dirty.linked.ready_to_sync.joins(:todo_list).where.not(todo_lists: { external_id: nil }).select(
        "todo_items.id", "todo_items.name", "todo_items.completed", "todo_items.external_id",
        "todo_items.local_version", "todo_lists.external_id AS list_external_id"
      )
    end

    def changes_for(item, remote)
      changes = {}
      changes[:name] = item.name if item.name != remote.name
      changes[:completed] = item.completed if item.completed != !!remote.completed
      changes
    end

    # Runs the PATCH and records the result. A failure of one record never stops the others.
    def patch(record, kind)
      remote = yield
      @run.increment_stat(:remote_calls)
      @run.increment_stat(:"#{kind}s_updated_remote")
      mark_synced(record.class, record, remote.updated_at)
      OperationLog.success(@client, "PATCH #{kind}", local: record.id, remote: record.external_id, detail: "(v#{record.local_version})")
    rescue ExternalTodo::Client::NotFoundError => e
      @run.increment_stat(:remote_calls)
      deleted_remotely(record, kind, e)
    rescue ExternalTodo::Client::Error => e
      @run.increment_stat(:remote_calls)
      Failures.record(record.class, record.id, e, run: @run)
    end

    def mark_synced(model, record, remote_updated_at)
      model.where(id: record.id).where("synced_version < ?", record.local_version)
           .update_all(synced_version: record.local_version, remote_updated_at: remote_updated_at, **Syncable::SYNC_OK)
    end

    def flush_noops(rows)
      return if rows.empty?

      BulkWriter.mark_items_synced(rows)
      @run.increment_stat(:skipped_noop, rows.size)
      rows.clear
    end

    # A 404 on PATCH means the record vanished remotely after our snapshot: the
    # delete wins (D5) and it is removed locally without callbacks, so no tombstone.
    def deleted_remotely(record, kind, error)
      if kind == "list"
        TodoList.transaction do
          TodoItem.where(todo_list_id: record.id).delete_all
          TodoList.where(id: record.id).delete_all
        end
      else
        TodoItem.where(id: record.id).delete_all
      end
      @run.increment_stat(:"#{kind}s_deleted_local")
      Rails.logger.warn("[TodoSync] #{kind} #{record.id} was deleted remotely (#{error.message}); deleted locally, " \
                        "dropping local changes (v#{record.local_version})")
    end

    def tick
      @processed += 1
      SyncState.heartbeat_if_due!
      Thread.pass if (@processed % HEARTBEAT_EVERY).zero?
    end
  end
end
