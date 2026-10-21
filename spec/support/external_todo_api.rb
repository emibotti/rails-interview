require "webmock/rspec"
require_relative "../../lib/fake_external_todo_api"

# Stubs http://external.test with an in-memory FakeExternalTodoApi.
# Exposes `fake_api` and `external_client` (no sleeping between retries).
RSpec.shared_context "with fake external todo api" do
  let(:fake_api) { FakeExternalTodoApi.new }
  let(:external_client) do
    ExternalTodo::Client.new(
      base_url: "http://external.test",
      retry_options: { max: 2, interval: 0, backoff_factor: 1, interval_randomness: 0 },
      logger: Logger.new(nil)
    )
  end

  before do
    stub_request(:any, %r{\Ahttp://external\.test}).to_rack(fake_api)
  end
end
