module TodoSync
  # Runs one sync cycle under the global lock and records it in a SyncRun.
  # TODO: add the circuit breaker (step 10) and the entry points (job, scheduler, rake tasks: step 9).
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

      deletions_allowed = DeletionGuard.allow?(snapshot)

      Linker.call(snapshot, run)
      Puller.call(snapshot, run, deletions_allowed: deletions_allowed)
      TombstonePusher.call(snapshot, run, client: @client)
      CreatePusher.call(snapshot, run, client: @client)
      ItemCreation.call(snapshot, run, client: @client)
      # A recreated list leaves a tombstone for the old one: send that DELETE in this same cycle.
      TombstonePusher.call(snapshot, run, client: @client) if run.stats["lists_recreated_remote"]
      UpdatePusher.call(snapshot, run, client: @client)

      status = deletions_allowed ? :succeeded : :aborted_deletions
      run.finish!(status)
      Rails.logger.info("[TodoSync] run #{run.id} #{status}: #{run.stats}")
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
