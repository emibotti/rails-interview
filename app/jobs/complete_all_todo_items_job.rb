# Marks as completed every pending item of a list with id <= up_to_id.
#
# Items are updated in batches with a single UPDATE each, without a wrapping
# transaction, so SQLite's write lock is released between batches. Filtering by
# completed: false makes the job idempotent and safe to retry.
class CompleteAllTodoItemsJob < ApplicationJob
  BATCH_SIZE = 1000

  queue_as :default

  discard_on ActiveJob::DeserializationError

  retry_on ActiveRecord::StatementInvalid, wait: 1.second, attempts: 3 do |job, _error|
    todo_list = job.arguments.first
    todo_list.release_mark_all_lock!
    job.broadcast_status(todo_list, state: :failed)
  end

  def perform(todo_list, up_to_id)
    scope = todo_list.todo_items.where(completed: false, id: ..up_to_id)
    total = scope.count
    processed = 0

    broadcast_status(todo_list, state: :running, processed: processed, total: total)

    scope.in_batches(of: BATCH_SIZE) do |batch|
      processed += batch.update_all(completed: true, updated_at: Time.current)
      todo_list.mark_all_heartbeat!
      broadcast_status(todo_list, state: :running, processed: processed, total: total)

      # SQLite runs in-process and holds the GVL, so this loop would starve the
      # Puma threads it shares the process with (async adapter) until it ends.
      Thread.pass
    end

    todo_list.release_mark_all_lock!
    broadcast_status(todo_list, state: :done, processed: processed, total: total)
  end

  def broadcast_status(todo_list, **locals)
    Turbo::StreamsChannel.broadcast_replace_to(
      todo_list,
      target: ActionView::RecordIdentifier.dom_id(todo_list, :mark_all_status),
      partial: 'todo_lists/mark_all_status',
      locals: { todo_list: todo_list, **locals }
    )
  end
end
