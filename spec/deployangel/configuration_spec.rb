# frozen_string_literal: true

RSpec.describe DeployAngel::Configuration do
  it "reads settings from the environment" do
    config = described_class.new("DEPLOYANGEL_TOKEN" => "t", "DEPLOYANGEL_URL" => "https://x.test",
      "DEPLOYANGEL_REVISION" => "abc1234")

    expect(config.token).to eq("t")
    expect(config.endpoint).to eq("https://x.test")
    expect(config.revision).to eq("abc1234")
  end

  it "is active only in production by default, and only with a token" do
    config = described_class.new("DEPLOYANGEL_TOKEN" => "t")

    expect(config.active?("production")).to be(true)
    expect(config.active?("development")).to be(false)
    expect(described_class.new({}).active?("production")).to be(false)
  end

  it "sends exception messages unless DEPLOYANGEL_EXCEPTION_MESSAGES turns them off" do
    expect(described_class.new({}).exception_messages).to be(true)
    expect(described_class.new("DEPLOYANGEL_EXCEPTION_MESSAGES" => "false").exception_messages).to be(false)
  end

  it "defaults to the hosted API" do
    expect(described_class.new({}).endpoint).to eq("https://api.deployangel.com")
  end

  it "can be forced on or off" do
    base = { "DEPLOYANGEL_TOKEN" => "t", "DEPLOYANGEL_URL" => "https://x.test" }

    expect(described_class.new(base.merge("DEPLOYANGEL_ENABLED" => "true")).active?("development")).to be(true)
    expect(described_class.new(base.merge("DEPLOYANGEL_ENABLED" => "0")).active?("production")).to be(false)
  end
end
