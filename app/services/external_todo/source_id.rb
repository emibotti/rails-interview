module ExternalTodo
  # source_id sent to the external API: "<prefix>:list:<id>" / "<prefix>:item:<id>".
  # The prefix tells records we created apart from the ones of other systems.
  module SourceId
    KINDS = { "TodoList" => :list, "TodoItem" => :item }.freeze

    module_function

    def prefix
      Rails.configuration.x.external_todo.source_prefix
    end

    def for(record)
      kind = KINDS.fetch(record.class.name)
      "#{prefix}:#{kind}:#{record.id}"
    end

    # Returns [:list, 5] or nil when the source_id is blank or not ours.
    def parse(source_id)
      match = /\A#{Regexp.escape(prefix)}:(list|item):(\d+)\z/.match(source_id.to_s)
      match && [match[1].to_sym, match[2].to_i]
    end
  end
end
