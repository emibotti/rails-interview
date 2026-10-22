require "json"
require "securerandom"
require "time"

# In-memory fake of the External Todo API (docs/external-api.yaml in SYNC_PLAN.md,
# annex B). Plain Rack app with no dependency on the rack gem, so it can be used
# from specs (WebMock `to_rack`) and from `bin/fake_external_api`.
#
# Test helpers: seed_list, lists, find_list, requests, reset!, fail_next, timeout_next.
class FakeExternalTodoApi
  attr_accessor :supports_item_creation, :clock

  def initialize(supports_item_creation: false, clock: -> { Time.now })
    @supports_item_creation = supports_item_creation
    @clock = clock
    @mutex = Mutex.new
    reset!
  end

  def reset!
    @mutex.synchronize do
      @lists = []
      @requests = []
      @failures = []
      @timeouts = []
    end
  end

  # Seeds a list directly, without recording a request. Items: [{ description:, completed:, source_id: }].
  def seed_list(name:, source_id: nil, items: [])
    @mutex.synchronize { build_list(name: name, source_id: source_id, items: items) }.then { |list| deep_copy(list) }
  end

  def lists
    @mutex.synchronize { deep_copy(@lists) }
  end

  def find_list(id)
    @mutex.synchronize { deep_copy(@lists.find { |list| list["id"] == id }) }
  end

  # [[method, path, parsed_body], ...] in arrival order.
  def requests
    @mutex.synchronize { @requests.dup }
  end

  # Answers the next `times` matching requests with `status` without applying them.
  def fail_next(method, path_regex, status: 500, times: 1, headers: {}, body: nil)
    @mutex.synchronize do
      @failures << { method: method.to_s.upcase, path: path_regex, status: status, times: times, headers: headers, body: body }
    end
  end

  # Raises Net::ReadTimeout for the next `times` matching requests. With
  # after_processing: true the change is applied first ("created but timed out").
  def timeout_next(method, path_regex, after_processing: false, times: 1)
    @mutex.synchronize do
      @timeouts << { method: method.to_s.upcase, path: path_regex, after_processing: after_processing, times: times }
    end
  end

  def call(env)
    method = env["REQUEST_METHOD"]
    path = env["PATH_INFO"]
    raw = env["rack.input"]&.read.to_s
    env["rack.input"]&.rewind

    @mutex.synchronize do
      body = parse_body(raw)
      @requests << [method, path, body]
      return json(400, error: "Invalid JSON") if body == :invalid

      if (failure = take(@failures, method, path))
        return [failure[:status], { "Content-Type" => "application/json" }.merge(failure[:headers]),
                [failure[:body] || JSON.generate(error: "Injected failure")]]
      end

      timeout = take(@timeouts, method, path)
      raise Net::ReadTimeout, "fake timeout" if timeout && !timeout[:after_processing]

      response = route(method, path, body)
      raise Net::ReadTimeout, "fake timeout" if timeout
      response
    end
  end

  private

  def route(method, path, body)
    segments = path.split("/").reject(&:empty?)
    case [method, segments.length]
    when ["GET", 1] then segments[0] == "todolists" ? json(200, @lists) : not_found
    when ["POST", 1] then segments[0] == "todolists" ? create_list(body) : not_found
    when ["PATCH", 2], ["DELETE", 2] then segments[0] == "todolists" ? list_member(method, segments[1], body) : not_found
    when ["POST", 3] then create_item(segments, body)
    when ["PATCH", 4], ["DELETE", 4] then item_member(method, segments, body)
    else not_found
    end
  end

  def create_list(body)
    return json(400, error: "Invalid body") unless body.is_a?(Hash)

    items = Array(body["items"]).map { |item| { description: item["description"], completed: item["completed"], source_id: item["source_id"] } }
    json(201, build_list(name: body["name"], source_id: body["source_id"], items: items))
  end

  def list_member(method, id, body)
    list = @lists.find { |l| l["id"] == id }
    return not_found unless list

    if method == "DELETE"
      @lists.delete(list)
      return [204, {}, []]
    end
    return json(400, error: "Invalid body") unless body.is_a?(Hash)

    list["name"] = body["name"] if body.key?("name")
    list["updated_at"] = now
    json(200, list)
  end

  def create_item(segments, body)
    return not_found unless @supports_item_creation && segments[0] == "todolists" && segments[2] == "todoitems"

    list = @lists.find { |l| l["id"] == segments[1] }
    return not_found unless list
    return json(400, error: "Invalid body") unless body.is_a?(Hash)

    item = build_item(description: body["description"], completed: body["completed"], source_id: body["source_id"])
    list["items"] << item
    json(201, item)
  end

  def item_member(method, segments, body)
    return not_found unless segments[0] == "todolists" && segments[2] == "todoitems"

    list = @lists.find { |l| l["id"] == segments[1] }
    item = list && list["items"].find { |i| i["id"] == segments[3] }
    return not_found unless item

    if method == "DELETE"
      list["items"].delete(item)
      return [204, {}, []]
    end
    return json(400, error: "Invalid body") unless body.is_a?(Hash)

    item["description"] = body["description"] if body.key?("description")
    item["completed"] = body["completed"] if body.key?("completed")
    item["updated_at"] = now
    json(200, item)
  end

  def build_list(name:, source_id:, items:)
    timestamp = now
    list = {
      "id" => SecureRandom.uuid, "source_id" => source_id, "name" => name,
      "created_at" => timestamp, "updated_at" => timestamp, "items" => []
    }
    list["items"] = items.map { |item| build_item(**item.slice(:description, :completed, :source_id)) }
    @lists << list
    list
  end

  def build_item(description: nil, completed: false, source_id: nil)
    timestamp = now
    {
      "id" => SecureRandom.uuid, "source_id" => source_id, "description" => description,
      "completed" => completed || false, "created_at" => timestamp, "updated_at" => timestamp
    }
  end

  def take(queue, method, path)
    entry = queue.find { |e| e[:method] == method && e[:path].match?(path) }
    return unless entry

    entry[:times] -= 1
    queue.delete(entry) if entry[:times] <= 0
    entry
  end

  def parse_body(raw)
    return nil if raw.empty?

    JSON.parse(raw)
  rescue JSON::ParserError
    :invalid
  end

  def now
    clock.call.utc.iso8601(3)
  end

  def deep_copy(object)
    object && JSON.parse(JSON.generate(object))
  end

  def json(status, payload)
    [status, { "Content-Type" => "application/json" }, [JSON.generate(payload)]]
  end

  def not_found
    json(404, error: "Not found")
  end
end
