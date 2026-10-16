class TodoList < ApplicationRecord
  # A mark all lock whose heartbeat is older than this is considered abandoned
  # (e.g. the process running the job died) and can be taken again.
  MARK_ALL_STALE_AFTER = 2.minutes

  has_many :todo_items, dependent: :destroy

  validates :name, presence: true

  def mark_all_running?
    mark_all_heartbeat_at.present? && mark_all_heartbeat_at > MARK_ALL_STALE_AFTER.ago
  end

  # Atomically takes the lock with a conditional UPDATE, so two concurrent
  # requests can't both start a mark all on the same list.
  def acquire_mark_all_lock!
    now = Time.current
    acquired = TodoList
      .where(id: id)
      .where('mark_all_heartbeat_at IS NULL OR mark_all_heartbeat_at < ?', now - MARK_ALL_STALE_AFTER)
      .update_all(mark_all_heartbeat_at: now) == 1

    self.mark_all_heartbeat_at = now if acquired
    acquired
  end

  def mark_all_heartbeat!
    update_columns(mark_all_heartbeat_at: Time.current)
  end

  def release_mark_all_lock!
    update_columns(mark_all_heartbeat_at: nil)
  end
end
