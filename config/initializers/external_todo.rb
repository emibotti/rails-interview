# Configuration for the External Todo API client and the two-way sync.
Rails.application.configure do
  config.x.external_todo.base_url = ENV.fetch("EXTERNAL_TODO_API_URL") do
    Rails.env.test? ? "http://external.test" : "http://localhost:4000"
  end
  config.x.external_todo.open_timeout = 2
  config.x.external_todo.timeout = 10
  config.x.external_todo.retry_options = {
    max: 2,
    interval: 0.5,
    backoff_factor: 2,
    interval_randomness: 0.5
  }
  config.x.external_todo.source_prefix = "rails-interview"

  # How to push items created locally in an already synced list (the external API cannot create items in an
  # existing list): recreate_list, skip or api_endpoint. `skip` is the off switch for the recreate workaround.
  config.x.external_todo.item_creation_strategy = ENV.fetch("EXTERNAL_TODO_ITEM_CREATION", "recreate_list")
  config.x.external_todo.recreate_max_items = 5000

  # Deletion guard: refuse local deletions when more than this share of the linked
  # lists is missing from the snapshot (only with at least guard_min_linked of them).
  config.x.todo_sync.guard_min_linked = 5
  config.x.todo_sync.guard_max_missing_ratio = 0.5

  # On in development and production (TODO_SYNC_ENABLED=false turns it off, e.g. with a huge local database,
  # since the first sync uploads everything). Off in test so the existing specs never enqueue TodoSyncJob or
  # hit the network (specs of the sync use the :todo_sync tag).
  config.x.todo_sync.enabled = !Rails.env.test? && ENV["TODO_SYNC_ENABLED"] != "false"
end
