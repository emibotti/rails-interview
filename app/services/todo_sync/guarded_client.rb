module TodoSync
  # Circuit breaker around the client for the length of one sync cycle.
  #
  # After `threshold` consecutive retryable failures (connection errors, timeouts, 5xx) the next call
  # raises CircuitOpenError instead of hitting the API, and the Runner aborts the cycle: if the API is
  # down, trying every remaining record only wastes time and requests. Any answer from the server
  # (including 4xx) means it is alive and resets the count. The call that trips the breaker still
  # raises its own error, so that record gets its failure recorded.
  class GuardedClient
    class CircuitOpenError < StandardError; end

    METHODS = %i[list_todo_lists create_todo_list update_todo_list delete_todo_list
                 update_todo_item delete_todo_item create_todo_item].freeze

    def initialize(client, threshold:)
      @client = client
      @threshold = threshold
      @consecutive_failures = 0
    end

    METHODS.each do |name|
      define_method(name) do |*args, **kwargs|
        if @consecutive_failures >= @threshold
          raise CircuitOpenError, "circuit breaker open after #{@consecutive_failures} consecutive failures"
        end

        # A slow API must not make the lock look abandoned while we wait for it.
        SyncState.heartbeat_if_due!
        call(name, args, kwargs)
      end
    end

    # Details of the last call (status, attempts, duration), for the operation log lines.
    def last_request
      @client.last_request
    end

    def attempts_total
      @client.attempts_total
    end

    private

    def call(name, args, kwargs)
      result = @client.public_send(name, *args, **kwargs)
      @consecutive_failures = 0
      result
    rescue ExternalTodo::Client::RetryableError, ExternalTodo::Client::InvalidResponseError
      @consecutive_failures += 1
      raise
    rescue ExternalTodo::Client::Error
      @consecutive_failures = 0
      raise
    end
  end
end
