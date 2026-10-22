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
      TodoList.unlinked.select(:id, :name, :local_version).find_each do |list|
        push(list)
        SyncState.heartbeat!
        Thread.pass
      end
    end

    private

    def push(list)
      items = TodoItem.where(todo_list_id: list.id).order(:id).select(:id, :name, :completed, :local_version).to_a
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      remote = @client.create_todo_list(
        name: list.name,
        source_id: ExternalTodo::SourceId.for(list),
        items: items.map { |item| { name: item.name, completed: item.completed, source_id: ExternalTodo::SourceId.for(item) } }
      )
      @run.increment_stat(:remote_calls)
      save_links(list, items, remote)

      ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
      Rails.logger.info("[TodoSync] POST list #{list.id} -> #{remote.external_id} (#{items.size} items, #{ms}ms)")
    rescue ExternalTodo::Client::TimeoutError => e
      # Ambiguous: don't re-POST in this cycle, the next snapshot tells.
      @run.increment_stat(:remote_calls)
      @run.increment_stat(:create_timeouts)
      Rails.logger.warn("[TodoSync] POST list #{list.id} timed out; it will be linked by source_id if it was created (#{e.message})")
    rescue ExternalTodo::Client::Error => e
      # TODO: per-record backoff and dead letters instead of just counting the failure (step 10).
      @run.increment_stat(:remote_calls)
      @run.increment_stat(:failures)
      Rails.logger.error("[TodoSync] POST list #{list.id} failed: #{e.message}")
    end

    # Stores the remote ids in one transaction. synced_version is set to the
    # version that was SENT, so an edit made during the POST leaves the record dirty.
    def save_links(list, items, remote)
      pairs = pair_items(list, items, remote)

      TodoList.transaction do
        TodoList.where(id: list.id, external_id: nil).where("synced_version < ?", list.local_version)
                .update_all(external_id: remote.external_id, remote_updated_at: remote.updated_at, synced_version: list.local_version)
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
      by_id = remote.items.index_by { |remote_item| ExternalTodo::SourceId.parse(remote_item.source_id)&.last }
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
