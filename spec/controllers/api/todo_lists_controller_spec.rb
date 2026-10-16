require 'rails_helper'

describe Api::TodoListsController do
  render_views

  describe 'GET index' do
    let!(:todo_list) { TodoList.create(name: 'Setup RoR project') }

    context 'when format is HTML' do
      it 'raises a routing error' do
        expect {
          get :index
        }.to raise_error(ActionController::RoutingError, 'Not supported format')
      end
    end

    context 'when format is JSON' do
      it 'returns a success code' do
        get :index, format: :json

        expect(response.status).to eq(200)
      end

      it 'includes todo list records' do
        get :index, format: :json

        todo_lists = JSON.parse(response.body)

        aggregate_failures 'includes the id and name' do
          expect(todo_lists.count).to eq(1)
          expect(todo_lists[0].keys).to match_array(['id', 'name'])
          expect(todo_lists[0]['id']).to eq(todo_list.id)
          expect(todo_lists[0]['name']).to eq(todo_list.name)
        end
      end
    end
  end

  describe 'GET index pagination' do
    let!(:todo_list) { TodoList.create!(name: 'Setup RoR project') }

    describe 'pagination' do
      let(:page_params) { {} }

      let(:all_ids) { TodoList.order(:id).pluck(:id) }

      before { TodoList.where.not(id: todo_list.id).delete_all
        29.times { |i| TodoList.create!(name: "Extra #{i}") } }

      it 'returns the first 25 records ordered by id by default' do
        get :index, params: page_params, format: :json

        expect(response.status).to eq(200)
        expect(JSON.parse(response.body).map { |r| r['id'] }).to eq(all_ids.first(25))
      end

      it 'returns the remaining records on the next page' do
        get :index, params: page_params.merge(page: 2), format: :json

        expect(JSON.parse(response.body).map { |r| r['id'] }).to eq(all_ids.last(5))
      end

      it 'returns an empty array for a page beyond the last one' do
        get :index, params: page_params.merge(page: 3), format: :json

        expect(response.status).to eq(200)
        expect(JSON.parse(response.body)).to eq([])
      end

      it 'falls back to the first page for invalid page values' do
        ['0', '-1', 'abc', ''].each do |value|
          get :index, params: page_params.merge(page: value), format: :json

          expect(JSON.parse(response.body).map { |r| r['id'] }).to eq(all_ids.first(25)), "page=#{value.inspect}"
          expect(response.headers['X-Page']).to eq('1')
        end
      end

      it 'sends the pagination metadata in headers' do
        get :index, params: page_params, format: :json

        expect(response.headers['X-Total-Count']).to eq('30')
        expect(response.headers['X-Total-Pages']).to eq('2')
        expect(response.headers['X-Page']).to eq('1')
        expect(response.headers['X-Per-Page']).to eq('25')
      end

      it 'sends first, last and next links on the first page' do
        get :index, params: page_params, format: :json

        links = response.headers['Link']
        expect(links).to include('page=2>; rel="next"', 'page=1>; rel="first"', 'page=2>; rel="last"')
        expect(links).not_to include('rel="prev"')
      end

      it 'sends first, last and prev links on the last page' do
        get :index, params: page_params.merge(page: 2), format: :json

        links = response.headers['Link']
        expect(links).to include('page=1>; rel="prev"', 'page=2>; rel="last"')
        expect(links).not_to include('rel="next"')
      end

      it 'keeps the response a plain array with the same fields' do
        get :index, params: page_params, format: :json

        body = JSON.parse(response.body)
        expect(body).to be_an(Array)
        expect(body.first.keys).to match_array(%w[id name])
      end
    end
  end

  describe 'GET show' do
    let!(:todo_list) { TodoList.create!(name: 'Setup RoR project') }

    it 'returns the list' do
      get :show, params: { id: todo_list.id }, format: :json

      body = JSON.parse(response.body)
      expect(response.status).to eq(200)
      expect(body).to eq('id' => todo_list.id, 'name' => 'Setup RoR project')
    end

    it 'returns 404 when the list does not exist' do
      get :show, params: { id: 0 }, format: :json

      expect(response.status).to eq(404)
    end

    it 'raises a routing error for HTML' do
      expect {
        get :show, params: { id: todo_list.id }
      }.to raise_error(ActionController::RoutingError, 'Not supported format')
    end
  end

  describe 'POST create' do
    it 'creates a list' do
      expect {
        post :create, params: { name: 'New list' }, format: :json
      }.to change(TodoList, :count).by(1)

      body = JSON.parse(response.body)
      expect(response.status).to eq(201)
      expect(body['name']).to eq('New list')
      expect(body.keys).to match_array(%w[id name])
    end

    it 'accepts params nested under todo_list' do
      post :create, params: { todo_list: { name: 'Nested' } }, format: :json

      expect(response.status).to eq(201)
      expect(JSON.parse(response.body)['name']).to eq('Nested')
    end

    it 'returns 422 without a name' do
      expect {
        post :create, format: :json
      }.not_to change(TodoList, :count)

      expect(response.status).to eq(422)
      expect(JSON.parse(response.body)['errors']).to have_key('name')
    end

    it 'returns 422 with a blank name' do
      post :create, params: { name: '' }, format: :json

      expect(response.status).to eq(422)
    end

    it 'ignores non permitted params' do
      post :create, params: { name: 'List', id: 9999 }, format: :json

      expect(response.status).to eq(201)
      expect(JSON.parse(response.body)['id']).not_to eq(9999)
    end
  end

  describe 'PATCH update' do
    let!(:todo_list) { TodoList.create!(name: 'Old name') }

    it 'updates the name' do
      patch :update, params: { id: todo_list.id, name: 'New name' }, format: :json

      expect(response.status).to eq(200)
      expect(JSON.parse(response.body)['name']).to eq('New name')
      expect(todo_list.reload.name).to eq('New name')
    end

    it 'returns 422 and does not change the list with a blank name' do
      patch :update, params: { id: todo_list.id, name: '' }, format: :json

      expect(response.status).to eq(422)
      expect(todo_list.reload.name).to eq('Old name')
    end

    it 'returns 404 when the list does not exist' do
      patch :update, params: { id: 0, name: 'x' }, format: :json

      expect(response.status).to eq(404)
    end
  end

  describe 'DELETE destroy' do
    let!(:todo_list) { TodoList.create!(name: 'To delete') }

    it 'deletes the list' do
      expect {
        delete :destroy, params: { id: todo_list.id }, format: :json
      }.to change(TodoList, :count).by(-1)

      expect(response.status).to eq(204)
      expect(response.body).to be_empty
    end

    it 'deletes its items too' do
      todo_list.todo_items.create!(name: 'Item')

      expect {
        delete :destroy, params: { id: todo_list.id }, format: :json
      }.to change(TodoItem, :count).by(-1)
    end

    it 'returns 404 when the list does not exist' do
      delete :destroy, params: { id: 0 }, format: :json

      expect(response.status).to eq(404)
    end
  end
end
