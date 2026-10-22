require 'rails_helper'

# Last write wins at record level, comparing the local updated_at with the remote one.
RSpec.describe TodoSync::Runner do
  include ActiveSupport::Testing::TimeHelpers
  include_context 'with fake external todo api'

  def sync
    described_class.call(trigger: :spec, client: external_client)
  end

  def patches
    fake_api.requests.select { |method, *| method == 'PATCH' }
  end

  let(:t0) { Time.utc(2026, 5, 1, 10) }
  let!(:list) { TodoList.create!(name: 'List') }
  let!(:item) { list.todo_items.create!(name: 'task') }
  let(:remote_list) { fake_api.find_list(list.external_id) }

  before do
    fake_api.clock = -> { t0 }
    sync
    [list, item].each(&:reload)
  end

  def edit_locally(at:, **attrs)
    travel_to(at) { item.update!(**attrs) }
  end

  def edit_remotely(at:, **attrs)
    fake_api.clock = -> { at }
    external_client.update_todo_item(list.external_id, item.external_id, **attrs)
  end

  def remote_item
    fake_api.find_list(list.external_id)['items'].first
  end

  it 'only local change: pushes it' do
    edit_locally(at: t0 + 1.hour, completed: true)

    run = sync

    expect(remote_item['completed']).to be(true)
    expect(run.stats['conflicts']).to be_nil
  end

  it 'only remote change: applies it' do
    edit_remotely(at: t0 + 1.hour, completed: true)

    run = sync

    expect(item.reload.completed).to be(true)
    expect(patches.size).to eq(1) # the one made by the spec
    expect(run.stats['conflicts']).to be_nil
  end

  it 'both changed, remote newer: the remote value wins and nothing is sent' do
    edit_locally(at: t0 + 1.hour, name: 'local name')
    edit_remotely(at: t0 + 2.hours, name: 'remote name')

    run = sync

    expect(item.reload).to have_attributes(name: 'remote name', dirty_for_sync?: false, updated_at: t0 + 2.hours)
    expect(remote_item['description']).to eq('remote name')
    expect(patches.size).to eq(1)
    expect(run.stats).to include('conflicts' => 1, 'items_updated_local' => 1)
  end

  it 'both changed, local newer: the local value is pushed' do
    edit_remotely(at: t0 + 1.hour, name: 'remote name')
    edit_locally(at: t0 + 2.hours, name: 'local name')

    run = sync

    expect(remote_item['description']).to eq('local name')
    expect(item.reload).to have_attributes(name: 'local name', dirty_for_sync?: false)
    expect(run.stats).to include('conflicts' => 1, 'items_updated_remote' => 1)
  end

  it 'a tie goes to the remote' do
    edit_locally(at: t0 + 1.hour, name: 'local name')
    edit_remotely(at: t0 + 1.hour, name: 'remote name')

    sync

    expect(item.reload.name).to eq('remote name')
  end

  it 'both changed to the same value: not a conflict, no request' do
    edit_locally(at: t0 + 2.hours, completed: true)
    edit_remotely(at: t0 + 1.hour, completed: true)
    patches_before = patches.size

    run = sync

    expect(patches.size).to eq(patches_before)
    expect(run.stats['conflicts']).to be_nil
    expect(item.reload.dirty_for_sync?).to be(false)
  end

  it 'lists are resolved the same way' do
    travel_to(t0 + 1.hour) { list.update!(name: 'local list') }
    fake_api.clock = -> { t0 + 2.hours }
    external_client.update_todo_list(list.external_id, name: 'remote list')

    sync

    expect(list.reload.name).to eq('remote list')
    expect(list.dirty_for_sync?).to be(false)
  end

  it 'is stable: running again changes nothing' do
    edit_locally(at: t0 + 1.hour, name: 'local name')
    edit_remotely(at: t0 + 2.hours, name: 'remote name')
    sync
    before_count = fake_api.requests.size

    run = sync

    expect(fake_api.requests.size - before_count).to eq(1)
    expect(run.stats).to eq('remote_calls' => 1, 'http_requests' => 1)
  end

  describe 'delete against edit' do
    it 'local delete, remote edit: the delete wins' do
      item.destroy!
      edit_remotely(at: t0 + 1.hour, name: 'edited remotely')
      allow(Rails.logger).to receive(:warn).and_call_original

      sync

      expect(Rails.logger).to have_received(:warn).with(a_string_including('delete wins', 'edited after the local delete'))
      expect(remote_item).to be_nil
      expect(list.todo_items.count).to eq(0)
      expect(SyncTombstone.count).to eq(0)
    end

    it 'remote delete, local edit: the delete wins' do
      TodoList.create!(name: 'keeps the snapshot big enough')
      sync
      edit_locally(at: t0 + 1.hour, completed: true)
      external_client.delete_todo_item(list.external_id, item.external_id)
      allow(Rails.logger).to receive(:warn).and_call_original

      sync

      expect(Rails.logger).to have_received(:warn).with(a_string_including('delete wins', 'its own unsynced changes (v2)'))
      expect(TodoItem.exists?(item.id)).to be(false)
      expect(fake_api.find_list(list.external_id)['items']).to be_empty
    end
  end
end
