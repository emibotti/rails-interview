require "rails_helper"

RSpec.describe SyncRun do
  it "starts running and finishes with a status" do
    run = described_class.start!(:periodic)
    expect(run).to have_attributes(status: "running", trigger: "periodic", started_at: be_present)

    run.finish!(:succeeded)
    expect(run.reload).to have_attributes(status: "succeeded", finished_at: be_present)
  end

  it "rejects unknown statuses" do
    expect(described_class.new(status: "weird")).not_to be_valid
  end

  it "counts stats" do
    run = described_class.start!(:manual)
    run.increment_stat(:remote_calls)
    run.increment_stat(:remote_calls, 2)
    run.save!

    expect(run.reload.stats).to eq("remote_calls" => 3)
  end
end
