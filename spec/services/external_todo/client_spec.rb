require "rails_helper"

RSpec.describe ExternalTodo::Client do
  include_context "with fake external todo api"

  let(:client) { external_client }

  def requests_to(method)
    fake_api.requests.select { |m, _path, _body| m == method }
  end

  describe "#list_todo_lists" do
    it "returns domain structs with name instead of description" do
      fake_api.seed_list(name: "Remote", source_id: "x", items: [{ description: "a", completed: true, source_id: "i1" }])

      lists = client.list_todo_lists

      expect(lists.size).to eq(1)
      expect(lists.first).to have_attributes(name: "Remote", source_id: "x")
      expect(lists.first.updated_at).to be_a(Time)
      expect(lists.first.items.first).to have_attributes(name: "a", completed: true, source_id: "i1")
    end

    it "raises InvalidResponseError when the body is not an array" do
      stub_request(:get, "http://external.test/todolists").to_return(
        status: 200, body: '{"a":1}', headers: { "Content-Type" => "application/json" }
      )

      expect { client.list_todo_lists }.to raise_error(ExternalTodo::Client::InvalidResponseError)
    end

    it "raises InvalidResponseError on invalid JSON" do
      stub_request(:get, "http://external.test/todolists").to_return(
        status: 200, body: "not json", headers: { "Content-Type" => "application/json" }
      )

      expect { client.list_todo_lists }.to raise_error(ExternalTodo::Client::InvalidResponseError)
    end

    it "retries a 500 up to the maximum and then raises RetryableError" do
      fake_api.fail_next(:get, %r{/todolists}, status: 500, times: 5)

      expect { client.list_todo_lists }.to raise_error(ExternalTodo::Client::RetryableError) { |e| expect(e.status).to eq(500) }
      expect(requests_to("GET").size).to eq(3) # 1 + max 2 retries
    end

    it "retries an error page that is not JSON and reports its status" do
      stub = stub_request(:get, "http://external.test/todolists").to_return(
        status: 502, body: "<html>Bad Gateway</html>", headers: { "Content-Type" => "application/json" }
      )

      expect { client.list_todo_lists }.to raise_error(ExternalTodo::Client::RetryableError, /GET \/todolists failed with 502: <html>Bad Gateway/)
      expect(stub).to have_been_requested.times(3)
    end

    it "reports a 4xx with a non JSON body by its status, without retrying" do
      stub = stub_request(:get, "http://external.test/todolists").to_return(
        status: 403, body: "Forbidden", headers: { "Content-Type" => "application/json" }
      )

      expect { client.list_todo_lists }.to raise_error(ExternalTodo::Client::ClientError, /failed with 403: Forbidden/)
      expect(stub).to have_been_requested.once
    end

    it "retries a timeout and succeeds" do
      fake_api.timeout_next(:get, %r{/todolists})

      expect(client.list_todo_lists).to eq([])
      expect(requests_to("GET").size).to eq(2)
    end

    it "retries a 429 honouring Retry-After" do
      fake_api.fail_next(:get, %r{/todolists}, status: 429, headers: { "Retry-After" => "0" })

      expect(client.list_todo_lists).to eq([])
      expect(requests_to("GET").size).to eq(2)
    end
  end

  describe "#create_todo_list" do
    it "sends items with description and returns the created list" do
      list = client.create_todo_list(
        name: "L", source_id: "rails-interview:list:1",
        items: [{ name: "a", completed: false, source_id: "rails-interview:item:1" }]
      )

      expect(fake_api.requests.last[2]).to eq(
        "source_id" => "rails-interview:list:1", "name" => "L",
        "items" => [{ "source_id" => "rails-interview:item:1", "description" => "a", "completed" => false }]
      )
      expect(list.external_id).to be_present
      expect(list.items.first.name).to eq("a")
    end

    it "does not retry a 500" do
      fake_api.fail_next(:post, %r{/todolists}, status: 500, times: 5)

      expect { client.create_todo_list(name: "L", source_id: "s") }.to raise_error(ExternalTodo::Client::RetryableError)
      expect(requests_to("POST").size).to eq(1)
    end

    it "raises TimeoutError without retrying" do
      fake_api.timeout_next(:post, %r{/todolists}, after_processing: true)

      expect { client.create_todo_list(name: "L", source_id: "s") }.to raise_error(ExternalTodo::Client::TimeoutError)
      expect(requests_to("POST").size).to eq(1)
      expect(fake_api.lists.size).to eq(1) # created even though the client saw a timeout
    end
  end

  describe "#update_todo_list" do
    it "patches the name" do
      remote = fake_api.seed_list(name: "Old")

      updated = client.update_todo_list(remote["id"], name: "New")

      expect(updated.name).to eq("New")
      expect(fake_api.find_list(remote["id"])["name"]).to eq("New")
    end
  end

  describe "#update_todo_item" do
    let!(:remote) { fake_api.seed_list(name: "L", items: [{ description: "a", completed: false, source_id: "i" }]) }
    let(:item_id) { remote["items"].first["id"] }

    it "sends only the present keys, translating name to description" do
      client.update_todo_item(remote["id"], item_id, completed: true)
      expect(fake_api.requests.last[2]).to eq("completed" => true)

      client.update_todo_item(remote["id"], item_id, name: "b")
      expect(fake_api.requests.last[2]).to eq("description" => "b")
    end

    it "rejects unknown keys" do
      expect { client.update_todo_item(remote["id"], item_id, foo: 1) }.to raise_error(ArgumentError, /foo/)
    end

    it "retries a 503" do
      fake_api.fail_next(:patch, %r{todoitems}, status: 503)

      expect(client.update_todo_item(remote["id"], item_id, completed: true).completed).to be(true)
      expect(requests_to("PATCH").size).to eq(2)
    end

    it "raises NotFoundError for an unknown item" do
      expect { client.update_todo_item(remote["id"], "nope", completed: true) }.to raise_error(ExternalTodo::Client::NotFoundError)
    end

    it "raises ClientError with the body in the message on 422" do
      fake_api.fail_next(:patch, %r{todoitems}, status: 422, body: '{"error":"bad"}')

      expect { client.update_todo_item(remote["id"], item_id, completed: true) }
        .to raise_error(ExternalTodo::Client::ClientError, /422.*bad/)
      expect(requests_to("PATCH").size).to eq(1)
    end
  end

  describe "deletes" do
    it "deletes a list and cascades to its items" do
      remote = fake_api.seed_list(name: "L", items: [{ description: "a", completed: false, source_id: "i" }])

      expect(client.delete_todo_list(remote["id"])).to be(true)
      expect(fake_api.lists).to be_empty
    end

    it "deletes an item" do
      remote = fake_api.seed_list(name: "L", items: [{ description: "a", completed: false, source_id: "i" }])

      client.delete_todo_item(remote["id"], remote["items"].first["id"])

      expect(fake_api.find_list(remote["id"])["items"]).to be_empty
    end

    it "raises NotFoundError for a missing list" do
      expect { client.delete_todo_list("nope") }.to raise_error(ExternalTodo::Client::NotFoundError)
    end

    it "url-encodes ids" do
      expect { client.delete_todo_list("a/b c") }.to raise_error(ExternalTodo::Client::NotFoundError)
      expect(fake_api.requests.last[1]).to eq("/todolists/a%2Fb%20c")
    end
  end

  describe "#create_todo_item" do
    it "is not found unless the fake supports the proposed endpoint" do
      remote = fake_api.seed_list(name: "L")

      expect { client.create_todo_item(remote["id"], name: "a", completed: false, source_id: "s") }
        .to raise_error(ExternalTodo::Client::NotFoundError)
    end

    it "creates the item when supported" do
      fake_api.supports_item_creation = true
      remote = fake_api.seed_list(name: "L")

      item = client.create_todo_item(remote["id"], name: "a", completed: true, source_id: "s")

      expect(item).to have_attributes(name: "a", completed: true, source_id: "s")
    end
  end

  it "raises RetryableError when the connection fails" do
    stub_request(:get, "http://external.test/todolists").to_raise(Faraday::ConnectionFailed.new("boom"))

    expect { client.list_todo_lists }.to raise_error(ExternalTodo::Client::RetryableError)
  end
end
