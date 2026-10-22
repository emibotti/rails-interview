module TodoSync
  # Records that gave up (too many attempts, or a 4xx the API will keep rejecting). They keep their data and
  # their error, the pushers skip them, and an operator decides: fix the cause and `retry_all!`.
  module DeadLetters
    module_function

    # [[type, id_or_external_id, error], ...]
    def all
      [TodoList, TodoItem].flat_map do |model|
        model.dead_letters.order(:id).map { |record| [model.name, record.id, record.sync_error] }
      end + SyncTombstone.where("attempts >= ?", Backoff.max_attempts).order(:id).map do |tombstone|
        ["SyncTombstone", tombstone.external_id, tombstone.last_error]
      end
    end

    # Puts every dead letter back in play. Returns how many were reset.
    def retry_all!
      reset = Syncable::SYNC_OK
      count = [TodoList, TodoItem].sum { |model| model.dead_letters.update_all(reset) }
      count + SyncTombstone.where("attempts >= ?", Backoff.max_attempts).update_all(attempts: 0, next_attempt_at: nil, last_error: nil)
    end
  end
end
