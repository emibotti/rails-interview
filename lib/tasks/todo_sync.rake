namespace :todo_sync do
  desc 'Pull the external API state into the local database (remote -> local)'
  task pull: :environment do
    run = TodoSync::Runner.call(trigger: :rake_pull)

    if run == :busy
      puts 'Another sync is running'
    else
      puts "Run ##{run.id} #{run.status}: #{run.stats}"
      puts "Error: #{run.error}" if run.error
    end
  end
end
