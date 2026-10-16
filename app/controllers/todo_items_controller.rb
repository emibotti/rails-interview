class TodoItemsController < ApplicationController
  before_action :set_todo_item

  # PATCH /todolists/:todo_list_id/todoitems/:id
  #
  # JSON endpoint used by the checkbox of the todo list page.
  def update
    completed = params[:completed].to_s

    respond_to do |format|
      format.json do
        if %w[true false].include?(completed) && @todo_item.update(completed: completed == 'true')
          render json: { id: @todo_item.id, completed: @todo_item.completed }
        else
          render json: { errors: { completed: ['must be true or false'] } }, status: :unprocessable_entity
        end
      end
    end
  end

  private

  def set_todo_item
    @todo_item = TodoItem.where(todo_list_id: params[:todo_list_id]).find(params[:id])
  end
end
