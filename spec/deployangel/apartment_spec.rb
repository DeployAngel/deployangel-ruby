# frozen_string_literal: true

RSpec.describe DeployAngel::Apartment do
  before do
    adapter = Class.new do
      def default_tenant = "public"
      def switch!(tenant = nil) = raise("Could not find schema #{tenant}")
    end
    stub_const("Apartment::Tenant", Module.new)
    stub_const("Apartment::Adapters::AbstractAdapter", adapter)
    described_class.install
  end

  after { Thread.current[DeployAngel::Redaction::TENANTS] = nil }

  it "notes each tenant before switching, even one that doesn't exist, but not the default" do
    adapter = Apartment::Adapters::AbstractAdapter.new
    expect { adapter.switch!("acme_lending") }.to raise_error("Could not find schema acme_lending")
    expect { adapter.switch!("public") }.to raise_error(RuntimeError)

    expect(DeployAngel::Redaction.current).to eq([ [ "acme_lending", "<tenant>" ] ])
  end

  it "installs once" do
    described_class.install

    expect(Apartment::Adapters::AbstractAdapter.ancestors.count(DeployAngel::Apartment::Switch)).to eq(1)
  end
end
