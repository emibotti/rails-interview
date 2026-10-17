require 'rails_helper'

describe 'Todo items checkbox', type: :request do
  let!(:todo_list) { TodoList.create!(name: 'List') }
  let!(:todo_item) { todo_list.todo_items.create!(name: 'Item') }
  let(:headers) { { 'Accept' => 'application/json' } }

  def toggle(completed, item: todo_item, list: todo_list)
    patch todo_list_todo_item_path(list, item), params: { completed: completed }, as: :json, headers: headers
  end

  describe 'PATCH /todolists/:todo_list_id/todoitems/:id' do
    it 'marks the item as completed' do
      toggle(true)

      expect(response.status).to eq(200)
      expect(JSON.parse(response.body)).to eq('id' => todo_item.id, 'completed' => true)
      expect(todo_item.reload.completed).to eq(true)
    end

    it 'unmarks a completed item' do
      todo_item.update!(completed: true)

      toggle(false)

      expect(response.status).to eq(200)
      expect(JSON.parse(response.body)['completed']).to eq(false)
      expect(todo_item.reload.completed).to eq(false)
    end

    it 'is idempotent' do
      2.times { toggle(true) }

      expect(response.status).to eq(200)
      expect(todo_item.reload.completed).to eq(true)
    end

    it 'updates updated_at' do
      todo_item.update_columns(updated_at: 1.day.ago)

      toggle(true)

      expect(todo_item.reload.updated_at).to be_within(1.minute).of(Time.current)
    end

    it 'does not touch the other items' do
      other = todo_list.todo_items.create!(name: 'Other')

      toggle(true)

      expect(other.reload.completed).to eq(false)
    end

    it 'accepts the form encoded boolean strings' do
      patch todo_list_todo_item_path(todo_list, todo_item), params: { completed: 'true' }, headers: headers

      expect(response.status).to eq(200)
      expect(todo_item.reload.completed).to eq(true)
    end

    it 'returns 422 without completed' do
      patch todo_list_todo_item_path(todo_list, todo_item), params: {}, as: :json, headers: headers

      expect(response.status).to eq(422)
    end

    it 'returns 422 with an invalid completed value and keeps the item' do
      toggle('maybe')

      expect(response.status).to eq(422)
      expect(todo_item.reload.completed).to eq(false)
    end

    it 'returns 404 for an item of another list' do
      other_list = TodoList.create!(name: 'Other list')

      expect { toggle(true, list: other_list) }.to raise_error(ActiveRecord::RecordNotFound)
      expect(todo_item.reload.completed).to eq(false)
    end

    it 'returns 404 when the item does not exist' do
      expect {
        patch todo_list_todo_item_path(todo_list, id: 0), params: { completed: true }, as: :json, headers: headers
      }.to raise_error(ActiveRecord::RecordNotFound)
    end

    it 'raises a routing error for HTML' do
      expect {
        patch todo_list_todo_item_path(todo_list, todo_item), params: { completed: true }
      }.to raise_error(ActionController::RoutingError, 'Not supported format')
    end
  end

  describe 'CSRF protection' do
    around do |example|
      original = ActionController::Base.allow_forgery_protection
      ActionController::Base.allow_forgery_protection = true
      example.run
      ActionController::Base.allow_forgery_protection = original
    end

    it 'rejects a request without a token' do
      expect { toggle(true) }.to raise_error(ActionController::InvalidAuthenticityToken)
      expect(todo_item.reload.completed).to eq(false)
    end

    it 'accepts the token sent in the X-CSRF-Token header, as the Stimulus controller does' do
      get todo_list_path(todo_list)
      token = Nokogiri::HTML(response.body).at_css('meta[name=csrf-token]')['content']

      patch todo_list_todo_item_path(todo_list, todo_item), params: { completed: true }, as: :json,
        headers: headers.merge('X-CSRF-Token' => token)

      expect(response.status).to eq(200)
      expect(todo_item.reload.completed).to eq(true)
    end
  end
end
