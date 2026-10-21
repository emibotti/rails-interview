# One row per sync cycle: trigger, outcome, counters and error.
class SyncRun < ApplicationRecord
  STATUSES = %w[running succeeded failed aborted aborted_deletions].freeze

  validates :status, inclusion: { in: STATUSES }

  def self.start!(trigger)
    create!(trigger: trigger.to_s, status: "running", started_at: Time.current)
  end

  def finish!(status, error: nil)
    update!(status: status.to_s, finished_at: Time.current, error: error)
  end

  def increment_stat(key, by = 1)
    self.stats = stats.merge(key.to_s => stats.fetch(key.to_s, 0) + by)
  end
end
