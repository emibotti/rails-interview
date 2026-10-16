class TodoListsController < ApplicationController
  PER_PAGE = Paginable::PER_PAGE

  before_action :set_todo_list, only: %i[show complete_all]

  # GET /todolists
  def index
    @todo_lists = TodoList.all

    respond_to :html
  end

  # GET /todolists/new
  def new
    @todo_list = TodoList.new

    respond_to :html
  end

  # GET /todolists/:id
  def show
    @items_count = @todo_list.todo_items.count
    @pending_count = @todo_list.todo_items.where(completed: false).count
    @total_pages = [(@items_count.to_f / PER_PAGE).ceil, 1].max
    @page = params[:page].to_i.clamp(1, @total_pages)
    @todo_items = @todo_list.todo_items.order(:id).limit(PER_PAGE).offset((@page - 1) * PER_PAGE)

    respond_to :html
  end

  # POST /todolists/:id/complete_all
  #
  # When a job is enqueued (202) or already running (409) the response stream is
  # empty: the status is only driven by the job broadcasts, otherwise a late
  # response could overwrite a "done" broadcast with a stale "running" state.
  def complete_all
    up_to_id = @todo_list.todo_items.where(completed: false).maximum(:id)

    if up_to_id.nil?
      respond_to_complete_all(:ok, notice: 'All items are already completed.') do
        turbo_stream.replace(
          helpers.dom_id(@todo_list, :mark_all_status),
          partial: 'todo_lists/mark_all_status',
          locals: { todo_list: @todo_list, state: :done }
        )
      end
    elsif @todo_list.acquire_mark_all_lock!
      # Items created after this point have a greater id and won't be touched.
      CompleteAllTodoItemsJob.perform_later(@todo_list, up_to_id)
      respond_to_complete_all(:accepted, notice: 'Marking all items as completed.')
    else
      respond_to_complete_all(:conflict, alert: 'Already marking all items as completed.')
    end
  end

  private

  def set_todo_list
    @todo_list = TodoList.find(params[:id])
  end

  def respond_to_complete_all(status, flash_options)
    respond_to do |format|
      format.turbo_stream { render turbo_stream: block_given? ? yield : '', status: status }
      format.html { redirect_to todo_list_path(@todo_list), flash_options }
    end
  end
end
