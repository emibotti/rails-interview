# Change tracking for records synced with the External Todo API.
#
# - `local_version` is bumped on every local change of a synced field. A record
#   is dirty while `local_version > synced_version`.
# - Deleting a record that was synced leaves a SyncTombstone, so the remote
#   DELETE can still be sent and the next pull doesn't bring the record back.
#
# Callbacks don't run for update_all / insert_all / update_columns. That is
# intentional for the sync itself (no echo), and bulk local writes must bump
# local_version by hand (see CompleteAllTodoItemsJob).
module Syncable
  extend ActiveSupport::Concern

  # Written together with synced_version when an operation succeeds: forgets previous failures.
  SYNC_OK = { sync_attempts: 0, next_sync_at: nil, sync_error: nil }.freeze

  included do
    before_update :bump_local_version, if: :sync_relevant_changes?
    after_destroy :record_tombstone, if: :external_id?

    # Ask for a (debounced) sync once the change is committed. Bulk writes skip these callbacks
    # and ask once at the end by themselves (CompleteAllTodoItemsJob, dev:seed_items).
    after_create_commit { request_sync(:created) }
    after_update_commit(if: :sync_relevant_saved_changes?) { request_sync(:updated) }
    after_destroy_commit(if: :external_id?) { request_sync(:destroyed) }

    # Records the pushers may try now: not waiting for a retry and not a dead letter.
    scope :ready_to_sync, lambda {
      where("#{table_name}.next_sync_at IS NULL OR #{table_name}.next_sync_at <= ?", Time.current)
        .where("#{table_name}.sync_attempts < ?", TodoSync::Backoff.max_attempts)
    }
    scope :dead_letters, -> { where("#{table_name}.sync_attempts >= ?", TodoSync::Backoff.max_attempts) }
    scope :dirty, -> { where("#{table_name}.local_version > #{table_name}.synced_version") }
    scope :linked, -> { where.not(external_id: nil) }
    scope :unlinked, -> { where(external_id: nil) }
  end

  class_methods do
    # Attributes whose local changes must reach the external API.
    def sync_attributes
      %w[name]
    end
  end

  def dirty_for_sync?
    local_version > synced_version
  end

  private

  def sync_relevant_changes?
    self.class.sync_attributes.any? { |attribute| will_save_change_to_attribute?(attribute) }
  end

  def sync_relevant_saved_changes?
    self.class.sync_attributes.any? { |attribute| saved_change_to_attribute?(attribute) }
  end

  # Runs after the change was committed: a failure here must not turn a successful write into a 500 for the
  # client. The periodic todo_sync:run picks up whatever this request would have scheduled.
  def request_sync(action)
    TodoSync::Scheduler.request!(reason: "#{self.class.name.underscore}_#{action}")
  rescue StandardError => e
    Rails.logger.error("[TodoSync] could not request a sync after #{self.class.name} #{action}: #{e.class}: #{e.message}")
  end

  def bump_local_version
    self.local_version += 1
  end

  def record_tombstone
    SyncTombstone.find_or_create_by!(record_type: self.class.name, external_id: external_id) do |tombstone|
      tombstone.list_external_id = tombstone_list_external_id
      tombstone.remote_updated_at = remote_updated_at
    end
  end

  def tombstone_list_external_id
    nil
  end
end
