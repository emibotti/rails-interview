require 'rails_helper'

# Per-record backoff, dead letters and the circuit breaker, through the Runner.
RSpec.describe TodoSync::Runner do
  include ActiveSupport::Testing::TimeHelpers
  include_context 'with fake external todo api'

  def sync
    TodoSync::Runner.call(trigger: :spec, client: external_client)
  end

  def patches
    fake_api.requests.select { |method, *| method == 'PATCH' }
  end

  let!(:list) { TodoList.create!(name: 'List') }
  let!(:items) { Array.new(4) { |i| list.todo_items.create!(name: "item #{i}") } }

  before do
    sync
    [list, *items].each(&:reload)
  end

  describe 'a failing record' do
    it 'does not stop the others' do
      items.each { |item| item.update!(completed: true) }
      fake_api.fail_next(:patch, %r{todoitems}, status: 503, times: 3) # exhausts the retries of the first item

      run = sync

      expect(run.status).to eq('succeeded')
      expect(run.stats).to include('failures' => 1, 'items_updated_remote' => 3)
      expect(TodoItem.dirty.count).to eq(1)
    end

    it 'is retried with exponential backoff between cycles, not on every cycle' do
      item = items.first
      item.update!(completed: true)
      fake_api.fail_next(:patch, %r{todoitems}, status: 503, times: 3)

      sync
      expect(item.reload).to have_attributes(sync_attempts: 1, sync_error: a_string_including('503'), next_sync_at: be > Time.current)

      patches_before = patches.size
      sync # still waiting
      expect(patches.size).to eq(patches_before)
      expect(item.reload.sync_attempts).to eq(1)

      travel_to(item.next_sync_at + 1.second) do
        fake_api.fail_next(:patch, %r{todoitems}, status: 503, times: 3)
        sync
        expect(item.reload.sync_attempts).to eq(2)
        expect(item.next_sync_at - Time.current).to be > 30.seconds # longer than after the first failure
      end
    end

    it 'succeeds after failing and forgets the failures' do
      item = items.first
      item.update!(completed: true)
      fake_api.fail_next(:patch, %r{todoitems}, status: 503, times: 3)
      sync

      travel_to(item.reload.next_sync_at + 1.second) { sync }

      expect(item.reload).to have_attributes(sync_attempts: 0, next_sync_at: nil, sync_error: nil, dirty_for_sync?: false)
    end

    it 'becomes a dead letter after the maximum number of attempts' do
      item = items.first
      item.update!(completed: true)
      item.update_columns(sync_attempts: TodoSync::Backoff.max_attempts - 1, next_sync_at: nil)
      fake_api.fail_next(:patch, %r{todoitems}, status: 503, times: 3)

      run = sync

      expect(item.reload.sync_error).to start_with('dead letter after 8 attempts')
      expect(item.next_sync_at).to be_nil
      expect(run.stats['dead_letters']).to eq(1)
      expect(TodoItem.dead_letters).to contain_exactly(item)
    end
  end

  describe 'a client error (422)' do
    it 'goes straight to dead letter without retrying' do
      item = items.first
      item.update!(completed: true)
      fake_api.fail_next(:patch, %r{todoitems}, status: 422, body: '{"error":"bad"}')

      run = sync

      expect(patches.size).to eq(1)
      expect(item.reload.sync_error).to match(/dead letter.*422/)
      expect(item.sync_attempts).to eq(TodoSync::Backoff.max_attempts)
      expect(run.stats).to include('failures' => 1, 'dead_letters' => 1)

      patches_before = patches.size
      travel_to(2.days.from_now) { sync }
      expect(patches.size).to eq(patches_before) # never retried by itself
    end

    it 'also applies to lists that cannot be created' do
      fresh = TodoList.create!(name: 'Rejected')
      fake_api.fail_next(:post, %r{/todolists}, status: 422)

      sync

      expect(fresh.reload.sync_error).to start_with('dead letter')
      expect(TodoList.dead_letters).to contain_exactly(fresh)
    end
  end

  describe 'tombstones' do
    it 'go to dead letter on a client error and are not retried' do
      items.first.destroy!
      fake_api.fail_next(:delete, %r{todoitems}, status: 403)

      sync

      expect(SyncTombstone.first).to have_attributes(attempts: TodoSync::Backoff.max_attempts, next_attempt_at: nil,
                                                    last_error: a_string_including('dead letter', '403'))
      deletes = fake_api.requests.count { |method, *| method == 'DELETE' }
      travel_to(2.days.from_now) { sync }
      expect(fake_api.requests.count { |method, *| method == 'DELETE' }).to eq(deletes)
    end
  end

  describe 'circuit breaker' do
    before { allow(Rails.configuration.x.todo_sync).to receive(:circuit_breaker_threshold).and_return(3) }

    it 'cuts the cycle after N consecutive retryable failures' do
      items.each { |item| item.update!(completed: true) }
      fake_api.fail_next(:patch, %r{todoitems}, status: 503, times: 100)

      run = sync

      expect(run.status).to eq('aborted')
      expect(run.error).to include('circuit breaker open after 3 consecutive failures')
      expect(patches.size).to eq(3 * 3) # 3 calls, each with 1 + 2 in-request retries; the 4th is never sent
      expect(TodoItem.where('sync_attempts > 0').count).to eq(3)
      expect(SyncState.locked?).to be(false)
    end

    it 'is not tripped by client errors, since the server is answering' do
      items.each { |item| item.update!(completed: true) }
      fake_api.fail_next(:patch, %r{todoitems}, status: 422, times: 4)

      run = sync

      expect(run.status).to eq('succeeded')
      expect(run.stats['dead_letters']).to eq(4)
    end

    it 'resets with a success in between' do
      items.each { |item| item.update!(completed: true) }
      fake_api.fail_next(:patch, %r{todoitems}, status: 503, times: 6) # items 1 and 2 fail, then it recovers

      run = sync

      expect(run.status).to eq('succeeded')
      expect(run.stats).to include('failures' => 2, 'items_updated_remote' => 2)
    end
  end

  describe 'dead letters' do
    it 'lists dead letters and puts them back in play' do
      item = items.first
      item.update!(completed: true)
      fake_api.fail_next(:patch, %r{todoitems}, status: 422)
      sync
      items.last.destroy!
      fake_api.fail_next(:delete, %r{todoitems}, status: 403)
      sync

      expect(TodoSync::DeadLetters.all.map(&:first)).to contain_exactly('TodoItem', 'SyncTombstone')

      expect(TodoSync::DeadLetters.retry_all!).to eq(2)

      expect(item.reload).to have_attributes(sync_attempts: 0, sync_error: nil, next_sync_at: nil)
      expect(SyncTombstone.first).to have_attributes(attempts: 0, last_error: nil)
      expect(TodoSync::DeadLetters.all).to be_empty

      sync
      expect(item.reload.dirty_for_sync?).to be(false)
      expect(SyncTombstone.count).to eq(0)
    end

    it 'leaves records skipped by the item creation strategy alone' do
      item = list.todo_items.create!(name: 'late')
      item.update_columns(sync_error: 'unsupported_by_remote: x')

      expect(TodoSync::DeadLetters.retry_all!).to eq(0)
      expect(item.reload.sync_error).to eq('unsupported_by_remote: x')
    end
  end
end
