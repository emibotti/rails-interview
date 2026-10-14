module Api
  class TodoListsController < ApplicationController
    protect_from_forgery with: :null_session

    before_action :set_todo_list, only: %i[show update destroy]

    rescue_from ActiveRecord::RecordNotFound, with: :render_not_found

    # GET /api/todolists
    def index
      @todo_lists = TodoList.all

      respond_to :json
    end

    # GET /api/todolists/:id
    def show
      respond_to :json
    end

    # POST /api/todolists
    def create
      @todo_list = TodoList.new(todo_list_params)

      respond_to do |format|
        format.json do
          if @todo_list.save
            render :show, status: :created
          else
            render_errors(@todo_list)
          end
        end
      end
    end

    # PATCH/PUT /api/todolists/:id
    def update
      respond_to do |format|
        format.json do
          if @todo_list.update(todo_list_params)
            render :show
          else
            render_errors(@todo_list)
          end
        end
      end
    end

    # DELETE /api/todolists/:id
    def destroy
      respond_to do |format|
        format.json do
          @todo_list.destroy
          head :no_content
        end
      end
    end

    private

    def set_todo_list
      @todo_list = TodoList.find(params[:id])
    end

    def todo_list_params
      params.fetch(:todo_list, params).permit(:name)
    end

    def render_errors(record)
      render json: { errors: record.errors }, status: :unprocessable_entity
    end

    def render_not_found
      render json: { error: 'Not found' }, status: :not_found
    end
  end
end
