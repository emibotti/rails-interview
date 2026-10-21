require 'rails_helper'

RSpec.describe Syncable do
  let(:list) { TodoList.create!(name: 'L') }
  let(:item) { list.todo_items.create!(name: 'a') }

  it 'starts dirty with local_version 1 and synced_version 0' do
    expect(list).to have_attributes(local_version: 1, synced_version: 0, dirty_for_sync?: true)
    expect(TodoList.dirty).to include(list)
  end

  describe 'local_version' do
    it 'is bumped when a synced field changes' do
      expect { list.update!(name: 'New') }.to change { list.reload.local_version }.from(1).to(2)
      expect { item.update!(name: 'b') }.to change { item.reload.local_version }.from(1).to(2)
      expect { item.update!(completed: true) }.to change { item.reload.local_version }.from(2).to(3)
    end

    it 'is not bumped when nothing changes or only unsynced columns change' do
      expect { list.save! }.not_to(change { list.reload.local_version })
      expect { list.update!(name: list.name) }.not_to(change { list.reload.local_version })
      expect { item.update!(external_id: 'x', synced_version: 1) }.not_to(change { item.reload.local_version })
    end

    it 'is not bumped by update_columns, which the sync uses to avoid echo' do
      expect { item.update_columns(name: 'remote', completed: true) }.not_to(change { item.reload.local_version })
    end
  end

  describe 'scopes' do
    it 'splits linked and unlinked and finds dirty records' do
      linked = list.todo_items.create!(name: 'linked', external_id: 'ext-1', local_version: 3, synced_version: 3)
      pending = list.todo_items.create!(name: 'pending')

      expect(TodoItem.linked).to contain_exactly(linked)
      expect(TodoItem.unlinked).to contain_exactly(pending)
      expect(TodoItem.dirty).to contain_exactly(pending)
    end
  end

  describe 'tombstones' do
    it 'creates one tombstone when a synced list is destroyed, and none for its items' do
      list.update_columns(external_id: 'list-ext', remote_updated_at: Time.utc(2026, 1, 1))
      list.todo_items.create!(name: 'a', external_id: 'item-ext')

      expect { list.destroy! }.to change(SyncTombstone, :count).by(1)

      expect(SyncTombstone.last).to have_attributes(
        record_type: 'TodoList', external_id: 'list-ext', list_external_id: nil, remote_updated_at: Time.utc(2026, 1, 1)
      )
      expect(TodoItem.count).to eq(0)
    end

    it 'creates a tombstone with the list external id when a synced item is destroyed' do
      list.update_columns(external_id: 'list-ext')
      item.update_columns(external_id: 'item-ext')

      expect { item.destroy! }.to change(SyncTombstone, :count).by(1)

      expect(SyncTombstone.last).to have_attributes(record_type: 'TodoItem', external_id: 'item-ext', list_external_id: 'list-ext')
    end

    it 'creates nothing for records that were never synced' do
      item
      expect { item.destroy! && list.destroy! }.not_to change(SyncTombstone, :count)
    end

    it 'deletes the items of a list without loading them' do
      list.todo_items.create!(name: 'a')
      list.todo_items.create!(name: 'b')

      expect(TodoItem).not_to receive(:new)
      expect { list.destroy! }.to change(TodoItem, :count).by(-2)
    end
  end
end
