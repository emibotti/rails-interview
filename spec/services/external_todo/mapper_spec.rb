require "rails_helper"

RSpec.describe ExternalTodo::Mapper do
  it "maps a list with items, translating description to name" do
    list = described_class.remote_list(
      "id" => "l1", "source_id" => "s", "name" => "L", "created_at" => "2026-01-01T10:00:00.000Z",
      "updated_at" => "2026-01-02T10:00:00Z",
      "items" => [{ "id" => "i1", "description" => "a", "completed" => true }]
    )

    expect(list.external_id).to eq("l1")
    expect(list.updated_at).to eq(Time.utc(2026, 1, 2, 10))
    expect(list.items.first).to have_attributes(external_id: "i1", name: "a", completed: true)
  end

  it "tolerates missing and null fields" do
    list = described_class.remote_list("id" => 7, "name" => nil, "created_at" => nil, "items" => nil)

    expect(list).to have_attributes(external_id: "7", name: nil, created_at: nil, updated_at: nil, items: [])
    expect(described_class.remote_item({})).to have_attributes(external_id: nil, name: nil, completed: nil)
  end

  it "falls back to a lenient parse and then to nil for odd timestamps" do
    expect(described_class.time("2026-01-01 10:00:00")).to be_a(Time)
    expect(described_class.time("garbage")).to be_nil
  end

  it "builds update bodies with only the present keys" do
    expect(described_class.update_item_body(name: "x")).to eq(description: "x")
    expect(described_class.update_item_body(completed: false)).to eq(completed: false)
    expect(described_class.update_item_body).to eq({})
    expect(described_class.update_list_body(name: "x")).to eq(name: "x")
  end
end
