require 'rails_helper'

describe TodoList do
  let(:todo_list) { TodoList.create!(name: 'List') }

  it 'is invalid without a name' do
    expect(TodoList.new).not_to be_valid
  end

  describe 'mark all lock' do
    it 'is not running by default' do
      expect(todo_list.mark_all_running?).to eq(false)
    end

    it 'can be acquired when free' do
      expect(todo_list.acquire_mark_all_lock!).to eq(true)
      expect(todo_list.mark_all_running?).to eq(true)
      expect(todo_list.reload.mark_all_running?).to eq(true)
    end

    it 'cannot be acquired twice' do
      todo_list.acquire_mark_all_lock!

      expect(TodoList.find(todo_list.id).acquire_mark_all_lock!).to eq(false)
    end

    it 'can be acquired again once released' do
      todo_list.acquire_mark_all_lock!
      todo_list.release_mark_all_lock!

      expect(todo_list.reload.mark_all_running?).to eq(false)
      expect(todo_list.acquire_mark_all_lock!).to eq(true)
    end

    it 'can be taken over when the heartbeat is stale' do
      todo_list.update_columns(mark_all_heartbeat_at: (TodoList::MARK_ALL_STALE_AFTER + 1.second).ago)

      expect(todo_list.mark_all_running?).to eq(false)
      expect(todo_list.acquire_mark_all_lock!).to eq(true)
    end

    it 'is kept alive by the heartbeat' do
      todo_list.update_columns(mark_all_heartbeat_at: 1.minute.ago)
      todo_list.mark_all_heartbeat!

      expect(todo_list.reload.mark_all_heartbeat_at).to be_within(1.second).of(Time.current)
    end
  end
end
