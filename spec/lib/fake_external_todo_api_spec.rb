require "rails_helper"

RSpec.describe FakeExternalTodoApi do
  let(:api) { described_class.new }

  def call(method, path, body = nil)
    input = StringIO.new(body ? JSON.generate(body) : "")
    status, _headers, chunks = api.call("REQUEST_METHOD" => method, "PATH_INFO" => path, "rack.input" => input)
    [status, chunks.join.then { |s| s.empty? ? nil : JSON.parse(s) }]
  end

  it "creates, lists, patches and deletes lists with items" do
    status, list = call("POST", "/todolists", name: "L", source_id: "s", items: [{ description: "a", completed: true, source_id: "i" }])
    expect(status).to eq(201)
    expect(list["items"].first).to include("description" => "a", "completed" => true)

    expect(call("GET", "/todolists")[1].size).to eq(1)

    status, patched = call("PATCH", "/todolists/#{list['id']}", name: "New")
    expect([status, patched["name"]]).to eq([200, "New"])

    item_path = "/todolists/#{list['id']}/todoitems/#{list['items'].first['id']}"
    expect(call("PATCH", item_path, completed: false)[1]["completed"]).to be(false)
    expect(call("DELETE", item_path)[0]).to eq(204)
    expect(call("DELETE", "/todolists/#{list['id']}")[0]).to eq(204)
    expect(call("GET", "/todolists")[1]).to eq([])
  end

  it "answers 404 for unknown ids and routes, and 400 for invalid JSON" do
    expect(call("DELETE", "/todolists/nope")).to eq([404, { "error" => "Not found" }])
    expect(call("GET", "/nope")[0]).to eq(404)
    status, = api.call("REQUEST_METHOD" => "POST", "PATH_INFO" => "/todolists", "rack.input" => StringIO.new("{"))
    expect(status).to eq(400)
  end

  it "uses the injected clock for updated_at" do
    api.clock = -> { Time.utc(2026, 1, 1) }
    list = api.seed_list(name: "L")
    api.clock = -> { Time.utc(2026, 2, 1) }

    _status, patched = call("PATCH", "/todolists/#{list['id']}", name: "M")

    expect(patched["created_at"]).to eq("2026-01-01T00:00:00.000Z")
    expect(patched["updated_at"]).to eq("2026-02-01T00:00:00.000Z")
  end

  it "only creates items in existing lists when enabled" do
    list = api.seed_list(name: "L")
    expect(call("POST", "/todolists/#{list['id']}/todoitems", description: "a")[0]).to eq(404)

    api.supports_item_creation = true
    expect(call("POST", "/todolists/#{list['id']}/todoitems", description: "a")[0]).to eq(201)
  end

  it "injects failures and logs requests" do
    api.fail_next(:get, %r{/todolists}, status: 503)

    expect(call("GET", "/todolists")[0]).to eq(503)
    expect(call("GET", "/todolists")[0]).to eq(200)
    expect(api.requests.map(&:first)).to eq(%w[GET GET])
  end
end
