module TodoSync
  # One log line per remote operation that went through: what it was, which local and remote record it
  # concerned and how the HTTP call ended. Failures are logged by Failures with the error message
  # (method, path, status and truncated body).
  #
  #   [todo_sync] [run=7] [TodoSync] PATCH item local=42 remote=9f3c... -> 200 (1 attempt, 83ms)
  module OperationLog
    module_function

    def success(client, op, local:, remote:, detail: nil)
      request = client.last_request
      outcome = request ? "#{request.status} (#{request.attempts} attempt#{'s' unless request.attempts == 1}, #{request.duration_ms}ms)" : "ok"
      Rails.logger.info("[TodoSync] #{op} local=#{local} remote=#{remote} -> #{outcome}#{" #{detail}" if detail}")
    end
  end
end
