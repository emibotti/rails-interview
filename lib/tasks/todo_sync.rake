namespace :todo_sync do
  desc 'Run one sync cycle with the external API and print the summary'
  task run: :environment do
    run = TodoSync::Runner.call(trigger: :rake)

    if run == :busy
      puts 'Another sync is running'
    else
      puts run.summary
    end
  end

  desc 'List the records that gave up syncing (dead letters) with their error'
  task failed: :environment do
    dead = TodoSync::DeadLetters.all
    puts "#{dead.size} dead letters"
    dead.each { |type, id, error| puts "  #{type} #{id}: #{error}" }
  end

  desc 'Put every dead letter back in play and ask for a sync'
  task retry_failed: :environment do
    count = TodoSync::DeadLetters.retry_all!
    TodoSync::Scheduler.request!(reason: :retry_failed) if count.positive?
    puts "#{count} dead letters reset"
  end

  desc 'Show the last sync runs and what is pending (dirty records, tombstones, errors)'
  task status: :environment do
    state = SyncState.instance
    puts "Sync #{Rails.configuration.x.todo_sync.enabled ? 'enabled' : 'DISABLED'}; API: #{Rails.configuration.x.external_todo.base_url}; " \
         "item creation: #{Rails.configuration.x.external_todo.item_creation_strategy}"
    puts "Lock: #{SyncState.locked? ? "held (heartbeat #{state.lock_heartbeat_at})" : 'free'}; " \
         "scheduled: #{state.scheduled_at || 'no'}; last success: #{state.last_succeeded_at || 'never'}"

    puts "\nLast runs"
    SyncRun.order(id: :desc).limit(5).each do |run|
      duration = run.finished_at && run.started_at ? "#{(run.finished_at - run.started_at).round(2)}s" : '-'
      puts "  ##{run.id} #{run.trigger} #{run.status} #{duration} #{run.stats}#{" error=#{run.error.truncate(120)}" if run.error}"
    end

    puts "\nPending"
    puts "  dirty:      #{TodoList.dirty.count} lists, #{TodoItem.dirty.count} items"
    puts "  unlinked:   #{TodoList.unlinked.count} lists, #{TodoItem.unlinked.count} items"
    puts "  tombstones: #{SyncTombstone.count}"
    SyncTombstone.where('attempts > 0').order(:id).limit(10).each do |tombstone|
      puts "    #{tombstone.record_type} #{tombstone.external_id} attempts=#{tombstone.attempts} next=#{tombstone.next_attempt_at} #{tombstone.last_error&.truncate(100)}"
    end

    failed = [TodoList, TodoItem].flat_map { |model| model.where.not(sync_error: nil).limit(10).map { |record| [model.name, record] } }
    puts "  retrying:   #{TodoList.where('sync_attempts > 0').count - TodoList.dead_letters.count} lists, " \
         "#{TodoItem.where('sync_attempts > 0').count - TodoItem.dead_letters.count} items"
    puts "  dead:       #{TodoSync::DeadLetters.all.size} (bin/rails todo_sync:failed, todo_sync:retry_failed)"
    puts "  with errors: #{TodoList.where.not(sync_error: nil).count} lists, #{TodoItem.where.not(sync_error: nil).count} items"
    failed.each { |type, record| puts "    #{type} #{record.id}: #{record.sync_error.truncate(120)}" }
  end
end
