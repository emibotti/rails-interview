require 'rails_helper'

RSpec.describe TodoSync::Runner do
  include_context 'with fake external todo api'

  def sync
    described_class.call(trigger: :spec, client: external_client)
  end

  def requests_to(method)
    fake_api.requests.select { |m, _path, _body| m == method }
  end

  let!(:list) { TodoList.create!(name: 'Local list') }
  let!(:items) { %w[a b c].map { |name| list.todo_items.create!(name: name) } }
  let(:remote) { fake_api.lists.first }

  before do
    sync # creates and links everything
    fake_api.clock = -> { Time.utc(2026, 6, 1) }
  end

  it 'makes a single request (the GET) when nothing changed' do
    before_count = fake_api.requests.size

    run = sync

    expect(fake_api.requests.size - before_count).to eq(1)
    expect(run.stats).to eq('remote_calls' => 1, 'http_requests' => 1)
  end

  describe 'lists' do
    it 'sends one PATCH for a renamed list and leaves it clean' do
      list.update!(name: 'Renamed')

      run = sync

      expect(requests_to('PATCH').size).to eq(1)
      expect(requests_to('PATCH').first[2]).to eq('name' => 'Renamed')
      expect(remote['name']).to eq('Renamed')
      expect(list.reload).to have_attributes(dirty_for_sync?: false, synced_version: 2, remote_updated_at: Time.utc(2026, 6, 1))
      expect(run.stats['lists_updated_remote']).to eq(1)
    end

    it 'marks the record as synced without a call when the remote already has the value' do
      external_client.update_todo_list(remote['id'], name: 'Same')
      list.update!(name: 'Same')

      run = sync

      expect(requests_to('PATCH').size).to eq(1) # only the one the spec made
      expect(list.reload.dirty_for_sync?).to be(false)
      expect(run.stats['skipped_noop']).to eq(1)
    end
  end

  describe 'items' do
    it 'sends only the fields that differ' do
      items.first.update!(completed: true)

      sync

      expect(requests_to('PATCH').map { |r| r[2] }).to eq([{ 'completed' => true }])
      expect(items.first.reload.dirty_for_sync?).to be(false)
      expect(remote['items'].first['completed']).to be(true)
    end

    it 'sends name changes as description' do
      items.last.update!(name: 'renamed', completed: true)

      sync

      expect(requests_to('PATCH').first[2]).to eq('description' => 'renamed', 'completed' => true)
    end

    it 'sends N - M PATCHes for a mark all when M items are already completed remotely' do
      remote['items'].first(2).each { |i| external_client.update_todo_item(remote['id'], i['id'], completed: true) }
      patches_before = requests_to('PATCH').size

      CompleteAllTodoItemsJob.perform_now(list, items.last.id)
      run = sync

      expect(requests_to('PATCH').size - patches_before).to eq(1) # 3 items - 2 already done
      expect(fake_api.lists.first['items'].map { |i| i['completed'] }).to all(be(true))
      expect(TodoItem.dirty).to be_empty
      expect(run.stats).to include('items_updated_remote' => 1, 'skipped_noop' => 2)
    end

    it 'marks many unchanged items in batches' do
      stub_const('TodoSync::BulkWriter::BATCH_SIZE', 2)
      remote['items'].each { |i| external_client.update_todo_item(remote['id'], i['id'], completed: true) }
      patches_before = requests_to('PATCH').size

      CompleteAllTodoItemsJob.perform_now(list, items.last.id)
      sync

      expect(requests_to('PATCH').size).to eq(patches_before)
      expect(TodoItem.dirty).to be_empty
    end

    it 'leaves the item dirty when it is edited during the PATCH' do
      items.first.update!(completed: true)
      allow(external_client).to receive(:update_todo_item).and_wrap_original do |original, *args, **kwargs|
        original.call(*args, **kwargs).tap { items.first.update!(name: 'edited meanwhile') }
      end

      sync

      expect(items.first.reload).to have_attributes(local_version: 3, synced_version: 2, dirty_for_sync?: true)
      expect(remote['items'].first['completed']).to be(true)

      allow(external_client).to receive(:update_todo_item).and_call_original
      sync
      expect(fake_api.lists.first['items'].first['description']).to eq('edited meanwhile')
      expect(items.first.reload.dirty_for_sync?).to be(false)
    end
  end

  describe 'failures' do
    it 'does not retry a 422, counts it and keeps the record dirty' do
      items.first.update!(completed: true)
      fake_api.fail_next(:patch, %r{todoitems}, status: 422, body: '{"error":"bad"}')

      run = sync

      expect(run.stats['failures']).to eq(1)
      expect(items.first.reload.dirty_for_sync?).to be(true)
      expect(run.status).to eq('succeeded')
    end

    it 'does not stop the other records when one fails' do
      items.each { |item| item.update!(completed: true) }
      fake_api.fail_next(:patch, %r{todoitems}, status: 422, times: 1)

      sync

      expect(TodoItem.dirty.count).to eq(1)
      expect(fake_api.lists.first['items'].count { |i| i['completed'] }).to eq(2)
    end

    it 'deletes locally, without callbacks, a record that is gone remotely (PATCH 404)' do
      fake_api.reset!
      fake_api.seed_list(name: 'unrelated')
      items.first.update!(completed: true)
      allow(TodoSync::Snapshot).to receive(:new).and_wrap_original do |original, lists|
        original.call(lists + [stale_remote_list])
      end

      sync

      expect(TodoItem.exists?(items.first.id)).to be(false)
      expect(SyncTombstone.count).to eq(0)
    end
  end

  # A list that is no longer in the fake but still in the (stale) snapshot, to force a 404.
  def stale_remote_list
    ExternalTodo::RemoteList.new(
      external_id: list.reload.external_id, name: list.name, items: items.map do |item|
        ExternalTodo::RemoteItem.new(external_id: item.reload.external_id, name: item.name, completed: false)
      end
    )
  end
end
