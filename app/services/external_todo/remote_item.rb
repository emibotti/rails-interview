module ExternalTodo
  RemoteItem = Struct.new(:external_id, :source_id, :name, :completed, :created_at, :updated_at, keyword_init: true)
end
