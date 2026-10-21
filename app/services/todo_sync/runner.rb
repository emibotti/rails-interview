module TodoSync
  # Runs one sync cycle under the global lock and records it in a SyncRun.
  # TODO: the cycle is only snapshot (one GET) + pull. Add link, tombstone/create/update pushes and the
  # item-creation strategy (steps 4 to 8), the deletion guard and the circuit breaker (steps 6 and 10).
  class Runner
    def self.call(trigger:, client: ExternalTodo::Client.build)
      new(trigger: trigger, client: client).call
    end

    def initialize(trigger:, client:)
      @trigger = trigger
      @client = client
    end

    # Returns the SyncRun, or :busy when another cycle holds the lock.
    def call
      return :busy unless SyncState.acquire_lock!

      run = SyncRun.start!(@trigger)
      Rails.logger.tagged("todo_sync", "run=#{run.id}") { execute(run) }
      run
    ensure
      SyncState.release_lock! if run
    end

    private

    def execute(run)
      snapshot = Snapshot.new(@client.list_todo_lists)
      run.increment_stat(:remote_calls)

      Puller.call(snapshot, run)
      run.finish!(:succeeded)
      Rails.logger.info("[TodoSync] run #{run.id} succeeded: #{run.stats}")
    rescue ExternalTodo::Client::Error => e
      # Without a fresh snapshot nothing else is safe to do: abort the cycle.
      Rails.logger.error("[TodoSync] run #{run.id} aborted: #{e.message}")
      run.finish!(:aborted, error: e.message)
    rescue StandardError => e
      Rails.logger.error("[TodoSync] run #{run.id} failed: #{e.class}: #{e.message}")
      run.finish!(:failed, error: "#{e.class}: #{e.message}")
      raise
    end
  end
end
