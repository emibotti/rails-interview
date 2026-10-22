module TodoSync
  # Items created locally in a list that already exists remotely. The external API
  # has no endpoint for that (items can only be created inside POST /todolists), so
  # how they reach it is a configurable strategy (EXTERNAL_TODO_ITEM_CREATION):
  #
  # - recreate_list (default, temporary): POST a new list with all the items and delete the old one.
  # - skip: leave them pending with a sync_error. Safe, but they are not propagated.
  # - api_endpoint: use the proposed POST /todolists/{id}/todoitems. The target once the API has it.
  #
  # All strategies answer `call(snapshot, run, client:)` and handle the unlinked
  # items whose list is linked, grouped by list.
  module ItemCreation
    STRATEGIES = {
      "recreate_list" => "TodoSync::ItemCreation::RecreateList",
      "skip" => "TodoSync::ItemCreation::Skip",
      "api_endpoint" => "TodoSync::ItemCreation::ApiEndpoint"
    }.freeze

    module_function

    def strategy
      name = Rails.configuration.x.external_todo.item_creation_strategy.to_s
      STRATEGIES.fetch(name) { raise ArgumentError, "unknown item creation strategy #{name.inspect} (expected #{STRATEGIES.keys.join(', ')})" }.constantize
    end

    def call(snapshot, run, client:)
      strategy.call(snapshot, run, client: client)
    end

    # Linked lists that have items waiting to be created remotely.
    def lists_with_unlinked_items
      list_ids = TodoItem.unlinked.ready_to_sync.where(todo_list_id: TodoList.linked.ready_to_sync.select(:id)).distinct.pluck(:todo_list_id)
      TodoList.where(id: list_ids).select(:id, :name, :external_id, :local_version, :remote_updated_at).order(:id)
    end

    def clear_errors(list_id)
      TodoItem.where(todo_list_id: list_id).where.not(sync_error: nil).update_all(sync_error: nil)
    end
  end
end
