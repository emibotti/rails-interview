module TodoSync
  # Exponential backoff with jitter for the retries that span sync cycles (per record, per tombstone,
  # per failed run). In-request retries of idempotent calls live in ExternalTodo::Client.
  #
  # delay = min(base * 2^(attempts - 1), max), then "equal jitter": half of it fixed and half random,
  # so records that failed together don't all come back at the same instant.
  # https://aws.amazon.com/blogs/architecture/exponential-backoff-and-jitter/
  module Backoff
    module_function

    def delay(attempts, base: config.backoff_base, max: config.backoff_max, random: Random)
      capped = [base * (2**[attempts - 1, 0].max), max].min
      capped / 2.0 + random.rand * capped / 2.0
    end

    # Attempts after which a record goes to the dead letters.
    def max_attempts
      config.max_attempts
    end

    def config
      Rails.configuration.x.todo_sync
    end
  end
end
