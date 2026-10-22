require 'rails_helper'

# End to end against the fake: changes on both sides, then one cycle (twice) and local == remote.
RSpec.describe 'Sync convergence' do
  include_context 'with fake external todo api'

  def sync
    TodoSync::Runner.call(trigger: :spec, client: external_client)
  end

  def local_state
    TodoList.includes(:todo_items).order(:name).map do |list|
      [list.name, list.todo_items.sort_by(&:name).map { |item| [item.name, item.completed] }]
    end
  end

  def remote_state
    fake_api.lists.sort_by { |list| list['name'] }.map do |list|
      [list['name'], list['items'].sort_by { |item| item['description'] }.map { |item| [item['description'], item['completed']] }]
    end
  end

  it 'converges after creates, edits and deletes on both sides' do
    keep = TodoList.create!(name: 'Keep')
    edited = TodoList.create!(name: 'Edit me')
    doomed = TodoList.create!(name: 'Delete me locally')
    removed_remotely = TodoList.create!(name: 'Delete me remotely')
    [keep, edited, doomed, removed_remotely].each { |l| 2.times { |i| l.todo_items.create!(name: "#{l.name} #{i}") } }
    4.times { |i| TodoList.create!(name: "Filler #{i}") } # keeps the deletion guard quiet
    sync
    [keep, edited, doomed, removed_remotely].each(&:reload)

    # local side
    edited.update!(name: 'Edited locally')
    keep.todo_items.first.update!(completed: true)
    keep.todo_items.create!(name: 'New local item')
    TodoList.create!(name: 'New local list').todo_items.create!(name: 'inside')
    doomed.destroy!
    # remote side
    fake_api.clock = -> { Time.current + 1.hour }
    fake_api.seed_list(name: 'Remote only', items: [{ description: 'r1', completed: true }])
    remote_keep = fake_api.find_list(keep.external_id)
    external_client.update_todo_item(keep.external_id, remote_keep['items'].last['id'], completed: true)
    external_client.delete_todo_list(removed_remotely.external_id)

    sync
    sync

    expect(local_state).to eq(remote_state)
    expect(TodoItem.dirty).to be_empty
    expect(TodoList.dirty).to be_empty
    expect(SyncTombstone.count).to eq(0)
    expect(local_state.map(&:first)).to include('Edited locally', 'New local list', 'Remote only', 'Keep')
    expect(local_state.map(&:first)).not_to include('Delete me locally', 'Delete me remotely')
    expect(sync.stats).to eq('remote_calls' => 1, 'http_requests' => 1)
  end
end
