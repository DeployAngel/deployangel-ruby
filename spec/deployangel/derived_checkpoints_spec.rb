# frozen_string_literal: true

require "active_support"
require "active_support/notifications"

RSpec.describe DeployAngel::Rails::Checkpoints do
  let(:recorded) { [] }

  before do
    described_class.instance_variable_set(:@installed, nil)
    allow(DeployAngel).to receive(:checkpoint) { |name, **| recorded << name }
  end

  it "counts mail delivered and files stored from Rails' notifications, with nothing from the payload" do
    described_class.install
    described_class.install # once

    ActiveSupport::Notifications.instrument("deliver.action_mailer", mailer: "ReceiptMailer", to: [ "someone@example.com" ]) {}
    ActiveSupport::Notifications.instrument("service_upload.active_storage", key: "abc123", service: "S3", checksum: "x") {}
    ActiveSupport::Notifications.instrument("deliver.action_mailer", mailer: "ReceiptMailer") {}

    expect(recorded).to eq([ "rails.mail.delivered", "rails.storage.stored", "rails.mail.delivered" ])
  end

  it "is on unless turned off in the environment" do
    expect(DeployAngel::Configuration.new({}).derived_checkpoints).to be(true)
    expect(DeployAngel::Configuration.new({ "DEPLOYANGEL_DERIVED_CHECKPOINTS" => "false" }).derived_checkpoints).to be(false)
  end
end
