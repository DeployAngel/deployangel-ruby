# frozen_string_literal: true

RSpec.describe "Checkpoints" do
  let(:clock) { FakeClock.new(Time.utc(2026, 9, 30, 14, 0, 10)) }
  let(:aggregator) { DeployAngel::Aggregator.new(clock: clock) }

  it "counts checkpoints per minute and sends them in the payload" do
    aggregator.record_checkpoint(name: "order.created")
    aggregator.record_checkpoint(name: "order.created", count: 2)
    aggregator.record_checkpoint(name: "webhook.stripe.processed")
    clock.advance(60)

    period = aggregator.drain.sole
    payload = DeployAngel::Protocol.telemetry(period, instance: DeployAngel::Instance.new(env: { "DYNO" => "web.1" }),
      release: DeployAngel::Release.new("v1", nil, "config"), runtime: {})
    expect(payload["checkpoints"]).to contain_exactly({ "key" => "order.created", "count" => 3 },
      { "key" => "webhook.stripe.processed", "count" => 1 })
  end

  it "folds names past the limit into one bucket" do
    stub_const("DeployAngel::Aggregator::MAX_CHECKPOINTS", 3)
    %w[a b c d].each { |name| aggregator.record_checkpoint(name: name) }
    clock.advance(60)

    expect(aggregator.drain.sole.checkpoints).to eq("a" => 1, "b" => 1, "__other__" => 2)
  end

  it "ignores invalid names and counts without raising, and announces the capability" do
    expect(DeployAngel.checkpoint("")).to be_nil
    expect(DeployAngel.checkpoint("has spaces")).to be_nil
    expect(DeployAngel.checkpoint("order.created", count: 0)).to be_nil
    expect(DeployAngel.capabilities).not_to include("checkpoints")

    DeployAngel.checkpoint("order.created")
    expect(DeployAngel.capabilities).to include("checkpoints")
  ensure
    DeployAngel.instance_variable_set(:@capabilities, nil)
  end
end
