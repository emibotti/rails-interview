module TodoSync
  # Sends the remote DELETE for records deleted locally, then drops the tombstone.
  #
  # - A list tombstone covers its items (deleting a list remotely deletes them),
  #   so item tombstones of a deleted list are dropped without a call.
  # - A tombstone whose record is no longer in the snapshot needs no call either.
  # - 204 and 404 both mean "gone": the tombstone is dropped.
  class TombstonePusher
    def self.call(snapshot, run, client:)
      new(snapshot, run, client).call
    end

    def initialize(snapshot, run, client)
      @snapshot = snapshot
      @run = run
      @client = client
    end

    def call
      # Dead tombstones (too many attempts, or a 4xx) are kept and listed by todo_sync:failed, but not retried.
      due = SyncTombstone.where("next_attempt_at IS NULL OR next_attempt_at <= ?", Time.current)
                         .where("attempts < ?", Backoff.max_attempts).order(:id).to_a
      list_ids = due.select { |t| t.record_type == "TodoList" }.to_set(&:external_id)

      due.each do |tombstone|
        if tombstone.record_type == "TodoItem" && list_ids.include?(tombstone.list_external_id)
          drop(tombstone, :tombstones_coalesced)
        elsif already_gone?(tombstone)
          drop(tombstone, :skipped_noop)
        else
          delete_remote(tombstone)
        end
        SyncState.heartbeat_if_due!
      end
    end

    private

    def already_gone?(tombstone)
      if tombstone.record_type == "TodoList"
        !@snapshot.lists_by_external_id.key?(tombstone.external_id)
      else
        !@snapshot.items_by_external_id.key?(tombstone.external_id)
      end
    end

    def delete_remote(tombstone)
      begin
        if tombstone.record_type == "TodoList"
          @client.delete_todo_list(tombstone.external_id)
        else
          @client.delete_todo_item(tombstone.list_external_id, tombstone.external_id)
        end
      rescue ExternalTodo::Client::NotFoundError
        nil # already deleted: same outcome
      end
      @run.increment_stat(:remote_calls)
      @run.increment_stat(tombstone.record_type == "TodoList" ? :lists_deleted_remote : :items_deleted_remote)
      OperationLog.success(@client, "DELETE #{tombstone.record_type.sub('Todo', '').downcase}", local: "-", remote: tombstone.external_id)
      tombstone.destroy!
    rescue ExternalTodo::Client::Error => e
      @run.increment_stat(:remote_calls)
      Failures.record_tombstone(tombstone, e, run: @run)
    end

    def drop(tombstone, stat)
      @run.increment_stat(stat)
      Rails.logger.info("[TodoSync] dropping tombstone #{tombstone.record_type} #{tombstone.external_id} (#{stat})")
      tombstone.destroy!
    end
  end
end
