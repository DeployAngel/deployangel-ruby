# frozen_string_literal: true

require "deployangel/capistrano/steps"

RSpec.describe DeployAngel::Capistrano::Steps do
  let(:clock) { FakeClock.new(Time.utc(2026, 9, 30, 14)) }
  let(:cli) { { sleeper: ->(seconds) { clock.advance(seconds) }, clock: clock } }
  let(:sha) { "81ac27d0000aaaa" }

  it "registers the release with its commit and Capistrano's release timestamp" do
    client = FakeClient.new
    outcome, message = described_class.register(token: "da_live_x", commit: sha, version: "20260930140000", client: client, **cli)

    expect(outcome).to eq(:ok)
    expect(message).to include("Registered deployment 43")
    expect(client.calls).to include([ :register, { commit: sha, version: "20260930140000", kind: nil, provider: "capistrano", source_url: nil } ])
  end

  it "warns instead of failing the deploy without a token or when DeployAngel is unreachable" do
    expect(described_class.register(token: nil, commit: sha).first).to eq(:warn)

    failing = FakeClient.new
    def failing.register_deployment(**) = raise(DeployAngel::Client::Error, "connection refused")
    outcome, message = described_class.register(token: "da_live_x", commit: sha, client: failing, **cli)
    expect(outcome).to eq(:warn)
    expect(message).to include("could not register", "connection refused")
  end

  it "fails the deploy only when the release failed verification" do
    passed = FakeClient.new(documents: [ verdict_document(state: "observing", initial_check: { "result" => "no_problems" }) ])
    expect(described_class.verify(token: "t", commit: sha, until_mode: "initial", timeout: "5m", client: passed, **cli).first).to eq(:ok)

    failed = FakeClient.new(documents: [ verdict_document(state: "closed", verdict: "failed") ])
    outcome, message = described_class.verify(token: "t", commit: sha, until_mode: "initial", timeout: "5m", client: failed, **cli)
    expect(outcome).to eq(:fail)
    expect(message).to include("failed verification")

    slow = FakeClient.new(documents: [ verdict_document(state: "observing") ])
    expect(described_class.verify(token: "t", commit: sha, until_mode: "verdict", timeout: "2m", client: slow, **cli).first).to eq(:warn)
  end
end
