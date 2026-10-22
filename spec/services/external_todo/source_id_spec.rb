require "rails_helper"

RSpec.describe ExternalTodo::SourceId do
  it "builds namespaced source ids" do
    list = TodoList.create!(name: "L")
    item = list.todo_items.create!(name: "a")

    expect(described_class.for(list)).to eq("rails-interview:list:#{list.id}")
    expect(described_class.for(item)).to eq("rails-interview:item:#{item.id}")
  end

  it "parses ours and rejects the rest" do
    expect(described_class.parse("rails-interview:list:5")).to eq([:list, 5])
    expect(described_class.parse("rails-interview:item:12")).to eq([:item, 12])
    expect(described_class.parse("other:list:5")).to be_nil
    expect(described_class.parse("rails-interview:list:x")).to be_nil
    expect(described_class.parse(nil)).to be_nil
  end
end
