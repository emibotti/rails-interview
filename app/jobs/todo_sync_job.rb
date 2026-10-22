# Trigger for a sync cycle. It takes no record ids: what to sync lives in the database
# (dirty records, tombstones), so a lost job loses nothing; the next request or the
# periodic `todo_sync:run` picks it all up. Never raises: errors are logged and rescheduled.
class TodoSyncJob < ApplicationJob
  queue_as :default

  def perform(reason = "scheduled")
    # Changes made from now on schedule another run.
    TodoSync::Scheduler.clear!

    result = TodoSync::Runner.call(trigger: reason)
    if result == :busy
      # Another cycle holds the lock and may have read stale state: ask again instead of dropping the request.
      TodoSync::Scheduler.request!(reason: reason)
    elsif result.status.in?(%w[aborted failed])
      TodoSync::Scheduler.request!(reason: "retry_after_#{result.status}", wait: TodoSync::Scheduler.retry_delay)
    end
  rescue StandardError => e
    Rails.logger.error("[TodoSync] job crashed: #{e.class}: #{e.message}")
    TodoSync::Scheduler.request!(reason: "retry_after_error", wait: TodoSync::Scheduler.retry_delay)
  end
end
