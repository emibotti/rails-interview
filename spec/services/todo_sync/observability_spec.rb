require 'rails_helper'

RSpec.describe 'Sync observability' do
  include_context 'with fake external todo api'

  let(:log) { StringIO.new }

  def sync
    logger = ActiveSupport::TaggedLogging.new(Logger.new(log))
    allow(Rails).to receive(:logger).and_return(logger)
    TodoSync::Runner.call(trigger: :spec, client: external_client)
  end

  let!(:list) { TodoList.create!(name: 'Observed') }
  let!(:items) { %w[a b].map { |name| list.todo_items.create!(name: name) } }

  describe 'run counters' do
    it 'leaves exact counters and a duration for a full cycle' do
      run = sync
      expect(run.stats).to eq('remote_calls' => 2, 'http_requests' => 2, 'lists_created_remote' => 1, 'items_created_remote' => 2)
      expect(run.reload).to have_attributes(status: 'succeeded', trigger: 'spec', duration: be >= 0, finished_at: be_present)

      items.each { |item| item.reload.update!(completed: true) }
      list.reload.update!(name: 'Renamed')
      TodoItem.create!(todo_list: list, name: 'c').destroy! # never synced: no tombstone, no calls
      second = sync

      expect(second.stats).to eq(
        'remote_calls' => 4, 'http_requests' => 4, 'items_updated_remote' => 2, 'lists_updated_remote' => 1
      )
    end

    it 'counts retried HTTP attempts separately from logical calls' do
      sync
      list.reload.update!(name: 'Renamed')
      fake_api.fail_next(:patch, %r{/todolists/}, status: 503, times: 1)

      run = sync

      expect(run.stats).to include('remote_calls' => 2, 'http_requests' => 3, 'lists_updated_remote' => 1)
    end

    it 'counts imports, deletes and conflicts' do
      sync
      fake_api.seed_list(name: 'Remote only', items: [{ description: 'x', completed: false }])
      items.first.reload.destroy!

      run = sync

      expect(run.stats).to include('lists_created_local' => 1, 'items_created_local' => 1, 'items_deleted_remote' => 1)
    end

    it 'has a one line summary' do
      run = sync

      expect(run.summary).to match(/\Arun #\d+ succeeded \(spec\) in [\d.]+s \| .*lists_created_remote=1/)
    end
  end

  describe 'logs' do
    it 'tags every line of a run with todo_sync and the run id' do
      run = sync

      lines = log.string.lines.select { |line| line.include?('[TodoSync]') }
      expect(lines).not_to be_empty
      expect(lines).to all(include("[todo_sync] [run=#{run.id}]"))
    end

    it 'logs one line per remote operation with op, local id, remote id, status, attempts and duration' do
      sync
      expect(log.string).to match(
        /POST list local=#{list.id} remote=\S+ -> 201 \(1 attempt, \d+ms\) \(2 items\)/
      )

      log.truncate(0)
      log.rewind
      items.first.reload.update!(completed: true)
      fake_api.fail_next(:patch, %r{todoitems}, status: 503, times: 1)
      sync

      remote_id = items.first.reload.external_id
      expect(log.string).to match(/PATCH item local=#{items.first.id} remote=#{remote_id} -> 200 \(2 attempts, \d+ms\) \(v2\)/)
    end

    it 'logs deletes' do
      sync
      remote_id = list.reload.external_id
      list.destroy!
      log.truncate(0)
      log.rewind

      sync

      expect(log.string).to match(/DELETE list local=- remote=#{remote_id} -> 204/)
    end

    it 'logs the failure with method, path, status and the body of the error' do
      sync
      items.first.reload.update!(completed: true)
      fake_api.fail_next(:patch, %r{todoitems}, status: 422, body: '{"error":"description too long"}')
      sync

      expect(log.string).to match(%r{PATCH /todolists/\S+/todoitems/\S+ failed with 422: \{"error":"description too long"\}})
      expect(log.string).to include('dead letter')
    end
  end

  describe 'error messages' do
    it 'carry the request, the status and a truncated body' do
      fake_api.fail_next(:get, %r{/todolists}, status: 500, body: 'x' * 2000, times: 5)

      error = begin
        external_client.list_todo_lists
      rescue ExternalTodo::Client::Error => e
        e
      end

      expect(error).to be_a(ExternalTodo::Client::RetryableError)
      expect(error.message).to start_with('GET /todolists failed with 500: xxx')
      expect(error.message.length).to be < 600
      expect(error).to have_attributes(status: 500, http_method: :get, path: '/todolists')
    end

    it 'say what timed out' do
      fake_api.timeout_next(:post, %r{/todolists})

      expect { external_client.create_todo_list(name: 'x', source_id: 's') }
        .to raise_error(ExternalTodo::Client::TimeoutError, /POST \/todolists timed out/)
    end

    it 'say which run aborted and why' do
      fake_api.fail_next(:get, %r{/todolists}, status: 503, times: 5)

      run = sync

      expect(run.error).to eq('GET /todolists failed with 503: {"error":"Injected failure"}')
      expect(log.string).to include("run #{run.id} aborted")
    end
  end
end
