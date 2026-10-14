require 'rails_helper'

describe Api::TodoItemsController do
  render_views

  let!(:todo_list) { TodoList.create!(name: 'Setup RoR project') }
  let!(:other_list) { TodoList.create!(name: 'Other list') }
  let!(:todo_item) { todo_list.todo_items.create!(name: 'Write specs') }
  let!(:other_item) { other_list.todo_items.create!(name: 'Foreign item') }

  let(:body) { JSON.parse(response.body) }

  describe 'GET index' do
    it 'raises a routing error for HTML' do
      expect {
        get :index, params: { todo_list_id: todo_list.id }
      }.to raise_error(ActionController::RoutingError, 'Not supported format')
    end

    it 'returns only the items of the given list' do
      get :index, params: { todo_list_id: todo_list.id }, format: :json

      expect(response.status).to eq(200)
      expect(body.map { |i| i['id'] }).to eq([todo_item.id])
      expect(body[0].keys).to match_array(%w[id name completed todo_list_id created_at updated_at])
    end

    it 'returns an empty array when the list has no items' do
      todo_item.destroy

      get :index, params: { todo_list_id: todo_list.id }, format: :json

      expect(response.status).to eq(200)
      expect(body).to eq([])
    end

    it 'returns 404 when the list does not exist' do
      get :index, params: { todo_list_id: 0 }, format: :json

      expect(response.status).to eq(404)
    end
  end

  describe 'GET show' do
    it 'returns the item' do
      get :show, params: { todo_list_id: todo_list.id, id: todo_item.id }, format: :json

      expect(response.status).to eq(200)
      expect(body['id']).to eq(todo_item.id)
      expect(body['name']).to eq('Write specs')
      expect(body['completed']).to eq(false)
    end

    it 'returns 404 when the item does not exist' do
      get :show, params: { todo_list_id: todo_list.id, id: 0 }, format: :json

      expect(response.status).to eq(404)
    end

    it 'returns 404 when the item belongs to another list' do
      get :show, params: { todo_list_id: todo_list.id, id: other_item.id }, format: :json

      expect(response.status).to eq(404)
    end

    it 'raises a routing error for HTML' do
      expect {
        get :show, params: { todo_list_id: todo_list.id, id: todo_item.id }
      }.to raise_error(ActionController::RoutingError, 'Not supported format')
    end
  end

  describe 'POST create' do
    let(:params) { { todo_list_id: todo_list.id, name: 'New item' } }

    it 'creates an item with completed false by default' do
      expect {
        post :create, params: params, format: :json
      }.to change { todo_list.todo_items.count }.by(1)

      expect(response.status).to eq(201)
      expect(body['name']).to eq('New item')
      expect(body['completed']).to eq(false)
      expect(body['todo_list_id']).to eq(todo_list.id)
    end

    it 'accepts completed: true' do
      post :create, params: params.merge(completed: true), format: :json

      expect(response.status).to eq(201)
      expect(body['completed']).to eq(true)
    end

    it 'accepts params nested under todo_item' do
      post :create, params: { todo_list_id: todo_list.id, todo_item: { name: 'Nested' } }, format: :json

      expect(response.status).to eq(201)
      expect(body['name']).to eq('Nested')
    end

    it 'returns 422 without a name' do
      expect {
        post :create, params: { todo_list_id: todo_list.id }, format: :json
      }.not_to change(TodoItem, :count)

      expect(response.status).to eq(422)
      expect(body['errors']).to have_key('name')
    end

    it 'returns 422 with a blank name' do
      post :create, params: params.merge(name: ''), format: :json

      expect(response.status).to eq(422)
    end

    it 'returns 404 when the list does not exist' do
      post :create, params: { todo_list_id: 0, name: 'x' }, format: :json

      expect(response.status).to eq(404)
    end

    it 'ignores non permitted params' do
      post :create, params: params.merge(todo_list_id: todo_list.id, id: 9999, created_at: 1.year.ago), format: :json

      expect(response.status).to eq(201)
      expect(body['id']).not_to eq(9999)
      expect(body['todo_list_id']).to eq(todo_list.id)
    end
  end

  describe 'PATCH update' do
    let(:base) { { todo_list_id: todo_list.id, id: todo_item.id } }

    it 'updates the name' do
      patch :update, params: base.merge(name: 'Renamed'), format: :json

      expect(response.status).to eq(200)
      expect(body['name']).to eq('Renamed')
      expect(todo_item.reload.name).to eq('Renamed')
    end

    it 'marks the item as completed' do
      patch :update, params: base.merge(completed: true), format: :json

      expect(response.status).to eq(200)
      expect(todo_item.reload.completed).to eq(true)
    end

    it 'returns 422 and does not change the item with a blank name' do
      patch :update, params: base.merge(name: ''), format: :json

      expect(response.status).to eq(422)
      expect(todo_item.reload.name).to eq('Write specs')
    end

    it 'returns 404 when the item does not exist' do
      patch :update, params: base.merge(id: 0, name: 'x'), format: :json

      expect(response.status).to eq(404)
    end

    it 'returns 404 and does not change an item of another list' do
      patch :update, params: base.merge(id: other_item.id, name: 'Hacked'), format: :json

      expect(response.status).to eq(404)
      expect(other_item.reload.name).to eq('Foreign item')
    end
  end

  describe 'DELETE destroy' do
    it 'deletes the item' do
      expect {
        delete :destroy, params: { todo_list_id: todo_list.id, id: todo_item.id }, format: :json
      }.to change(TodoItem, :count).by(-1)

      expect(response.status).to eq(204)
      expect(response.body).to be_empty
    end

    it 'returns 404 when the item does not exist' do
      delete :destroy, params: { todo_list_id: todo_list.id, id: 0 }, format: :json

      expect(response.status).to eq(404)
    end

    it 'returns 404 and keeps an item of another list' do
      expect {
        delete :destroy, params: { todo_list_id: todo_list.id, id: other_item.id }, format: :json
      }.not_to change(TodoItem, :count)

      expect(response.status).to eq(404)
    end
  end
end
