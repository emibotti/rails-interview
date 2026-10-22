module ExternalTodo
  # Anti-corruption layer: translates between the external wire format
  # (items use `description`) and our domain structs (items use `name`).
  module Mapper
    module_function

    def remote_list(hash)
      RemoteList.new(
        external_id: string(hash["id"]),
        source_id: string(hash["source_id"]),
        name: hash["name"],
        created_at: time(hash["created_at"]),
        updated_at: time(hash["updated_at"]),
        items: Array(hash["items"]).map { |item| remote_item(item) }
      )
    end

    def remote_item(hash)
      RemoteItem.new(
        external_id: string(hash["id"]),
        source_id: string(hash["source_id"]),
        name: hash["description"],
        completed: hash["completed"],
        created_at: time(hash["created_at"]),
        updated_at: time(hash["updated_at"])
      )
    end

    def create_list_body(name:, source_id:, items: [])
      {
        source_id: source_id,
        name: name,
        items: items.map { |item| create_item_body(**item) }
      }
    end

    def create_item_body(name:, completed:, source_id:)
      { source_id: source_id, description: name, completed: completed }
    end

    def update_list_body(name:)
      { name: name }
    end

    # Only the present keys are sent; `name` goes out as `description`.
    def update_item_body(**attrs)
      body = {}
      body[:description] = attrs[:name] if attrs.key?(:name)
      body[:completed] = attrs[:completed] if attrs.key?(:completed)
      body
    end

    def string(value)
      value&.to_s
    end

    def time(value)
      return if value.blank?

      Time.iso8601(value.to_s)
    rescue ArgumentError
      lenient_time(value)
    end

    def lenient_time(value)
      Time.zone.parse(value.to_s)
    rescue ArgumentError
      nil
    end
  end
end
