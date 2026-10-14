module Api
  class TodoItemsController < ApplicationController
    protect_from_forgery with: :null_session

    before_action :set_todo_list
    before_action :set_todo_item, only: %i[show update destroy]

    rescue_from ActiveRecord::RecordNotFound, with: :render_not_found

    # GET /api/todolists/:todo_list_id/todoitems
    def index
      @todo_items = @todo_list.todo_items.order(:id)

      respond_to :json
    end

    # GET /api/todolists/:todo_list_id/todoitems/:id
    def show
      respond_to :json
    end

    # POST /api/todolists/:todo_list_id/todoitems
    def create
      @todo_item = @todo_list.todo_items.new(todo_item_params)

      respond_to do |format|
        format.json do
          if @todo_item.save
            render :show, status: :created
          else
            render_errors(@todo_item)
          end
        end
      end
    end

    # PATCH/PUT /api/todolists/:todo_list_id/todoitems/:id
    def update
      respond_to do |format|
        format.json do
          if @todo_item.update(todo_item_params)
            render :show
          else
            render_errors(@todo_item)
          end
        end
      end
    end

    # DELETE /api/todolists/:todo_list_id/todoitems/:id
    def destroy
      respond_to do |format|
        format.json do
          @todo_item.destroy
          head :no_content
        end
      end
    end

    private

    def set_todo_list
      @todo_list = TodoList.find(params[:todo_list_id])
    end

    def set_todo_item
      @todo_item = @todo_list.todo_items.find(params[:id])
    end

    def todo_item_params
      params.fetch(:todo_item, params).permit(:name, :completed)
    end

    def render_errors(record)
      render json: { errors: record.errors }, status: :unprocessable_entity
    end

    def render_not_found
      render json: { error: 'Not found' }, status: :not_found
    end
  end
end
