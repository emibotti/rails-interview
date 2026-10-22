module TodoSync
  # Binds remote records that we created (their source_id is ours) to the local
  # record they came from, without creating anything.
  #
  # This is what makes creates idempotent without an Idempotency-Key: if a POST
  # timed out but the server did create the list, the next snapshot contains it
  # with our source_id and we just store its remote id instead of posting again.
  #
  # synced_version is not touched: the UpdatePusher compares the record with the
  # snapshot and marks it as synced when nothing differs (no API call).
  class Linker
    def self.call(snapshot, run)
      new(snapshot, run).call
    end

    def initialize(snapshot, run)
      @snapshot = snapshot
      @run = run
    end

    def call
      @snapshot.lists_by_source_id.each do |local_id, remote_lists|
        local_list = TodoList.select(:id, :external_id).find_by(id: local_id)
        next remote_lists.each { |remote_list| orphan("list", remote_list) } unless local_list

        remote_lists.each do |remote_list|
          link_list(local_list, remote_list)
          link_items(local_list, remote_list) if linked_to?(local_list, remote_list)
        end
      end
    end

    private

    def link_list(local_list, remote_list)
      if local_list.external_id.nil?
        link(TodoList, local_list.id, remote_list)
        @run.increment_stat(:lists_linked)
      elsif local_list.external_id != remote_list.external_id
        duplicate(local_list, remote_list)
      end
    end

    # Two remote lists carry the source_id of the same local list. If the one the
    # local record points to is still in the snapshot, the other is a duplicate
    # we created (an ambiguous POST, or a list recreated by the item creation
    # strategy) and gets deleted through a tombstone.
    def duplicate(local_list, remote_list)
      return relink_to_recreated(local_list, remote_list) if recreated?(local_list, remote_list)

      unless @snapshot.lists_by_external_id.key?(local_list.external_id)
        Rails.logger.warn("[TodoSync] remote list #{remote_list.external_id} has the source_id of local list " \
                          "#{local_list.id}, which points to #{local_list.external_id} (not in the snapshot); leaving it alone")
        return
      end

      SyncTombstone.find_or_create_by!(record_type: "TodoList", external_id: remote_list.external_id) do |tombstone|
        tombstone.remote_updated_at = remote_list.updated_at
      end
      @run.increment_stat(:duplicates_found)
      Rails.logger.warn("[TodoSync] remote list #{remote_list.external_id} duplicates local list #{local_list.id} " \
                        "(linked to #{local_list.external_id}); scheduled for deletion")
    end

    # The item creation strategy `recreate_list` POSTs a new list with all the items. If that POST timed out,
    # the new list exists remotely but the local list still points to the old one. The new one is recognisable
    # because it contains local items that are not linked yet (the reason for recreating in the first place).
    def recreated?(local_list, remote_list)
      unlinked_ids = TodoItem.where(todo_list_id: local_list.id, external_id: nil).pluck(:id).to_set
      remote_list.items.any? { |item| unlinked_ids.include?(ExternalTodo::SourceId.parse(item.source_id)&.last) }
    end

    # Adopts the recreated list and schedules the old one for deletion.
    # Versions are not touched: the UpdatePusher diffs against the snapshot and sends what differs.
    def relink_to_recreated(local_list, remote_list)
      old_external_id = local_list.external_id
      TodoList.transaction do
        old = @snapshot.lists_by_external_id[old_external_id]
        SyncTombstone.find_or_create_by!(record_type: "TodoList", external_id: old_external_id) do |tombstone|
          tombstone.remote_updated_at = old&.updated_at
        end
        TodoList.where(id: local_list.id).update_all(external_id: remote_list.external_id, remote_updated_at: remote_list.updated_at)

        own_item_ids = TodoItem.where(todo_list_id: local_list.id).pluck(:id).to_set
        rows = remote_list.items.filter_map do |remote_item|
          kind, item_id = ExternalTodo::SourceId.parse(remote_item.source_id)
          next unless kind == :item && own_item_ids.include?(item_id) && remote_item.external_id.present?

          [item_id, remote_item.external_id, remote_item.updated_at, 0]
        end
        BulkWriter.mark_items_synced(rows, mode: :retarget)
      end
      local_list.external_id = remote_list.external_id
      @run.increment_stat(:lists_relinked)
      Rails.logger.warn("[TodoSync] local list #{local_list.id} adopted the recreated remote list #{remote_list.external_id}; " \
                        "#{old_external_id} scheduled for deletion")
    end

    def linked_to?(local_list, remote_list)
      local_list.external_id.nil? || local_list.external_id == remote_list.external_id
    end

    def link_items(local_list, remote_list)
      remote_list.items.each do |remote_item|
        kind, local_id = ExternalTodo::SourceId.parse(remote_item.source_id)
        next unless kind == :item && remote_item.external_id.present?

        # Only items of this very list; the unlinked condition keeps it idempotent.
        linked = link(TodoItem, local_id, remote_item, todo_list_id: local_list.id)
        @run.increment_stat(:items_linked) if linked == 1
      end
    end

    # Stores the remote id (and timestamp) on an unlinked local row. Skips the
    # row if it was deleted, linked meanwhile or belongs to another list.
    def link(model, local_id, remote, **conditions)
      linked = model.where(id: local_id, external_id: nil, **conditions)
                    .update_all(external_id: remote.external_id, remote_updated_at: remote.updated_at, **Syncable::SYNC_OK)
      Rails.logger.info("[TodoSync] linked #{model.name} #{local_id} -> #{remote.external_id}") if linked == 1
      linked
    end

    # The source_id says the record is ours but there is no such local record.
    # Most likely it was deleted locally before it was ever synced. We don't
    # delete it remotely: the prefix alone can't tell it from a record of
    # another environment sharing the same remote.
    def orphan(kind, remote)
      @run.increment_stat(:orphans)
      Rails.logger.warn("[TodoSync] remote #{kind} #{remote.external_id} has our source_id #{remote.source_id} " \
                        "but no local record; leaving it alone")
    end
  end
end
