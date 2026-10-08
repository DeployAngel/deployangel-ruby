# frozen_string_literal: true

RSpec.describe DeployAngel::Configuration do
  it "reads settings from the environment" do
    config = described_class.new("DEPLOYANGEL_TOKEN" => "t", "DEPLOYANGEL_URL" => "https://x.test",
      "DEPLOYANGEL_REVISION" => "abc1234")

    expect(config.token).to eq("t")
    expect(config.endpoint).to eq("https://x.test")
    expect(config.revision).to eq("abc1234")
  end

  it "is active in every environment but development and test by default, and only with a token" do
    config = described_class.new("DEPLOYANGEL_TOKEN" => "t")

    expect(%w[production staging preview].map { |environment| config.active?(environment) }).to all(be(true))
    expect(config.active?("development")).to be(false)
    expect(config.active?("test")).to be(false)
    expect(described_class.new({}).active?("production")).to be(false)
  end

  it "reports only from the listed environments when they're set" do
    config = described_class.new("DEPLOYANGEL_TOKEN" => "t")
    config.environments = %w[production]

    expect(config.active?("production")).to be(true)
    expect(config.active?("staging")).to be(false)
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
