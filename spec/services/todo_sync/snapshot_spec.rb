require 'rails_helper'

RSpec.describe TodoSync::Snapshot do
  def remote_list(**attrs)
    ExternalTodo::RemoteList.new(items: [], **attrs)
  end

  def remote_item(**attrs)
    ExternalTodo::RemoteItem.new(**attrs)
  end

  let(:ours_item) { remote_item(external_id: 'i1', source_id: 'rails-interview:item:3') }
  let(:foreign_item) { remote_item(external_id: 'i2', source_id: 'other:3') }
  let(:ours_list) { remote_list(external_id: 'l1', source_id: 'rails-interview:list:5', items: [ours_item, foreign_item]) }
  let(:snapshot) { described_class.new([ours_list, remote_list(external_id: nil, name: 'no id')]) }

  it 'drops lists without id' do
    expect(snapshot.lists).to eq([ours_list])
  end

  it 'indexes by remote id' do
    expect(snapshot.lists_by_external_id).to eq('l1' => ours_list)
    expect(snapshot.items_by_external_id.keys).to match_array(%w[i1 i2])
  end

  it 'indexes by parsed source_id, only for our records' do
    expect(snapshot.lists_by_source_id).to eq(5 => ours_list)
    expect(snapshot.items_by_source_id).to eq(3 => ours_item)
  end
end
