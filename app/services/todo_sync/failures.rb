module TodoSync
  # Records why a remote operation failed, per record, so one bad record never blocks the rest.
  #
  # - Retryable errors (connection, timeouts, 408/429/5xx, invalid responses): attempts + 1 and
  #   `next_sync_at` with exponential backoff and jitter. At max_attempts the record becomes a dead letter.
  # - Client errors (other 4xx, e.g. 422): retrying cannot help, so the record is a dead letter immediately.
  #
  # A dead letter keeps its local data and its error, is skipped by the pushers and is listed by
  # `todo_sync:failed`; `todo_sync:retry_failed` puts it back in play. Success resets all of it (see Syncable::SYNC_OK).
  module Failures
    module_function

    def record(model, id, error, run:)
      attempts = model.where(id: id).pick(:sync_attempts)
      return unless attempts # the record is gone

      attempts, next_at, dead = outcome(attempts + 1, error)
      model.where(id: id).update_all(sync_attempts: attempts, next_sync_at: next_at, sync_error: describe(error, dead, attempts))
      count(run, model.name, id, error, dead, attempts, next_at)
    end

    def record_tombstone(tombstone, error, run:)
      attempts, next_at, dead = outcome(tombstone.attempts + 1, error)
      tombstone.update!(attempts: attempts, next_attempt_at: next_at, last_error: describe(error, dead, attempts))
      count(run, "tombstone #{tombstone.record_type}", tombstone.external_id, error, dead, attempts, next_at)
    end

    # [attempts, next_attempt_at, dead?]
    def outcome(attempts, error)
      max = Backoff.max_attempts
      dead = error.is_a?(ExternalTodo::Client::ClientError) || attempts >= max
      attempts = max if dead
      [attempts, (Time.current + Backoff.delay(attempts) unless dead), dead]
    end

    def describe(error, dead, attempts)
      prefix = dead ? "dead letter after #{attempts} attempt#{'s' unless attempts == 1}: " : ""
      "#{prefix}#{error.message}".truncate(500)
    end

    def count(run, what, id, error, dead, attempts, next_at)
      run.increment_stat(:failures)
      run.increment_stat(:dead_letters) if dead
      if dead
        Rails.logger.error("[TodoSync] #{what} #{id} is now a dead letter: #{error.message}")
      else
        Rails.logger.error("[TodoSync] #{what} #{id} failed (attempt #{attempts}), next try after #{next_at.utc.iso8601}: #{error.message}")
      end
    end
  end
end
