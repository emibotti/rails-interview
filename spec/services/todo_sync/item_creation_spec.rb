require 'rails_helper'

# New items in a list that is already synced: the three strategies (D9).
RSpec.describe TodoSync::ItemCreation do
  include_context 'with fake external todo api'

  def sync
    TodoSync::Runner.call(trigger: :spec, client: external_client)
  end

  def requests_to(method)
    fake_api.requests.select { |m, _path, _body| m == method }
  end

  let!(:list) { TodoList.create!(name: 'Synced list') }
  let!(:old_items) { %w[a b].map { |name| list.todo_items.create!(name: name) } }
  let(:new_items) { %w[c d].map { |name| list.todo_items.create!(name: name) } }

  before do
    sync # the list and its first items are now remote
    [list, *old_items].each(&:reload)
    new_items
  end

  describe 'recreate_list (default)' do
    it 'sends 1 POST with all the items and 1 DELETE of the old list' do
      old_remote_id = list.external_id
      posts = requests_to('POST').size
      deletes = requests_to('DELETE').size

      run = sync

      expect(requests_to('POST').size - posts).to eq(1)
      expect(requests_to('DELETE').size - deletes).to eq(1)
      expect(fake_api.lists.size).to eq(1)
      remote = fake_api.lists.first
      expect(remote['id']).not_to eq(old_remote_id)
      expect(remote['source_id']).to eq("rails-interview:list:#{list.id}")
      expect(remote['items'].map { |i| i['description'] }).to eq(%w[a b c d])
      expect(run.stats).to include('lists_recreated_remote' => 1)
    end

    it 'links the list and every item to the new remote ids, and leaves nothing dirty or pending' do
      sync

      remote = fake_api.lists.first
      expect(list.reload.external_id).to eq(remote['id'])
      expect((old_items + new_items).map { |i| i.reload.external_id }).to eq(remote['items'].map { |i| i['id'] })
      expect(TodoList.dirty).to be_empty
      expect(TodoItem.dirty).to be_empty
      expect(SyncTombstone.count).to eq(0)
    end

    it 'converges: the next cycle only reads' do
      sync
      before_count = fake_api.requests.size

      run = sync

      expect(fake_api.requests.size - before_count).to eq(1)
      expect(run.stats).to eq('remote_calls' => 1, 'http_requests' => 1)
    end

    it 'keeps the tombstone when the DELETE of the old list fails, and finishes next cycle' do
      old_remote_id = list.external_id
      fake_api.fail_next(:delete, %r{/todolists}, status: 503, times: 3)

      sync

      expect(fake_api.lists.size).to eq(2) # duplicate for now
      expect(SyncTombstone.pluck(:external_id)).to eq([old_remote_id])
      expect(list.reload.external_id).not_to eq(old_remote_id)

      travel_to_after_backoff { sync }

      expect(fake_api.lists.map { |l| l['id'] }).to eq([list.reload.external_id])
      expect(SyncTombstone.count).to eq(0)
    end

    it 'adopts the new list after a POST that timed out, without leaving duplicates' do
      old_remote_id = list.external_id
      fake_api.timeout_next(:post, %r{/todolists}, after_processing: true)

      first = sync
      expect(first.stats['create_timeouts']).to eq(1)
      expect(fake_api.lists.size).to eq(2) # created remotely, the client saw a timeout
      expect(list.reload.external_id).to eq(old_remote_id)

      second = sync

      newest = fake_api.lists.find { |l| l['items'].size == 4 }
      expect(fake_api.lists.map { |l| l['id'] }).to eq([newest['id']])
      expect(list.reload.external_id).to eq(newest['id'])
      expect((old_items + new_items).map { |i| i.reload.external_id }).to eq(newest['items'].map { |i| i['id'] })
      expect(second.stats['lists_relinked']).to eq(1)
      expect(TodoItem.dirty).to be_empty
      expect(SyncTombstone.count).to eq(0)
    end

    it 'falls back to skip, with a clear error, above recreate_max_items' do
      allow(Rails.configuration.x.external_todo).to receive(:recreate_max_items).and_return(3)
      posts = requests_to('POST').size

      run = sync

      expect(requests_to('POST').size).to eq(posts)
      expect(new_items.map { |i| i.reload.sync_error }).to all(include('unsupported_by_remote', 'recreate_max_items=3'))
      expect(run.stats['items_skipped_unsupported']).to eq(2)
    end

    it 'does nothing for lists without new items' do
      sync
      posts = requests_to('POST').size

      sync

      expect(requests_to('POST').size).to eq(posts)
    end
  end

  describe 'skip' do
    item_creation_strategy 'skip'

    it 'makes no remote calls for the new items and flags them' do
      before_count = fake_api.requests.size

      run = sync

      expect(fake_api.requests.size - before_count).to eq(1) # the GET
      expect(new_items.map { |i| i.reload.sync_error }).to all(start_with('unsupported_by_remote'))
      expect(new_items.map { |i| i.external_id }).to all(be_nil)
      expect(run.stats['items_skipped_unsupported']).to eq(2)
      expect(fake_api.lists.first['items'].size).to eq(2)
    end

    it 'does not rewrite the flag on later cycles' do
      sync

      run = sync

      expect(run.stats['items_skipped_unsupported']).to be_nil
    end
  end

  describe 'api_endpoint' do
    item_creation_strategy 'api_endpoint'

    it 'sends 1 POST per new item' do
      fake_api.supports_item_creation = true
      posts = requests_to('POST').size

      run = sync

      expect(requests_to('POST').size - posts).to eq(2)
      expect(fake_api.lists.first['items'].map { |i| i['description'] }).to eq(%w[a b c d])
      expect(new_items.map { |i| i.reload.external_id }).to all(be_present)
      expect(TodoItem.dirty).to be_empty
      expect(run.stats['items_created_remote']).to eq(2)
    end

    it 'counts a failure when the API does not have the endpoint' do
      run = sync # the fake answers 404 unless supports_item_creation

      expect(run.stats['failures']).to eq(2)
      expect(new_items.map { |i| i.reload.external_id }).to all(be_nil)
    end
  end

  it 'rejects an unknown strategy' do
    allow(Rails.configuration.x.external_todo).to receive(:item_creation_strategy).and_return('magic')

    expect { described_class.strategy }.to raise_error(ArgumentError, /magic.*recreate_list, skip, api_endpoint/)
  end

  def travel_to_after_backoff(&block)
    extend ActiveSupport::Testing::TimeHelpers
    travel_to(10.minutes.from_now, &block)
  end
end
