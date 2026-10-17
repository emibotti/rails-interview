require 'rails_helper'

describe CompleteAllTodoItemsJob do
  include ActiveJob::TestHelper

  let!(:todo_list) { TodoList.create!(name: 'Big list') }
  let!(:items) { Array.new(5) { |i| todo_list.todo_items.create!(name: "Item #{i}") } }
  let(:up_to_id) { items.last.id }
  let(:stream) { todo_list.to_gid_param }

  before do
    stub_const('CompleteAllTodoItemsJob::BATCH_SIZE', 2)
    todo_list.acquire_mark_all_lock!
  end

  it 'completes every pending item of the list' do
    described_class.perform_now(todo_list, up_to_id)

    expect(todo_list.todo_items.where(completed: false)).to be_empty
  end

  it 'broadcasts once per batch plus the initial and final status, not once per item' do
    # 5 items in batches of 2 => 3 batches, + initial (0/5) + done
    expect {
      described_class.perform_now(todo_list, up_to_id)
    }.to have_broadcasted_to(stream).exactly(5).times
  end

  it 'broadcasts the progress and the final done status' do
    expect {
      described_class.perform_now(todo_list, up_to_id)
    }.to have_broadcasted_to(stream).with(a_string_including('data-state="running"', '2 / 5'))
      .and have_broadcasted_to(stream).with(a_string_including('data-state="done"', 'Done: 5 items'))
  end

  it 'does not touch items created after the job was enqueued' do
    later_item = todo_list.todo_items.create!(name: 'Created later')

    described_class.perform_now(todo_list, up_to_id)

    expect(later_item.reload.completed).to eq(false)
  end

  it 'does not touch items of other lists' do
    other_item = TodoList.create!(name: 'Other').todo_items.create!(name: 'Other item')

    described_class.perform_now(todo_list, [up_to_id, other_item.id].max)

    expect(other_item.reload.completed).to eq(false)
  end

  it 'updates updated_at of the completed items' do
    items.first.update_columns(updated_at: 1.day.ago)

    described_class.perform_now(todo_list, up_to_id)

    expect(items.first.reload.updated_at).to be_within(1.minute).of(Time.current)
  end

  it 'only counts and updates pending items' do
    items.first.update!(completed: true)

    expect {
      described_class.perform_now(todo_list, up_to_id)
    }.to have_broadcasted_to(stream).with(a_string_including('Done: 4 items'))
  end

  it 'is idempotent' do
    described_class.perform_now(todo_list, up_to_id)

    expect {
      described_class.perform_now(todo_list, up_to_id)
    }.not_to change { todo_list.todo_items.order(:id).pluck(:completed, :updated_at) }
  end

  it 'releases the lock when done' do
    described_class.perform_now(todo_list, up_to_id)

    expect(todo_list.reload.mark_all_running?).to eq(false)
  end

  context 'when the database keeps failing' do
    before do
      allow_any_instance_of(ActiveRecord::Relation).to receive(:update_all).and_wrap_original do |method, *args|
        raise ActiveRecord::StatementInvalid, 'database is locked' if method.receiver.klass == TodoItem

        method.call(*args)
      end
    end

    it 'releases the lock and broadcasts the failure after the last attempt' do
      expect {
        perform_enqueued_jobs { described_class.perform_later(todo_list, up_to_id) }
      }.to have_broadcasted_to(stream).with(a_string_including('data-state="failed"'))

      expect(todo_list.reload.mark_all_running?).to eq(false)
    end
  end

  context 'when the list was deleted' do
    it 'discards the job' do
      described_class.perform_later(todo_list, up_to_id)
      todo_list.destroy

      expect { perform_enqueued_jobs }.not_to raise_error
    end
  end
end
