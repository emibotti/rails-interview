require 'rails_helper'

describe TodoItem do
  let(:todo_list) { TodoList.create!(name: 'List') }

  it 'is valid with a name and a todo list' do
    expect(TodoItem.new(name: 'Item', todo_list: todo_list)).to be_valid
  end

  it 'is invalid without a name' do
    item = TodoItem.new(todo_list: todo_list)

    expect(item).not_to be_valid
    expect(item.errors[:name]).to be_present
  end

  it 'is invalid with a blank name' do
    expect(TodoItem.new(name: '  ', todo_list: todo_list)).not_to be_valid
  end

  it 'is invalid without a todo list' do
    expect(TodoItem.new(name: 'Item')).not_to be_valid
  end

  it 'defaults completed to false' do
    expect(TodoItem.new.completed).to eq(false)
  end

  it 'is destroyed along with its todo list' do
    todo_list.todo_items.create!(name: 'Item')

    expect { todo_list.destroy }.to change(TodoItem, :count).by(-1)
  end
end
