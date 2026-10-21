require "rails_helper"

RSpec.describe SyncTombstone do
  it "is unique per record type and external id" do
    described_class.create!(record_type: "TodoList", external_id: "a")

    expect { described_class.create!(record_type: "TodoList", external_id: "a") }
      .to raise_error(ActiveRecord::RecordNotUnique)
    expect(described_class.create!(record_type: "TodoItem", external_id: "a")).to be_persisted
  end

  it "validates the record type" do
    expect(described_class.new(record_type: "User", external_id: "a")).not_to be_valid
  end
end
