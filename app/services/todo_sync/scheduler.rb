module TodoSync
  # Asks for a sync with a debounce: many requests in a burst enqueue a single job.
  #
  # The winner of a conditional UPDATE on sync_states.scheduled_at is the only one that enqueues
  # (same pattern as TodoList#acquire_mark_all_lock!). TodoSyncJob clears the mark when it starts,
  # so changes made while a cycle runs schedule the next one. A mark older than the stale limit
  # means the job was lost (the :async adapter forgets jobs on a Puma restart) and can be taken again.
  #
  # TODO: also request a sync when Puma boots, to recover what a restart lost. Puma 5.6 has no `on_booted`
  # hook; for now `bin/rails todo_sync:run` from cron is the safety net (see README/NOTES).
  module Scheduler
    DEBOUNCE = 5.seconds
    STALE_MARGIN = 1.minute
    MAX_RETRY_DELAY = 15.minutes

    module_function

    # Returns true if this call enqueued the job.
    def request!(reason:, wait: DEBOUNCE)
      return false unless Rails.configuration.x.todo_sync.enabled

      SyncState.instance
      now = Time.current
      won = SyncState.where(id: SyncState::SINGLETON_ID)
                     .where("scheduled_at IS NULL OR scheduled_at < ?", now - (wait + STALE_MARGIN))
                     .update_all(scheduled_at: now) == 1
      TodoSyncJob.set(wait: wait).perform_later(reason.to_s) if won
      won
    end

    def clear!
      SyncState.where(id: SyncState::SINGLETON_ID).update_all(scheduled_at: nil)
    end

    # Backoff with jitter after consecutive aborted or failed runs.
    def retry_delay
      failures = SyncRun.order(id: :desc).limit(10).pluck(:status).take_while { |status| %w[aborted failed].include?(status) }.size
      Backoff.delay([failures, 1].max, max: MAX_RETRY_DELAY)
    end
  end
end
