require 'rails_helper'

RSpec.describe TodoSyncJob, :todo_sync do
  include ActiveJob::TestHelper
  include_context 'with fake external todo api'

  it 'runs a sync cycle' do
    list = TodoList.create!(name: 'Local')
    list.todo_items.create!(name: 'a')

    described_class.perform_now('spec')

    expect(fake_api.lists.map { |l| l['name'] }).to eq(['Local'])
    expect(SyncRun.last).to have_attributes(trigger: 'spec', status: 'succeeded')
    expect(SyncState.locked?).to be(false)
  end

  it 'clears the schedule mark when it starts, so changes during the run schedule another one' do
    SyncState.instance.update_columns(scheduled_at: Time.current)

    described_class.perform_now

    expect(SyncState.instance.scheduled_at).to be_nil
  end

  it 'asks for another sync when the lock is taken instead of dropping the request' do
    SyncState.acquire_lock!

    expect { described_class.perform_now('spec') }.to have_enqueued_job(described_class).with('spec')
    expect(fake_api.requests).to be_empty
  end

  it 'reschedules with a backoff when the snapshot cannot be fetched' do
    fake_api.fail_next(:get, %r{/todolists}, status: 500, times: 10)

    expect { described_class.perform_now('spec') }
      .to have_enqueued_job(described_class).with('retry_after_aborted').at(be_within(20.seconds).of(23.seconds.from_now))
    expect(SyncRun.last.status).to eq('aborted')
  end

  it 'does not raise on unexpected errors and reschedules' do
    allow(TodoSync::Runner).to receive(:call).and_raise('boom')

    expect { described_class.perform_now('spec') }.to have_enqueued_job(described_class).with('retry_after_error')
  end

  it 'is not enqueued by the existing endpoints when the sync is disabled' do
    Rails.configuration.x.todo_sync.enabled = false

    expect { TodoList.create!(name: 'x') }.not_to have_enqueued_job(described_class)
  ensure
    Rails.configuration.x.todo_sync.enabled = true
  end
end
