module TodoSync
  module ItemCreation
    # One POST per item against the proposed POST /todolists/{id}/todoitems.
    # A timeout is not retried: the next snapshot contains the item with our source_id and the Linker binds it.
    class ApiEndpoint
      def self.call(snapshot, run, client:)
        new(run, client).call
      end

      def initialize(run, client)
        @run = run
        @client = client
      end

      def call
        ItemCreation.lists_with_unlinked_items.each do |list|
          ItemCreation.clear_errors(list.id)
          TodoItem.unlinked.ready_to_sync.where(todo_list_id: list.id).select(:id, :name, :completed, :local_version).find_each do |item|
            create(list, item)
            SyncState.heartbeat!
            Thread.pass
          end
        end
      end

      private

      def create(list, item)
        remote = @client.create_todo_item(list.external_id, name: item.name, completed: item.completed,
                                                            source_id: ExternalTodo::SourceId.for(item))
        @run.increment_stat(:remote_calls)
        # synced_version = the version sent, so an edit during the request leaves the item dirty.
        TodoItem.where(id: item.id, external_id: nil).where("synced_version < ?", item.local_version)
                .update_all(external_id: remote.external_id, remote_updated_at: remote.updated_at, synced_version: item.local_version, **Syncable::SYNC_OK)
        @run.increment_stat(:items_created_remote)
        OperationLog.success(@client, "POST item", local: item.id, remote: remote.external_id, detail: "(list #{list.id})")
      rescue ExternalTodo::Client::TimeoutError => e
        @run.increment_stat(:remote_calls)
        @run.increment_stat(:create_timeouts)
        Rails.logger.warn("[TodoSync] POST item #{item.id} timed out; it will be linked by source_id if it was created (#{e.message})")
        Failures.record(TodoItem, item.id, e, run: @run)
      rescue ExternalTodo::Client::Error => e
        @run.increment_stat(:remote_calls)
        Failures.record(TodoItem, item.id, e, run: @run)
      end
    end
  end
end
