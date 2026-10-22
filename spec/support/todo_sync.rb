# The sync is disabled in the test environment so existing specs never enqueue TodoSyncJob.
# Tag a group or example with `:todo_sync` to enable it.
RSpec.configure do |config|
  config.around(:each, :todo_sync) do |example|
    settings = Rails.configuration.x.todo_sync
    original = settings.enabled
    settings.enabled = true
    example.run
  ensure
    settings.enabled = original
  end
end
