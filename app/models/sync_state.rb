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
  # How often long loops refresh the heartbeat: well below LOCK_STALE_AFTER, without a write per record.
  HEARTBEAT_EVERY = 30.seconds

  def self.acquire_lock!
    instance
    now = Time.current
    acquired = where(id: SINGLETON_ID)
               .where("lock_heartbeat_at IS NULL OR lock_heartbeat_at < ?", now - LOCK_STALE_AFTER)
               .update_all(lock_heartbeat_at: now) == 1
    @last_heartbeat_at = now if acquired
    acquired
  end

  def self.heartbeat!
    @last_heartbeat_at = Time.current
    where(id: SINGLETON_ID).update_all(lock_heartbeat_at: @last_heartbeat_at)
  end

  # Cheap to call from any loop or before any API call: writes at most every HEARTBEAT_EVERY.
  def self.heartbeat_if_due!
    heartbeat! if @last_heartbeat_at.nil? || @last_heartbeat_at < HEARTBEAT_EVERY.ago
  end

  def self.release_lock!
    where(id: SINGLETON_ID).update_all(lock_heartbeat_at: nil)
  end

  def self.locked?
    instance.lock_heartbeat_at.present? && instance.lock_heartbeat_at > LOCK_STALE_AFTER.ago
  end
end
