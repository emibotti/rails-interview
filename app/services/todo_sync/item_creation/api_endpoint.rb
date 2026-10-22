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
          TodoItem.unlinked.where(todo_list_id: list.id).select(:id, :name, :completed, :local_version).find_each do |item|
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
                .update_all(external_id: remote.external_id, remote_updated_at: remote.updated_at, synced_version: item.local_version)
        @run.increment_stat(:items_created_remote)
        Rails.logger.info("[TodoSync] POST item #{item.id} in list #{list.id} -> #{remote.external_id}")
      rescue ExternalTodo::Client::TimeoutError => e
        @run.increment_stat(:remote_calls)
        @run.increment_stat(:create_timeouts)
        Rails.logger.warn("[TodoSync] POST item #{item.id} timed out; it will be linked by source_id if it was created (#{e.message})")
      rescue ExternalTodo::Client::Error => e
        # TODO: per-record backoff and dead letters instead of just counting the failure (step 10).
        @run.increment_stat(:remote_calls)
        @run.increment_stat(:failures)
        Rails.logger.error("[TodoSync] POST item #{item.id} in list #{list.id} failed: #{e.message}")
      end
    end
  end
end
