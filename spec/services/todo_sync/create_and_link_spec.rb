require 'rails_helper'

# Push of local creates and linking by source_id, through the Runner.
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

  describe 'creating local lists remotely' do
    it 'creates the list with its 3 items in one POST and links everything' do
      run = sync

      expect(requests_to('POST').size).to eq(1)
      remote = fake_api.lists.first
      expect(remote).to include('name' => 'Local list', 'source_id' => "rails-interview:list:#{list.id}")
      expect(remote['items'].map { |i| i['description'] }).to eq(%w[a b c])

      expect(list.reload.external_id).to eq(remote['id'])
      expect(list.remote_updated_at).to eq(Time.zone.parse(remote['updated_at']))
      items.each_with_index do |item, index|
        remote_item = remote['items'][index]
        expect(item.reload.external_id).to eq(remote_item['id'])
        expect(remote_item['source_id']).to eq("rails-interview:item:#{item.id}")
      end
      expect(run.stats).to include('lists_created_remote' => 1, 'items_created_remote' => 3, 'remote_calls' => 2)
    end

    it 'marks what was sent as synced' do
      sync

      [list.reload, *items.map(&:reload)].each do |record|
        expect(record).to have_attributes(local_version: 1, synced_version: 1, dirty_for_sync?: false)
      end
    end

    it 'sends the completed state and does not post lists that are already linked' do
      items.first.update!(completed: true)
      sync
      expect(fake_api.lists.first['items'].first['completed']).to be(true)

      expect { sync }.not_to(change { requests_to('POST').size })
    end

    it 'does not re-post when the cycle is repeated, and the second cycle makes one request (the GET)' do
      sync
      count_before = fake_api.requests.size

      sync

      expect(fake_api.requests.size - count_before).to eq(1)
      expect(fake_api.lists.size).to eq(1)
    end

    it 'leaves the records dirty when they are edited during the POST' do
      allow(external_client).to receive(:create_todo_list).and_wrap_original do |original, **args|
        original.call(**args).tap do
          list.update!(name: 'Edited during POST')
          items.first.update!(completed: true)
        end
      end

      sync

      expect(list.reload).to have_attributes(external_id: be_present, local_version: 2, synced_version: 1, dirty_for_sync?: true)
      expect(items.first.reload).to have_attributes(external_id: be_present, local_version: 2, synced_version: 1)
      expect(items.last.reload.dirty_for_sync?).to be(false)
    end

    it 'leaves items created during the POST unlinked' do
      late_item = nil
      allow(external_client).to receive(:create_todo_list).and_wrap_original do |original, **args|
        original.call(**args).tap { late_item = list.todo_items.create!(name: 'late') }
      end

      sync

      expect(late_item.reload).to have_attributes(external_id: nil, synced_version: 0)
    end

    it 'links the items in batches' do
      stub_const('TodoSync::BulkWriter::BATCH_SIZE', 2)

      sync

      expect(items.map { |i| i.reload.external_id }).to all(be_present)
      expect(items.map(&:external_id).uniq.size).to eq(3)
    end

    it 'matches items by position when the API does not echo source_ids' do
      stub_const('ExternalTodo::Mapper', ExternalTodo::Mapper.dup)
      allow(ExternalTodo::Mapper).to receive(:remote_item).and_wrap_original do |original, hash|
        original.call(hash.merge('source_id' => nil))
      end

      sync

      expect(items.map { |i| i.reload.external_id }).to eq(fake_api.lists.first['items'].map { |i| i['id'] })
    end
  end

  describe 'ambiguous POST (processed but timed out)' do
    it 'ends with a single remote list, linked, after the next cycle' do
      fake_api.timeout_next(:post, %r{/todolists}, after_processing: true)

      first = sync
      expect(first.stats['create_timeouts']).to eq(1)
      expect(list.reload.external_id).to be_nil
      expect(fake_api.lists.size).to eq(1) # it was created remotely

      second = sync

      expect(requests_to('POST').size).to eq(1) # never re-posted
      expect(fake_api.lists.size).to eq(1)
      remote = fake_api.lists.first
      expect(list.reload.external_id).to eq(remote['id'])
      expect(items.map { |i| i.reload.external_id }).to eq(remote['items'].map { |i| i['id'] })
      expect(second.stats).to include('lists_linked' => 1, 'items_linked' => 3)
    end

    it 'does not link a record whose source_id belongs to a deleted local record' do
      remote = fake_api.seed_list(name: 'Ghost', source_id: 'rails-interview:list:99999')

      run = sync

      expect(run.stats['orphans']).to eq(1)
      expect(fake_api.find_list(remote['id'])).to be_present
      expect(TodoList.where(external_id: remote['id'])).to be_empty
    end
  end

  describe 'duplicates' do
    it 'tombstones a remote list that duplicates an already linked local list, and deletes it' do
      sync # creates and links the list
      duplicate = fake_api.seed_list(name: 'Local list', source_id: "rails-interview:list:#{list.id}")

      run = sync

      expect(run.stats).to include('duplicates_found' => 1, 'lists_deleted_remote' => 1)
      expect(fake_api.lists.map { |l| l['id'] }).to eq([list.reload.external_id])
      expect(fake_api.find_list(duplicate['id'])).to be_nil
      expect(SyncTombstone.count).to eq(0)
    end

    it 'keeps the tombstone of a duplicate whose DELETE fails' do
      sync
      duplicate = fake_api.seed_list(name: 'Local list', source_id: "rails-interview:list:#{list.id}")
      fake_api.fail_next(:delete, %r{/todolists}, status: 503, times: 10)

      sync

      expect(SyncTombstone.pluck(:external_id)).to eq([duplicate['id']])
    end

    it 'is idempotent' do
      sync
      fake_api.seed_list(name: 'Local list', source_id: "rails-interview:list:#{list.id}")

      2.times { sync }

      expect(fake_api.lists.size).to eq(1)
      expect(SyncTombstone.count).to eq(0)
    end
  end

  describe 'failures' do
    it 'counts a 422 without retrying and keeps the list unlinked' do
      fake_api.fail_next(:post, %r{/todolists}, status: 422, body: '{"error":"bad"}')

      run = sync

      expect(requests_to('POST').size).to eq(1)
      expect(run.stats['failures']).to eq(1)
      expect(list.reload.external_id).to be_nil
      expect(run.status).to eq('succeeded')
    end

    it 'keeps going with the next list after a failure' do
      other = TodoList.create!(name: 'Other')
      fake_api.fail_next(:post, %r{/todolists}, status: 500)

      sync

      expect([list.reload.external_id, other.reload.external_id].compact.size).to eq(1)
    end
  end
end
