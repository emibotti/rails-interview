module ExternalTodo
  RemoteList = Struct.new(:external_id, :source_id, :name, :created_at, :updated_at, :items, keyword_init: true)
end
