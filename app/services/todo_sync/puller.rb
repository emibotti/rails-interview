module TodoSync
  # Applies the remote snapshot to the local database (remote -> local).
  #
  # Everything is written with insert_all / update_all so no callbacks run: a
  # remote change must not bump local_version nor trigger another sync (D7).
  # Local edits are protected with a conditional UPDATE on local_version.
  #
  # Records linked locally that are missing from the snapshot were deleted remotely and are deleted
  # here too (delete wins), but only when `deletions_allowed` (see DeletionGuard). Remote records with
  # a pending tombstone were deleted locally and are not brought back.
  # Conflicts (both sides changed with different values) are decided at record level: the most recent
  # updated_at wins, and a tie goes to the remote (deterministic). When the remote wins it is applied here;
  # when the local wins the record stays dirty and the UpdatePusher sends it. A delete beats an edit on either side.
  class Puller
    BATCH_SIZE = 1000
    LIST_COLUMNS = %i[id name external_id local_version synced_version remote_updated_at updated_at].freeze
    ITEM_COLUMNS = (LIST_COLUMNS + %i[completed]).freeze

    def self.call(snapshot, run, deletions_allowed: true)
      new(snapshot, run, deletions_allowed).call
    end

    def initialize(snapshot, run, deletions_allowed)
      @snapshot = snapshot
      @run = run
      @deletions_allowed = deletions_allowed
    end

    def call
      local_lists = TodoList.linked.select(*LIST_COLUMNS).index_by(&:external_id)
      @tombstones = SyncTombstone.pluck(:record_type, :external_id, :remote_updated_at)
                                 .to_h { |type, external_id, updated_at| [[type, external_id], updated_at] }

      @snapshot.lists.each do |remote_list|
        TodoList.transaction { pull_list(remote_list, local_lists[remote_list.external_id]) }
        # Share the GVL with Puma's request threads, like CompleteAllTodoItemsJob.
        Thread.pass
      end

      delete_lists_missing_remotely(local_lists)
    end

    private

    def pull_list(remote_list, local_list)
      return skip_tombstoned("TodoList", remote_list) if tombstoned?("TodoList", remote_list)
      return skip_invalid("list", remote_list) if remote_list.name.blank?

      if local_list
        pull_known_list(remote_list, local_list)
      elsif ours?(remote_list)
        # Created by us (e.g. a POST that timed out): the Linker binds it to its local record.
        pending_link("list", remote_list)
      else
        create_list(remote_list)
      end
    end

    def create_list(remote_list)
      now = Time.current
      TodoList.insert_all!([synced_row(remote_list, now, name: remote_list.name, external_id: remote_list.external_id)])
      list_id = TodoList.where(external_id: remote_list.external_id).pick(:id)
      insert_items(list_id, remote_list.items, check_ours: false)

      @run.increment_stat(:lists_created_local)
      Rails.logger.info("[TodoSync] pulled new list #{list_id} <- #{remote_list.external_id}")
    end

    def pull_known_list(remote_list, local_list)
      reconcile(TodoList, local_list, remote_list, { name: remote_list.name }, "list")

      local_items = TodoItem.where(todo_list_id: local_list.id).linked.select(*ITEM_COLUMNS).index_by(&:external_id)
      new_items = []
      remote_list.items.each do |remote_item|
        local_item = local_items[remote_item.external_id]
        if local_item
          next skip_invalid("item", remote_item) if remote_item.name.blank?

          reconcile(TodoItem, local_item, remote_item, item_values(remote_item, local_item), "item")
        else
          new_items << remote_item
        end
      end
      insert_items(local_list.id, new_items, check_ours: true)
      delete_items_missing_remotely(local_items, remote_list)
    end

    def delete_lists_missing_remotely(local_lists)
      return unless @deletions_allowed

      local_lists.each_value do |local_list|
        next if @snapshot.lists_by_external_id.key?(local_list.external_id)

        dirty_items = TodoItem.where(todo_list_id: local_list.id).dirty.count
        TodoList.transaction do
          TodoItem.where(todo_list_id: local_list.id).delete_all
          TodoList.where(id: local_list.id).delete_all
        end
        @run.increment_stat(:lists_deleted_local)
        warn_lost_changes("list", local_list, dirty_items: dirty_items)
      end
    end

    def delete_items_missing_remotely(local_items, remote_list)
      return unless @deletions_allowed

      remote_ids = remote_list.items.to_set(&:external_id)
      missing = local_items.values.reject { |item| remote_ids.include?(item.external_id) }
      return if missing.empty?

      missing.each_slice(BATCH_SIZE) { |batch| TodoItem.where(id: batch.map(&:id)).delete_all }
      @run.increment_stat(:items_deleted_local, missing.size)
      missing.each { |item| warn_lost_changes("item", item) }
    end

    # Delete wins over a pending local edit; say what was lost.
    def warn_lost_changes(kind, local, dirty_items: 0)
      message = "#{kind} #{local.id} (#{local.external_id}) was deleted remotely and deleted locally"
      lost = []
      lost << "its own unsynced changes (v#{local.local_version})" if local.local_version > local.synced_version
      lost << "#{dirty_items} items with unsynced local changes" if dirty_items.positive?
      if lost.any?
        Rails.logger.warn("[TodoSync] delete wins: #{message}, dropping #{lost.join(' and ')}")
      else
        Rails.logger.info("[TodoSync] #{message}")
      end
    end

    def tombstoned?(type, remote)
      @tombstones.key?([type, remote.external_id])
    end

    # Deleted locally but not yet deleted remotely: don't resurrect it.
    def skip_tombstoned(type, remote)
      deleted_at = @tombstones[[type, remote.external_id]]
      if deleted_at && remote.updated_at && remote.updated_at > deleted_at
        Rails.logger.warn("[TodoSync] delete wins: remote #{type} #{remote.external_id} was edited after the local delete; deleting it anyway")
      end
      @run.increment_stat(:skipped_tombstoned)
      nil
    end

    # Compares the remote record against the local one and applies the remote
    # values when it is safe to do so.
    def reconcile(model, local, remote, values, kind)
      return if remote.updated_at && same_time?(local.remote_updated_at, remote.updated_at)

      remote_updated_at = remote.updated_at || Time.current
      return model.where(id: local.id).update_all(remote_updated_at: remote_updated_at) if values.all? { |k, v| local[k] == v }

      if local.local_version > local.synced_version
        # Both sides changed and the values differ: last write wins.
        @run.increment_stat(:conflicts)
        unless remote_wins?(local, remote)
          Rails.logger.warn("[TodoSync] conflict on #{kind} #{local.id}: local is newer (#{local.updated_at.utc.iso8601(3)} > " \
                            "#{remote.updated_at&.utc&.iso8601(3)}); keeping it, the push will overwrite the remote")
          return
        end
        Rails.logger.warn("[TodoSync] conflict on #{kind} #{local.id}: remote is newer or equal; discarding the local change (v#{local.local_version})")
      end

      # Conditional on local_version: if the user edited the record after we
      # read it, nothing is updated and the next cycle re-evaluates.
      updated = model.where(id: local.id, local_version: local.local_version).update_all(
        values.merge(synced_version: local.local_version, remote_updated_at: remote_updated_at, updated_at: remote_updated_at)
      )
      if updated == 1
        @run.increment_stat(:"#{kind}s_updated_local")
        Rails.logger.info("[TodoSync] pulled #{kind} #{local.id} <- #{remote.external_id}")
      else
        Rails.logger.info("[TodoSync] #{kind} #{local.id} was edited during the pull; will re-evaluate next cycle")
      end
    end

    def insert_items(list_id, remote_items, check_ours:)
      now = Time.current
      rows = remote_items.filter_map do |remote_item|
        next skip_tombstoned("TodoItem", remote_item) if tombstoned?("TodoItem", remote_item)
        next skip_invalid("item", remote_item) if remote_item.external_id.blank? || remote_item.name.blank?
        next pending_link("item", remote_item) if check_ours && ours?(remote_item)

        synced_row(remote_item, now, name: remote_item.name, external_id: remote_item.external_id,
                                     todo_list_id: list_id, completed: remote_item.completed || false)
      end

      rows.each_slice(BATCH_SIZE) { |batch| TodoItem.insert_all!(batch) }
      @run.increment_stat(:items_created_local, rows.size) if rows.any?
    end

    # A row born in sync with the remote: not dirty, remote timestamps kept.
    def synced_row(remote, now, **attributes)
      attributes.merge(
        local_version: 1, synced_version: 1,
        remote_updated_at: remote.updated_at || now,
        created_at: remote.created_at || now,
        updated_at: remote.updated_at || now
      )
    end

    def item_values(remote_item, local_item)
      { name: remote_item.name, completed: remote_item.completed.nil? ? local_item.completed : remote_item.completed }
    end

    def ours?(remote)
      ExternalTodo::SourceId.parse(remote.source_id).present?
    end

    def skip_invalid(kind, remote)
      @run.increment_stat(:skipped_invalid)
      Rails.logger.warn("[TodoSync] skipping remote #{kind} #{remote.external_id.inspect}: blank name or missing id")
      nil
    end

    def pending_link(kind, remote)
      @run.increment_stat(:pending_link)
      Rails.logger.info("[TodoSync] remote #{kind} #{remote.external_id} is ours (#{remote.source_id}); waiting to be linked")
      nil
    end

    # The remote wins when it is at least as recent as the local edit (a tie goes to the remote).
    # Compared to the millisecond, the precision of the wire format. Without a remote updated_at there is
    # nothing to compare, so the local change is kept rather than silently discarded.
    def remote_wins?(local, remote)
      remote.updated_at.present? && remote.updated_at.to_f.round(3) >= local.updated_at.to_f.round(3)
    end

    def same_time?(a, b)
      a.present? && b.present? && (a.to_f - b.to_f).abs < 0.001
    end
  end
end
