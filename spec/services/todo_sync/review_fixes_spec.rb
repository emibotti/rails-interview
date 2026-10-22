require 'rails_helper'

# Regression specs for the findings of the final code review.
RSpec.describe 'Code review fixes' do
  include ActiveSupport::Testing::TimeHelpers
  include_context 'with fake external todo api'

  def sync
    TodoSync::Runner.call(trigger: :spec, client: external_client)
  end

  def requests_to(method)
    fake_api.requests.select { |m, *| m == method }
  end

  describe 'the lock' do
    it 'is released when the run cannot be created' do
      allow(SyncRun).to receive(:start!).and_raise(ActiveRecord::StatementInvalid, 'database is locked')

      expect { sync }.to raise_error(ActiveRecord::StatementInvalid)
      expect(SyncState.locked?).to be(false)
    end

    it 'keeps its heartbeat fresh during a slow cycle, once per HEARTBEAT_EVERY' do
      TodoList.create!(name: 'L')
      SyncState.acquire_lock!
      SyncState.instance.update_columns(lock_heartbeat_at: 4.minutes.ago)
      expect { SyncState.heartbeat_if_due! }.not_to(change { SyncState.instance.reload.lock_heartbeat_at }) # just acquired

      travel_to((SyncState::HEARTBEAT_EVERY + 1.second).from_now) do
        expect { SyncState.heartbeat_if_due! }.to(change { SyncState.instance.reload.lock_heartbeat_at })
      end
    end

    it 'is refreshed before an API call when due' do
      SyncState.acquire_lock!
      stale = 4.minutes.ago
      SyncState.instance.update_columns(lock_heartbeat_at: stale)
      client = TodoSync::GuardedClient.new(external_client, threshold: 5)

      travel_to((SyncState::HEARTBEAT_EVERY + 1.second).from_now) { client.list_todo_lists }

      expect(SyncState.instance.reload.lock_heartbeat_at).to be > stale
    end
  end

  describe 'requesting a sync after commit' do
    it 'never turns a successful write into an error', :todo_sync do
      allow(TodoSync::Scheduler).to receive(:request!).and_raise(ActiveRecord::StatementInvalid, 'database is locked')
      allow(Rails.logger).to receive(:error).and_call_original

      list = nil
      expect { list = TodoList.create!(name: 'saved anyway') }.not_to raise_error

      expect(TodoList.exists?(list.id)).to be(true)
      expect(Rails.logger).to have_received(:error).with(a_string_including('could not request a sync'))
    end
  end

  describe 'authentication errors' do
    let!(:list) { TodoList.create!(name: 'L') }
    let!(:items) { Array.new(8) { |i| list.todo_items.create!(name: "i#{i}") } }

    before do
      sync
      [list, *items].each(&:reload)
      allow(Rails.configuration.x.todo_sync).to receive(:circuit_breaker_threshold).and_return(3)
    end

    it 'do not dead-letter records: they trip the circuit breaker and back off' do
      items.each { |item| item.update!(completed: true) }
      fake_api.fail_next(:patch, %r{todoitems}, status: 401, times: 100)

      run = sync

      expect(run.status).to eq('aborted')
      expect(run.error).to include('circuit breaker')
      expect(TodoItem.dead_letters).to be_empty
      expect(requests_to('PATCH').size).to eq(3)
    end
  end

  describe 'linking items of lists we did not create' do
    item_creation_strategy 'api_endpoint'

    it 'binds an item whose POST timed out, instead of posting it again' do
      remote = fake_api.seed_list(name: 'Imported', source_id: 'other-system:1', items: [{ description: 'remote item', completed: false }])
      sync
      list = TodoList.find_by!(external_id: remote['id'])
      fake_api.supports_item_creation = true
      item = list.todo_items.create!(name: 'mine')
      fake_api.timeout_next(:post, %r{todoitems}, after_processing: true)

      sync
      expect(requests_to('POST').size).to eq(1)
      expect(item.reload.external_id).to be_nil

      second = sync

      expect(requests_to('POST').size).to eq(1) # not posted again
      expect(item.reload.external_id).to eq(fake_api.find_list(remote['id'])['items'].find { |i| i['description'] == 'mine' }['id'])
      expect(second.stats['items_linked']).to eq(1)
      expect(fake_api.find_list(remote['id'])['items'].size).to eq(2)
    end

    it 'does not write anything when every item is already linked' do
      list = TodoList.create!(name: 'Ours')
      list.todo_items.create!(name: 'a')
      sync
      linking_updates = []
      callback = ->(*, payload) { linking_updates << payload[:sql] if payload[:sql] =~ /UPDATE "todo_items"/ }

      ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') { sync }

      expect(linking_updates).to be_empty
    end
  end

  describe 'pairing items of a created list' do
    item_creation_strategy 'skip'

    it 'ignores remote items whose source_id is not an item' do
      list = TodoList.create!(name: 'Pair')
      first, second = %w[a b].map { |name| list.todo_items.create!(name: name) }
      allow(external_client).to receive(:create_todo_list).and_wrap_original do |original, **args|
        remote = original.call(**args)
        remote.items.first.source_id = "rails-interview:list:#{first.id}" # wrong kind, same number
        remote.items.pop # and the sizes differ, so there is no positional fallback either
        remote
      end

      run = sync

      expect(first.reload.external_id).to be_nil
      expect(second.reload.external_id).to be_nil
      expect(run.stats['unpaired_items']).to eq(2)
    end
  end

  describe 'uploading big lists in batches' do
    before { stub_const('TodoSync::CreatePusher', TodoSync::CreatePusher) }

    it 'sends only create_batch_size items in the first POST and counts the rest as deferred' do
      Rails.configuration.x.external_todo.item_creation_strategy = 'skip'
      allow(Rails.configuration.x.external_todo).to receive(:create_batch_size).and_return(3)
      list = TodoList.create!(name: 'Big')
      TodoItem.insert_all(Array.new(8) { |i| { todo_list_id: list.id, name: "item #{i}", completed: false, created_at: Time.current, updated_at: Time.current } })

      run = sync

      expect(fake_api.lists.first['items'].size).to eq(3)
      expect(run.stats['items_deferred']).to eq(5)
      expect(list.todo_items.unlinked.count).to eq(5)
    ensure
      Rails.configuration.x.external_todo.item_creation_strategy = 'recreate_list'
    end

    context 'with the api_endpoint strategy' do
      item_creation_strategy 'api_endpoint'

      it 'creates the rest over several cycles, each one a background job' do
        allow(Rails.configuration.x.external_todo).to receive(:create_batch_size).and_return(3)
        allow(Rails.configuration.x.external_todo).to receive(:item_creation_batch_size).and_return(2)
        fake_api.supports_item_creation = true
        Rails.configuration.x.todo_sync.enabled = true
        list = TodoList.create!(name: 'Big')
        TodoItem.insert_all(Array.new(8) { |i| { todo_list_id: list.id, name: "item #{i}", completed: false, created_at: Time.current, updated_at: Time.current } })
        TodoSync::Scheduler.clear!

        first = sync
        expect(fake_api.lists.first['items'].size).to eq(3 + 2)
        expect(first.stats['item_creation_continues']).to eq(1)
        expect(ActiveJob::Base.queue_adapter.enqueued_jobs.map { |j| j['arguments'] }).to include(['continue_item_creation'])

        TodoSync::Scheduler.clear!
        2.times { sync; TodoSync::Scheduler.clear! }

        expect(fake_api.lists.first['items'].size).to eq(8)
        expect(list.todo_items.unlinked.count).to eq(0)
        expect(fake_api.lists.size).to eq(1)
      ensure
        Rails.configuration.x.todo_sync.enabled = false
      end
    end

    context 'with the default recreate_list strategy' do
      it 'flags the remaining items instead of recreating a list above recreate_max_items' do
        allow(Rails.configuration.x.external_todo).to receive(:create_batch_size).and_return(3)
        allow(Rails.configuration.x.external_todo).to receive(:recreate_max_items).and_return(5)
        list = TodoList.create!(name: 'Big')
        TodoItem.insert_all(Array.new(8) { |i| { todo_list_id: list.id, name: "item #{i}", completed: false, created_at: Time.current, updated_at: Time.current } })

        run = sync

        expect(run.stats['items_skipped_unsupported']).to eq(5)
        expect(list.todo_items.unlinked.first.sync_error).to include('api_endpoint')
        expect(requests_to('POST').size).to eq(1)
      end
    end
  end
end
