module TodoSync
  # Protects against an empty or truncated snapshot wiping the local database:
  # the API has no tombstones, so "missing from the snapshot" is the only signal
  # of a remote delete, and a bad response looks exactly like a mass delete.
  #
  # Deletions are refused when the snapshot is empty but we have linked lists, or
  # when too many linked lists are missing (thresholds in config.x.todo_sync).
  module DeletionGuard
    module_function

    def allow?(snapshot)
      linked = TodoList.linked.pluck(:external_id)
      return true if linked.empty?

      if snapshot.lists.empty?
        Rails.logger.error("[TodoSync] deletion guard: empty snapshot but #{linked.size} linked lists; refusing to delete locally")
        return false
      end

      config = Rails.configuration.x.todo_sync
      missing = linked.count { |external_id| !snapshot.lists_by_external_id.key?(external_id) }
      if linked.size >= config.guard_min_linked && missing.fdiv(linked.size) > config.guard_max_missing_ratio
        Rails.logger.error("[TodoSync] deletion guard: #{missing} of #{linked.size} linked lists are missing from the snapshot; " \
                           "refusing to delete locally")
        return false
      end

      true
    end
  end
end
