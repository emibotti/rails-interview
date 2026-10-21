# Single row holding the sync coordination state: the debounce mark and the
# global lock (with heartbeat, like the mark all lock of TodoList).
class SyncState < ApplicationRecord
  SINGLETON_ID = 1
  # A lock whose heartbeat is older than this is considered abandoned.
  LOCK_STALE_AFTER = 5.minutes

  def self.instance
    find_or_create_by!(id: SINGLETON_ID)
  rescue ActiveRecord::RecordNotUnique
    find(SINGLETON_ID)
  end

  # Atomically takes the lock with a conditional UPDATE.
  def self.acquire_lock!
    instance
    now = Time.current
    where(id: SINGLETON_ID)
      .where("lock_heartbeat_at IS NULL OR lock_heartbeat_at < ?", now - LOCK_STALE_AFTER)
      .update_all(lock_heartbeat_at: now) == 1
  end

  def self.heartbeat!
    where(id: SINGLETON_ID).update_all(lock_heartbeat_at: Time.current)
  end

  def self.release_lock!
    where(id: SINGLETON_ID).update_all(lock_heartbeat_at: nil)
  end

  def self.locked?
    instance.lock_heartbeat_at.present? && instance.lock_heartbeat_at > LOCK_STALE_AFTER.ago
  end
end
