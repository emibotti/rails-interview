require 'rails_helper'

# Pull half of the sync cycle (remote -> local), exercised through the Runner.
RSpec.describe TodoSync::Runner do
  include_context 'with fake external todo api'

  def pull
    described_class.call(trigger: :spec, client: external_client)
  end

  def seed_remote(name: 'Remote', items: [{ description: 'a', completed: false }], source_id: nil)
    fake_api.seed_list(name: name, source_id: source_id, items: items)
  end

  def write_queries
    queries = []
    callback = ->(*, payload) { queries << payload[:sql] if payload[:sql] =~ /\A\s*(INSERT|UPDATE|DELETE)/i && payload[:name] != 'SCHEMA' }
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') { yield }
    # The run bookkeeping (sync_runs / sync_states) is not data written by the pull.
    queries.reject { |sql| sql =~ /sync_(runs|states)/ }
  end

  describe 'importing remote records' do
    it 'creates lists and items locally, mapping description to name' do
      remote = seed_remote(items: [{ description: 'a', completed: true }, { description: 'b', completed: false }])

      run = pull

      expect(run.status).to eq('succeeded')
      list = TodoList.find_by!(external_id: remote['id'])
      expect(list.name).to eq('Remote')
      expect(list.todo_items.order(:id).pluck(:name, :completed)).to eq([['a', true], ['b', false]])
      expect(list.todo_items.pluck(:external_id)).to match_array(remote['items'].map { |i| i['id'] })
      expect(run.stats).to include('lists_created_local' => 1, 'items_created_local' => 2, 'remote_calls' => 1)
    end

    it 'imports records born in sync: not dirty, with the remote timestamps' do
      fake_api.clock = -> { Time.utc(2026, 3, 1, 10) }
      remote = seed_remote

      pull

      list = TodoList.find_by!(external_id: remote['id'])
      item = list.todo_items.first
      [list, item].each do |record|
        expect(record).to have_attributes(local_version: 1, synced_version: 1, dirty_for_sync?: false)
        expect(record.remote_updated_at).to eq(Time.utc(2026, 3, 1, 10))
      end
      expect(list.created_at).to eq(Time.utc(2026, 3, 1, 10))
      expect(TodoList.dirty).to be_empty
    end

    it 'does one request per cycle' do
      3.times { seed_remote }

      pull

      expect(fake_api.requests.size).to eq(1)
    end

    it 'imports a list with many items in batches' do
      stub_const('TodoSync::Puller::BATCH_SIZE', 2)
      seed_remote(items: Array.new(5) { |i| { description: "i#{i}", completed: false } })

      pull

      expect(TodoItem.count).to eq(5)
    end

    it 'skips remote records with a blank name' do
      seed_remote(name: '')
      seed_remote(name: 'Valid', items: [{ description: '', completed: false }, { description: 'ok', completed: false }])

      run = pull

      expect(TodoList.pluck(:name)).to eq(['Valid'])
      expect(TodoItem.pluck(:name)).to eq(['ok'])
      expect(run.stats['skipped_invalid']).to eq(2)
    end

    it 'leaves records created by us to the linker' do
      seed_remote(name: 'Ours', source_id: 'rails-interview:list:99')
      seed_remote(name: 'Foreign', source_id: 'other-system:7')

      run = pull

      expect(TodoList.pluck(:name)).to eq(['Foreign'])
      expect(run.stats['pending_link']).to eq(1)
    end
  end

  describe 'idempotence' do
    it 'does not write anything when run twice' do
      seed_remote(items: [{ description: 'a', completed: false }, { description: 'b', completed: true }])
      pull

      expect(write_queries { pull }).to be_empty
      expect(TodoList.count).to eq(1)
      expect(TodoItem.count).to eq(2)
    end
  end

  describe 'remote changes on linked records' do
    let!(:remote) { seed_remote }
    let(:remote_item_id) { remote['items'].first['id'] }

    before do
      fake_api.clock = -> { Time.utc(2026, 1, 1) }
      pull
      fake_api.clock = -> { Time.utc(2026, 2, 1) }
    end

    let(:list) { TodoList.find_by!(external_id: remote['id']) }
    let(:item) { list.todo_items.first }

    it 'applies a remote change to a clean record without echo' do
      external_client.update_todo_list(remote['id'], name: 'Renamed remotely')
      external_client.update_todo_item(remote['id'], remote_item_id, completed: true)

      run = pull

      expect(list.reload.name).to eq('Renamed remotely')
      expect(item.reload.completed).to be(true)
      expect(list).to have_attributes(local_version: 1, synced_version: 1)
      expect(item).to have_attributes(local_version: 1, synced_version: 1)
      expect(list.remote_updated_at).to eq(Time.utc(2026, 2, 1))
      expect(TodoList.dirty).to be_empty
      expect(TodoItem.dirty).to be_empty
      expect(run.stats).to include('lists_updated_local' => 1, 'items_updated_local' => 1)
    end

    it 'only records the new remote timestamp when the values are equal' do
      external_client.update_todo_list(remote['id'], name: remote['name'])

      expect { pull }.not_to(change { list.reload.name })
      expect(list.remote_updated_at).to eq(Time.utc(2026, 2, 1))
    end

    it 'does not overwrite a record that is dirty locally' do
      list.update!(name: 'Local edit')
      known_remote_updated_at = list.remote_updated_at
      external_client.update_todo_list(remote['id'], name: 'Remote edit')

      run = pull

      expect(list.reload).to have_attributes(name: 'Local edit', local_version: 2, synced_version: 1)
      expect(list.remote_updated_at).to eq(known_remote_updated_at) # still detectable as a conflict
      expect(run.stats['conflicts']).to eq(1)
    end

    it 'does not overwrite an edit made while the pull was running' do
      external_client.update_todo_list(remote['id'], name: 'Remote edit')
      allow(TodoList).to receive(:linked).and_wrap_original do |original|
        original.call.tap { list.update!(name: 'Edited meanwhile') } # edit after the pull read the records
      end

      pull

      expect(list.reload).to have_attributes(name: 'Edited meanwhile', local_version: 2)
    end

    it 'creates new remote items in a linked list' do
      remote_list = external_client.list_todo_lists.first
      fake_api.supports_item_creation = true
      external_client.create_todo_item(remote_list.external_id, name: 'new remote', completed: false, source_id: nil)

      pull

      expect(list.todo_items.pluck(:name)).to match_array(['a', 'new remote'])
    end
  end

  describe 'failures' do
    it 'aborts the run and releases the lock when the snapshot fails' do
      fake_api.fail_next(:get, %r{/todolists}, status: 500, times: 5)

      run = pull

      expect(run).to have_attributes(status: 'aborted', error: a_string_including('500'))
      expect(SyncState.locked?).to be(false)
    end

    it 'returns :busy when another cycle holds the lock' do
      SyncState.acquire_lock!

      expect(pull).to eq(:busy)
      expect(fake_api.requests).to be_empty
    end

    it 'marks the run as failed and releases the lock on unexpected errors' do
      seed_remote
      allow(TodoSync::Puller).to receive(:call).and_raise('boom')

      expect { pull }.to raise_error('boom')
      expect(SyncRun.last.status).to eq('failed')
      expect(SyncState.locked?).to be(false)
    end
  end
end
