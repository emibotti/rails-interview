module TodoSync
  module ItemCreation
    # Temporary workaround for an API that cannot create items in an existing list:
    #
    # 1. POST a new list with the current name and ALL the local items (synced and new), with their source_ids.
    # 2. In one transaction, point the list and every item to the new remote ids and leave a tombstone for the old list.
    # 3. The normal tombstone mechanism deletes the old list (with its retries).
    #
    # Create first, delete after: a failure leaves a duplicate (recoverable) instead of losing data. If the POST
    # times out, the next snapshot has two remote lists with our source_id and the Linker adopts the one that
    # contains the new items. Two calls per list, however many new items it has.
    #
    # Known risks (see NOTES.md): remote ids change (the source_id stays), the remote created_at is lost, an item created
    # remotely by someone else between our GET and the DELETE is lost, and big lists make a heavy POST (hence recreate_max_items).
    class RecreateList
      def self.call(snapshot, run, client:)
        new(run, client).call
      end

      def initialize(run, client)
        @run = run
        @client = client
      end

      def call
        ItemCreation.lists_with_unlinked_items.each do |list|
          total = TodoItem.where(todo_list_id: list.id).count
          max = Rails.configuration.x.external_todo.recreate_max_items
          if total > max
            Skip.new(@run).call("list has #{total} items, above recreate_max_items=#{max}", only_list_ids: [list.id])
          else
            ItemCreation.clear_errors(list.id)
            recreate(list)
          end
          SyncState.heartbeat!
          Thread.pass
        end
      end

      private

      def recreate(list)
        items = TodoItem.where(todo_list_id: list.id).order(:id).select(:id, :name, :completed, :local_version).to_a
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        remote = @client.create_todo_list(
          name: list.name,
          source_id: ExternalTodo::SourceId.for(list),
          items: items.map { |item| { name: item.name, completed: item.completed, source_id: ExternalTodo::SourceId.for(item) } }
        )
        @run.increment_stat(:remote_calls)
        save(list, items, remote)

        ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
        Rails.logger.info("[TodoSync] recreated list #{list.id}: #{list.external_id} -> #{remote.external_id} (#{items.size} items, #{ms}ms)")
      rescue ExternalTodo::Client::TimeoutError => e
        @run.increment_stat(:remote_calls)
        @run.increment_stat(:create_timeouts)
        Rails.logger.warn("[TodoSync] recreating list #{list.id} timed out; the Linker adopts it next cycle if it was created (#{e.message})")
        Failures.record(TodoList, list.id, e, run: @run)
      rescue ExternalTodo::Client::Error => e
        @run.increment_stat(:remote_calls)
        Failures.record(TodoList, list.id, e, run: @run)
      end

      def save(list, items, remote)
        by_id = remote.items.index_by { |remote_item| ExternalTodo::SourceId.parse(remote_item.source_id)&.last }
        unless items.all? { |item| by_id.key?(item.id) }
          # Not matchable: keep the old list, and the next snapshot will show two lists for the Linker to sort out.
          @run.increment_stat(:unpaired_items, items.size)
          Rails.logger.error("[TodoSync] recreated list #{list.id}: the API did not echo the item source_ids; leaving it to the Linker")
          return
        end

        old_external_id = list.external_id
        TodoList.transaction do
          # The old list must still be the one we point to, otherwise someone else already moved it.
          moved = TodoList.where(id: list.id, external_id: old_external_id).update_all(
            ["external_id = ?, remote_updated_at = ?, synced_version = MAX(synced_version, ?), " \
             "sync_attempts = 0, next_sync_at = NULL, sync_error = NULL",
             remote.external_id, remote.updated_at, list.local_version]
          )
          next if moved.zero?

          BulkWriter.mark_items_synced(
            items.map { |item| [item.id, by_id[item.id].external_id, by_id[item.id].updated_at, item.local_version] },
            mode: :relink
          )
          SyncTombstone.find_or_create_by!(record_type: "TodoList", external_id: old_external_id) do |tombstone|
            tombstone.remote_updated_at = list.remote_updated_at
          end
        end
        @run.increment_stat(:lists_recreated_remote)
      end
    end
  end
end
