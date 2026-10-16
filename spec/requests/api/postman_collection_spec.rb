require 'rails_helper'

# Mirrors the flow of the external Postman collection
# (crunchloop/interview-tests): same paths, bodies and expected statuses.
describe 'Postman collection flow', type: :request do
  let(:headers) { { 'Accept' => 'application/json' } }

  # Not a memoized `let`: the response changes between requests.
  def json
    JSON.parse(response.body)
  end

  it 'runs the whole collection' do
    post '/api/todolists', params: { name: 'Example List' }, as: :json, headers: headers
    expect(response.status).to eq(200)
    expect(json).to have_key('id')
    list_id = json['id']

    get '/api/todolists', headers: headers
    expect(response.status).to eq(200)
    expect(json).to be_an(Array)

    post "/api/todolists/#{list_id}/todos", params: { description: 'Item Description', completed: false }, as: :json, headers: headers
    expect(response.status).to eq(200)
    expect(json).to have_key('id')
    item_id = json['id']

    get "/api/todolists/#{list_id}/todos", headers: headers
    expect(response.status).to eq(200)
    expect(json).to be_an(Array)
    expect(json.first['description']).to eq('Item Description')

    put "/api/todolists/#{list_id}/todos/#{item_id}", params: { description: 'Updated Description', completed: true }, as: :json, headers: headers
    expect(response.status).to eq(200)
    expect(json['description']).to eq('Updated Description')
    expect(json['completed']).to eq(true)

    delete "/api/todolists/#{list_id}/todos/#{item_id}", headers: headers
    expect([200, 204]).to include(response.status)

    put "/api/todolists/#{list_id}", params: { name: 'Updated List Name' }, as: :json, headers: headers
    expect(response.status).to eq(200)
    expect(json['name']).to eq('Updated List Name')

    delete "/api/todolists/#{list_id}", headers: headers
    expect([200, 204]).to include(response.status)
  end

  it 'serves the same items under /todoitems and /todos' do
    list = TodoList.create!(name: 'List')
    list.todo_items.create!(name: 'Item')

    get "/api/todolists/#{list.id}/todoitems", headers: headers
    items = json
    get "/api/todolists/#{list.id}/todos", headers: headers

    expect(json).to eq(items)
  end
end
