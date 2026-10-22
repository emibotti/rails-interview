module TodoSync
  # Pushes local lists that were never synced, each with all its items in a
  # single POST (the API can't create items in an existing list, see D9).
  #
  # POST is not idempotent and is never retried here: on a timeout the list may
  # exist remotely, and the Linker binds it by source_id in the next cycle.
  class CreatePusher
    def self.call(snapshot, run, client:)
      new(run, client).call
    end

    def initialize(run, client)
      @run = run
      @client = client
    end

    def call
      TodoList.unlinked.ready_to_sync.select(:id, :name, :local_version).find_each do |list|
        push(list)
        SyncState.heartbeat_if_due!
        Thread.pass
      end
    end

    private

    def push(list)
      all_items = TodoItem.where(todo_list_id: list.id)
      # The first POST carries at most create_batch_size items: a huge body times out, and a timeout is ambiguous. The
      # rest are unlinked items of a linked list, which the item creation strategy takes over (see ItemCreation).
      items = all_items.order(:id).limit(Rails.configuration.x.external_todo.create_batch_size)
                       .select(:id, :name, :completed, :local_version).to_a
      deferred = all_items.count - items.size

      remote = @client.create_todo_list(
        name: list.name,
        source_id: ExternalTodo::SourceId.for(list),
        items: items.map { |item| { name: item.name, completed: item.completed, source_id: ExternalTodo::SourceId.for(item) } }
      )
      @run.increment_stat(:remote_calls)
      save_links(list, items, remote)
      OperationLog.success(@client, "POST list", local: list.id, remote: remote.external_id,
                                                 detail: "(#{items.size} items#{", #{deferred} deferred" if deferred.positive?})")
      @run.increment_stat(:items_deferred, deferred) if deferred.positive?
    rescue ExternalTodo::Client::TimeoutError => e
      # Ambiguous: don't re-POST in this cycle, the next snapshot tells.
      @run.increment_stat(:remote_calls)
      @run.increment_stat(:create_timeouts)
      Rails.logger.warn("[TodoSync] POST list #{list.id} timed out; it will be linked by source_id if it was created (#{e.message})")
      Failures.record(TodoList, list.id, e, run: @run)
    rescue ExternalTodo::Client::Error => e
      @run.increment_stat(:remote_calls)
      Failures.record(TodoList, list.id, e, run: @run)
    end

    # Stores the remote ids in one transaction. synced_version is set to the
    # version that was SENT, so an edit made during the POST leaves the record dirty.
    def save_links(list, items, remote)
      pairs = pair_items(list, items, remote)

      TodoList.transaction do
        TodoList.where(id: list.id, external_id: nil).where("synced_version < ?", list.local_version)
                .update_all(external_id: remote.external_id, remote_updated_at: remote.updated_at, synced_version: list.local_version, **Syncable::SYNC_OK)
        BulkWriter.mark_items_synced(
          pairs.map { |item, remote_item| [item.id, remote_item.external_id, remote_item.updated_at, item.local_version] },
          mode: :link
        )
      end
      @run.increment_stat(:lists_created_remote)
      @run.increment_stat(:items_created_remote, pairs.size)
    end

    # [[local_item, remote_item], ...] matched by source_id. If the API doesn't
    # echo the source_ids, falls back to the order in which they were sent.
    def pair_items(list, items, remote)
      by_id = remote.items.each_with_object({}) do |remote_item, index|
        kind, id = ExternalTodo::SourceId.parse(remote_item.source_id)
        index[id] = remote_item if kind == :item
      end
      if items.all? { |item| by_id.key?(item.id) }
        return items.map { |item| [item, by_id[item.id]] }
      end

      if remote.items.size == items.size
        Rails.logger.warn("[TodoSync] list #{list.id}: the API did not echo item source_ids; matching by position")
        return items.zip(remote.items)
      end

      @run.increment_stat(:unpaired_items, items.size)
      Rails.logger.error("[TodoSync] list #{list.id}: could not match #{items.size} local items with #{remote.items.size} remote ones; " \
                         "the list is linked and the items will be linked by source_id next cycle")
      []
    end
  end
end
