require 'rails_helper'

describe 'Todo lists', type: :request do
  let!(:todo_list) { TodoList.create!(name: 'Setup RoR project') }

  describe 'GET /todolists/:id' do
    it 'renders the list with a turbo stream subscription and the items frame' do
      todo_list.todo_items.create!(name: 'First item')

      get todo_list_path(todo_list)

      expect(response.status).to eq(200)
      expect(response.body).to include('Setup RoR project', 'First item')
      expect(html.at_css('turbo-cable-stream-source[signed-stream-name]')).to be_present
      expect(html.at_css('[data-controller="mark-all"] turbo-frame#todo_items')).to be_present
    end

    it 'enables the mark all button when nothing is running' do
      get todo_list_path(todo_list)

      expect(mark_all_button['disabled']).to be_nil
    end

    it 'disables the mark all button while a mark all is running' do
      todo_list.acquire_mark_all_lock!

      get todo_list_path(todo_list)

      expect(mark_all_button['disabled']).not_to be_nil
      expect(response.body).to include('data-state="running"')
    end

    it 'enables the mark all button when the lock is stale' do
      todo_list.update_columns(mark_all_heartbeat_at: 1.hour.ago)

      get todo_list_path(todo_list)

      expect(mark_all_button['disabled']).to be_nil
    end

    describe 'checkboxes' do
      let!(:done_item) { todo_list.todo_items.create!(name: 'Done', completed: true) }
      let!(:pending_item) { todo_list.todo_items.create!(name: 'Pending') }

      it 'renders a checkbox per item reflecting completed' do
        get todo_list_path(todo_list)

        expect(checkbox(done_item)['checked']).not_to be_nil
        expect(checkbox(pending_item)['checked']).to be_nil
      end

      it 'wires every item to the todo-item controller with its update url' do
        get todo_list_path(todo_list)

        row = html.at_css("li##{ActionView::RecordIdentifier.dom_id(pending_item)}")
        expect(row['data-controller']).to eq('todo-item')
        expect(row['data-todo-item-url-value']).to eq(todo_list_todo_item_path(todo_list, pending_item))
        expect(row['data-completed']).to eq('false')
        expect(checkbox(pending_item)['data-action']).to eq('todo-item#toggle')
      end

      it 'shows the pending counter inside the items frame' do
        get todo_list_path(todo_list)

        counter = html.at_css('turbo-frame#todo_items [data-mark-all-target="pending"]')
        expect(counter.text.strip).to eq('1')
        expect(counter['data-count']).to eq('1')
      end

      it 'reflects the changes made through the checkbox endpoint' do
        patch todo_list_todo_item_path(todo_list, pending_item), params: { completed: true }, as: :json,
          headers: { 'Accept' => 'application/json' }
        patch todo_list_todo_item_path(todo_list, done_item), params: { completed: false }, as: :json,
          headers: { 'Accept' => 'application/json' }

        get todo_list_path(todo_list)

        expect(checkbox(pending_item)['checked']).not_to be_nil
        expect(checkbox(done_item)['checked']).to be_nil
      end

      it 'shows every checkbox checked after a mark all' do
        perform_enqueued_jobs do
          post complete_all_todo_list_path(todo_list), headers: { 'Accept' => 'text/vnd.turbo-stream.html, text/html' }
        end

        get todo_list_path(todo_list)

        expect(html.css('turbo-frame#todo_items input[type=checkbox]').map { |c| c['checked'] }).to all(be_present)
        expect(html.at_css('[data-mark-all-target="pending"]').text.strip).to eq('0')
      end
    end

    describe 'pagination' do
      let!(:items) { Array.new(30) { |i| todo_list.todo_items.create!(name: "Item #{i + 1}") } }

      it 'shows the first 25 items on the first page' do
        get todo_list_path(todo_list)

        expect(item_names).to eq(items.first(25).map(&:name))
        expect(response.body).to include('Page 1 of 2')
      end

      it 'shows the remaining items on the second page' do
        get todo_list_path(todo_list, page: 2)

        expect(item_names).to eq(items.last(5).map(&:name))
        expect(response.body).to include('Page 2 of 2')
      end

      it 'clamps pages out of range' do
        get todo_list_path(todo_list, page: 99)
        expect(response.body).to include('Page 2 of 2')

        get todo_list_path(todo_list, page: -1)
        expect(response.body).to include('Page 1 of 2')
      end

      it 'renders pagination links that advance the browser history' do
        get todo_list_path(todo_list)

        link = html.at_css("turbo-frame#todo_items a[href='#{todo_list_path(todo_list, page: 2)}']")
        expect(link['data-turbo-action']).to eq('advance')
      end
    end

    it 'shows a single empty page for a list without items' do
      get todo_list_path(todo_list)

      expect(response.body).to include('Page 1 of 1')
    end

    it 'returns 404 when the list does not exist' do
      expect { get todo_list_path(id: 0) }.to raise_error(ActiveRecord::RecordNotFound)
    end

    it 'raises a routing error for JSON' do
      expect {
        get todo_list_path(todo_list, format: :json)
      }.to raise_error(ActionController::RoutingError, 'Not supported format')
    end
  end

  describe 'POST /todolists/:id/complete_all' do
    let(:turbo_stream) { { 'Accept' => 'text/vnd.turbo-stream.html, text/html' } }
    let!(:items) { Array.new(3) { |i| todo_list.todo_items.create!(name: "Item #{i}") } }

    it 'enqueues a single job up to the current max id and takes the lock' do
      expect {
        post complete_all_todo_list_path(todo_list), headers: turbo_stream
      }.to have_enqueued_job(CompleteAllTodoItemsJob).with(todo_list, items.last.id).exactly(:once)

      expect(response.status).to eq(202)
      expect(response.media_type).to eq('text/vnd.turbo-stream.html')
      expect(todo_list.reload.mark_all_running?).to eq(true)
    end

    it 'does not update any item within the request' do
      post complete_all_todo_list_path(todo_list), headers: turbo_stream

      expect(todo_list.todo_items.where(completed: false).count).to eq(3)
    end

    it 'returns 409 without enqueuing when a mark all is already running' do
      todo_list.acquire_mark_all_lock!

      expect {
        post complete_all_todo_list_path(todo_list), headers: turbo_stream
      }.not_to have_enqueued_job

      expect(response.status).to eq(409)
    end

    it 'enqueues only one job for two consecutive requests' do
      expect {
        2.times { post complete_all_todo_list_path(todo_list), headers: turbo_stream }
      }.to have_enqueued_job(CompleteAllTodoItemsJob).exactly(:once)
    end

    it 'takes over a stale lock' do
      todo_list.update_columns(mark_all_heartbeat_at: 1.hour.ago)

      expect {
        post complete_all_todo_list_path(todo_list), headers: turbo_stream
      }.to have_enqueued_job(CompleteAllTodoItemsJob)

      expect(response.status).to eq(202)
    end

    it 'does not enqueue anything when there are no pending items' do
      todo_list.todo_items.update_all(completed: true)

      expect {
        post complete_all_todo_list_path(todo_list), headers: turbo_stream
      }.not_to have_enqueued_job

      expect(response.status).to eq(200)
      expect(response.body).to include('data-state="done"')
      expect(todo_list.reload.mark_all_running?).to eq(false)
    end

    it 'redirects to the list for plain HTML requests' do
      post complete_all_todo_list_path(todo_list)

      expect(response).to redirect_to(todo_list_path(todo_list))
      expect(flash[:notice]).to eq('Marking all items as completed.')
    end

    it 'returns 404 when the list does not exist' do
      expect {
        post complete_all_todo_list_path(id: 0), headers: turbo_stream
      }.to raise_error(ActiveRecord::RecordNotFound)
    end

    it 'raises a routing error for JSON' do
      expect {
        post complete_all_todo_list_path(todo_list, format: :json)
      }.to raise_error(ActionController::RoutingError, 'Not supported format')
    end

    describe 'end to end' do
      it 'completes all the items and releases the lock' do
        perform_enqueued_jobs do
          post complete_all_todo_list_path(todo_list), headers: turbo_stream
        end

        expect(todo_list.todo_items.where(completed: false)).to be_empty
        expect(todo_list.reload.mark_all_running?).to eq(false)
      end

      it 'leaves items created after the request pending' do
        post complete_all_todo_list_path(todo_list), headers: turbo_stream
        later_item = todo_list.todo_items.create!(name: 'Created later')

        perform_enqueued_jobs

        expect(items.map { |item| item.reload.completed }).to all(eq(true))
        expect(later_item.reload.completed).to eq(false)
      end

      it 'broadcasts the progress to the list stream' do
        expect {
          perform_enqueued_jobs { post complete_all_todo_list_path(todo_list), headers: turbo_stream }
        }.to have_broadcasted_to(todo_list.to_gid_param).with(a_string_including('data-state="done"'))
      end

      it 'allows marking all again once finished' do
        perform_enqueued_jobs { post complete_all_todo_list_path(todo_list), headers: turbo_stream }
        todo_list.todo_items.create!(name: 'New item')

        expect {
          post complete_all_todo_list_path(todo_list), headers: turbo_stream
        }.to have_enqueued_job(CompleteAllTodoItemsJob)
      end
    end
  end

  def html
    Nokogiri::HTML(response.body)
  end

  def mark_all_button
    html.at_css("form[action='#{complete_all_todo_list_path(todo_list)}'] button")
  end

  def checkbox(item)
    html.at_css("li##{ActionView::RecordIdentifier.dom_id(item)} input[type=checkbox]")
  end

  def item_names
    html.css('turbo-frame#todo_items li .todo-item__name').map { |name| name.text.strip }
  end
end
