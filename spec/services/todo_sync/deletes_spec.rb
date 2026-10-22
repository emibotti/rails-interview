require 'rails_helper'

RSpec.describe TodoSync::Runner do
  include ActiveSupport::Testing::TimeHelpers
  include_context 'with fake external todo api'

  def sync
    described_class.call(trigger: :spec, client: external_client)
  end

  def requests_to(method)
    fake_api.requests.select { |m, _path, _body| m == method }
  end

  let!(:list) { TodoList.create!(name: 'Local list') }
  let!(:items) { %w[a b c].map { |name| list.todo_items.create!(name: name) } }

  context 'with everything synced' do
    before do
      sync
      [list, *items].each(&:reload) # pick up the external ids stored by the sync
    end

    describe 'local deletes' do
      it 'sends one DELETE for a deleted list, not one per item, and drops the tombstone' do
        list.destroy!
        expect(SyncTombstone.count).to eq(1)
        before_count = requests_to('DELETE').size

        run = sync

        expect(requests_to('DELETE').size - before_count).to eq(1)
        expect(fake_api.lists).to be_empty
        expect(SyncTombstone.count).to eq(0)
        expect(run.stats['lists_deleted_remote']).to eq(1)
      end

      it 'sends one DELETE for a deleted item' do
        items.first.destroy!

        sync

        expect(requests_to('DELETE').size).to eq(1)
        expect(fake_api.lists.first['items'].size).to eq(2)
        expect(SyncTombstone.count).to eq(0)
      end

      it 'coalesces: deleting an item and then its list is one DELETE' do
        items.first.destroy!
        list.destroy!
        expect(SyncTombstone.count).to eq(2)

        run = sync

        expect(requests_to('DELETE').size).to eq(1)
        expect(requests_to('DELETE').first[1]).to match(%r{\A/todolists/[^/]+\z})
        expect(SyncTombstone.count).to eq(0)
        expect(run.stats['tombstones_coalesced']).to eq(1)
      end

      it 'treats a 404 as success' do
        remote_id = list.external_id
        list.destroy!
        fake_api.fail_next(:delete, %r{/todolists}, status: 404)

        sync

        expect(SyncTombstone.count).to eq(0)
        expect(requests_to('DELETE').size).to eq(1) # not retried
        expect(fake_api.find_list(remote_id)).to be_present # the injected 404 never deleted it, but we are done
      end

      it 'does not call the API for a record that is already gone remotely' do
        remote_id = list.external_id
        list.destroy!
        fake_api.reset!
        before_count = fake_api.requests.size

        sync

        expect(requests_to('DELETE')).to be_empty
        expect(fake_api.requests.size - before_count).to eq(1) # the GET
        expect(SyncTombstone.where(external_id: remote_id)).to be_empty
      end

      it 'keeps the tombstone with a backoff when the DELETE fails, and never resurrects the record' do
        list.destroy!
        fake_api.fail_next(:delete, %r{/todolists}, status: 503, times: 10)

        first = sync
        second = sync # the remote list is still in the snapshot

        expect(first.stats['failures']).to eq(1)
        expect(TodoList.count).to eq(0)
        expect(TodoItem.count).to eq(0)
        tombstone = SyncTombstone.first
        expect(tombstone).to have_attributes(attempts: 1, last_error: a_string_including('503'), next_attempt_at: be > Time.current)
        expect(second.stats['skipped_tombstoned']).to eq(1)
        expect(requests_to('DELETE').size).to eq(3) # one request + 2 in-request retries, none in the second cycle

        travel_to(2.minutes.from_now) do
          fake_api.reset!
          fake_api.seed_list(name: 'unrelated')
          sync
        end
        expect(SyncTombstone.count).to eq(0) # no longer in the snapshot
      end

      it 'does not resurrect an item with a pending tombstone' do
        items.first.destroy!
        fake_api.fail_next(:delete, %r{todoitems}, status: 503, times: 10)

        sync

        expect(list.todo_items.count).to eq(2)
      end

      it 'warns that the delete wins when the remote was edited after the local delete' do
        remote_id = list.external_id
        list.destroy!
        external_client.update_todo_list(remote_id, name: 'edited remotely')
        fake_api.fail_next(:delete, %r{/todolists}, status: 503, times: 10)
        allow(Rails.logger).to receive(:warn).and_call_original

        sync

        expect(Rails.logger).to have_received(:warn).with(a_string_including('delete wins', remote_id))
      end
    end

    describe 'remote deletes' do
      it 'deletes locally a list that disappeared remotely, without tombstones' do
        other = TodoList.create!(name: 'Other')
        sync # link it so the remaining list keeps the snapshot non-empty
        fake_api.lists.find { |l| l['id'] == list.external_id }.then { |l| external_client.delete_todo_list(l['id']) }

        run = sync

        expect(TodoList.pluck(:id)).to eq([other.id])
        expect(TodoItem.count).to eq(0)
        expect(SyncTombstone.count).to eq(0)
        expect(run.stats['lists_deleted_local']).to eq(1)
        expect(run.status).to eq('succeeded')
      end

      it 'deletes locally an item that disappeared remotely' do
        external_client.delete_todo_item(list.external_id, items.first.external_id)

        run = sync

        expect(list.todo_items.pluck(:id)).to match_array(items.drop(1).map(&:id))
        expect(SyncTombstone.count).to eq(0)
        expect(run.stats['items_deleted_local']).to eq(1)
      end

      it 'warns what is lost when the record had pending local changes' do
        other = TodoList.create!(name: 'Other')
        sync
        items.first.update!(completed: true)
        external_client.delete_todo_list(list.external_id)
        allow(Rails.logger).to receive(:warn).and_call_original

        sync

        expect(Rails.logger).to have_received(:warn).with(a_string_including('delete wins', '1 items with unsynced local changes'))
        expect(TodoList.pluck(:id)).to eq([other.id])
      end
    end

    describe 'deletion guard' do
      it 'deletes nothing when the snapshot is empty and flags the run' do
        fake_api.reset!

        run = sync

        expect(run.status).to eq('aborted_deletions')
        expect(TodoList.count).to eq(1)
        expect(TodoItem.count).to eq(3)
        expect(run.stats['lists_deleted_local']).to be_nil
      end

      it 'deletes nothing when more than half of the linked lists are missing' do
        lists = Array.new(5) { |i| TodoList.create!(name: "L#{i}") }
        sync
        lists.first(4).each { |l| external_client.delete_todo_list(l.reload.external_id) }

        run = sync

        expect(run.status).to eq('aborted_deletions')
        expect(TodoList.count).to eq(6)
      end

      it 'allows deletions below the threshold' do
        lists = Array.new(5) { |i| TodoList.create!(name: "L#{i}") }
        sync
        external_client.delete_todo_list(lists.first.reload.external_id)

        run = sync

        expect(run.status).to eq('succeeded')
        expect(TodoList.count).to eq(5)
      end

      it 'still pushes while deletions are refused' do
        lists = Array.new(5) { |i| TodoList.create!(name: "L#{i}") }
        sync
        lists.first(4).each { |l| external_client.delete_todo_list(l.reload.external_id) }
        items.first.update!(completed: true)

        run = sync

        expect(run.status).to eq('aborted_deletions')
        expect(fake_api.find_list(list.external_id)['items'].first['completed']).to be(true)
      end
    end
  end
end
