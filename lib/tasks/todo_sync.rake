namespace :todo_sync do
  desc 'Run one sync cycle with the external API and print the summary'
  task run: :environment do
    run = TodoSync::Runner.call(trigger: :rake)

    if run == :busy
      puts 'Another sync is running'
    else
      puts "Run ##{run.id} #{run.status}: #{run.stats}"
      puts "Error: #{run.error}" if run.error
    end
  end
end
