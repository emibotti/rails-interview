# Backport of the SQLite3 connection setup of Rails 8.0 (with sqlite3 >= 2.1).
# Remove this file when upgrading to Rails 8.0.
#
# With Rails 7.0 and the sqlite3 1.x gem, `timeout` in database.yml uses
# sqlite3_busy_timeout, which waits for a lock while holding Ruby's GVL. Jobs
# run inside the Puma process (async adapter), so a writer waiting for a lock
# can block the very thread that would release it, freezing both until the
# timeout expires and failing with "database is locked".
#
# - The busy handler waits with Ruby's sleep, releasing the GVL meanwhile, like
#   Rails 8.0's `busy_handler_timeout`.
# - WAL lets readers and the (single) writer work without blocking each other
#   (a default since Rails 7.1).
ActiveSupport.on_load(:active_record_sqlite3adapter) do
  prepend(Module.new do
    private

    def configure_connection
      super

      if (timeout = self.class.type_cast_config_to_integer(@config[:timeout]))
        timeout_in_seconds = timeout / 1000.0
        started_at = nil

        # Replaces the busy timeout set by super.
        @connection.busy_handler do |count|
          now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          started_at = now if count.zero?

          next false if now - started_at > timeout_in_seconds

          sleep(0.001)
          true
        end
      end

      execute('PRAGMA journal_mode = WAL', 'SCHEMA')
      execute('PRAGMA synchronous = NORMAL', 'SCHEMA')
    end
  end)
end
