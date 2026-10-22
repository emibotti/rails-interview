require 'rails_helper'

RSpec.describe TodoSync::Scheduler, :todo_sync do
  include ActiveJob::TestHelper

  let(:list) { TodoList.create!(name: 'List') }

  describe '.request!' do
    it 'enqueues one job for a burst of requests (debounce)' do
      expect {
        10.times { described_class.request!(reason: :spec) }
      }.to have_enqueued_job(TodoSyncJob).exactly(:once)
    end

    it 'delays the job by the debounce' do
      expect { described_class.request!(reason: :spec) }
        .to have_enqueued_job(TodoSyncJob).with('spec').at(be_within(2.seconds).of(5.seconds.from_now))
    end

    it 'recovers an abandoned mark, e.g. a job lost on a restart' do
      SyncState.instance.update_columns(scheduled_at: 3.minutes.ago)

      expect { described_class.request!(reason: :spec) }.to have_enqueued_job(TodoSyncJob).exactly(:once)
    end

    it 'does not enqueue again while a recent mark exists' do
      SyncState.instance.update_columns(scheduled_at: 10.seconds.ago)

      expect { described_class.request!(reason: :spec) }.not_to have_enqueued_job(TodoSyncJob)
    end

    it 'does nothing when the sync is disabled' do
      Rails.configuration.x.todo_sync.enabled = false

      expect { described_class.request!(reason: :spec) }.not_to have_enqueued_job(TodoSyncJob)
    ensure
      Rails.configuration.x.todo_sync.enabled = true
    end
  end

  describe 'model callbacks' do
    it 'enqueues a single job for 10 consecutive changes' do
      expect {
        list
        9.times { |i| list.update!(name: "Name #{i}") }
      }.to have_enqueued_job(TodoSyncJob).exactly(:once)
    end

    it 'asks for a sync when an item is created, updated or destroyed after being synced' do
      item = list.todo_items.create!(name: 'a')
      item.update_columns(external_id: 'ext')
      TodoSync::Scheduler.clear!

      expect { item.update!(completed: true) }.to have_enqueued_job(TodoSyncJob)
      TodoSync::Scheduler.clear!
      expect { item.destroy! }.to have_enqueued_job(TodoSyncJob)
    end

    it 'does not ask for a sync when no synced field changed' do
      list
      TodoSync::Scheduler.clear!

      expect { list.update!(mark_all_heartbeat_at: Time.current) }.not_to have_enqueued_job(TodoSyncJob)
    end

    it 'does not ask for a sync when deleting something that was never synced' do
      list
      TodoSync::Scheduler.clear!

      expect { list.destroy! }.not_to have_enqueued_job(TodoSyncJob)
    end

    it 'does not run for the sync own writes (no callbacks)' do
      list
      TodoSync::Scheduler.clear!

      expect {
        list.update_columns(name: 'remote', external_id: 'x')
        TodoList.where(id: list.id).update_all(name: 'again')
      }.not_to have_enqueued_job(TodoSyncJob)
    end
  end

  describe 'bulk writes' do
    it 'a mark all of 1000 items enqueues a single job' do
      TodoItem.insert_all(Array.new(1000) { |i| { todo_list_id: list.id, name: "Item #{i}", completed: false, created_at: Time.current, updated_at: Time.current } })
      list.acquire_mark_all_lock!
      TodoSync::Scheduler.clear!

      expect {
        CompleteAllTodoItemsJob.perform_now(list, list.todo_items.maximum(:id))
      }.to have_enqueued_job(TodoSyncJob).exactly(:once)
      expect(TodoItem.dirty.count).to eq(1000)
    end

    it 'a mark all with nothing to do does not ask for a sync' do
      list.acquire_mark_all_lock!
      TodoSync::Scheduler.clear!

      expect { CompleteAllTodoItemsJob.perform_now(list, 0) }.not_to have_enqueued_job(TodoSyncJob)
    end
  end

  describe '.retry_delay' do
    it 'grows with consecutive aborted runs, with jitter, and is capped' do
      expect(described_class.retry_delay).to be_between(15.seconds, 30.seconds)

      SyncRun.create!(status: 'aborted')
      expect(described_class.retry_delay).to be_between(15.seconds, 30.seconds)
      SyncRun.create!(status: 'failed')
      expect(described_class.retry_delay).to be_between(30.seconds, 60.seconds)
      8.times { SyncRun.create!(status: 'aborted') }
      expect(described_class.retry_delay).to be_between(7.5.minutes, 15.minutes)

      SyncRun.create!(status: 'succeeded')
      expect(described_class.retry_delay).to be_between(15.seconds, 30.seconds)
    end
  end
end
