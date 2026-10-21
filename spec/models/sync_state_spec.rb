require "rails_helper"

RSpec.describe SyncState do
  describe ".instance" do
    it "creates the single row lazily and always returns it" do
      expect { described_class.instance }.to change(described_class, :count).from(0).to(1)
      expect(described_class.instance.id).to eq(SyncState::SINGLETON_ID)
      expect { described_class.instance }.not_to change(described_class, :count)
    end
  end

  describe "lock" do
    it "is exclusive" do
      expect(described_class.acquire_lock!).to be(true)
      expect(described_class.acquire_lock!).to be(false)
      expect(described_class.locked?).to be(true)
    end

    it "can be taken again after release" do
      described_class.acquire_lock!
      described_class.release_lock!

      expect(described_class.locked?).to be(false)
      expect(described_class.acquire_lock!).to be(true)
    end

    it "can be taken when the heartbeat is abandoned" do
      described_class.acquire_lock!
      described_class.instance.update_columns(lock_heartbeat_at: (SyncState::LOCK_STALE_AFTER + 1.second).ago)

      expect(described_class.locked?).to be(false)
      expect(described_class.acquire_lock!).to be(true)
    end

    it "stays held while the heartbeat is refreshed" do
      described_class.acquire_lock!
      described_class.instance.update_columns(lock_heartbeat_at: 4.minutes.ago)
      described_class.heartbeat!

      expect(described_class.acquire_lock!).to be(false)
    end
  end
end
