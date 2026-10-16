namespace :dev do
  desc 'Insert COUNT pending todo items into a todo list (creates one if LIST_ID is missing)'
  task :seed_items, %i[list_id count] => :environment do |_task, args|
    count = (args[:count] || 10_000).to_i
    todo_list = TodoList.find_by(id: args[:list_id]) || TodoList.create!(name: "Big list (#{count} items)")
    now = Time.current
    batch_size = 5_000

    (1..count).each_slice(batch_size) do |numbers|
      TodoItem.insert_all(numbers.map do |n|
        { todo_list_id: todo_list.id, name: "Item #{n}", completed: false, created_at: now, updated_at: now }
      end)
    end

    puts "Inserted #{count} items into todo list ##{todo_list.id} (#{todo_list.name})"
  end
end
