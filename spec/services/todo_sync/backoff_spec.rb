require 'rails_helper'

RSpec.describe TodoSync::Backoff do
  let(:no_jitter) { instance_double(Random, rand: 1.0) }   # full delay
  let(:max_jitter) { instance_double(Random, rand: 0.0) }  # half delay

  it 'doubles with every attempt, up to the maximum' do
    delays = (1..9).map { |attempt| described_class.delay(attempt, base: 30, max: 3600, random: no_jitter) }

    expect(delays).to eq([30, 60, 120, 240, 480, 960, 1920, 3600, 3600])
  end

  it 'keeps between half and the full delay (equal jitter)' do
    expect(described_class.delay(3, base: 30, max: 3600, random: max_jitter)).to eq(60)
    expect(described_class.delay(3, base: 30, max: 3600, random: no_jitter)).to eq(120)
    100.times { expect(described_class.delay(3, base: 30, max: 3600)).to be_between(60, 120) }
  end

  it 'reads the defaults from the configuration' do
    expect(described_class.delay(1, random: no_jitter)).to eq(Rails.configuration.x.todo_sync.backoff_base)
    expect(described_class.max_attempts).to eq(8)
  end
end
